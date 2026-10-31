export type Criterion = { weight: number; description: string | null };
export type ScalarOverride = { tag: "SetScalar"; contents: string } | { tag: "ClearScalar" };
export type ListOverride = { tag: "AppendList" | "ReplaceList"; contents: string[] };
export type ContextLayer = {
  title?: ScalarOverride | null;
  audience?: ScalarOverride | null;
  model?: ScalarOverride | null;
  tags?: ListOverride | null;
  instructions?: ListOverride | null;
  grading_directions?: ListOverride | null;
  rubric?: { tag: "MergeRubric" | "ReplaceRubric"; contents: Record<string, Criterion> } | null;
};
export type EffectiveContext = {
  title: string | null;
  audience: string | null;
  model: string | null;
  tags: string[];
  instructions: string[];
  grading_directions: string[];
  rubric: Record<string, Criterion>;
};

export type ContextErrorDetails = { path?: string; field?: string };
export type ContextErrorInfo = { message: string; details: ContextErrorDetails };

export class ContextApiError extends Error {
  constructor(public status: number, message: string, public details: ContextErrorDetails = {}) {
    super(message);
  }
}

export function contextErrorInfo(error: unknown): ContextErrorInfo {
  return {
    message: error instanceof Error ? error.message : String(error),
    details: error instanceof ContextApiError ? error.details : {}
  };
}

export async function contextRequest<T>(accountId: string, path: string, options: {
  effective?: boolean;
  method?: "GET" | "POST" | "PUT" | "DELETE";
  layer?: ContextLayer | undefined;
  signal?: AbortSignal;
} = {}): Promise<T> {
  const method = options.method ?? "GET";
  const base = `/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/context`;
  const url = method === "GET"
    ? `${base}${options.effective ? "/effective" : ""}?${new URLSearchParams({ path })}`
    : base;
  const response = await fetch(url, {
    method,
    signal: options.signal ?? null,
    ...(method === "GET" ? {} : {
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(method === "DELETE" ? { path } : { path, contextLayer: options.layer })
    })
  });
  if (!response.ok) {
    const body = await response.text();
    let message = body || `HTTP ${response.status}`;
    const details: ContextErrorDetails = {};
    try {
      const error = JSON.parse(body)?.error;
      if (typeof error?.message === "string" && error.message.trim()) message = error.message;
      for (const key of ["path", "field"] as const) {
        const value = error?.details?.[key];
        if (typeof value === "string" && value.trim()) details[key] = value;
      }
    } catch { /* Plain text error. */ }
    throw new ContextApiError(response.status, message, details);
  }
  return response.status === 204 ? undefined as T : await response.json() as T;
}
