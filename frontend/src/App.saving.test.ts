import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

async function setup() {
  const essay = { path: ["Notes"], title: "Notes", markdown: "Saved draft", prompt: "Saved prompt" };
  const state = {
    save: async (body: Record<string, string>): Promise<Response> => {
      Object.assign(essay, body);
      return json(essay);
    },
    writes: [] as Record<string, string>[]
  };
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.endsWith("/accounts")) return json([{ accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: null }]);
    if (url.endsWith("/workspace")) return json({ tree: [{ name: "Notes", path: essay.path, nodeType: "WorkspaceEssayNode", children: [] }] });
    if (url.includes("/context/effective")) return json({ title: null, audience: null, model: null, tags: [], instructions: [], grading_directions: [], rubric: {} });
    if (url.includes("/context")) return json({ error: { message: "Context does not exist." } }, 404);
    if (url.endsWith("/essays/Notes")) {
      if (init?.method === "PUT") {
        const body = JSON.parse(String(init.body));
        state.writes.push(body);
        return state.save(body);
      }
      return json(essay);
    }
    return new Response("", { status: 200 });
  }));
  localStorage.setItem("essay-account-id", "alice");
  const { container } = render(App);
  await screen.findByText("Currently editing Notes.");
  const editor = (label: string) => Array.from(container.querySelectorAll<HTMLElement & { label: string; value: string }>("sl-textarea"))
    .find((element) => element.label === label)!;
  const input = async (label: string, value: string) => {
    const element = editor(label);
    element.value = value;
    await fireEvent(element, new CustomEvent("sl-input"));
  };
  return { state, essay, editor, input };
}

describe("Editor save states", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.restoreAllMocks();
  });

  const fields = [
    { field: "markdown", label: "Essay Markdown", name: "Draft", sibling: "Assignment prompt" },
    { field: "prompt", label: "Assignment prompt", name: "Prompt", sibling: "Essay Markdown" }
  ] as const;

  it.each(fields)("shows pending and saved states for $field without losing newer or sibling edits", async ({ field, label, name, sibling }) => {
    const { state, essay, editor, input } = await setup();
    const saveStatus = screen.getByRole("status", { name: `${name} save status` });
    expect(saveStatus).toHaveTextContent(`${name} saved`);
    await input(label, "First edit");
    await input(sibling, "Sibling edit");
    expect(saveStatus).toHaveTextContent(`Unsaved ${name.toLowerCase()} changes`);

    let finish!: (response: Response) => void;
    state.save = () => new Promise((resolve) => { finish = resolve; });
    await fireEvent.click(screen.getByText(`Save ${name}`));
    expect(saveStatus).toHaveTextContent(`Saving ${name.toLowerCase()}…`);
    const pendingButton = screen.getByText(`Saving ${name.toLowerCase()}…`, { selector: "sl-button" });
    expect(pendingButton).toHaveAttribute("disabled");
    await fireEvent.click(pendingButton);
    expect(state.writes).toEqual([{ [field]: "First edit" }]);

    await input(label, "Newer edit");
    finish(json({ ...essay, [field]: "First edit" }));
    await waitFor(() => expect(saveStatus).toHaveTextContent(`Unsaved ${name.toLowerCase()} changes`));
    expect(editor(label).value).toBe("Newer edit");
    expect(editor(sibling).value).toBe("Sibling edit");
    expect(screen.getByText(/Newer changes are still unsaved/)).toBeInTheDocument();

    state.save = async (body) => json({ ...essay, ...body });
    await fireEvent.click(screen.getByText(`Save ${name}`));
    await waitFor(() => expect(saveStatus).toHaveTextContent(`${name} saved.`));
    expect(editor(sibling).value).toBe("Sibling edit");
  });

  it.each(fields)("preserves $field edits and allows retry after a failed save", async ({ field, label, name, sibling }) => {
    const { state, essay, editor, input } = await setup();
    const saveStatus = screen.getByRole("status", { name: `${name} save status` });
    await input(label, "Keep this edit");
    await input(sibling, "Keep sibling edit");
    state.save = async () => json({ error: { message: "Disk is full." } }, 500);
    await fireEvent.click(screen.getByText(`Save ${name}`));
    await waitFor(() => expect(saveStatus).toHaveTextContent(`${name} not saved. Your edits are still here; try saving again.`));
    expect(screen.getByRole("alert")).toHaveTextContent(`Could not save ${name.toLowerCase()}: Disk is full.`);
    expect(editor(label).value).toBe("Keep this edit");
    expect(editor(sibling).value).toBe("Keep sibling edit");
    const unload = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(unload);
    expect(unload.defaultPrevented).toBe(true);

    state.save = async (body) => json({ ...essay, ...body });
    await fireEvent.click(screen.getByText(`Save ${name}`));
    await waitFor(() => expect(saveStatus).toHaveTextContent(`${name} saved.`));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(state.writes).toEqual([{ [field]: "Keep this edit" }, { [field]: "Keep this edit" }]);
    expect(editor(sibling).value).toBe("Keep sibling edit");
  });
});
