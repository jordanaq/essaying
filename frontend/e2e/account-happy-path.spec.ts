import { expect, test } from "@playwright/test";

test("create account, log in, and log out", async ({ page }) => {
  const uniqueSuffix = Date.now().toString().slice(-6);
  const displayName = `e2e-user-${uniqueSuffix}`;
  const expectedAccountId = displayName;

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
});
