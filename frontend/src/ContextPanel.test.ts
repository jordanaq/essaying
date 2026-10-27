import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ContextPanel from "./ContextPanel.svelte";
import type { ContextLayer, EffectiveContext } from "./context-api";

const effective: EffectiveContext = {
  title: "History Essays", audience: "Students", model: "custom-model", tags: ["history"],
  instructions: ["Use sources."], grading_directions: ["Check evidence."],
  rubric: { clarity: { weight: 0.4, description: "Clear writing" } }
};
const props = { accountId: "alice smith", directoryPath: ["History & Art"], essayPath: ["History & Art", "draft.md"] };
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });

function mockApi(initial: ContextLayer | null = null, parents: Record<string, ContextLayer> = {}) {
  let layer = initial;
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input), "http://localhost");
    if (url.pathname.endsWith("/effective")) return json(effective);
    if (init?.method === "DELETE") { layer = null; return new Response(null, { status: 204 }); }
    if (init?.method === "POST" || init?.method === "PUT") {
      layer = JSON.parse(String(init.body)).contextLayer;
      return json(layer, init.method === "POST" ? 201 : 200);
    }
    const path = url.searchParams.get("path") ?? "";
    if (path in parents) return json(parents[path]);
    if (path === "context.json") return json({ error: { message: "Context does not exist." } }, 404);
    return layer ? json(layer) : json({ error: { message: "Context does not exist." } }, 404);
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

async function changeMode(label: string, value: string) {
  await fireEvent.change(screen.getByLabelText(label), { target: { value } });
}

