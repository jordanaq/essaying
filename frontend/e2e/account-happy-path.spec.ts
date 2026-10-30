import { expect, test } from "@playwright/test";

test("create account, log in, and log out", async ({ page, request }) => {
  const uniqueSuffix = Date.now().toString().slice(-6);
  const displayName = `e2e-user-${uniqueSuffix}`;
  const expectedAccountId = displayName;
  let createdAccountId: string | null = expectedAccountId;

  try {
    await page.goto("/");

    await expect(page.getByText("Welcome to Essaying")).toBeVisible();

    const displayNameInput = page.locator("sl-input").first();
    await expect(displayNameInput).toBeVisible();
    await displayNameInput.evaluate((el, name) => {
      const input = el as { value: string; dispatchEvent: (ev: Event) => boolean };
      input.value = name;
      input.dispatchEvent(new CustomEvent("sl-input", { bubbles: true, composed: true }));
    }, displayName);

    await page
      .locator('sl-card:has-text("Create Account") sl-button:has-text("Create Account")')
      .first()
      .click();

    await expect(page.getByText("Essaying Workbench")).toBeVisible();
    await expect(page.getByText(`Logged in as ${displayName} (${expectedAccountId})`)).toBeVisible();

    await page.getByText("Log Out").click();
    await expect(page.getByText("Welcome to Essaying")).toBeVisible();
  } finally {
    if (createdAccountId) {
      const cleanupResponse = await request.delete(`/api/v1/accounts/${encodeURIComponent(createdAccountId)}`);
      if (!cleanupResponse.ok() && cleanupResponse.status() !== 404) {
        throw new Error(`Cleanup delete failed with HTTP ${cleanupResponse.status()}`);
      }
    }
  }
});

