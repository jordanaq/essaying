import { expect, type Page } from "@playwright/test";

export async function useRawEditors(page: Page) {
  for (const label of ["Assignment prompt", "Essay Markdown"]) {
    const toggle = page.getByRole("button", { name: `Raw Markdown for ${label}`, exact: true });
    await expect(toggle).toBeEnabled();
    if (await toggle.getAttribute("aria-pressed") !== "true") await toggle.click();
  }
}
