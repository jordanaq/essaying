import { writable } from "svelte/store";
import { contextRequest, contextErrorInfo, type ContextErrorInfo, type EffectiveContext } from "./context-api";

export function contextSelection(accountId: string | null, essayPath: string[] | null): string {
  return JSON.stringify([accountId, essayPath]);
}

type Preview = {
  selection: string;
  status: "idle" | "loading" | "ready" | "error";
  context: EffectiveContext | null;
  error: ContextErrorInfo | null;
};

export function createContextPreview() {
  const { subscribe, set } = writable<Preview>({ selection: "", status: "idle", context: null, error: null });
  let controller: AbortController | undefined;

  function cancel() {
    controller?.abort();
    set({ selection: "", status: "idle", context: null, error: null });
  }

  async function load(accountId: string, essayPath: string[] | null) {
    controller?.abort();
    const request = new AbortController();
    controller = request;
    const selection = contextSelection(accountId, essayPath);
    set({ selection, status: essayPath ? "loading" : "idle", context: null, error: null });
    if (!essayPath) return;
    try {
      const context = await contextRequest<EffectiveContext>(accountId, essayPath.join("/"), {
        effective: true, signal: request.signal
      });
      if (!request.signal.aborted) set({ selection, status: "ready", context, error: null });
    } catch (error) {
      if (!request.signal.aborted) set({ selection, status: "error", context: null, error: contextErrorInfo(error) });
    }
  }

  return { subscribe, load, cancel };
}
