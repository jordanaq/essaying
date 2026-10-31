import { fireEvent, screen } from "@testing-library/svelte";

// Existing persistence/grading cases edit exact Markdown through source mode.
// Rendered editing and its keyboard behavior have their own component/browser cases.
export async function rawEditor(label: string): Promise<HTMLTextAreaElement> {
  const toggle = screen.getByRole("button", { name: `Raw Markdown for ${label}` });
  if (toggle.getAttribute("aria-pressed") !== "true") await fireEvent.click(toggle);
  return screen.getByRole("textbox", { name: label }) as HTMLTextAreaElement;
}
