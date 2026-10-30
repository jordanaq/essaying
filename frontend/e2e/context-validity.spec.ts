import { expect, test } from "@playwright/test";

test("context validity gates grading while editing, saving, and collapsed-panel recovery remain usable", async ({ page }) => {
  const context = { title: "Saved settings", audience: null, model: "gpt-6.1-sol", tags: [], instructions: [], grading_directions: [], rubric: { clarity: { weight: 1, description: null } } };
  const essays = ["First Essay", "Second Essay"].map((name) => ({ path: [name], title: name, prompt: "", markdown: `# ${name}` }));
  let firstReads = 0;
  let repaired = false;
  let savedMarkdown: string | undefined;
  let releaseInitial: (() => Promise<void>) | undefined;
  let releaseStale: (() => Promise<void>) | undefined;
  await page.addInitScript(() => localStorage.setItem("essay-account-id", "alice"));
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.pathname === "/api/v1/accounts") {
      await route.fulfill({ json: [{ accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: null }] });
    } else if (url.pathname.endsWith("/workspace")) {
      await route.fulfill({ json: { tree: essays.map((essay) => ({ name: essay.title, path: essay.path, nodeType: "WorkspaceEssayNode", children: [] })) } });
    } else if (url.pathname.endsWith("/context/effective")) {
      if (url.searchParams.get("path") === "First Essay") {
        firstReads += 1;
        if (firstReads === 1) releaseInitial = () => route.fulfill({ json: context });
        else releaseStale = () => route.fulfill({ json: { ...context, title: "Stale first essay" } });
      } else {
        await route.fulfill(repaired ? { json: { ...context, title: "Repaired settings" } }
          : { status: 422, json: { error: { message: "Invalid ancestor context." } } });
      }
    } else if (url.pathname.endsWith("/context")) {
      await route.fulfill({ status: 404, json: { error: { message: "Context does not exist." } } });
    } else if (url.pathname.endsWith("/ai/grade")) {
      await route.fulfill({ json: { overallScore: 80, feedback: "Real grading response.", criteria: { clarity: { score: 80, feedback: "Clear argument.", normalizedWeight: 1 } } } });
    } else {
      const essay = essays.find((item) => decodeURIComponent(url.pathname).endsWith(`/essays/${item.title}`));
      if (essay) {
        if (request.method() === "PUT") savedMarkdown = request.postDataJSON().markdown;
        await route.fulfill({ json: { ...essay, markdown: savedMarkdown ?? essay.markdown } });
      } else await route.fulfill({ status: 404 });
    }
  });

  await page.goto("/");
  const grade = page.locator("sl-button").filter({ hasText: "Grade essay" });
  await expect.poll(() => !!releaseInitial).toBe(true);
  await expect(grade).toHaveJSProperty("disabled", true);
  await releaseInitial!();
  await expect(grade).toHaveJSProperty("disabled", false);
  await grade.click();
  await expect(page.getByText("Real grading response.", { exact: true })).toBeVisible();
  await page.getByRole("tab", { name: "Context", exact: true }).click();

  await page.getByRole("button", { name: "Refresh preview" }).click();
  await expect.poll(() => !!releaseStale).toBe(true);
  await expect(grade).toHaveJSProperty("disabled", true);
  const feedbackPanel = page.locator("sl-card").filter({ has: page.getByRole("tablist", { name: "Context and feedback" }) });
  await feedbackPanel.locator("sl-button").filter({ hasText: "Collapse" }).click();
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await expect(page.getByText("Currently editing Second Essay.", { exact: true })).toBeVisible();
  await expect(page.getByText(/Grading is unavailable/)).toBeVisible();
  await releaseStale!();
  await expect(grade).toHaveJSProperty("disabled", true);

  const editor = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
  await editor.fill("# Still editable with broken context");
  await page.getByText("Save Draft", { exact: true }).click();
  await expect.poll(() => savedMarkdown).toBe("# Still editable with broken context");
  await expect(page.getByText("Draft saved for Second Essay", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Expand context and feedback" }).click();
  await expect(page.getByRole("alert")).toHaveText("Invalid ancestor context.");
  repaired = true;
  await page.getByRole("button", { name: "Retry preview" }).click();
  await expect(page.getByText("Repaired settings", { exact: true })).toBeVisible();
  await expect(grade).toHaveJSProperty("disabled", false);
  await expect(editor).toHaveValue("# Still editable with broken context");
});
