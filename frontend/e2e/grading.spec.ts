import { expect, test, type Page, type Route } from "@playwright/test";

const result = { overallScore: 80, feedback: "A clear comparative argument.", criteria: {
  interpretation: { score: 90, feedback: "Distinguishes authorial voices.", normalizedWeight: 0.5 },
  evidence: { score: 70, feedback: "Discuss specific passages.", normalizedWeight: 0.5 }
} };

async function setup(page: Page) {
  const essays = ["Religion", "Another Essay"].map((title) => ({ path: [title], title, markdown: "Saved draft.", prompt: "" }));
  const state = { pending: null as Route | null, requests: [] as unknown[], contextError: false, rubric: true };
  await page.addInitScript(() => localStorage.setItem("essay-account-id", "alice"));
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.pathname.endsWith("/accounts")) return route.fulfill({ json: [{ accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: "gpt-6.1-sol" }] });
    if (url.pathname.endsWith("/workspace")) return route.fulfill({ json: { tree: essays.map((essay) => ({ name: essay.title, path: essay.path, nodeType: "WorkspaceEssayNode", children: [] })) } });
    if (url.pathname.endsWith("/context/effective")) return route.fulfill(state.contextError
      ? { status: 422, json: { error: { message: "Invalid parent context." } } }
      : { json: { title: "Inherited settings", audience: null, model: null, tags: [], instructions: [], grading_directions: [], rubric: state.rubric ? { interpretation: { weight: 1, description: null }, evidence: { weight: 1, description: null } } : {} } });
    if (url.pathname.endsWith("/context")) return route.fulfill({ status: 404, json: { error: { message: "Context does not exist." } } });
    if (url.pathname.endsWith("/ai/grade")) {
      state.requests.push(request.postDataJSON());
      state.pending = route;
      return;
    }
    const essay = essays.find((item) => decodeURIComponent(url.pathname).endsWith(`/essays/${item.title}`));
    if (essay) {
      if (request.method() === "PUT") Object.assign(essay, request.postDataJSON());
      return route.fulfill({ json: essay });
    }
    return route.fulfill({ status: 404 });
  });
  await page.goto("/");
  await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("Saved draft.");
  return state;
}

for (const width of [390, 1280]) {
  test(`grading inherited rubric shows results and keeps new edits at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await setup(page);
    await page.getByRole("button", { name: "Grade essay", exact: true }).click();
    await expect.poll(() => !!state.pending).toBe(true);
    expect(state.requests).toEqual([{ path: "Religion" }]);
    await expect(page.getByRole("tab", { name: "Feedback", exact: true })).toHaveAttribute("aria-selected", "true");
    await expect(page.getByRole("button", { name: "Grading…", exact: true })).toBeDisabled();
    const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
    await draft.fill("Draft edited while waiting.");
    await state.pending!.fulfill({ json: result });
    const feedback = page.getByRole("region", { name: "Essay grading feedback" });
    await expect(feedback.getByText("80 / 100", { exact: true })).toBeVisible();
    await expect(feedback.getByRole("article", { name: "Feedback for evidence" })).toContainText("70 / 100 · Weight: 50%");
    await expect(feedback.getByText(/earlier saved inputs/)).toBeVisible();
    await expect(draft).toHaveValue("Draft edited while waiting.");
    await expect(page.getByRole("button", { name: "Grade essay", exact: true })).toBeDisabled();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}

test("grading recovers from provider errors and missing inherited rubric", async ({ page }) => {
  const state = await setup(page);
  const grade = page.getByRole("button", { name: "Grade essay", exact: true });
  await grade.click();
  await expect.poll(() => !!state.pending).toBe(true);
  await state.pending!.fulfill({ status: 504, body: "The AI provider request timed out. Retry or choose a faster model." });
  await expect(page.getByRole("alert")).toContainText("timed out");
  state.pending = null;
  await grade.click();
  await expect.poll(() => !!state.pending).toBe(true);
  await state.pending!.fulfill({ json: result });
  await expect(page.getByText("A clear comparative argument.")).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);

  await page.getByRole("tab", { name: "Context", exact: true }).click();
  state.rubric = false;
  await page.getByRole("button", { name: "Refresh preview", exact: true }).click();
  await expect(page.getByText(/Add at least one rubric criterion/)).toBeVisible();
  await expect(grade).toBeDisabled();
  state.rubric = true;
  await page.getByRole("button", { name: "Refresh preview", exact: true }).click();
  await expect(grade).toBeEnabled();
});
