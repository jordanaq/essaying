<script lang="ts">
  import type { GradeResult } from "./grading-api";
  export let result: GradeResult | null = null;
  export let loading = false;
  export let error = "";
  export let stale = false;
  export let essayTitle = "";
  const number = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });
</script>

<section aria-label="Essay grading feedback" aria-busy={loading}>
  {#if loading}
    <p role="status">Grading {essayTitle}… You can keep editing while you wait.</p>
  {:else if error}
    <p class="error" role="alert">Could not grade essay: {error}</p>
    <p>When ready, choose Grade essay to try again.</p>
  {:else if result}
    <h2>Feedback for {essayTitle}</h2>
    {#if stale}
      <p class="stale" role="status">This feedback is for earlier saved inputs. Save or discard your changes and grade again for an updated result.</p>
    {/if}
    <p class="overall">Overall score: <strong>{number.format(result.overallScore)} / 100</strong></p>
    <div class="feedback-text">{result.feedback}</div>
    {#each Object.entries(result.criteria) as [name, criterion]}
      <article aria-label={`Feedback for ${name}`}>
        <h3>{name}</h3>
        <p>{number.format(criterion.score)} / 100 · Weight: {number.format(criterion.normalizedWeight * 100)}%</p>
        <div class="feedback-text">{criterion.feedback}</div>
      </article>
    {/each}
  {:else}
    <p>Choose Grade essay to get feedback on your saved draft using the effective rubric.</p>
  {/if}
</section>

<style>
  h2 { font-size: 1.1rem; margin: 0 0 12px; overflow-wrap: anywhere; }
  h3 { font-size: 1rem; margin: 0; overflow-wrap: anywhere; }
  p { color: var(--ctp-subtext0); font-size: 0.9rem; }
  .overall { color: var(--ctp-text); }
  .feedback-text { white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.5; }
  article { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--ctp-surface2); }
  .error { color: var(--ctp-red); }
  .stale { padding: 10px; border: 1px solid var(--ctp-rosewater); border-radius: 6px; }
</style>
