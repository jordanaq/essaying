import { expect, test, type Page, type Route } from "@playwright/test";

type Essay = { path: string[]; title: string; prompt: string; markdown: string };

async function setup(page: Page, firstTitle = "First Essay") {
  const essays: Essay[] = [
    { path: [firstTitle], title: firstTitle, prompt: "First assignment", markdown: "First draft" },
    { path: ["Second Essay"], title: "Second Essay", prompt: "", markdown: "" }
  ];
  const state = {
    holdSave: false, failSave: false,
    pending: null as null | { route: Route; essay: Essay; body: Partial<Essay>; snapshot: Essay },
    writes: [] as Partial<Essay>[],
    creations: [] as { parentPath: string[]; essayName: string; prompt?: string; markdown?: string }[]
  };
  const layers = new Map<string, object>();
  const finishSave = async () => {
    const pending = state.pending!;
    Object.assign(pending.essay, pending.body);
    await pending.route.fulfill({ json: { ...pending.snapshot, ...pending.body } });
    state.pending = null;
  };
  await page.addInitScript(() => localStorage.setItem("essay-account-id", "alice"));
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = decodeURIComponent(url.pathname);
    if (path === "/api/v1/accounts") {
      await route.fulfill({ json: ["alice", "bob"].map((id) => ({ accountId: { unAccountId: id }, displayName: id, preferredModel: null })) });
    } else if (path.endsWith("/workspace")) {
      await route.fulfill({ json: { tree: [
        ...essays.map((essay) => ({ name: essay.title, path: essay.path, nodeType: "WorkspaceEssayNode", children: [] })),
        { name: "Notes", path: ["Notes"], nodeType: "WorkspaceDirectoryNode", children: [] }
      ] } });
    } else if (path.endsWith("/workspace/essays") && request.method() === "POST") {
      const body = request.postDataJSON();
      state.creations.push(body);
      const essay = {
        path: [...body.parentPath, body.essayName], title: body.essayName,
        prompt: body.prompt ?? "", markdown: body.markdown ?? ""
      };
      essays.push(essay);
      await route.fulfill({ status: 201, json: essay });
    } else if (path.endsWith("/context/effective")) {
      await route.fulfill({ json: { title: null, audience: null, model: "gpt-6.1-sol", tags: [], instructions: [], grading_directions: [], rubric: { clarity: { weight: 1, description: null } } } });
    } else if (path.endsWith("/context")) {
      const key = url.searchParams.get("path") ?? request.postDataJSON().path;
      if (request.method() === "GET") {
        await route.fulfill(layers.has(key) ? { json: layers.get(key) } : { status: 404, json: { error: { message: "Context does not exist." } } });
      } else if (request.method() === "DELETE") {
        layers.delete(key);
        await route.fulfill({ status: 204 });
      } else {
        layers.set(key, request.postDataJSON().contextLayer);
        await route.fulfill({ json: layers.get(key) });
      }
    } else {
      const essay = essays.find((item) => path.endsWith(`/essays/${item.path.join("/")}`));
      if (!essay) return route.fulfill({ status: 404 });
      if (request.method() === "PUT") {
        const body = request.postDataJSON();
        state.writes.push(body);
        if (state.failSave) return route.fulfill({ status: 500, json: { error: { message: "Unable to persist this file." } } });
        expect(Object.keys(body)).toHaveLength(1);
        state.pending = { route, essay, body, snapshot: { ...essay } };
        if (!state.holdSave) await finishSave();
      } else await route.fulfill({ json: essay });
    }
  });
  await page.goto("/");
  await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("First draft");
  return { state, essays, finishSave };
}

