<script lang="ts">
  import { onDestroy } from "svelte";
  import { contextRequest, ContextApiError, type ContextLayer } from "./context-api";
  import { createContextPreview } from "./context-preview";

  export let preview = createContextPreview();
  export let accountId: string;
  export let directoryPath: string[] = [];
  export let essayPath: string[] | null = null;

  type Field = { key: "title" | "audience" | "model"; label: string; mode: string; value: string };
  type ListField = { key: "tags" | "instructions" | "grading_directions"; label: string; mode: string; value: string };
  type RubricRow = { name: string; weight: number; description: string };
  let fields: Field[] = [];
  let lists: ListField[] = [];
  let inherited: Record<ListField["key"], string[]> = { tags: [], instructions: [], grading_directions: [] };
  let inheritedLoading = false;
  let inheritedError = "";
  let rubricMode = "inherit";
  let criteria: RubricRow[] = [];
  let scope = "";
  let currentSelection = "";
  let exists = false;
  let loading = false;
  export let busy = false;
  let error = "";
  let notice = "";
  export let dirty = false;
  let confirmDelete = false;
  $: effective = $preview.context;
  $: effectiveError = $preview.error;
  $: effectiveLoading = $preview.status === "loading";
  let layerController: AbortController | undefined;
  let mutationController: AbortController | undefined;

  $: selection = JSON.stringify([accountId, directoryPath]);
  $: if (selection !== currentSelection) {
    currentSelection = selection;
    scope = directoryPath.join("/");
  }
  $: scopes = Array.from({ length: directoryPath.length + 1 }, (_, index) => directoryPath.slice(0, index).join("/"));
  $: essayScope = essayPath !== null && scope === essayPath.join("/");
  $: layerPath = scope ? `${scope}/context.json` : "context.json";
  $: void loadLayer(accountId, layerPath);
  $: void preview.load(accountId, essayPath);

  onDestroy(() => {
    layerController?.abort();
    preview.cancel();
    mutationController?.abort();
  });

  function populate(layer: ContextLayer) {
    fields = (["title", "audience", "model"] as const).map((key) => {
      const operation = layer[key];
      return { key, label: key.charAt(0).toUpperCase() + key.slice(1), mode: operation?.tag ?? "inherit", value: operation?.tag === "SetScalar" ? operation.contents : "" };
    });
    lists = (["tags", "instructions", "grading_directions"] as const).map((key) => {
      const operation = layer[key];
      return { key, label: key === "grading_directions" ? "Grading directions" : key.charAt(0).toUpperCase() + key.slice(1), mode: operation?.tag ?? "inherit", value: operation?.contents.join("\n") ?? "" };
    });
    rubricMode = layer.rubric?.tag ?? "inherit";
    criteria = Object.entries(layer.rubric?.contents ?? {}).map(([name, criterion]) => ({ name, weight: criterion.weight, description: criterion.description ?? "" }));
    dirty = false;
    confirmDelete = false;
  }

  export function discardChanges() {
    void loadLayer(accountId, layerPath);
  }

  async function loadLayer(account: string, path: string) {
    layerController?.abort();
    mutationController?.abort();
    busy = false;
    const controller = new AbortController();
    layerController = controller;
    loading = true;
    error = notice = "";
    exists = false;
    populate({});
    void loadInherited(account, path, controller);
    try {
      const layer = await contextRequest<ContextLayer>(account, path, { signal: controller.signal });
      if (controller.signal.aborted) return;
      populate(layer);
      exists = true;
    } catch (err) {
      if (controller.signal.aborted) return;
      if (!(err instanceof ContextApiError && err.status === 404)) error = String(err instanceof Error ? err.message : err);
    } finally {
      if (!controller.signal.aborted) loading = false;
    }
  }

  async function loadInherited(account: string, path: string, controller: AbortController) {
    inherited = { tags: [], instructions: [], grading_directions: [] };
    inheritedError = "";
    const directories = path.split("/").slice(0, -1);
    inheritedLoading = directories.length > 0;
    try {
      const parents = await Promise.all(directories.map(async (_, index) => {
        const parentPath = [...directories.slice(0, index), "context.json"].join("/");
        try {
          return await contextRequest<ContextLayer>(account, parentPath, { signal: controller.signal });
        } catch (err) {
          if (err instanceof ContextApiError && err.status === 404) return {};
          throw err;
        }
      }));
      if (controller.signal.aborted) return;
      const resolved: typeof inherited = { tags: [], instructions: [], grading_directions: [] };
      for (const parent of parents) {
        for (const key of ["tags", "instructions", "grading_directions"] as const) {
          const operation = parent[key];
          if (operation) resolved[key] = operation.tag === "ReplaceList" ? [...operation.contents] : [...resolved[key], ...operation.contents];
        }
        resolved.tags = [...new Set(resolved.tags)];
      }
      inherited = resolved;
    } catch (err) {
      if (!controller.signal.aborted) inheritedError = err instanceof Error ? err.message : String(err);
    } finally {
      if (!controller.signal.aborted) inheritedLoading = false;
    }
  }

  function buildLayer(): ContextLayer {
    const layer: ContextLayer = {};
    for (const field of fields) {
      if (field.mode === "SetScalar") {
        if (!field.value.trim()) throw new Error(`${field.label} must not be blank.`);
        layer[field.key] = { tag: "SetScalar", contents: field.value };
      } else if (field.mode === "ClearScalar") layer[field.key] = { tag: "ClearScalar" };
    }
    for (const field of lists) {
      if (field.mode === "AppendList" || field.mode === "ReplaceList") {
        layer[field.key] = { tag: field.mode, contents: field.value.split("\n").map((line) => line.trim()).filter(Boolean) };
      }
    }
    if (rubricMode === "MergeRubric" || rubricMode === "ReplaceRubric") {
      const entries = criteria.map((row) => {
        if (!row.name.trim() || !Number.isFinite(row.weight) || row.weight < 0) throw new Error("Each criterion needs a name and a nonnegative weight.");
        return [row.name.trim(), { weight: row.weight, description: row.description.trim() || null }] as const;
      });
      if (new Set(entries.map(([name]) => name)).size !== entries.length) throw new Error("Criterion names must be unique.");
      layer.rubric = { tag: rubricMode, contents: Object.fromEntries(entries) };
    }
    return layer;
  }

  async function mutate(remove = false) {
    const controller = new AbortController();
    mutationController = controller;
    busy = true;
    error = notice = "";
    try {
      const layer = remove ? undefined : buildLayer();
      preview.cancel();
      const saved = await contextRequest<ContextLayer>(accountId, layerPath, {
        method: remove ? "DELETE" : exists ? "PUT" : "POST", layer, signal: controller.signal
      });
      if (controller.signal.aborted) return;
      exists = !remove;
      populate(saved ?? {});
      notice = remove ? "Layer removed. Parent settings now apply." : "Context saved.";
      void preview.load(accountId, essayPath);
    } catch (err) {
      if (!controller.signal.aborted) {
        error = err instanceof Error ? err.message : String(err);
        void preview.load(accountId, essayPath);
      }
    } finally {
      if (!controller.signal.aborted) busy = false;
    }
  }