test("create and delete a folder and essay from the workspace tree", async ({ page }) => {
  const uniqueSuffix = Date.now().toString().slice(-6);
  const accountId = `e2e-workspace-${uniqueSuffix}`;
  const folderName = `folder-${uniqueSuffix}`;
  const essayName = `essay-${uniqueSuffix}`;
  const nestedEssayName = `nested-${uniqueSuffix}`;
  type TreeNode = { name: string; path: string[]; nodeType: string; children: TreeNode[] };
  let workspaceTree: TreeNode[] = [];

  function samePath(left: string[], right: string[]) {
    return left.length === right.length && left.every((segment, index) => segment === right[index]);
  }

  function insertNode(nodes: TreeNode[], parentPath: string[], created: TreeNode): TreeNode[] {
    if (parentPath.length === 0) {
      return [...nodes, created];
    }
    return nodes.map((node) =>
      samePath(node.path, parentPath)
        ? { ...node, children: [...node.children, created] }
        : { ...node, children: insertNode(node.children, parentPath, created) }
    );
  }

  function removeNode(nodes: TreeNode[], path: string[]): TreeNode[] {
    return nodes
      .filter((node) => !samePath(node.path, path))
      .map((node) => ({ ...node, children: removeNode(node.children, path) }));
  }

  try {
    await page.addInitScript((id) => localStorage.setItem("essay-account-id", id), accountId);
    await page.route("**/api/v1/accounts", async (route) => {
      await route.fulfill({
        status: 200,
        json: [{ accountId: { unAccountId: accountId }, displayName: accountId, preferredModel: null }]
      });
    });
    await page.route(`**/api/v1/accounts/${accountId}/**`, async (route) => {
      const request = route.request();
      const routePath = new URL(request.url()).pathname.split(`/api/v1/accounts/${accountId}/`)[1] ?? "";

      if (routePath === "workspace" && request.method() === "GET") {
        await route.fulfill({ status: 200, json: { tree: workspaceTree } });
        return;
      }

      if (routePath === "workspace/directories" && request.method() === "POST") {
        const body = request.postDataJSON() as { parentPath: string[]; directoryName: string };
        const created: TreeNode = {
          name: body.directoryName,
          path: [...body.parentPath, body.directoryName],
          nodeType: "WorkspaceDirectoryNode",
          children: []
        };
        workspaceTree = insertNode(workspaceTree, body.parentPath, created);
        await route.fulfill({ status: 201, json: created });
        return;
      }

      if (routePath === "workspace/essays" && request.method() === "POST") {
        const body = request.postDataJSON() as { parentPath: string[]; essayName: string; markdown: string; prompt: string };
        expect(body.markdown).toBe("");
        expect(body.prompt).toBe("");
        const essayPath = [...body.parentPath, body.essayName];
        workspaceTree = insertNode(workspaceTree, body.parentPath, {
          name: body.essayName,
          path: essayPath,
          nodeType: "WorkspaceEssayNode",
          children: []
        });
        await route.fulfill({
          status: 201,
          json: { path: essayPath, title: body.essayName, prompt: "", markdown: body.markdown ?? "" }
        });
        return;
      }

      if (request.method() === "DELETE") {
        const pathSegments = routePath.split("/");
        workspaceTree = removeNode(workspaceTree, pathSegments.slice(2).map(decodeURIComponent));
        await route.fulfill({ status: 204 });
        return;
      }

      await route.fulfill({ status: 404, json: { message: `Unhandled test API route: ${routePath}` } });
    });

    await page.goto("/");
    await expect(page.getByText("Essaying Workbench")).toBeVisible();
    await expect(page.locator("sl-tree-item.workspace-root")).toBeVisible();

    const createFolderResponse = page.waitForResponse((response) =>
      response.url().endsWith("/workspace/directories") && response.request().method() === "POST"
    );
    await page.getByRole("button", { name: "Actions for Workspace", exact: true }).click();
    await page.getByRole("menuitem", { name: "Create folder", exact: true }).click();
    await page.getByRole("textbox", { name: "Folder name" }).fill(folderName);
    await page.getByRole("button", { name: "Create Folder", exact: true }).click();
    expect((await createFolderResponse).ok()).toBe(true);

    const folderRow = page.locator(`sl-tree-item[data-path='["${folderName}"]']`);
    await expect(folderRow).toBeVisible();
    await folderRow.hover();

    const createEssayResponse = page.waitForResponse((response) =>
      response.url().endsWith("/workspace/essays") && response.request().method() === "POST"
    );
    await page.getByRole("button", { name: `Actions for ${folderName}`, exact: true }).click();
    await page.getByRole("menuitem", { name: "Create essay", exact: true }).click();
    await page.getByRole("textbox", { name: "Essay name" }).fill(essayName);
    await page.getByRole("button", { name: "Create Essay", exact: true }).click();
    const essayResponse = await createEssayResponse;
    expect(essayResponse.ok()).toBe(true);
    expect(await essayResponse.json()).toMatchObject({
      path: [folderName, `${essayName}`],
      title: essayName
    });
    const essayRow = page.locator(`sl-tree-item[data-path='["${folderName}","${essayName}"]']`);
    await expect(essayRow).toBeVisible();
    await expect(essayRow.locator('sl-menu-item[value="essay"], sl-menu-item[value="folder"]')).toHaveCount(0);
    await essayRow.hover();

    const deleteEssayResponse = page.waitForResponse((response) =>
      response.request().method() === "DELETE"
    );
    await page.getByRole("button", { name: `Actions for ${essayName}`, exact: true }).click();
    await page.getByRole("menuitem", { name: "Delete essay", exact: true }).click();
    await expect(page.getByText(`Delete ${essayName}? This cannot be undone.`)).toBeVisible();
    await expect(page.getByText(/This permanently deletes the essay, assignment prompt/)).toBeVisible();
    await page.getByRole("button", { name: "Delete", exact: true }).click();
    const essayDelete = await deleteEssayResponse;
    expect(essayDelete.status()).toBe(204);
    expect(new URL(essayDelete.url()).pathname).toContain(`/workspace/essays/${folderName}/${essayName}`);
    await expect(essayRow).toHaveCount(0);

    const createNestedEssayResponse = page.waitForResponse((response) =>
      response.url().endsWith("/workspace/essays") && response.request().method() === "POST"
    );
    await folderRow.hover();
    await page.getByRole("button", { name: `Actions for ${folderName}`, exact: true }).click();
    await page.getByRole("menuitem", { name: "Create essay", exact: true }).click();
    await page.getByRole("textbox", { name: "Essay name" }).fill(nestedEssayName);
    await page.getByRole("button", { name: "Create Essay", exact: true }).click();
    expect((await createNestedEssayResponse).ok()).toBe(true);

    const deleteDirectoryResponse = page.waitForResponse((response) =>
      response.request().method() === "DELETE"
    );
    await folderRow.hover();
    await page.getByRole("button", { name: `Actions for ${folderName}`, exact: true }).click();
    await page.getByRole("menuitem", { name: "Delete folder", exact: true }).click();
    await expect(page.getByText("This also permanently deletes everything inside the folder.")).toBeVisible();
    await page.getByRole("button", { name: "Delete", exact: true }).click();
    const directoryDelete = await deleteDirectoryResponse;
    expect(directoryDelete.status()).toBe(204);
    expect(new URL(directoryDelete.url()).pathname).toContain(`/workspace/directories/${folderName}`);
    await expect(folderRow).toHaveCount(0);
  } finally {
    workspaceTree = [];
  }
});
