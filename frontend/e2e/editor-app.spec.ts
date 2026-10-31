import { expect, test, type Page, type Route } from "@playwright/test";
import type { Editor } from "@tiptap/core";

const fields = [
  { label: "Essay Markdown", field: "markdown", name: "Draft", sibling: "Assignment prompt" },
  { label: "Assignment prompt", field: "prompt", name: "Prompt", sibling: "Essay Markdown" }
] as const;
type Essay = { path: string[]; title: string; markdown: string; prompt: string };

async function setup(page: Page) {
  const accounts = new Map(["alice", "bob"].map((id) => [id, ["First Essay", "Second Essay"].map((title) => ({
    title, path: [title], markdown: "A draft", prompt: "An assignment"
  }))]));
  const state = {
    failSave: false, holdSave: false,
    writes: [] as Record<string, string>[],
    pending: null as null | { route: Route; essay: Essay; body: Record<string, string>; snapshot: Essay }
  };
  async function finishSave() {
    const pending = state.pending!;
    Object.assign(pending.essay, pending.body);
    state.pending = null;
    await pending.route.fulfill({ json: { ...pending.snapshot, ...pending.body } });
  }
  await page.addInitScript(() => localStorage.setItem("essay-account-id", "alice"));
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = decodeURIComponent(url.pathname);
    const essays = accounts.get(path.split("/")[4] ?? "") ?? [];
    if (path === "/api/v1/accounts") return route.fulfill({ json: ["alice", "bob"].map((id) => ({
      accountId: { unAccountId: id }, displayName: id, preferredModel: "gpt-6.1-sol"
    })) });
    if (path.endsWith("/workspace")) return route.fulfill({ json: { tree: essays.map((essay) => ({
      name: essay.title, path: essay.path, nodeType: "WorkspaceEssayNode", children: []
    })) } });
    if (path.endsWith("/context/effective")) return route.fulfill({ json: {
      title: null, audience: null, model: null, tags: [], instructions: [], grading_directions: [],
      rubric: { clarity: { weight: 1, description: null } }
    } });
    if (path.endsWith("/context")) return route.fulfill({ status: 404, json: { error: { message: "Context does not exist." } } });
    if (path.endsWith("/ai/prompt")) return route.fulfill({ json: { prompts: ["## Generated assignment\n\n1. Compare\n2. Support"] } });
    const essay = essays.find((item) => path.endsWith(`/essays/${item.title}`));
    if (!essay) return route.fulfill({ status: 404 });
    if (request.method() !== "PUT") return route.fulfill({ json: essay });
    const body = request.postDataJSON();
    state.writes.push(body);
    if (state.failSave) return route.fulfill({ status: 500, json: { error: { message: "Disk is full." } } });
    state.pending = { route, essay, body, snapshot: { ...essay } };
    if (!state.holdSave) await finishSave();
  });
  await page.goto("/");
  await expect(page.getByText("Currently editing First Essay.", { exact: true })).toBeVisible();
  return { state, finishSave, accounts };
}

const editorFor = (page: Page, label: string) => page.getByRole("textbox", { name: label, exact: true });
const toggleFor = (page: Page, label: string) => page.getByRole("button", { name: `Raw Markdown for ${label}`, exact: true });
const toolbarFor = (page: Page, label: string) => page.getByRole("group", { name: `${label} formatting`, exact: true });

