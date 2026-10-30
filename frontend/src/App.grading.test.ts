import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import type { EffectiveContext } from "./context-api";

const context: EffectiveContext = {
  title: "Inherited context", audience: null, model: null, tags: [], instructions: [], grading_directions: [],
  rubric: { interpretation: { weight: 3, description: "Interpret fairly." }, evidence: { weight: 1, description: null } }
};
const result = {
  overallScore: 85, feedback: "A well-supported comparison.",
  criteria: {
    interpretation: { score: 90, feedback: "Good distinctions.", normalizedWeight: 0.75 },
    evidence: { score: 70, feedback: "Discuss another passage.", normalizedWeight: 0.25 }
  }
};
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

async function setup(options: { effective?: EffectiveContext; draft?: string; model?: string | null; brokenContext?: boolean } = {}) {
  const essays = ["First Essay", "Second Essay"].map((title) => ({ title, path: ["Religion", title], prompt: "", markdown: options.draft ?? "Saved comparison." }));
  const state = { grade: async (): Promise<Response> => json(result), calls: [] as RequestInit[] };
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.endsWith("/accounts")) return json([{ accountId: { unAccountId: "alice smith" }, displayName: "Alice", preferredModel: options.model === undefined ? "gpt-6.1-sol" : options.model }]);
    if (url.endsWith("/workspace")) return json({ tree: [{ name: "Religion", path: ["Religion"], nodeType: "WorkspaceDirectoryNode", children: essays.map((essay) => ({ name: essay.title, path: essay.path, nodeType: "WorkspaceEssayNode", children: [] })) }] });
    if (url.includes("/context/effective")) return options.brokenContext ? json({ error: { message: "Invalid ancestor context." } }, 422) : json(options.effective ?? context);
    // The essay has no context file: its valid effective context is inherited.
    if (url.includes("/context")) return json({ error: { message: "Context does not exist." } }, 404);
    if (url.endsWith("/ai/grade")) { state.calls.push(init!); return state.grade(); }
    const essay = essays.find((item) => url.endsWith(item.path.map(encodeURIComponent).join("/")));
    if (essay) {
      if (init?.method === "PUT") Object.assign(essay, JSON.parse(String(init.body)));
      return json(essay);
    }
    return new Response("", { status: 200 });
  });
  vi.stubGlobal("fetch", fetchMock);
  localStorage.setItem("essay-account-id", "alice smith");
  const rendered = render(App);
  await screen.findByText("Currently editing Religion/First Essay.");
  const gradeButton = () => screen.getByText("Grade essay", { selector: "sl-button" });
  const editor = (label: string) => Array.from(rendered.container.querySelectorAll<HTMLElement & { label: string; value: string }>("sl-textarea")).find((element) => element.label === label)!;
  const input = async (label: string, value: string) => {
    const element = editor(label);
    element.value = value;
    await fireEvent(element, new CustomEvent("sl-input"));
  };
  return { ...rendered, state, fetchMock, gradeButton, editor, input };
}

