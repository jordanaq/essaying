import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.goto("/e2e/fixtures/markdown-editor.html");
});

test("renders both editors by default and switches views without edits", async ({ page }, testInfo) => {
  const draft = page.getByRole("textbox", { name: "Draft", exact: true });
  await expect(draft.getByRole("heading", { name: "An argument" })).toBeVisible();
  await expect(draft.locator("ul li")).toHaveCount(2);
  await expect(draft.locator("ol li")).toHaveCount(2);
  await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveAttribute("contenteditable", "true");
  await page.screenshot({ path: testInfo.outputPath("markdown-editor.png"), fullPage: true });
  const toggle = page.getByRole("button", { name: "Raw Markdown for Draft", exact: true });
  await toggle.click();
  await expect(draft).toHaveValue(/# An argument/);
  await toggle.click();
  await expect(draft).toHaveAttribute("contenteditable", "true");
  await expect(page.getByRole("status", { name: "Edit count" })).toHaveText("0 edits");
});

test("bold and italic shortcuts update Markdown and undo survives a mode switch", async ({ page }) => {
  const draft = page.getByRole("textbox", { name: "Draft", exact: true });
  await draft.fill("A strong argument");
  await draft.press("ControlOrMeta+a");
  await draft.press("ControlOrMeta+b");
  await expect(draft.locator("strong")).toHaveText("A strong argument");
  const toggle = page.getByRole("button", { name: "Raw Markdown for Draft", exact: true });
  await toggle.click();
  // Replacing the heading's text keeps its block style, as normal rich editing does.
  await expect(draft).toHaveValue("# **A strong argument**");
  await toggle.click();
  await draft.press("ControlOrMeta+z");
  await expect(draft.locator("strong")).toHaveCount(0);
  await draft.press("ControlOrMeta+Shift+z");
  await expect(draft.locator("strong")).toHaveText("A strong argument");
  await draft.press("ControlOrMeta+i");
  await expect(draft.locator("em")).toHaveText("A strong argument");
});

test("toolbar bold preserves the text selection", async ({ page }) => {
  const draft = page.getByRole("textbox", { name: "Draft", exact: true });
  await draft.fill("Selected words");
  await draft.press("ControlOrMeta+a");
  const formatting = page.getByRole("group", { name: "Draft formatting", exact: true });
  await formatting.getByRole("button", { name: "Bold", exact: true }).click();
  await expect(draft.locator("strong")).toHaveText("Selected words");
  await expect(formatting.getByRole("button", { name: "Bold", exact: true })).toHaveAttribute("aria-pressed", "true");
});

for (const [name, tag] of [["Bulleted list", "ul"], ["Numbered list", "ol"]] as const) {
  test(`${name} continues on Enter and exits on an empty item`, async ({ page }) => {
    const draft = page.getByRole("textbox", { name: "Draft", exact: true });
    await draft.fill("First item");
    await page.getByRole("group", { name: "Draft formatting", exact: true }).getByRole("button", { name, exact: true }).click();
    await draft.press("End");
    await draft.press("Enter");
    await page.keyboard.type("Second item");
    await expect(draft.locator(`${tag} li`)).toHaveText(["First item", "Second item"]);
    await draft.press("Enter");
    await draft.press("Enter");
    await page.keyboard.type("After the list");
    await expect(draft.locator(":scope > p")).toHaveText("After the list");
  });
}

test("raw edits render and stay independent of the assignment", async ({ page }) => {
  const draft = page.getByRole("textbox", { name: "Draft", exact: true });
  const toggle = page.getByRole("button", { name: "Raw Markdown for Draft", exact: true });
  await toggle.click();
  await draft.fill("## Revised\n\n1. First\n2. Second");
  await toggle.click();
  await expect(draft.getByRole("heading", { name: "Revised", level: 2 })).toBeVisible();
  await expect(draft.locator("ol li")).toHaveCount(2);
  await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveText("Explain your position and support it with evidence.");
});

test("loads a replacement without allowing undo into the previous document", async ({ page }) => {
  const draft = page.getByRole("textbox", { name: "Draft", exact: true });
  await draft.fill("An old unsaved edit");
  await page.getByRole("button", { name: "Load another draft" }).click();
  await draft.press("ControlOrMeta+z");
  await expect(draft.getByRole("heading", { name: "Another essay" })).toBeVisible();
  await expect(draft).not.toContainText("An old unsaved edit");
});