for (const { label, field, name, sibling } of fields) {
  test(`${name}: toolbar formats text, every heading, both lists, and undo/redo`, async ({ page }, testInfo) => {
    await setup(page);
    const editor = editorFor(page, label);
    const toolbar = toolbarFor(page, label);
    await expect(editor).toHaveAttribute("contenteditable", "true");
    if (field === "markdown") await page.screenshot({ path: testInfo.outputPath("default-editors.png"), fullPage: true });
    await editor.fill("Selected words");
    await editor.press("ControlOrMeta+a");
    await toolbar.getByRole("button", { name: "Bold", exact: true }).click();
    await expect(editor.locator("strong")).toHaveText("Selected words");
    await expect(toolbar.getByRole("button", { name: "Bold", exact: true })).toHaveAttribute("aria-pressed", "true");
    await toolbar.getByRole("button", { name: "Italic", exact: true }).click();
    await expect(editor.locator("em")).toHaveText("Selected words");
    await toolbar.getByRole("button", { name: "Undo", exact: true }).click();
    await expect(editor.locator("em")).toHaveCount(0);
    await toolbar.getByRole("button", { name: "Redo", exact: true }).click();
    await expect(editor.locator("em")).toHaveText("Selected words");
    for (const level of [1, 2, 3, 4, 5, 6]) {
      await toolbar.getByRole("combobox").selectOption(String(level));
      await expect(editor.getByRole("heading", { level })).toHaveText("Selected words");
    }
    await toolbar.getByRole("combobox").selectOption("0");
    await expect(editor.locator(":scope > p")).toHaveText("Selected words");
    for (const [button, tag] of [["Bulleted list", "ul"], ["Numbered list", "ol"]] as const) {
      await toolbar.getByRole("button", { name: button, exact: true }).click();
      await expect(editor.locator(`${tag} li`)).toHaveText("Selected words");
      await expect(toolbar.getByRole("button", { name: button, exact: true })).toHaveAttribute("aria-pressed", "true");
    }
    await toolbar.getByRole("button", { name: "Numbered list", exact: true }).click();
    await expect(editor.locator("ol, ul")).toHaveCount(0);
    await expect(page.getByRole("status", { name: `${name} save status` })).toHaveText(`Unsaved ${name.toLowerCase()} changes`);
    await expect(editorFor(page, sibling)).toHaveText(field === "markdown" ? "An assignment" : "A draft");
  });

  for (const platform of ["Control", "Meta"] as const) {
    test(`${name}: ${platform} formatting, heading/list, and undo/redo hotkeys`, async ({ page }) => {
      if (platform === "Meta") {
        // Select the editor library's Mac keymap before it loads; the runner is Linux.
        await page.addInitScript(() => Object.defineProperty(navigator, "platform", { get: () => "MacIntel" }));
      }
      await setup(page);
      const editor = editorFor(page, label);
      await editor.fill("Keyboard formatting");
      await editor.press(`${platform}+a`);
      await editor.press(`${platform}+b`);
      await expect(editor.locator("strong")).toHaveText("Keyboard formatting");
      await toggleFor(page, label).click();
      await expect(editor).toHaveValue("**Keyboard formatting**");
      await toggleFor(page, label).click();
      await editor.press(`${platform}+z`);
      await expect(editor.locator("strong")).toHaveCount(0);
      await editor.press(`${platform}+Shift+z`);
      await expect(editor.locator("strong")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+i`);
      await expect(editor.locator("em")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+i`);
      await editor.press(`${platform}+b`);
      await expect(editor.locator("em, strong")).toHaveCount(0);
      for (const level of [1, 2, 3, 4, 5, 6]) {
        await editor.press(`${platform}+Alt+${level}`);
        await expect(editor.getByRole("heading", { level })).toHaveText("Keyboard formatting");
      }
      await editor.press(`${platform}+Alt+0`);
      await expect(editor.locator(":scope > p")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+Shift+8`);
      await expect(editor.locator("ul li")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+Shift+7`);
      await expect(editor.locator("ol li")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+Shift+7`);
      await editor.press(`${platform}+Shift+s`);
      await expect(editor.locator("s")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+Shift+s`);
      await editor.press(`${platform}+e`);
      await expect(editor.locator("code")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+e`);
      await editor.press(`${platform}+Shift+b`);
      await expect(editor.locator("blockquote")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+Shift+b`);
      await editor.press(`${platform}+Alt+c`);
      await expect(editor.locator("pre code")).toHaveText("Keyboard formatting");
      await editor.press(`${platform}+Alt+c`);
      await expect(editor.locator("pre")).toHaveCount(0);
      await expect(page.getByRole("status", { name: `${name} save status` })).toHaveText(`Unsaved ${name.toLowerCase()} changes`);
    });
  }

  for (const [prefix, tag] of [["- ", "ul"], ["1. ", "ol"]] as const) {
    test(`${name}: ${tag} typing shortcut, Enter, Tab/Shift+Tab, and exiting the list`, async ({ page }) => {
      await setup(page);
      const editor = editorFor(page, label);
      await editor.fill("");
      await page.keyboard.type(`${prefix}First`);
      await expect(editor.locator(`${tag} li`)).toHaveText(["First"]);
      await editor.press("Enter");
      await page.keyboard.type("Second");
      await expect(editor.locator(`${tag} > li`)).toHaveCount(2);
      await editor.press("Tab");
      await expect(editor.locator(`${tag} > li > ${tag} > li`)).toHaveText("Second");
      await editor.press("Shift+Tab");
      await expect(editor.locator(`${tag} > li`)).toHaveText(["First", "Second"]);
      await editor.press("Enter");
      await editor.press("Enter");
      await page.keyboard.type("After the list");
      await editor.press("Shift+Enter");
      await page.keyboard.type("A soft break");
      await expect(editor.locator(":scope > p")).toHaveText("After the listA soft break");
      await expect(editor.locator(":scope > p > br")).toHaveCount(1);
      await toggleFor(page, label).click();
      await expect(editor).toHaveValue(new RegExp(`${tag === "ul" ? "-" : "1\\."} First`));
    });
  }

  test(`${name}: raw toggle preserves exact source, supports edits, and does not dirty saved content`, async ({ page }) => {
    const { state } = await setup(page);
    const editor = editorFor(page, label);
    const toggle = toggleFor(page, label);
    const status = page.getByRole("status", { name: `${name} save status` });
    await toggle.click();
    await toggle.click();
    await expect(status).toHaveText(`${name} saved`);
    expect(state.writes).toEqual([]);
    await toggle.click();
    const raw = "Heading\n=======\n\n__bold__ and *italic*\n\n* A bullet\n\n3. A number\n\n";
    await editor.fill(raw);
    await toggle.click();
    await expect(editor.getByRole("heading", { level: 1 })).toHaveText("Heading");
    await expect(editor.locator("strong")).toHaveText("bold");
    await expect(editor.locator("ul li")).toHaveText("A bullet");
    await expect(editor.locator("ol")).toHaveAttribute("start", "3");
    await toggle.click();
    await expect(editor).toHaveValue(raw);
    await page.getByRole("button", { name: `Save ${name}`, exact: true }).click();
    await expect(status).toHaveText(`${name} saved.`);
    expect(state.writes).toEqual([{ [field]: raw }]);
    await page.reload();
    await expect(editor).toHaveAttribute("contenteditable", "true");
    await expect(editor.getByRole("heading", { name: "Heading" })).toBeVisible();
    await expect(status).toHaveText(`${name} saved`);
  });

  test(`${name}: rendered Markdown saves independently and survives failure, retry, and reload`, async ({ page }) => {
    const { state } = await setup(page);
    const editor = editorFor(page, label);
    const other = editorFor(page, sibling);
    await editor.fill("Formatted edit");
    await editor.press("ControlOrMeta+a");
    await editor.press("ControlOrMeta+b");
    await other.fill("Unsaved sibling");
    state.failSave = true;
    await page.getByRole("button", { name: `Save ${name}`, exact: true }).click();
    await expect(page.getByRole("alert")).toContainText("Disk is full.");
    await expect(editor.locator("strong")).toHaveText("Formatted edit");
    await expect(other).toHaveText("Unsaved sibling");
    state.failSave = false;
    await page.getByRole("button", { name: `Save ${name}`, exact: true }).click();
    await expect(page.getByRole("status", { name: `${name} save status` })).toHaveText(`${name} saved.`);
    expect(state.writes).toEqual([{ [field]: "**Formatted edit**" }, { [field]: "**Formatted edit**" }]);
    await expect(other).toHaveText("Unsaved sibling");
    await page.getByRole("button", { name: field === "markdown" ? "Discard prompt changes" : "Discard draft changes", exact: true }).click();
    await page.reload();
    await expect(editor.locator("strong")).toHaveText("Formatted edit");
    await expect(other).toHaveText(field === "markdown" ? "An assignment" : "A draft");
  });

  test(`${name}: an in-flight save preserves newer rendered edits and sibling edits`, async ({ page }) => {
    const { state, finishSave } = await setup(page);
    const editor = editorFor(page, label);
    await editor.fill("First edit");
    await editor.press("ControlOrMeta+a");
    await editor.press("ControlOrMeta+b");
    state.holdSave = true;
    await page.getByRole("button", { name: `Save ${name}`, exact: true }).click();
    await expect.poll(() => !!state.pending).toBe(true);
    await expect(editor.locator("strong")).toHaveText("First edit");
    await editor.click();
    await editor.press("ControlOrMeta+End");
    expect(await editor.evaluate(() => ({ collapsed: getSelection()?.isCollapsed, selection: getSelection()?.toString() })))
      .toMatchObject({ collapsed: true });
    // Chromium delivers native caret moves through an asynchronous selectionchange.
    // Wait for the editor to receive it before typing at automation speed.
    await expect.poll(() => editor.evaluate((element) => {
      const { state } = (element as HTMLElement & { editor: Editor }).editor;
      return state.selection.empty && state.selection.to === state.doc.content.size - 1;
    })).toBe(true);
    await page.keyboard.type(" plus a newer edit");
    await expect(editor).toHaveText("First edit plus a newer edit");
    await editorFor(page, sibling).fill("Sibling edit");
    await expect(editor).toHaveText("First edit plus a newer edit");
    await finishSave();
    await expect(editor.locator("strong")).toHaveText("First edit plus a newer edit");
    await expect(editorFor(page, sibling)).toHaveText("Sibling edit");
    await expect(page.getByRole("status", { name: `${name} save status` })).toHaveText(`Unsaved ${name.toLowerCase()} changes`);
    expect(state.writes).toEqual([{ [field]: "**First edit**" }]);
  });

  test(`${name}: unsupported formatting stays intact in raw mode and can be repaired`, async ({ page }) => {
    await setup(page);
    const editor = editorFor(page, label);
    const toggle = toggleFor(page, label);
    await toggle.click();
    for (const raw of ["| A | B |\n| - | - |\n| C | D |", "![Image](image.png)", "- [ ] A task", "<!-- Keep this -->\n\nA paragraph"]) {
      await editor.fill(raw);
      await expect(editor).toHaveValue(raw);
      await expect(toggle).toBeDisabled();
      await expect(page.getByRole("region", { name: `${label} editor`, exact: true }).getByRole("status"))
        .toContainText("raw Markdown editing to preserve it");
    }
    await editor.fill("**Repaired**");
    await toggle.click();
    await expect(editor.locator("strong")).toHaveText("Repaired");
  });

  test(`${name}: renders links, quotes, code, and rules without following links while editing`, async ({ page }) => {
    await setup(page);
    const editor = editorFor(page, label);
    await toggleFor(page, label).click();
    const markdown = "> A quotation\n\n`inline code` and ~~removed text~~\n\n```text\nA code block\n```\n\n---\n\n[Example](https://example.com)";
    await editor.fill(markdown);
    await toggleFor(page, label).click();
    await expect(editor.locator("blockquote")).toHaveText("A quotation");
    await expect(editor.locator("p code")).toHaveText("inline code");
    await expect(editor.locator("s")).toHaveText("removed text");
    await expect(editor.locator("pre code")).toHaveText("A code block");
    await expect(editor.locator("hr")).toHaveCount(1);
    await editor.getByRole("link", { name: "Example", exact: true }).click();
    await expect(page).toHaveURL(/\/$/);
    await toggleFor(page, label).click();
    await expect(editor).toHaveValue(markdown);
  });
}