describe("Writing context", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("refreshes saved effective context without discarding unsaved layer edits", async () => {
    const fetchMock = mockApi({ title: { tag: "SetScalar", contents: "Saved title" } });
    render(ContextPanel, props);
    await screen.findByText("History Essays");
    await fireEvent.input(screen.getByRole("textbox", { name: "Title" }), { target: { value: "Unsaved title" } });
    fetchMock.mockImplementation(async () => json({ ...effective, title: "Changed outside the app" }));
    await fireEvent.click(screen.getByRole("button", { name: "Refresh preview" }));
    await screen.findByText("Changed outside the app");
    expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue("Unsaved title");
    expect(screen.getByText(/Unsaved changes/)).toBeInTheDocument();
  });

  it("clears a successful preview on failure and recovers through retry", async () => {
    const fetchMock = mockApi();
    render(ContextPanel, props);
    await screen.findByText("History Essays");
    fetchMock.mockImplementation(async () => json({ error: { message: "Invalid ancestor context." } }, 422));
    await fireEvent.click(screen.getByRole("button", { name: "Refresh preview" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Invalid ancestor context.");
    expect(screen.queryByText("History Essays")).not.toBeInTheDocument();
    fetchMock.mockImplementation(async () => json(effective));
    await fireEvent.click(screen.getByRole("button", { name: "Retry preview" }));
    await screen.findByText("History Essays");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("ignores an old account's effective response after switching accounts", async () => {
    let resolveOld!: (response: Response) => void;
    vi.stubGlobal("fetch", vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (!url.includes("/effective")) return Promise.resolve(json({}));
      if (url.includes("alice")) return new Promise<Response>((resolve) => { resolveOld = resolve; });
      return Promise.resolve(json({ ...effective, title: "Bob's context" }));
    }));
    const { rerender } = render(ContextPanel, { ...props, accountId: "alice" });
    await waitFor(() => expect(resolveOld).toBeDefined());
    await rerender({ ...props, accountId: "bob" });
    await screen.findByText("Bob's context");
    resolveOld(json({ ...effective, title: "Alice's context" }));
    await waitFor(() => expect(screen.queryByText("Resolving context…")).not.toBeInTheDocument());
    expect(screen.queryByText("Alice's context")).not.toBeInTheDocument();
    expect(screen.getByText("Bob's context")).toBeInTheDocument();
  });

  it("loads a missing folder layer as inherited and renders resolved essay context", async () => {
    const fetchMock = mockApi();
    render(ContextPanel, props);
    expect(await screen.findByText("History Essays")).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "Create context" })).toBeEnabled();
    expect(screen.getByText("Use sources.")).toBeInTheDocument();
    expect(screen.getByText("Clear writing")).toBeInTheDocument();
    const urls = fetchMock.mock.calls.map(([input]) => new URL(String(input), "http://localhost"));
    expect(urls.some((url) => url.pathname.includes("alice%20smith") && url.searchParams.get("path") === "History & Art/context.json")).toBe(true);
    expect(urls.some((url) => url.pathname.endsWith("/effective") && url.searchParams.get("path") === "History & Art/draft.md")).toBe(true);
  });

  it("creates tagged overrides, updates the saved layer, and removes it with confirmation", async () => {
    const fetchMock = mockApi();
    render(ContextPanel, props);
    await screen.findByRole("button", { name: "Create context" });
    await changeMode("Title behavior", "SetScalar");
    await fireEvent.input(screen.getByRole("textbox", { name: "Title" }), { target: { value: "My essay" } });
    await changeMode("Audience behavior", "ClearScalar");
    await changeMode("Instructions behavior", "AppendList");
    await fireEvent.input(screen.getByRole("textbox", { name: "Instructions" }), { target: { value: "Cite sources.\n\nUse examples." } });
    await changeMode("Tags behavior", "ReplaceList");
    await changeMode("Rubric behavior", "MergeRubric");
    await fireEvent.click(screen.getByRole("button", { name: "Add criterion" }));
    await fireEvent.input(screen.getByLabelText("Criterion 1 name"), { target: { value: "argument" } });
    await fireEvent.input(screen.getByLabelText("Criterion 1 weight"), { target: { value: "0.5" } });
    await fireEvent.click(screen.getByRole("button", { name: "Create context" }));
    await screen.findByText("Context saved.");
    const create = fetchMock.mock.calls.find(([, init]) => init?.method === "POST");
    expect(JSON.parse(String(create?.[1]?.body))).toEqual({ path: "History & Art/context.json", contextLayer: {
      title: { tag: "SetScalar", contents: "My essay" }, audience: { tag: "ClearScalar" },
      tags: { tag: "ReplaceList", contents: [] }, instructions: { tag: "AppendList", contents: ["Cite sources.", "Use examples."] },
      rubric: { tag: "MergeRubric", contents: { argument: { weight: 0.5, description: null } } }
    } });
    await changeMode("Title behavior", "inherit");
    await fireEvent.click(screen.getByRole("button", { name: "Save context" }));
    await waitFor(() => expect(fetchMock.mock.calls.some(([, init]) => init?.method === "PUT")).toBe(true));
    await screen.findByText("Context saved.");
    await fireEvent.click(screen.getByRole("button", { name: "Remove layer" }));
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(false);
    await fireEvent.click(screen.getByRole("button", { name: "Confirm removal" }));
    await screen.findByText("Layer removed. Parent settings now apply.");
    const deletion = fetchMock.mock.calls.find(([, init]) => init?.method === "DELETE");
    expect(deletion?.[0]).toBe("/api/v1/accounts/alice%20smith/workspace/context");
    expect(deletion?.[1]?.headers).toEqual({ "Content-Type": "application/json" });
    expect(JSON.parse(String(deletion?.[1]?.body))).toEqual({ path: "History & Art/context.json" });
    expect(screen.getByRole("button", { name: "Create context" })).toBeEnabled();
    expect(fetchMock.mock.calls.filter(([url]) => String(url).includes("/effective"))).toHaveLength(4);
  });

  it("shows read errors without treating them as missing layers and allows retry", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => json({ error: { message: "Unable to access context." } }, 500)));
    render(ContextPanel, { ...props, essayPath: null });
    expect(await screen.findByRole("alert")).toHaveTextContent("Unable to access context.");
    expect(screen.getByRole("button", { name: "Create context" })).toBeDisabled();
    mockApi();
    await fireEvent.click(screen.getByRole("button", { name: "Reload" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Create context" })).toBeEnabled());
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("shows resolved parent lists read only and saves only the current context additions", async () => {
    const fetchMock = mockApi({
      tags: { tag: "AppendList", contents: ["local"] },
      instructions: { tag: "AppendList", contents: ["Local instruction."] },
      grading_directions: { tag: "AppendList", contents: ["Local grading."] }
    }, {
      "context.json": {
        tags: { tag: "AppendList", contents: ["history", "history"] },
        instructions: { tag: "AppendList", contents: ["Root instruction."] },
        grading_directions: { tag: "AppendList", contents: ["Root grading."] }
      },
      "History/context.json": {
        tags: { tag: "AppendList", contents: ["history", "art"] },
        instructions: { tag: "ReplaceList", contents: ["Parent instruction."] },
        grading_directions: { tag: "ReplaceList", contents: [] }
      },
      "History/Art/context.json": {}
    });
    render(ContextPanel, { accountId: "alice", directoryPath: ["History", "Art", "Drafts"], essayPath: null });
    const inheritedInstructions = await screen.findByRole("textbox", { name: "Inherited instructions" });
    await waitFor(() => expect(inheritedInstructions).toHaveValue("Parent instruction."));
    expect(inheritedInstructions).toHaveAttribute("readonly");
    expect(screen.getByRole("textbox", { name: "Inherited tags" })).toHaveValue("history\nart");
    expect(screen.getByRole("textbox", { name: "Inherited grading directions" })).toHaveValue("");
    expect(screen.getByRole("textbox", { name: "Instructions" })).toHaveValue("Local instruction.");
    expect(inheritedInstructions.compareDocumentPosition(screen.getByRole("textbox", { name: "Instructions" })) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    await fireEvent.input(screen.getByRole("textbox", { name: "Instructions" }), { target: { value: "Edited local instruction." } });
    expect(inheritedInstructions).toHaveValue("Parent instruction.");
    await fireEvent.click(screen.getByRole("button", { name: "Save context" }));
    await screen.findByText("Context saved.");
    const update = fetchMock.mock.calls.find(([, init]) => init?.method === "PUT");
    expect(JSON.parse(String(update?.[1]?.body)).contextLayer.instructions).toEqual({ tag: "AppendList", contents: ["Edited local instruction."] });
    await changeMode("Instructions behavior", "ReplaceList");
    expect(screen.queryByRole("textbox", { name: "Inherited instructions" })).not.toBeInTheDocument();
  });

  it("clears the inherited display when switching to the workspace root", async () => {
    mockApi({ instructions: { tag: "AppendList", contents: ["Local instruction."] } }, {
      "context.json": { instructions: { tag: "AppendList", contents: ["Root instruction."] } }
    });
    render(ContextPanel, { ...props, essayPath: null });
    await waitFor(() => expect(screen.getByRole("textbox", { name: "Inherited instructions" })).toHaveValue("Root instruction."));
    await fireEvent.change(screen.getByLabelText("Edit settings for"), { target: { value: "" } });
    await waitFor(() => expect(screen.getByRole("textbox", { name: "Inherited instructions" })).toHaveValue(""));
    expect(screen.getByRole("textbox", { name: "Instructions" })).toHaveValue("Root instruction.");
  });

  it("ignores a stale folder response after changing selection", async () => {
    let resolveOld!: (response: Response) => void;
    vi.stubGlobal("fetch", vi.fn((input: RequestInfo | URL) => {
      const url = new URL(String(input), "http://localhost");
      if (url.searchParams.get("path") === "Old/context.json") return new Promise<Response>((resolve) => { resolveOld = resolve; });
      return Promise.resolve(json({ title: { tag: "SetScalar", contents: "New folder" } }));
    }));
    const { rerender } = render(ContextPanel, { accountId: "alice", directoryPath: ["Old"], essayPath: null });
    await waitFor(() => expect(resolveOld).toBeDefined());
    await rerender({ accountId: "alice", directoryPath: ["New"], essayPath: null });
    await screen.findByDisplayValue("New folder");
    resolveOld(json({ title: { tag: "SetScalar", contents: "Old folder" } }));
    await waitFor(() => expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue("New folder"));
  });
});
