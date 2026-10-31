import { expect, test } from "@playwright/test";
import { useRawEditors } from "./support/editors";

test("edit folder context and preview inheritance through the live API", async ({ page, request }) => {
  const accountId = `e2e-context-${Date.now()}`;
  const base = `/api/v1/accounts/${accountId}/workspace`;
  try {
    expect((await request.post("/api/v1/accounts", { data: { displayName: accountId, preferredModel: null } })).ok()).toBeTruthy();
    expect((await request.post(`${base}/directories`, { data: { parentPath: [], directoryName: "History" } })).ok()).toBeTruthy();
    expect((await request.post(`${base}/essays`, { data: { parentPath: ["History"], essayName: "draft", markdown: "# Draft" } })).ok()).toBeTruthy();
    expect((await request.post(`${base}/context`, { data: { path: "context.json", contextLayer: {
      audience: { tag: "SetScalar", contents: "Students" }, instructions: { tag: "AppendList", contents: ["Use sources."] }
    } } })).ok()).toBeTruthy();
    await page.addInitScript((id) => localStorage.setItem("essay-account-id", id), accountId);
    await page.goto("/");
    await useRawEditors(page);
    const panel = page.getByRole("region", { name: "Writing context" });
    await expect(panel.getByLabel("Edit settings for")).toHaveValue("History/draft");
    await expect(panel.getByLabel("Edit settings for").locator("option")).toHaveText([
      "Workspace root", "History", "History/draft (this essay)"
    ]);
    await expect(panel.getByRole("button", { name: "Create context" })).toBeEnabled();
    await expect(panel.getByText("Students", { exact: true })).toBeVisible();
    await panel.getByLabel("Title behavior").selectOption("SetScalar");
    await panel.getByRole("textbox", { name: "Title", exact: true }).fill("Causes of change");
    await panel.getByLabel("Rubric behavior").selectOption("MergeRubric");
    await panel.getByRole("button", { name: "Add criterion" }).click();
    await panel.getByLabel("Criterion 1 name").fill("evidence");
    await panel.getByLabel("Criterion 1 weight").fill("0.6");
    await panel.getByLabel("Criterion 1 description").fill("Support claims with sources.");
    await panel.getByRole("button", { name: "Create context" }).click();
    await expect(panel.getByText("Context saved.", { exact: true })).toBeVisible();
    await expect(panel.locator("dd").filter({ hasText: "Causes of change" })).toBeVisible();
    await expect(panel.getByText("Use sources.", { exact: true })).toBeVisible();
    await expect(panel.getByRole("table")).toContainText("Support claims with sources.");
    const ownLayer = await request.get(`${base}/context?path=History%2Fdraft%2Fcontext.json`);
    expect((await ownLayer.json()).title).toEqual({ tag: "SetScalar", contents: "Causes of change" });
    const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
    const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
    await expect(prompt).toHaveValue("");
    await prompt.fill("Compare short-term and long-term causes.");
    await draft.fill("# Unsaved response");
    await page.getByText("Save Prompt", { exact: true }).click();
    await expect(page.getByText("Prompt saved.", { exact: true })).toBeVisible();
    await expect(draft).toHaveValue("# Unsaved response");
    let savedEssay = await request.get(`${base}/essays/History/draft`);
    expect(await savedEssay.json()).toMatchObject({ prompt: "Compare short-term and long-term causes.", markdown: "# Draft" });
    await page.getByText("Save Draft", { exact: true }).click();
    await expect(page.getByText("Draft saved.", { exact: true })).toBeVisible();
    savedEssay = await request.get(`${base}/essays/History/draft`);
    expect(await savedEssay.json()).toMatchObject({ prompt: "Compare short-term and long-term causes.", markdown: "# Unsaved response" });
    await page.reload();
    await useRawEditors(page);
    await expect(prompt).toHaveValue("Compare short-term and long-term causes.");
    await expect(draft).toHaveValue("# Unsaved response");
    await expect(panel.getByRole("textbox", { name: "Title", exact: true })).toHaveValue("Causes of change");
    // Update saved settings outside the UI, then refresh only the effective preview.
    expect((await request.put(`${base}/context`, { data: { path: "context.json", contextLayer: {
      audience: { tag: "SetScalar", contents: "Researchers" }, instructions: { tag: "AppendList", contents: ["Use sources."] }
    } } })).ok()).toBeTruthy();
    await panel.getByRole("button", { name: "Refresh preview" }).click();
    await expect(panel.getByText("Researchers", { exact: true })).toBeVisible();
    await page.screenshot({ path: "/tmp/essaying-context-desktop.png", fullPage: true });
    await panel.getByLabel("Title behavior").selectOption("ClearScalar");
    await panel.getByRole("button", { name: "Save context" }).click();
    await expect(panel.locator("dd").first()).toHaveText("Not set");
    await panel.getByRole("button", { name: "Remove layer" }).click();
    await panel.getByRole("button", { name: "Confirm removal" }).click();
    await expect(panel.getByText("Layer removed. Parent settings now apply.")).toBeVisible();
    await expect(panel.getByText("Researchers", { exact: true })).toBeVisible();
    await expect(panel.getByText("No criteria set.", { exact: true })).toBeVisible();
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(panel.getByLabel("Title behavior")).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: "/tmp/essaying-context-mobile.png", fullPage: true });
  } finally {
    const cleanup = await request.delete(`/api/v1/accounts/${accountId}`);
    expect([204, 404]).toContain(cleanup.status());
  }
});
