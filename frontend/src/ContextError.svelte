<script lang="ts">
  import type { ContextErrorInfo } from "./context-api";

  export let error: ContextErrorInfo;
</script>

<div role="alert" class="context-error">
  <p>{error.message}</p>
  {#if error.details.path || error.details.field}
    <details>
      <summary>Details</summary>
      <dl>
        {#if error.details.path}<div><dt>File</dt><dd><code>{error.details.path}</code></dd></div>{/if}
        {#if error.details.field}<div><dt>Field</dt><dd><code>{error.details.field}</code></dd></div>{/if}
      </dl>
    </details>
  {/if}
</div>

<style>
  .context-error { margin: 12px 0; color: var(--ctp-text); border-left: 3px solid #f5a97f; padding-left: 10px; overflow-wrap: anywhere; }
  p { margin: 0; font-size: .85rem; line-height: 1.5; }
  details { margin-top: 6px; }
  summary { cursor: pointer; font-size: .78rem; }
  summary:focus-visible { outline: 2px solid var(--ctp-rosewater); outline-offset: 2px; }
  dl { margin: 6px 0 0; font-size: .78rem; line-height: 1.5; }
  dl div { display: grid; grid-template-columns: 40px minmax(0, 1fr); gap: 8px; margin-top: 4px; }
  dt { color: var(--ctp-subtext0); }
  dd { margin: 0; }
  code { white-space: pre-wrap; }
</style>