test("rendered edits guard navigation and discard resets formatting and history", async ({ page }) => {
  await setup(page);
  const draft = editorFor(page, "Essay Markdown");
  await draft.fill("Changed draft");
  await draft.press("ControlOrMeta+a");
  await draft.press("ControlOrMeta+b");
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await expect(draft.locator("strong")).toHaveText("Changed draft");
  await page.getByRole("button", { name: "Discard draft changes", exact: true }).click();
  await expect(draft).toHaveText("A draft");
  await expect(toolbarFor(page, "Essay Markdown").getByRole("button", { name: "Undo", exact: true })).toBeDisabled();
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await draft.press("ControlOrMeta+z");
  await expect(draft).toHaveText("A draft");
});

test("generated Markdown adoption renders, focuses the assignment, and preserves the draft", async ({ page }) => {
  const { state } = await setup(page);
  const draft = editorFor(page, "Essay Markdown");
  await draft.fill("Keep my draft");
  await page.getByText("Generate prompts", { exact: true }).click();
  await page.getByRole("button", { name: "Generate", exact: true }).click();
  await page.getByRole("button", { name: "Use prompt option 1" }).click();
  const prompt = editorFor(page, "Assignment prompt");
  await expect(prompt.getByRole("heading", { name: "Generated assignment" })).toBeVisible();
  await expect(prompt.locator("ol li")).toHaveText(["Compare", "Support"]);
  await expect(prompt).toBeFocused();
  await expect(draft).toHaveText("Keep my draft");
  await page.getByRole("button", { name: "Save Prompt", exact: true }).click();
  await expect(page.getByRole("status", { name: "Prompt save status" })).toHaveText("Prompt saved.");
  expect(state.writes).toEqual([{ prompt: "## Generated assignment\n\n1. Compare\n2. Support" }]);
});