</script>

<section class="context-panel" aria-label="Writing context">
  <div class="context-heading">
    <div><h3>Writing context</h3><p>Give every draft the right direction.</p></div>
    <span class="context-chip">{loading ? "Loading…" : exists ? essayScope ? "Essay layer" : "Folder layer" : "Inherited"}</span>
  </div>
  <label class="scope-label">Edit settings for
    <select bind:value={scope} disabled={loading || busy || dirty}>
      {#each scopes as path}<option value={path}>{path ? path === essayPath?.join("/") ? `${path} (this essay)` : path : "Workspace root"}</option>{/each}
    </select>
  </label>
  <p class="context-hint">{essayScope ? "Settings apply to this essay. Inherit keeps the parent setting." : "Settings apply to every essay in this folder and its descendants. Inherit keeps the parent setting."}</p>
  {#if error}<p role="alert" class="context-error">{error}</p>{/if}
  {#if notice}<p role="status" class="context-notice">{notice}</p>{/if}
  {#if loading}
    <p role="status">Loading context…</p>
  {:else}
    <form on:submit|preventDefault={() => mutate()} on:input={() => { dirty = true; notice = ""; }} on:change={() => { dirty = true; notice = ""; }}>
      <fieldset disabled={busy || !!error && !dirty}>
        {#each fields as field}
          <div class="context-field">
            <label for={`context-${field.key}-mode`}>{field.label}</label>
            <select id={`context-${field.key}-mode`} aria-label={`${field.label} behavior`} bind:value={field.mode}>
              <option value="inherit">Inherit</option><option value="SetScalar">Set value</option><option value="ClearScalar">Clear</option>
            </select>
            {#if field.mode === "SetScalar"}<input class="field-value" aria-label={field.label} bind:value={field.value} required placeholder={`Enter ${field.label.toLowerCase()}`} />{/if}
          </div>
        {/each}
        {#each lists as field}
          <div class="context-field">
            <label for={`context-${field.key}-mode`}>{field.label}</label>
            <select id={`context-${field.key}-mode`} aria-label={`${field.label} behavior`} bind:value={field.mode}>
              <option value="inherit">Inherit</option><option value="AppendList">Append</option><option value="ReplaceList">Replace</option>
            </select>
            {#if field.mode !== "inherit"}
              {#if field.mode === "AppendList"}
                <label class="field-value list-value">Inherited {field.label.toLowerCase()} (read only)
                  <textarea class="inherited-value" aria-label={`Inherited ${field.label.toLowerCase()}`} readonly rows="3"
                    value={inheritedLoading ? "Loading inherited items…" : inheritedError ? `Unable to load inherited items: ${inheritedError}` : inherited[field.key].join("\n")}
                    placeholder="No inherited items"></textarea>
                </label>
                <label class="field-value current-context-label" for={`context-${field.key}-value`}>Additions for this context</label>
              {/if}
              <textarea id={`context-${field.key}-value`} class="field-value" aria-label={field.label} bind:value={field.value} rows="3" placeholder="One item per line"></textarea>
              <small class="field-value">{field.mode === "ReplaceList" ? "Replaces inherited items. Leave empty to clear." : "Adds items after inherited items."}</small>
            {/if}
          </div>
        {/each}
        <div class="context-field">
          <label for="context-rubric-mode">Rubric</label>
          <select id="context-rubric-mode" aria-label="Rubric behavior" bind:value={rubricMode}>
            <option value="inherit">Inherit</option><option value="MergeRubric">Merge criteria</option><option value="ReplaceRubric">Replace rubric</option>
          </select>
        </div>
        {#if rubricMode !== "inherit"}
          <p class="context-hint">{rubricMode === "MergeRubric" ? "Adds criteria or overrides matching names." : "Replaces all inherited criteria. No criteria clears the rubric."}</p>
          {#each criteria as row, index}
            <div class="criterion-editor">
              <label>Name<input aria-label={`Criterion ${index + 1} name`} bind:value={row.name} required /></label>
              <label>Weight<input aria-label={`Criterion ${index + 1} weight`} type="number" min="0" step="any" bind:value={row.weight} required /></label>
              <label class="field-value">Description<input aria-label={`Criterion ${index + 1} description`} bind:value={row.description} /></label>
              <button class="text-button field-value" type="button" on:click={() => { criteria = criteria.filter((_, i) => i !== index); dirty = true; }}>Remove criterion</button>
            </div>
          {/each}
          <button type="button" on:click={() => { criteria = [...criteria, { name: "", weight: 1, description: "" }]; dirty = true; }}>Add criterion</button>
        {/if}
      </fieldset>
      <div class="context-actions">
        <button class="primary" type="submit" disabled={loading || busy || !!error && !dirty}>{busy ? "Saving…" : exists ? "Save context" : "Create context"}</button>
        <button type="button" disabled={busy} on:click={() => loadLayer(accountId, layerPath)}>{dirty ? "Discard changes" : "Reload"}</button>
        {#if exists}<button class="text-button" type="button" disabled={busy} on:click={() => (confirmDelete = !confirmDelete)}>Remove layer</button>{/if}
      </div>
      {#if dirty}<p class="context-hint">Unsaved changes. Save or discard before changing scope.</p>{/if}
    </form>
    {#if confirmDelete}
      <div class="delete-confirm"><p>Remove this {essayScope ? "essay’s" : "folder’s"} settings? Parent settings will apply.</p><button type="button" disabled={busy} on:click={() => mutate(true)}>Confirm removal</button><button type="button" disabled={busy} on:click={() => (confirmDelete = false)}>Cancel</button></div>
    {/if}
  {/if}
  <details class="effective-context" open>
    <summary>Effective essay context</summary>
    {#if essayPath && !effectiveError}
      <button type="button" disabled={effectiveLoading || busy} on:click={() => preview.load(accountId, essayPath)}>Refresh preview</button>
    {/if}
    {#if !essayPath}<p class="context-hint">Select an essay to see its combined settings.</p>
    {:else if effectiveLoading}<p role="status">Resolving context…</p>
    {:else if effectiveError}<p role="alert" class="context-error">{effectiveError}</p><button type="button" disabled={busy} on:click={() => preview.load(accountId, essayPath)}>Retry preview</button>
    {:else if effective}
      <p class="context-hint">Saved settings from root through this essay. {essayPath.join("/")}</p>
      <dl>{#each ["title", "audience", "model"] as key}<div><dt>{key}</dt><dd>{effective[key as "title" | "audience" | "model"] ?? "Not set"}</dd></div>{/each}</dl>
      <div class="context-tags">{#each effective.tags as tag}<span class="context-chip">{tag}</span>{/each}</div>
      {#each [{ label: "Instructions", items: effective.instructions }, { label: "Grading directions", items: effective.grading_directions }] as group}
        <h4>{group.label}</h4>{#if group.items.length}<ul>{#each group.items as item}<li>{item}</li>{/each}</ul>{:else}<p class="context-hint">None set.</p>{/if}
      {/each}
      <h4>Rubric</h4>
      {#if Object.keys(effective.rubric).length}
        <table><caption class="sr-only">Effective rubric criteria</caption><thead><tr><th>Criterion</th><th>Weight</th></tr></thead><tbody>{#each Object.entries(effective.rubric) as [name, criterion]}<tr><td>{name}{#if criterion.description}<small>{criterion.description}</small>{/if}</td><td>{criterion.weight}</td></tr>{/each}</tbody></table>
      {:else}<p class="context-hint">No criteria set.</p>{/if}
    {/if}
  </details>
</section>

<style>
  .context-panel { margin-bottom: 24px; color: var(--ctp-text); }
  .context-heading { display: flex; justify-content: space-between; gap: 12px; align-items: start; }
  h3 { font-size: 1.1rem; } h4 { margin: 18px 0 8px; font-size: .9rem; }
  p, li { font-size: .85rem; line-height: 1.5; }
  .context-heading p { margin: 5px 0 18px; color: var(--ctp-subtext0); }
  .context-chip { display: inline-block; font-size: .72rem; border: 1px solid var(--ctp-surface2); border-radius: 20px; padding: 4px 8px; white-space: nowrap; }
  .context-hint, small { color: var(--ctp-subtext0); font-size: .78rem; line-height: 1.5; }
  .scope-label, .criterion-editor label { display: grid; gap: 6px; font-size: .8rem; }
  input, textarea, select, button { font: inherit; color: var(--ctp-text); background: var(--ctp-mantle); border: 1px solid var(--ctp-surface2); border-radius: 6px; padding: 8px; min-width: 0; max-width: 100%; }
  input, textarea, select { width: 100%; font-size: .82rem; }
  textarea { resize: vertical; }
  button { cursor: pointer; font-size: .78rem; } button:disabled, fieldset:disabled { opacity: .55; cursor: default; }
  :is(input, textarea, select, button):focus-visible { outline: 2px solid var(--ctp-rosewater); outline-offset: 2px; }
  fieldset { border: 0; padding: 0; margin: 0; min-width: 0; }
  .context-field { display: grid; grid-template-columns: 1fr 145px; align-items: center; gap: 8px; padding: 10px 0; border-bottom: 1px solid var(--ctp-surface1); font-size: .85rem; }
  .field-value { grid-column: 1 / -1; }
  .list-value { display: grid; gap: 6px; font-size: .78rem; color: var(--ctp-subtext0); }
  .current-context-label { font-size: .78rem; color: var(--ctp-subtext0); }
  .inherited-value { background: var(--ctp-surface0); color: var(--ctp-subtext0); }
  .criterion-editor { display: grid; grid-template-columns: 1fr 75px; gap: 8px; margin: 10px 0; padding: 10px; border: 1px solid var(--ctp-surface1); border-radius: 8px; }
  .context-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
  .primary { background: var(--ctp-rosewater); color: var(--app-primary-fg); border-color: var(--ctp-rosewater); font-weight: 600; }
  .text-button { background: transparent; color: var(--ctp-subtext1); }
  .context-error { color: var(--ctp-text); border-left: 3px solid #f5a97f; padding-left: 10px; overflow-wrap: anywhere; }
  .context-notice { border-left: 3px solid var(--ctp-rosewater); padding-left: 10px; }
  .delete-confirm { margin-top: 12px; padding: 12px; border: 1px solid var(--ctp-rosewater); border-radius: 8px; } .delete-confirm button { margin-right: 8px; }
  .effective-context { margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--ctp-surface2); }
  summary { font-weight: 600; font-size: .9rem; cursor: pointer; }
  dl { margin: 14px 0; font-size: .82rem; } dl div { display: grid; grid-template-columns: 70px 1fr; gap: 8px; padding: 5px 0; } dt { text-transform: capitalize; color: var(--ctp-subtext0); } dd { margin: 0; overflow-wrap: anywhere; }
  .context-tags { display: flex; flex-wrap: wrap; gap: 6px; }
  ul { padding-left: 20px; } li { margin-bottom: 6px; overflow-wrap: anywhere; }
  table { border-collapse: collapse; width: 100%; font-size: .8rem; } th, td { text-align: left; vertical-align: top; padding: 8px 4px; border-bottom: 1px solid var(--ctp-surface1); overflow-wrap: anywhere; } td small { display: block; margin-top: 4px; } th:last-child, td:last-child { text-align: right; }
  .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
</style>
