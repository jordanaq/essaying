import { afterEach, describe, expect, it, vi } from "vitest";
import { contextRequest, ContextApiError } from "./context-api";

afterEach(() => vi.unstubAllGlobals());

describe("context error responses", () => {
  it("preserves only supported string details", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ error: {
      code: "INVALID_CONTEXT", message: "Invalid weight.",
      details: { path: "History/context.json", field: 'rubric.contents["use.of.sources"].weight', parameter: "contextLayer", extra: "ignored" }
    } }), { status: 422 })));
    await expect(contextRequest("alice", "History/context.json")).rejects.toMatchObject({
      status: 422, message: "Invalid weight.",
      details: { path: "History/context.json", field: 'rubric.contents["use.of.sources"].weight' }
    });
  });

  it.each([
    [{ error: { message: "Invalid context.", details: { path: 12, field: {} } } }, "Invalid context."],
    [{ error: { message: "Invalid context.", details: { path: " ", field: "" } } }, "Invalid context."],
    [{ error: { message: "Invalid context.", details: null } }, "Invalid context."],
    [null, "null"]
  ])("handles missing or malformed error details: %j", async (body, message) => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(body), { status: 422 })));
    await expect(contextRequest("alice", "context.json")).rejects.toMatchObject({ message, details: {} });
  });

  it("keeps plain-text failures usable", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("Service unavailable", { status: 503 })));
    const error = await contextRequest("alice", "context.json").catch((error) => error);
    expect(error).toBeInstanceOf(ContextApiError);
    expect(error).toMatchObject({ status: 503, message: "Service unavailable", details: {} });
  });
});
