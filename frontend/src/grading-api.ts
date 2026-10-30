export type CriterionGrade = { score: number; feedback: string; normalizedWeight: number };
export type GradeResult = { overallScore: number; feedback: string; criteria: Record<string, CriterionGrade> };

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function score(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100;
}
function feedback(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

// Check the wire response before rendering; scores and weights are calculated
// by the backend, never reconstructed from provider output in the browser.
export function parseGradeResult(value: unknown, criterionNames: string[]): GradeResult {
  if (!record(value) || !score(value.overallScore) || !feedback(value.feedback) || !record(value.criteria)) {
    throw new Error("The server returned an invalid grading result. Try grading again.");
  }
  const entries = Object.entries(value.criteria);
  if (entries.length !== criterionNames.length || entries.some(([name, grade]) =>
    !criterionNames.includes(name) || !record(grade) || !score(grade.score) || !feedback(grade.feedback)
    || typeof grade.normalizedWeight !== "number" || !Number.isFinite(grade.normalizedWeight)
    || grade.normalizedWeight < 0 || grade.normalizedWeight > 1
  )) {
    throw new Error("The server returned an invalid grading result. Try grading again.");
  }
  return value as GradeResult;
}

export async function gradeEssay(accountId: string, path: string[], criterionNames: string[], signal: AbortSignal): Promise<GradeResult> {
  const response = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/ai/grade`, {
    method: "POST", headers: { "Content-Type": "application/json" }, signal,
    body: JSON.stringify({ path: path.join("/") })
  });
  if (!response.ok) {
    const body = await response.text();
    let message = body || `HTTP ${response.status}`;
    try { message = JSON.parse(body).error?.message ?? message; } catch { /* Plain HTTP error. */ }
    throw new Error(message);
  }
  return parseGradeResult(await response.json(), criterionNames);
}
