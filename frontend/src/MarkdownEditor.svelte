<script lang="ts">
  import { onMount, tick } from "svelte";
  import { Editor } from "@tiptap/core";
  import { StarterKit } from "@tiptap/starter-kit";
  import { Markdown } from "@tiptap/markdown";

  export let label: string;
  export let value = "";
  export let documentKey = "";
  export let disabled = false;
  export let rows = 18;
  export let placeholder = "Start writing…";
  export let onChange: (markdown: string) => void = () => {};

  let host: HTMLDivElement;
  let source: HTMLTextAreaElement;
  let editor: Editor | undefined;
  let raw = false;
  let sourceOnly = false;
  let currentValue = value;
  let currentDocumentKey = documentKey;
  let renderedValue = "";
  let bold = false;
  let italic = false;
  let bulletList = false;
  let orderedList = false;
  let heading = "0";
  let canUndo = false;
  let canRedo = false;
  $: showRaw = raw || sourceOnly;

  // Mount once per document replacement. Ordinary edits and view switches keep
  // the same editor so selection and rich-text undo history survive.
  onMount(() => {
    replaceDocument(value);
    return () => editor?.destroy();
  });

  $: if (editor && (value !== currentValue || documentKey !== currentDocumentKey)) replaceDocument(value);
  $: if (editor) editor.setEditable(!disabled, false);
  $: if (editor) editor.setOptions({ editorProps: { attributes: {
    role: "textbox", "aria-label": label, "aria-multiline": "true",
    "aria-disabled": String(disabled), "data-placeholder": placeholder
  } } });

  function replaceDocument(markdown: string) {
    editor?.destroy();
    currentValue = markdown;
    currentDocumentKey = documentKey;
    editor = new Editor({
      element: host,
      extensions: [
        StarterKit.configure({
          underline: false,
          trailingNode: false,
          link: { openOnClick: false, autolink: false, linkOnPaste: false }
        }),
        Markdown
      ],
      editable: !disabled,
      content: "",
      onUpdate: ({ editor: instance }) => {
        if (!instance.isEditable || showRaw) return;
        renderedValue = instance.getMarkdown();
        publish(renderedValue);
      },
      onTransaction: ({ editor: instance }) => updateToolbar(instance)
    });
    loadMarkdown(markdown);
  }

  function needsSource(markdown: string) {
    if (!editor?.markdown) return false;
    // StarterKit covers these tokens. Keep unsupported structures in source
    // mode rather than silently dropping tables, images, tasks, or raw HTML.
    const supported = new Set([
      "space", "code", "heading", "hr", "blockquote", "list", "list_item",
      "paragraph", "text", "def", "escape", "link", "strong", "em", "codespan", "br", "del"
    ]);
    let unsupported = false;
    const tokens = editor.markdown.instance.lexer(markdown);
    editor.markdown.instance.walkTokens(tokens, (token) => {
      if (!supported.has(token.type) || (token.type === "list_item" && token.task)) unsupported = true;
    });
    return unsupported;
  }

  function loadMarkdown(markdown: string) {
    if (!editor) return;
    sourceOnly = needsSource(markdown);
    if (sourceOnly) raw = true;
    editor.chain().setMeta("addToHistory", false)
      .setContent(sourceOnly ? "" : markdown, { contentType: "markdown", emitUpdate: false }).run();
    renderedValue = markdown;
    updateToolbar(editor);
  }

  function updateToolbar(instance: Editor) {
    bold = instance.isActive("bold");
    italic = instance.isActive("italic");
    bulletList = instance.isActive("bulletList");
    orderedList = instance.isActive("orderedList");
    heading = String(instance.getAttributes("heading").level ?? 0);
    canUndo = instance.can().undo();
    canRedo = instance.can().redo();
  }

  function publish(markdown: string) {
    currentValue = markdown;
    value = markdown;
    onChange(markdown);
  }

  function editSource(event: Event) {
    if (disabled) return;
    publish((event.currentTarget as HTMLTextAreaElement).value);
    sourceOnly = needsSource(value);
    // Parse source only when returning to rendered mode. The textarea keeps
    // browser-native typing, selection, and undo while the user edits Markdown.
  }

  async function toggleMode() {
    if (disabled || sourceOnly) return;
    if (raw && value !== renderedValue) loadMarkdown(value);
    if (sourceOnly) return;
    raw = !raw;
    await focus();
  }

  export async function focus() {
    // A parent can replace the value and request focus in the same event (for
    // example adopting a generated prompt). Focus the editor after that update.
    await tick();
    if (disabled) return;
    if (showRaw) source?.focus();
    else editor?.commands.focus();
  }

  function setHeading(event: Event) {
    const level = Number((event.currentTarget as HTMLSelectElement).value);
    if (level === 0) editor?.chain().focus().setParagraph().run();
    else editor?.chain().focus().setHeading({ level: level as 1 | 2 | 3 | 4 | 5 | 6 }).run();
  }
</script>

