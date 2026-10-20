import { expect, test } from "@playwright/test";

test("switching to an empty essay clears the editor and saves empty markdown", async ({ page }) => {
  const populated = { path: ["meow", "meoww.md"], title: "meoww", markdown: "mrroww" };
  const empty = { path: ["meow", "meow in", "essay.md"], title: "essay", markdown: "" };
  await page.addInitScript(() => localStorage.setItem("essay-account-id", "alice"));
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const path = decodeURIComponent(new URL(request.url()).pathname);
    if (path === "/api/v1/accounts") {
      await route.fulfill({ json: [{ accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: null }] });
    } else if (path.endsWith("/workspace")) {
      await route.fulfill({ json: { tree: [{
        name: "meow", path: ["meow"], nodeType: "WorkspaceDirectoryNode", children: [
          { name: "meoww.md", path: populated.path, nodeType: "WorkspaceEssayNode", children: [] },
          { name: "meow in", path: ["meow", "meow in"], nodeType: "WorkspaceDirectoryNode", children: [
            { name: "essay.md", path: empty.path, nodeType: "WorkspaceEssayNode", children: [] }
          ] }
        ]
      }] } });
    } else if (path.endsWith("/workspace/essays/meow/meoww.md")) {
      await route.fulfill({ json: populated });
    } else if (path.endsWith("/workspace/essays/meow/meow in/essay.md")) {
      await route.fulfill({ json: empty });
    } else {
      await route.fulfill({ status: 404, json: { error: { message: "Context does not exist." } } });
    }
  });

  await page.goto("/");
  const editor = page.getByRole("textbox", { name: "Essay Markdown", exact: true });
  await expect(editor).toHaveValue("mrroww");
  await page.locator('.tree-item-name[title="meow in"]').click();
  await page.locator('.tree-item-name[title="essay.md"]').click();
  await expect(page.getByText("Currently editing meow/meow in/essay.md.", { exact: true })).toBeVisible();
  await expect(editor).toHaveValue("");

  const saveRequest = page.waitForRequest((request) => request.method() === "PUT");
  await page.getByText("Save Draft", { exact: true }).click();
  expect((await saveRequest).postDataJSON()).toEqual({ markdown: "" });
});
