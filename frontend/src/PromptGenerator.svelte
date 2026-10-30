<script lang="ts">
  import { onDestroy } from "svelte";

  export let accountId: string;
  export let essayPath: string[];
  export let contextReady = false;
  export let contextDirty = false;
  export let unavailableReason = "";
  export let onAdopt: (candidate: string) => void = () => {};

  let instructions = "";
  let prompts: string[] = [];
  let generating = false;
  let error = "";
  let controller: AbortController | undefined;

  $: blockedReason = contextDirty ? "Save or discard context changes before generating prompts."
    : !contextReady ? "Prompt generation requires valid writing context. Check the Context panel."
    : unavailableReason;
  // A changed context invalidates both the in-flight request and its candidates.
  $: if (!contextReady || contextDirty) clearResults();

  function clearResults() {
    controller?.abort();
    prompts = [];
    generating = false;
    error = "";
  }

  onDestroy(() => controller?.abort());

  function adopt(candidate: string) {
    if (!generating && !blockedReason) onAdopt(candidate);
  }

  async function generate() {
    if (generating || blockedReason) return;
    const request = new AbortController();
    controller = request;
    generating = true;
    prompts = [];
    error = "";
    try {
      const response = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/ai/prompt`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: request.signal,
        body: JSON.stringify({
          path: essayPath.join("/"),
          ...(instructions.trim() ? { instructions: instructions.trim() } : {})
        })
      });
      if (!response.ok) {
        const body = await response.text();
        let message = body || `HTTP ${response.status}`;
        try { message = JSON.parse(body).error?.message ?? message; } catch { /* Plain text error. */ }
        throw new Error(message);
      }
      const data: unknown = await response.json();
      if (typeof data !== "object" || data === null || !("prompts" in data)
          || !Array.isArray(data.prompts) || data.prompts.length === 0
          || !data.prompts.every((candidate: unknown) => typeof candidate === "string" && candidate.trim())) {
        throw new Error("No valid prompt candidates were returned. Try generating again.");
      }
      // Abort also guards against late responses when a transport ignores cancellation.
      if (!request.signal.aborted) prompts = data.prompts;
    } catch (cause) {
      if (!request.signal.aborted) error = cause instanceof Error ? cause.message : String(cause);
    } finally {
      if (!request.signal.aborted) generating = false;
    }
  }
</script>

<details class="prompt-generator">
  <summary>Generate prompts</summary>
  <p>Generate assignment options from saved writing context. Your draft and current assignment are not sent.</p>
  <label>
    Extra instructions (optional)
    <textarea rows="3" bind:value={instructions} disabled={generating}
      placeholder="For example: offer three questions comparing historical causes."></textarea>
  </label>
  <button type="button" on:click={generate} disabled={generating || !!blockedReason}>
    {generating ? "Generating prompts…" : "Generate"}
  </button>
  {#if blockedReason}<p role="status">{blockedReason}</p>{/if}
  {#if generating}<p role="status">Generating assignment options…</p>{/if}
  {#if error}<p role="alert" class="error">Could not generate prompts: {error}</p>{/if}
  {#if prompts.length}
    <section aria-label="Generated prompt candidates">
      <p role="status">{prompts.length} prompt {prompts.length === 1 ? "candidate" : "candidates"} generated.</p>
      <p>Double-click an option or choose “Use this prompt” to copy it into the assignment editor. Save Prompt keeps it.</p>
      {#each prompts as candidate, index}
        <!-- Double-click is a pointer shortcut; the button provides keyboard and touch access. -->
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
        <article aria-label={`Prompt option ${index + 1}`} on:dblclick={(event) => {
          if (!(event.target as HTMLElement).closest("button")) adopt(candidate);
        }}>
          <h3>Option {index + 1}</h3>
          <div class="candidate-text">{candidate}</div>
          <button type="button" disabled={generating || !!blockedReason}
            aria-label={`Use prompt option ${index + 1}`} on:click={() => adopt(candidate)}>Use this prompt</button>
        </article>
      {/each}
    </section>
  {/if}
</details>

<style>
  .prompt-generator { margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--ctp-surface2); }
  summary { cursor: pointer; font-weight: 600; }
  p { color: var(--ctp-subtext0); font-size: 0.875rem; }
  label { display: grid; gap: 6px; margin-bottom: 12px; font-size: 0.875rem; }
  textarea { box-sizing: border-box; width: 100%; resize: vertical; padding: 10px; border: 1px solid var(--ctp-surface2); border-radius: 6px; background: var(--ctp-base); color: var(--ctp-text); font: inherit; }
  button { padding: 8px 12px; border: 1px solid var(--ctp-surface2); border-radius: 6px; background: var(--ctp-surface0); color: var(--ctp-text); font: inherit; cursor: pointer; }
  button:disabled { opacity: 0.5; cursor: default; }
  article { margin-top: 12px; padding: 14px; border: 1px solid var(--ctp-surface2); border-radius: 8px; }
  h3 { margin: 0 0 10px; font-size: 0.95rem; }
  .candidate-text { white-space: pre-wrap; overflow-wrap: anywhere; }
  article button { margin-top: 12px; }
  .error { color: var(--ctp-red); }
</style>