for (const width of [390, 1280]) {
  test(`editors and context tabs support keyboard navigation at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await setup(page);
    const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
    const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
    for (const [editor, save] of [[prompt, "Save Prompt"], [draft, "Save Draft"]] as const) {
      await editor.focus();
      await editor.press("End");
      await page.keyboard.type(" edited with keyboard");
      await page.keyboard.press("Tab");
      const button = page.getByRole("button", { name: save, exact: true });
      await expect(button).toBeFocused();
      await page.keyboard.press("Enter");
      await expect(page.getByRole("status", { name: save === "Save Prompt" ? "Prompt save status" : "Draft save status" }))
        .toHaveText(/saved\./);
      await page.keyboard.press("Shift+Tab");
      await expect(editor).toBeFocused();
      await expect(editor).toHaveValue(/ edited with keyboard$/);
    }

    const context = page.getByRole("tab", { name: "Context", exact: true });
    const feedback = page.getByRole("tab", { name: "Feedback", exact: true });
    await context.focus();
    for (const [key, target] of [["ArrowRight", feedback], ["ArrowRight", context], ["End", feedback], ["Home", context], ["ArrowLeft", feedback]] as const) {
      await page.keyboard.press(key);
      await expect(target).toBeFocused();
      await expect(target).toHaveAttribute("aria-selected", "true");
      await expect(target).toHaveAttribute("tabindex", "0");
      const panelId = await target.getAttribute("aria-controls");
      await expect(page.locator(`#${panelId}`)).toBeVisible();
    }
  });

  test(`explorer menus preserve selection and support keyboard access at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await setup(page);
    const selected = page.locator('sl-tree-item[data-path=\'["First Essay"]\']');
    const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
    await prompt.fill("Unsaved assignment");

    const folderActions = page.getByRole("button", { name: "Actions for Notes", exact: true });
    await folderActions.click();
    await expect(page.getByRole("menuitem", { name: "Create essay", exact: true })).toBeVisible();
    await expect(page.getByRole("menuitem", { name: "Create folder", exact: true })).toBeVisible();
    await expect(page.getByRole("menuitem", { name: "Delete folder", exact: true })).toBeVisible();
    await expect(selected).toHaveAttribute("selected");
    await expect(prompt).toHaveValue("Unsaved assignment");
    await page.keyboard.press("Escape");
    await expect(folderActions).toBeFocused();
    await expect(page.getByRole("menu", { name: "Notes actions", exact: true })).not.toBeVisible();

    const workspaceActions = page.getByRole("button", { name: "Actions for Workspace", exact: true });
    await workspaceActions.focus();
    await Promise.all([
      page.locator('sl-menu[aria-label="Workspace actions"]').evaluate((menu) => new Promise<void>((resolve) => {
        menu.parentElement!.addEventListener("sl-after-show", () => resolve(), { once: true });
      })),
      workspaceActions.press("ArrowDown")
    ]);
    const createEssay = page.getByRole("menuitem", { name: "Create essay", exact: true });
    await expect(createEssay).toBeFocused();
    await page.keyboard.press("ArrowDown");
    await expect(page.getByRole("menuitem", { name: "Create folder", exact: true })).toBeFocused();
    await expect(page.getByRole("menuitem", { name: /Delete/ })).toHaveCount(0);
    await page.keyboard.press("Escape");
    await expect(workspaceActions).toBeFocused();
    await expect(page.getByRole("menu", { name: "Workspace actions", exact: true })).not.toBeVisible();

    await page.getByRole("button", { name: "Actions for Second Essay", exact: true }).click();
    await expect(page.getByRole("menuitem")).toHaveCount(1);
    await page.getByRole("menuitem", { name: "Delete essay", exact: true }).click();
    await expect(page.getByText("Delete Second Essay? This cannot be undone.")).toBeVisible();
    await expect(selected).toHaveAttribute("selected");
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await expect(prompt).toHaveValue("Unsaved assignment");
  });
}

for (const width of [320, 390, 768, 1280]) {
  test(`long essay names and Markdown wrap within the editor at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await setup(page, "A long essay title " + "UnbrokenTitle".repeat(20));
    const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
    const text = "# A heading\n\nA paragraph with **emphasis** and a long link:\nhttps://example.com/" + "long-path".repeat(100);
    await draft.fill(text);
    await expect(draft).toHaveValue(text);
    expect(await draft.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
    const typography = await draft.evaluate((element) => {
      const style = getComputedStyle(element);
      return { font: style.fontFamily, size: parseFloat(style.fontSize), line: parseFloat(style.lineHeight), resize: style.resize };
    });
    expect(typography.font).not.toContain("monospace");
    expect(typography.size).toBeGreaterThanOrEqual(16);
    expect(typography.line / typography.size).toBeGreaterThanOrEqual(1.5);
    expect(typography.resize).toBe("vertical");
    await page.getByRole("button", { name: "Save Draft", exact: true }).click();
    await expect(page.getByRole("status", { name: "Draft save status" })).toHaveText("Draft saved.");
    const badge = page.locator(".panel-header-controls sl-badge");
    const rectangle = await badge.boundingBox();
    expect(rectangle!.x).toBeGreaterThanOrEqual(0);
    expect(rectangle!.x + rectangle!.width).toBeLessThanOrEqual(width);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}

test("explorer menus and model popups follow dark and light themes", async ({ page }) => {
  await setup(page);
  for (const palette of [
    { background: "rgb(30, 32, 48)", text: "rgb(202, 211, 245)" },
    { background: "rgb(230, 233, 239)", text: "rgb(76, 79, 105)" }
  ]) {
    await page.getByRole("button", { name: "Actions for Workspace", exact: true }).click();
    const menu = page.getByRole("menu", { name: "Workspace actions", exact: true });
    await expect(menu).toHaveCSS("background-color", palette.background);
    const item = menu.getByRole("menuitem", { name: "Create folder", exact: true });
    await expect.poll(() => item.evaluate((element) => getComputedStyle(element.shadowRoot!.querySelector('[part="base"]')!).color)).toBe(palette.text);
    await page.keyboard.press("Escape");
    await expect(menu).not.toBeVisible();

    await page.getByRole("combobox", { name: "Model", exact: true }).click();
    const listbox = page.getByRole("listbox");
    await expect(listbox).toBeVisible();
    await expect(listbox).toHaveCSS("background-color", palette.background);
    const option = page.getByRole("option", { name: "gpt-5.6-luna", exact: true });
    await expect.poll(() => option.evaluate((element) => getComputedStyle(element.shadowRoot!.querySelector('[part="base"]')!).color)).toBe(palette.text);
    await page.keyboard.press("Escape");
    await expect(listbox).not.toBeVisible();
    if (palette.background === "rgb(30, 32, 48)") {
      await page.getByRole("button", { name: "Switch to Light", exact: true }).click();
    }
  }
});

test("independent saves preserve sibling edits and typing during a pending save", async ({ page }) => {
  const { state, finishSave } = await setup(page);
  const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
  const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
  await prompt.fill("Unsaved assignment");
  await draft.fill("Updated draft");
  await page.getByText("Save Draft", { exact: true }).click();
  await expect(page.getByText("Draft saved.", { exact: true })).toBeVisible();
  expect(state.writes[0]).toEqual({ markdown: "Updated draft" });
  await expect(prompt).toHaveValue("Unsaved assignment");
  await expect(page.getByText("Unsaved prompt changes", { exact: true })).toBeVisible();

  state.holdSave = true;
  await page.getByText("Save Prompt", { exact: true }).click();
  await expect.poll(() => state.pending !== null).toBe(true);
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await expect(page.locator("sl-badge").filter({ hasText: "Wait for the current save or workspace change to finish." })).toBeVisible();
  await expect(draft).toHaveValue("Updated draft");
  await prompt.fill("Typed after save started");
  await draft.fill("Unsaved sibling draft");
  await finishSave();
  await expect(page.getByText("Save Prompt", { exact: true })).toBeVisible();
  await expect(prompt).toHaveValue("Typed after save started");
  await expect(draft).toHaveValue("Unsaved sibling draft");
  await expect(page.getByText("Unsaved prompt changes", { exact: true })).toBeVisible();
  await expect(page.getByText("Unsaved draft changes", { exact: true })).toBeVisible();
  expect(state.writes[1]).toEqual({ prompt: "Unsaved assignment" });
  state.holdSave = false;
  await page.getByText("Save Prompt", { exact: true }).click();
  await expect(page.getByText("Prompt saved.", { exact: true })).toBeVisible();
  await expect(draft).toHaveValue("Unsaved sibling draft");
});

test("discard restores each field's latest saved value without discarding its sibling", async ({ page }) => {
  const { state } = await setup(page);
  const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
  const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
  await prompt.fill("Saved assignment");
  await page.getByText("Save Prompt", { exact: true }).click();
  await expect(page.getByText("Prompt saved.", { exact: true })).toBeVisible();
  await draft.fill("Saved draft");
  await page.getByText("Save Draft", { exact: true }).click();
  await expect(page.getByText("Draft saved.", { exact: true })).toBeVisible();

  await prompt.fill("Discard this assignment");
  await draft.fill("Keep this draft");
  await page.getByText("Discard prompt changes", { exact: true }).click();
  await expect(prompt).toHaveValue("Saved assignment");
  await expect(draft).toHaveValue("Keep this draft");
  await expect(page.getByText("Unsaved prompt changes", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Unsaved draft changes", { exact: true })).toBeVisible();

  await prompt.fill("Keep this assignment");
  await page.getByText("Discard draft changes", { exact: true }).click();
  await expect(draft).toHaveValue("Saved draft");
  await expect(prompt).toHaveValue("Keep this assignment");
  await expect(page.getByText("Unsaved draft changes", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Unsaved prompt changes", { exact: true })).toBeVisible();
  expect(state.writes).toEqual([{ prompt: "Saved assignment" }, { markdown: "Saved draft" }]);
});

test("creating an essay while a populated essay is selected starts with a blank prompt and draft", async ({ page }) => {
  const { state, essays } = await setup(page);
  await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveValue("First assignment");
  await page.getByRole("button", { name: "Actions for Workspace", exact: true }).click();
    await page.getByRole("menuitem", { name: "Create essay", exact: true }).click();
  await page.getByRole("textbox", { name: "Essay name" }).fill("New Essay");
  await page.getByRole("button", { name: "Create Essay", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("");
  await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveValue("");
  expect(state.creations).toEqual([{ parentPath: [], essayName: "New Essay", prompt: "", markdown: "" }]);
  await expect(page.locator('.tree-item-name[title="New Essay"]')).toBeVisible();
  expect(essays[0]).toMatchObject({ prompt: "First assignment", markdown: "First draft" });
  await page.locator('.tree-item-name[title="First Essay"]').click();
  await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("First draft");
  await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveValue("First assignment");
});

test("failed saves keep edits, retry works, and empty prompt and draft persist", async ({ page }) => {
  const { state } = await setup(page);
  const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
  const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
  state.failSave = true;
  await prompt.fill("Retry assignment");
  await draft.fill("Keep draft edit");
  await page.getByText("Save Prompt", { exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Unable to persist this file.");
  await expect(prompt).toHaveValue("Retry assignment");
  await expect(draft).toHaveValue("Keep draft edit");
  state.failSave = false;
  await prompt.fill("");
  await page.getByText("Save Prompt", { exact: true }).click();
  await expect(page.getByText("Prompt saved.", { exact: true })).toBeVisible();
  await draft.fill("");
  await page.getByText("Save Draft", { exact: true }).click();
  await expect(page.getByText("Draft saved.", { exact: true })).toBeVisible();
  expect(state.writes.slice(-2)).toEqual([{ prompt: "" }, { markdown: "" }]);
  await page.reload();
  await expect(prompt).toHaveValue("");
  await expect(draft).toHaveValue("");
});

test("navigation protects draft prompt and context changes and can discard explicitly", async ({ page }) => {
  await setup(page);
  const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
  const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
  const second = page.locator('.tree-item-name[title="Second Essay"]');
  await prompt.fill("Keep assignment");
  await draft.fill("Keep draft");
  for (const action of [() => second.click(), () => page.locator('.tree-item-name[title="Workspace"]').click(), () => page.getByText("Log Out", { exact: true }).click(),
    () => page.getByRole("button", { name: "Reload workspace", exact: true }).click()]) {
    page.once("dialog", (dialog) => dialog.dismiss());
    await action();
    await expect(prompt).toHaveValue("Keep assignment");
    await expect(draft).toHaveValue("Keep draft");
  }
  expect(await page.evaluate(() => {
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  })).toBe(true);
  page.once("dialog", (dialog) => dialog.accept());
  await second.click();
  await expect(draft).toHaveValue("");
  await expect(prompt).toHaveValue("");
  const panel = page.getByRole("region", { name: "Writing context" });
  await expect(panel.getByLabel("Edit settings for")).toHaveValue("Second Essay");
  await panel.getByLabel("Title behavior").selectOption("SetScalar");
  await panel.getByRole("textbox", { name: "Title", exact: true }).fill("Keep essay context");
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.locator('.tree-item-name[title="First Essay"]').click();
  await expect(panel.getByRole("textbox", { name: "Title", exact: true })).toHaveValue("Keep essay context");
  await panel.getByRole("button", { name: "Discard changes", exact: true }).click();
  await expect(panel.getByLabel("Title behavior")).toHaveValue("inherit");
  await panel.getByLabel("Title behavior").selectOption("SetScalar");
  await panel.getByRole("textbox", { name: "Title", exact: true }).fill("Discard on reload");
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Reload workspace", exact: true }).click();
  // Reload keeps the selected essay but resets its unsaved context edits.
  await expect(panel.getByLabel("Edit settings for")).toHaveValue("Second Essay");
  await expect(panel.getByLabel("Title behavior")).toHaveValue("inherit");
  await page.locator('.tree-item-name[title="First Essay"]').click();
  await expect(draft).toHaveValue("First draft");
  await expect(prompt).toHaveValue("First assignment");
  expect(await page.evaluate(() => {
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  })).toBe(false);
});

test("late essay loads cannot replace another account's view", async ({ page }) => {
  await setup(page);
  let pending: Route | undefined;
  await page.route("**/workspace/essays/Second%20Essay", (route) => { pending = route; });
  await page.locator('.tree-item-name[title="Second Essay"]').click();
  await expect.poll(() => !!pending).toBe(true);
  await page.getByText("Log Out", { exact: true }).click();
  await page.getByText("bob", { exact: true }).click();
  await expect(page.getByText("Logged in as bob (bob)", { exact: true })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("First draft");
  await pending!.fulfill({ json: { path: ["Second Essay"], title: "Stale", prompt: "Stale prompt", markdown: "Stale draft" } });
  await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("First draft");
  await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveValue("First assignment");
});

type EditedField = "prompt" | "draft" | "context";

async function editField(page: Page, field: EditedField) {
  if (field === "context") {
    const panel = page.getByRole("region", { name: "Writing context" });
    await panel.getByLabel("Title behavior").selectOption("SetScalar");
    const title = panel.getByRole("textbox", { name: "Title", exact: true });
    await title.fill("Unsaved context");
    return title;
  }
  const editor = page.getByRole("textbox", {
    name: field === "prompt" ? "Assignment prompt" : "Essay Markdown", exact: true
  });
  await editor.fill(`Unsaved ${field}`);
  return editor;
}

for (const field of ["prompt", "draft", "context"] as const) {
  for (const destination of ["essay", "folder", "root", "reload", "logout"] as const) {
    test(`${field}-only edits can cancel or confirm ${destination} navigation`, async ({ page }) => {
      await setup(page);
      const editor = await editField(page, field);
      const action = () => {
        switch (destination) {
          case "essay": return page.locator('.tree-item-name[title="Second Essay"]').click();
          case "folder": return page.locator('.tree-item-name[title="Notes"]').click();
          case "root": return page.locator('.tree-item-name[title="Workspace"]').click();
          case "reload": return page.getByRole("button", { name: "Reload workspace", exact: true }).click();
          case "logout": return page.getByText("Log Out", { exact: true }).click();
        }
      };
      const cancel = page.waitForEvent("dialog");
      const canceledAction = action();
      const cancelDialog = await cancel;
      expect(cancelDialog.type()).toBe("confirm");
      await cancelDialog.dismiss();
      await canceledAction;
      await expect(editor).toHaveValue(`Unsaved ${field}`);
      await expect(page.locator('sl-tree-item[data-path=\'["First Essay"]\']')).toHaveJSProperty("selected", true);

      const confirm = page.waitForEvent("dialog");
      const confirmedAction = action();
      await (await confirm).accept();
      await confirmedAction;
      if (destination === "logout") {
        await expect(page.getByText("Welcome to Essaying", { exact: true })).toBeVisible();
        return;
      }
      const draft = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
      const prompt = page.getByRole("textbox", { name: "Assignment prompt", exact: true });
      await expect(draft).toHaveValue(destination === "reload" ? "First draft" : "");
      await expect(prompt).toHaveValue(destination === "reload" ? "First assignment" : "");
      await expect(page.getByRole("region", { name: "Writing context" }).getByLabel("Title behavior")).toHaveValue("inherit");
      if (destination === "folder" || destination === "root") {
        await expect(draft).toBeDisabled();
        await expect(prompt).toBeDisabled();
      }
    });
  }

  test(`native browser reload warns about ${field}-only edits and supports cancel and discard`, async ({ page }) => {
    await setup(page);
    const editor = await editField(page, field);
    // Real reload exercises Chromium's native beforeunload dialog, including user activation.
    const canceledDialog = page.waitForEvent("dialog");
    const canceledReload = page.evaluate(() => { window.location.reload(); });
    const warning = await canceledDialog;
    expect(warning.type()).toBe("beforeunload");
    await warning.dismiss();
    await canceledReload;
    await expect(editor).toHaveValue(`Unsaved ${field}`);

    const confirmedDialog = page.waitForEvent("dialog");
    const confirmedReload = page.evaluate(() => { window.location.reload(); });
    const discardWarning = await confirmedDialog;
    expect(discardWarning.type()).toBe("beforeunload");
    await Promise.all([page.waitForEvent("load"), discardWarning.accept(), confirmedReload]);
    await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("First draft");
    await expect(page.getByRole("textbox", { name: "Assignment prompt", exact: true })).toHaveValue("First assignment");
    await expect(page.getByRole("region", { name: "Writing context" }).getByLabel("Title behavior")).toHaveValue("inherit");
  });
}

for (const width of [390, 1280]) {
  test(`editor controls remain usable without overlap at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await setup(page);
    const prompt = await editField(page, "prompt");
    const draft = await editField(page, "draft");
    const grade = page.getByRole("button", { name: "Grade essay", exact: true });
    await expect(grade).toBeDisabled();
    const controls = ["Save Prompt", "Discard prompt changes", "Save Draft", "Discard draft changes", "Grade essay"];
    const rectangles = [];
    for (const name of controls) {
      const button = page.getByRole("button", { name, exact: true });
      await button.scrollIntoViewIfNeeded();
      await expect(button).toBeVisible();
      rectangles.push(await button.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return { left: rect.left, right: rect.right, top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY };
      }));
    }
    for (const [index, rect] of rectangles.entries()) {
      expect(rect.left).toBeGreaterThanOrEqual(0);
      expect(rect.right).toBeLessThanOrEqual(width);
      for (const other of rectangles.slice(index + 1)) {
        expect(rect.right <= other.left || other.right <= rect.left || rect.bottom <= other.top || other.bottom <= rect.top).toBe(true);
      }
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.getByRole("button", { name: "Save Prompt", exact: true }).click();
    await expect(page.getByText("Prompt saved.", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Discard draft changes", exact: true }).click();
    await expect(draft).toHaveValue("First draft");
    await prompt.fill("Discard on a narrow screen too");
    await page.getByRole("button", { name: "Discard prompt changes", exact: true }).click();
    await expect(prompt).toHaveValue("Unsaved prompt");
    await draft.fill("Saved at this viewport");
    await page.getByRole("button", { name: "Save Draft", exact: true }).click();
    await expect(page.getByText("Draft saved.", { exact: true })).toBeVisible();
    await expect(grade).toBeEnabled();
  });
}
