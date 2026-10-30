import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import PromptGenerator from "./PromptGenerator.svelte";

const props = { accountId: "alice smith", essayPath: ["History & Art", "Causes"], contextReady: true };
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });

async function openGenerator() {
  await fireEvent.click(screen.getByText("Generate prompts", { selector: "summary" }));
}

describe("Prompt generation", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("sends only the essay identity and optional instructions and displays numbered candidates", async () => {
    const fetchMock = vi.fn().mockResolvedValue(json({ prompts: ["# Compare causes\nUse sources.", "Explain the consequences."] }));
    vi.stubGlobal("fetch", fetchMock);
    const { container } = render(PromptGenerator, props);
    expect(container.querySelector("details")).not.toHaveAttribute("open");
    await openGenerator();
    await fireEvent.input(screen.getByLabelText("Extra instructions (optional)"), { target: { value: "  Offer two options.  " } });
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    const candidates = await screen.findAllByRole("article");
    expect(candidates).toHaveLength(2);
    expect(candidates[0]).toHaveAccessibleName("Prompt option 1");
    expect(candidates[0]).toHaveTextContent("# Compare causes Use sources.");
    expect(candidates[1]).toHaveAccessibleName("Prompt option 2");
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("/api/v1/accounts/alice%20smith/workspace/ai/prompt");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body)).toEqual({ path: "History & Art/Causes", instructions: "Offer two options." });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it.each([
    { contextReady: false, reason: /requires valid writing context/ },
    { contextDirty: true, reason: /Save or discard context changes/ },
    { unavailableReason: "Wait for loading.", reason: /Wait for loading/ }
  ])("blocks requests when unavailable: %j", async ({ reason, ...overrides }) => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    render(PromptGenerator, { ...props, ...overrides });
    await openGenerator();
    expect(screen.getByRole("button", { name: "Generate" })).toBeDisabled();
    expect(screen.getByRole("status")).toHaveTextContent(reason);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("prevents duplicate generation, omits blank instructions, and recovers from a provider failure", async () => {
    let resolve!: (response: Response) => void;
    const fetchMock = vi.fn().mockImplementationOnce(() => new Promise<Response>((done) => { resolve = done; }))
      .mockResolvedValueOnce(json({ prompts: ["Try this assignment."] }));
    vi.stubGlobal("fetch", fetchMock);
    render(PromptGenerator, props);
    await openGenerator();
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    expect(screen.getByRole("button", { name: "Generating prompts…" })).toBeDisabled();
    expect(JSON.parse(fetchMock.mock.calls[0]![1].body)).toEqual({ path: "History & Art/Causes" });
    resolve(new Response("Provider timed out. Try again.", { status: 504 }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Provider timed out. Try again.");
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    await screen.findByText("Try this assignment.");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it.each([{ prompts: [] }, { prompts: [" "] }, { prompts: [123] }, null])("rejects malformed results: %j", async (data) => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(json(data)));
    render(PromptGenerator, props);
    await openGenerator();
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("No valid prompt candidates");
    expect(screen.queryByRole("article")).not.toBeInTheDocument();
  });

  it("invalidates candidates when context is edited", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(json({ prompts: ["Old context assignment."] })));
    const { rerender } = render(PromptGenerator, props);
    await openGenerator();
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    await screen.findByText("Old context assignment.");
    await rerender({ ...props, contextDirty: true });
    expect(screen.queryByRole("article")).not.toBeInTheDocument();
  });

  it("ignores a late response after context invalidation, even if the transport ignores abort", async () => {
    let resolve!: (response: Response) => void;
    const fetchMock = vi.fn(() => new Promise<Response>((done) => { resolve = done; }));
    vi.stubGlobal("fetch", fetchMock);
    const { rerender } = render(PromptGenerator, props);
    await openGenerator();
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    await rerender({ ...props, contextReady: false });
    resolve(json({ prompts: ["Stale candidate."] }));
    await rerender(props);
    await waitFor(() => expect(screen.getByRole("button", { name: "Generate" })).toBeEnabled());
    expect(screen.queryByText("Stale candidate.")).not.toBeInTheDocument();
  });

  it("aborts on removal and cannot put old results into a new essay's component", async () => {
    let resolve!: (response: Response) => void;
    let signal!: AbortSignal;
    vi.stubGlobal("fetch", vi.fn((_url, init) => {
      signal = init.signal;
      return new Promise<Response>((done) => { resolve = done; });
    }));
    const { unmount } = render(PromptGenerator, props);
    await openGenerator();
    await fireEvent.click(screen.getByRole("button", { name: "Generate" }));
    unmount();
    expect(signal.aborted).toBe(true);
    render(PromptGenerator, { ...props, essayPath: ["Another essay"] });
    await openGenerator();
    resolve(json({ prompts: ["Previous essay candidate."] }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Generate" })).toBeEnabled());
    expect(screen.queryByText("Previous essay candidate.")).not.toBeInTheDocument();
  });
});