<section class="markdown-editor" class:disabled style={`--editor-lines: ${rows};`} aria-label={`${label} editor`}>
  <div class="editor-heading">
    <span>{label}</span>
    <button type="button" aria-label={`Raw Markdown for ${label}`} aria-pressed={showRaw}
      disabled={disabled || sourceOnly} on:click={toggleMode}>Raw Markdown</button>
  </div>
  {#if sourceOnly}
    <p class="source-note" role="status">This document contains formatting that needs raw Markdown editing to preserve it.</p>
  {/if}
  <div class="formatting" role="group" aria-label={`${label} formatting`} hidden={showRaw}>
    <button type="button" aria-label="Bold" title="Bold (Ctrl+B / ⌘B)" aria-pressed={bold}
      disabled={disabled} on:mousedown|preventDefault on:click={() => editor?.chain().focus().toggleBold().run()}><strong>B</strong></button>
    <button type="button" aria-label="Italic" title="Italic (Ctrl+I / ⌘I)" aria-pressed={italic}
      disabled={disabled} on:mousedown|preventDefault on:click={() => editor?.chain().focus().toggleItalic().run()}><em>I</em></button>
    <select aria-label={`${label} text style`} value={heading} disabled={disabled} on:change={setHeading}>
      <option value="0">Paragraph</option>
      {#each [1, 2, 3, 4, 5, 6] as level}<option value={level}>Heading {level}</option>{/each}
    </select>
    <button type="button" aria-label="Bulleted list" title="Bulleted list" aria-pressed={bulletList}
      disabled={disabled} on:mousedown|preventDefault on:click={() => editor?.chain().focus().toggleBulletList().run()}>• List</button>
    <button type="button" aria-label="Numbered list" title="Numbered list" aria-pressed={orderedList}
      disabled={disabled} on:mousedown|preventDefault on:click={() => editor?.chain().focus().toggleOrderedList().run()}>1. List</button>
    <button type="button" aria-label="Undo" title="Undo (Ctrl+Z / ⌘Z)" disabled={disabled || !canUndo}
      on:mousedown|preventDefault on:click={() => editor?.chain().focus().undo().run()}>Undo</button>
    <button type="button" aria-label="Redo" title="Redo (Ctrl+Shift+Z / ⌘⇧Z)" disabled={disabled || !canRedo}
      on:mousedown|preventDefault on:click={() => editor?.chain().focus().redo().run()}>Redo</button>
  </div>
  <div class="rendered" hidden={showRaw} bind:this={host}></div>
  {#if showRaw}
    <textarea bind:this={source} aria-label={label} {rows} {disabled} {placeholder} {value} on:input={editSource}></textarea>
  {/if}
</section>

<style>
  .markdown-editor { min-width: 0; color: var(--ctp-text); }
  .editor-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 8px; font-size: .85rem; }
  .formatting { display: flex; flex-wrap: wrap; gap: 4px; padding: 6px; border: 1px solid var(--ctp-surface2); border-radius: 8px 8px 0 0; background: var(--ctp-mantle); }
  [hidden] { display: none; }
  button, select { font: inherit; font-size: .78rem; color: var(--ctp-text); background: var(--ctp-mantle); border: 1px solid var(--ctp-surface2); border-radius: 5px; padding: 6px 8px; cursor: pointer; }
  button[aria-pressed="true"] { background: var(--ctp-surface1); border-color: var(--ctp-rosewater); }
  button:disabled, select:disabled { opacity: .5; cursor: default; }
  :is(button, select, textarea):focus-visible { outline: 2px solid var(--ctp-rosewater); outline-offset: 2px; }
  .rendered { border: 1px solid var(--ctp-surface2); border-top: 0; border-radius: 0 0 8px 8px; resize: vertical; overflow: auto; min-height: 120px; }
  .rendered:focus-within { outline: 2px solid var(--ctp-rosewater); outline-offset: 2px; }
  .rendered :global(.tiptap) { min-height: calc(var(--editor-lines) * 1.7em); padding: 12px; outline: none; font-size: 1rem; line-height: 1.7; overflow-wrap: anywhere; }
  .rendered :global(.tiptap > :first-child) { margin-top: 0; }
  .rendered :global(.tiptap > :last-child) { margin-bottom: 0; }
  .rendered :global(p) { margin: 0 0 .8em; }
  .rendered :global(h1) { font-size: 1.8em; }
  .rendered :global(h2) { font-size: 1.5em; }
  .rendered :global(h3) { font-size: 1.25em; }
  .rendered :global(:is(h1, h2, h3, h4, h5, h6)) { margin: 1em 0 .4em; line-height: 1.3; }
  .rendered :global(ul) { list-style: disc; }
  .rendered :global(ol) { list-style: decimal; }
  .rendered :global(:is(ul, ol)) { padding-left: 1.6em; margin: .5em 0; }
  .rendered :global(li > p) { margin-bottom: .2em; }
  .rendered :global(blockquote) { border-left: 3px solid var(--ctp-surface2); margin-left: 0; padding-left: 1em; color: var(--ctp-subtext0); }
  .rendered :global(pre) { padding: 12px; border-radius: 6px; background: var(--ctp-mantle); white-space: pre-wrap; }
  .rendered :global(code) { font-size: .9em; background: var(--ctp-mantle); }
  .rendered :global(a) { color: var(--ctp-rosewater); text-decoration: underline; }
  .rendered :global(.tiptap:has(> p:only-child > br.ProseMirror-trailingBreak:only-child))::before { content: attr(data-placeholder); color: var(--ctp-subtext0); float: left; height: 0; pointer-events: none; }
  textarea { display: block; box-sizing: border-box; width: 100%; resize: vertical; padding: 12px; border: 1px solid var(--ctp-surface2); border-radius: 8px; background: var(--ctp-mantle); color: var(--ctp-text); font: .9rem/1.7 monospace; overflow-wrap: anywhere; }
  .source-note { font-size: .8rem; line-height: 1.5; color: var(--ctp-subtext0); }
  .disabled .rendered { opacity: .6; }
</style>