test("same-content document switches clear formatting history and folders disable the editors", async ({ page }) => {
  const { state } = await setup(page);
  const draft = editorFor(page, "Essay Markdown");
  await draft.press("ControlOrMeta+a");
  await draft.press("ControlOrMeta+b");
  await draft.press("ControlOrMeta+b");
  await expect(draft).toHaveText("A draft");
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await expect(page.getByText("Currently editing Second Essay.", { exact: true })).toBeVisible();
  await expect(toolbarFor(page, "Essay Markdown").getByRole("button", { name: "Undo", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Log Out", exact: true }).click();
  await page.getByRole("button", { name: "bob", exact: true }).click();
  await expect(page.getByText("Logged in as bob (bob)", { exact: true })).toBeVisible();
  await expect(draft).toHaveText("A draft");
  await expect(toolbarFor(page, "Essay Markdown").getByRole("button", { name: "Undo", exact: true })).toBeDisabled();
  await page.locator('.tree-item-name[title="Workspace"]').click();
  for (const { label } of fields) {
    await expect(editorFor(page, label)).toHaveAttribute("contenteditable", "false");
    await expect(toggleFor(page, label)).toBeDisabled();
    await expect(toolbarFor(page, label).getByRole("button", { name: "Bold", exact: true })).toBeDisabled();
  }
  expect(state.writes).toEqual([]);
});

for (const width of [320, 390, 1280]) {
  test(`editors collapse independently and preserve rendered/raw edits at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const { state } = await setup(page);
    const prompt = editorFor(page, "Assignment prompt");
    const draft = editorFor(page, "Essay Markdown");
    const promptHeader = page.locator('summary[aria-label="Assignment prompt section"]');
    const draftHeader = page.locator('summary[aria-label="Essay draft section"]');
    await expect(prompt).toBeVisible();
    await expect(draft).toBeVisible();
    await draft.fill("Focus on this draft");
    await draft.press("ControlOrMeta+a");
    await draft.press("ControlOrMeta+b");
    await toggleFor(page, "Assignment prompt").click();
    await prompt.fill("**Unsaved assignment**");

    const expandedHeight = (await promptHeader.locator("..").boundingBox())!.height;
    await promptHeader.click();
    await expect(prompt).not.toBeVisible();
    await expect(draft).toBeVisible();
    await expect(promptHeader.getByRole("status", { name: "Prompt save status" })).toHaveText("Unsaved prompt changes");
    expect((await promptHeader.locator("..").boundingBox())!.height).toBeLessThan(expandedHeight - 100);
    await promptHeader.press("Tab");
    await expect(draftHeader).toBeFocused();
    await draftHeader.press("Enter");
    await expect(draft).not.toBeVisible();
    await expect(draftHeader.getByRole("status", { name: "Draft save status" })).toHaveText("Unsaved draft changes");
    await expect(page.getByRole("button", { name: "Grade essay", exact: true })).toBeVisible();

    await draftHeader.press("Space");
    await expect(draft.locator("strong")).toHaveText("Focus on this draft");
    await toolbarFor(page, "Essay Markdown").getByRole("button", { name: "Undo", exact: true }).click();
    await expect(draft.locator("strong")).toHaveCount(0);
    await expect(draft).toHaveText("Focus on this draft");
    await promptHeader.click();
    await expect(prompt).toHaveValue("**Unsaved assignment**");
    await expect(toggleFor(page, "Assignment prompt")).toHaveAttribute("aria-pressed", "true");
    expect(state.writes).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });

  test(`both rendered editors wrap and their toolbars stay usable at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    await setup(page);
    for (const { label } of fields) {
      const editor = editorFor(page, label);
      await editor.fill("LongUnbrokenText".repeat(100));
      await editor.press("ControlOrMeta+a");
      await toolbarFor(page, label).getByRole("button", { name: "Bold", exact: true }).click();
      await expect(editor.locator("strong")).toHaveText("LongUnbrokenText".repeat(100));
      expect(await editor.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath("integrated-editors.png"), fullPage: true });
  });
}

test("collapsed editors still show pending/success/failure save status and navigation guards", async ({ page }) => {
  const { state, finishSave } = await setup(page);
  const draft = editorFor(page, "Essay Markdown");
  const header = page.locator('summary[aria-label="Essay draft section"]');
  await draft.fill("A pending draft");
  state.holdSave = true;
  await page.getByRole("button", { name: "Save Draft", exact: true }).click();
  await expect.poll(() => !!state.pending).toBe(true);
  await header.click();
  await expect(header.getByRole("status")).toHaveText("Saving draft…");
  await finishSave();
  await expect(header.getByRole("status")).toHaveText("Draft saved.");
  await expect(draft).not.toBeVisible();
  await header.click();
  await draft.fill("Keep this draft");
  state.holdSave = false;
  state.failSave = true;
  await page.getByRole("button", { name: "Save Draft", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Disk is full.");
  await header.click();
  await expect(header.getByRole("status")).toContainText("Draft not saved");
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await expect(page.getByText("Currently editing First Essay.", { exact: true })).toBeVisible();
  await header.click();
  await expect(draft).toHaveText("Keep this draft");
  await expect(page.getByRole("alert")).toContainText("Disk is full.");
});
