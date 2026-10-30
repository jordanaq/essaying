import { expect, test, type Route } from "@playwright/test";

for (const operation of ["save", "delete"] as const) {
  for (const succeeds of [true, false]) {
    test(`grading waits for context ${operation} ${succeeds ? "success" : "failure"} and subsequent resolution`, async ({ page }) => {
      const essay = { path: ["Draft"], title: "Draft", prompt: "", markdown: "# Draft" };
      const initialLayer = { title: { tag: "SetScalar", contents: "Saved title" } };
      const effective = { title: "Saved title", audience: null, model: "gpt-6.1-sol", tags: [], instructions: [], grading_directions: [], rubric: { clarity: { weight: 1, description: null } } };
      let mutation: Route | undefined;
      let resolution: Route | undefined;
      let effectiveReads = 0;
      await page.addInitScript(() => localStorage.setItem("essay-account-id", "alice"));
      await page.route("**/api/**", async (route) => {
        const request = route.request();
        const url = new URL(request.url());
        if (url.pathname === "/api/v1/accounts") {
          await route.fulfill({ json: [{ accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: null }] });
        } else if (url.pathname.endsWith("/workspace")) {
          await route.fulfill({ json: { tree: [{ name: essay.title, path: essay.path, nodeType: "WorkspaceEssayNode", children: [] }] } });
        } else if (url.pathname.endsWith("/context/effective")) {
          effectiveReads += 1;
          if (effectiveReads === 1) await route.fulfill({ json: effective });
          else resolution = route;
        } else if (url.pathname.endsWith("/context")) {
          if (request.method() === "GET") await route.fulfill({ json: initialLayer });
          else mutation = route;
        } else if (decodeURIComponent(url.pathname).endsWith("/essays/Draft")) {
          await route.fulfill({ json: essay });
        } else await route.fulfill({ status: 404 });
      });

      await page.goto("/");
      const panel = page.getByRole("region", { name: "Writing context" });
      const grade = page.locator("sl-button").filter({ hasText: "Grade essay" });
      await expect(grade).toHaveJSProperty("disabled", false);
      await expect(panel.getByRole("textbox", { name: "Title", exact: true })).toHaveValue("Saved title");
      if (operation === "save") {
        await panel.getByRole("textbox", { name: "Title", exact: true }).fill("Edited title");
        await panel.getByRole("button", { name: "Save context" }).click();
      } else {
        await panel.getByRole("button", { name: "Remove layer", exact: true }).click();
        await panel.getByRole("button", { name: "Confirm removal" }).click();
      }

      await expect.poll(() => !!mutation).toBe(true);
      expect(mutation!.request().method()).toBe(operation === "save" ? "PUT" : "DELETE");
      expect(mutation!.request().postDataJSON()).toEqual(operation === "save"
        ? { path: "Draft/context.json", contextLayer: { title: { tag: "SetScalar", contents: "Edited title" } } }
        : { path: "Draft/context.json" });
      await expect(grade).toHaveJSProperty("disabled", true);
      await expect(panel.getByRole("button", { name: "Refresh preview" })).toBeDisabled();
      await expect(page.locator("sl-button").filter({ hasText: "Save Draft" })).toHaveJSProperty("disabled", false);
      await page.getByRole("textbox", { name: "Essay Markdown", exact: true }).fill("# Editing during mutation");
      // Neither a successful write nor a failed write establishes context validity.
      if (!succeeds) {
        await mutation!.fulfill({ status: 500, json: { error: { message: "Unable to persist context." } } });
        await expect(panel.getByRole("alert")).toHaveText("Unable to persist context.");
        if (operation === "save") {
          await expect(panel.getByRole("textbox", { name: "Title", exact: true })).toHaveValue("Edited title");
          await expect(panel.getByText(/Unsaved changes/)).toBeVisible();
        }
      } else if (operation === "save") {
        await mutation!.fulfill({ json: mutation!.request().postDataJSON().contextLayer });
        await expect(panel.getByText("Context saved.", { exact: true })).toBeVisible();
      } else {
        await mutation!.fulfill({ status: 204 });
        await expect(panel.getByText("Layer removed. Parent settings now apply.", { exact: true })).toBeVisible();
      }
      await expect.poll(() => !!resolution).toBe(true);
      await expect(grade).toHaveJSProperty("disabled", true);
      await expect(panel.getByText("Resolving context…", { exact: true })).toBeVisible();
      await resolution!.fulfill({ json: { ...effective, title: succeeds ? operation === "save" ? "Edited title" : null : "Saved title" } });
      await expect(grade).toHaveJSProperty("disabled", true);
      await expect(page.getByRole("textbox", { name: "Essay Markdown", exact: true })).toHaveValue("# Editing during mutation");
      const nextAction = operation === "delete"
        ? succeeds ? "Create context" : "Remove layer"
        : "Save context";
      await expect(panel.getByRole("button", { name: nextAction, exact: true })).toBeEnabled();
    });
  }
}
