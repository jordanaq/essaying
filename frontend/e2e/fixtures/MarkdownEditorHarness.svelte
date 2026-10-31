<script lang="ts">
  import MarkdownEditor from "../../src/MarkdownEditor.svelte";
  let draft = "# An argument\n\nA **clear** opening.\n\n- Evidence\n- Explanation\n\n1. Introduce the claim\n2. Support it";
  let prompt = "Explain your position and support it with evidence.";
  let edits = 0;
</script>

<main>
  <h1>Markdown editor review</h1>
  <p>Component preview for L21. These edits stay in this browser page.</p>
  <MarkdownEditor label="Assignment prompt" bind:value={prompt} rows={5} onChange={() => edits += 1} />
  <MarkdownEditor label="Draft" bind:value={draft} onChange={() => edits += 1} />
  <p role="status" aria-label="Edit count">{edits} edits</p>
  <button type="button" on:click={() => { draft = "# Another essay\n\nA fresh document."; }}>Load another draft</button>
  <details><summary>Draft Markdown output</summary><pre data-testid="draft-output">{draft}</pre></details>
  <details><summary>Assignment Markdown output</summary><pre data-testid="prompt-output">{prompt}</pre></details>
</main>

<style>
  main { width: min(850px, calc(100% - 32px)); margin: 32px auto; }
  main > :global(section) { margin: 24px 0; }
  pre { white-space: pre-wrap; }
</style>