describe("Real essay grading", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    localStorage.clear();
    vi.spyOn(window, "confirm").mockReturnValue(true);
  });

  it("grades with inherited context, account model fallback and no assignment, then displays weighted feedback", async () => {
    const { gradeButton, state, fetchMock } = await setup();
    await waitFor(() => expect(gradeButton()).not.toHaveAttribute("disabled"));
    await fireEvent.click(gradeButton());
    await screen.findByText("A well-supported comparison.");
    expect(screen.getByRole("tab", { name: "Feedback" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText("85 / 100")).toBeInTheDocument();
    expect(screen.getByRole("article", { name: "Feedback for interpretation" })).toHaveTextContent("90 / 100 · Weight: 75%");
    expect(screen.getByRole("article", { name: "Feedback for evidence" })).toHaveTextContent("Discuss another passage.");
    const call = fetchMock.mock.calls.find(([url]) => String(url).endsWith("/ai/grade"))!;
    expect(call[0]).toBe("/api/v1/accounts/alice%20smith/workspace/ai/grade");
    expect(JSON.parse(String(state.calls[0]?.body))).toEqual({ path: "Religion/First Essay" });
  });

  it.each([
    { options: { draft: " \n " }, reason: "Write and save a nonblank draft" },
    { options: { effective: { ...context, rubric: {} } }, reason: "Add at least one rubric criterion" },
    { options: { effective: { ...context, rubric: { clarity: { weight: 0, description: null } } } }, reason: "finite, positive total weight" },
    { options: { effective: { ...context, rubric: { a: { weight: 1e308, description: null }, b: { weight: 1e308, description: null } } } }, reason: "finite, positive total weight" },
    { options: { model: null }, reason: "Select a model in Context" },
    { options: { brokenContext: true }, reason: "Grading is unavailable" }
  ])("blocks grading when $reason", async ({ options, reason }) => {
    const { gradeButton, state } = await setup(options);
    await screen.findByText(new RegExp(reason));
    expect(gradeButton()).toHaveAttribute("disabled");
    await fireEvent.click(gradeButton());
    expect(state.calls).toHaveLength(0);
  });

  it("accepts an effective model without an account preference", async () => {
    const { gradeButton } = await setup({ model: null, effective: { ...context, model: "gpt-6.1-sol" } });
    await waitFor(() => expect(gradeButton()).not.toHaveAttribute("disabled"));
  });

  it("keeps editing usable during grading, prevents duplicate calls and labels feedback for earlier inputs", async () => {
    const { gradeButton, state, input, editor } = await setup();
    let resolve!: (response: Response) => void;
    state.grade = () => new Promise((done) => { resolve = done; });
    await waitFor(() => expect(gradeButton()).not.toHaveAttribute("disabled"));
    await fireEvent.click(gradeButton());
    const pending = screen.getByText("Grading…", { selector: "sl-button" });
    await fireEvent.click(pending);
    expect(state.calls).toHaveLength(1);
    await input("Essay Markdown", "A newer draft.");
    await input("Assignment prompt", "A new assignment.");
    resolve(json(result));
    await screen.findByText("A well-supported comparison.");
    expect(screen.getByText(/This feedback is for earlier saved inputs/)).toBeInTheDocument();
    expect(editor("Essay Markdown").value).toBe("A newer draft.");
    expect(editor("Assignment prompt").value).toBe("A new assignment.");
    expect(gradeButton()).toHaveAttribute("disabled");
  });

  it.each([
    { response: () => new Response("AI provider timed out. Retry.", { status: 504 }), message: "AI provider timed out" },
    { response: () => json({ error: { message: "Provider unavailable." } }, 502), message: "Provider unavailable" },
    { response: () => json({ ...result, criteria: {} }), message: "invalid grading result" },
    { response: () => json({ ...result, overallScore: 150 }), message: "invalid grading result" }
  ])("shows $message and permits retry", async ({ response, message }) => {
    const { gradeButton, state } = await setup();
    state.grade = async () => response();
    await waitFor(() => expect(gradeButton()).not.toHaveAttribute("disabled"));
    await fireEvent.click(gradeButton());
    expect(await screen.findByRole("alert")).toHaveTextContent(message);
    expect(gradeButton()).not.toHaveAttribute("disabled");
    state.grade = async () => json(result);
    await fireEvent.click(gradeButton());
    await screen.findByText("A well-supported comparison.");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("ignores a late result after switching essays even if the transport ignores abort", async () => {
    const { gradeButton, state, container } = await setup();
    let resolve!: (response: Response) => void;
    state.grade = () => new Promise((done) => { resolve = done; });
    await waitFor(() => expect(gradeButton()).not.toHaveAttribute("disabled"));
    await fireEvent.click(gradeButton());
    const second = Array.from(container.querySelectorAll("sl-tree-item")).find((item) => item.getAttribute("data-path") === JSON.stringify(["Religion", "Second Essay"]))!;
    await fireEvent(container.querySelector("sl-tree")!, new CustomEvent("sl-selection-change", { detail: { selection: [second] } }));
    await screen.findByText("Currently editing Religion/Second Essay.");
    expect((state.calls[0]?.signal as AbortSignal).aborted).toBe(true);
    resolve(json(result));
    await waitFor(() => expect(gradeButton()).not.toHaveAttribute("disabled"));
    expect(screen.queryByText("A well-supported comparison.")).not.toBeInTheDocument();
  });
});
