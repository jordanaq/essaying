<script lang="ts">
  import { onMount } from "svelte";
  import "@shoelace-style/shoelace/dist/components/badge/badge.js";
  import "@shoelace-style/shoelace/dist/components/button/button.js";
  import "@shoelace-style/shoelace/dist/components/card/card.js";
  import "@shoelace-style/shoelace/dist/components/details/details.js";
  import "@shoelace-style/shoelace/dist/components/input/input.js";
  import "@shoelace-style/shoelace/dist/components/option/option.js";
  import "@shoelace-style/shoelace/dist/components/select/select.js";
  import "@shoelace-style/shoelace/dist/components/spinner/spinner.js";
  import "@shoelace-style/shoelace/dist/components/textarea/textarea.js";

  type ReadyResponse = {
    message: string;
    sampleContext: {
      title?: string | null;
      audience?: string | null;
      model?: string | null;
      instructions: string[];
      rubric: Record<string, { weight: number; description?: string | null }>;
    };
  };

  const essays = [
    "History/Project-Alpha/French-Revolution-Outline.md",
    "Literature/Poetry/Romanticism-Draft.md",
    "Science/Biology/Evolution-Notes.md"
  ];

  let selectedEssay = essays[0];
  let markdown = "# Essay Draft\n\nWrite your introduction here.";
  let model = "llama3.1:8b";
  let gradeStream = "";
  let status = "Idle";
  let backendMessage = "Not fetched";
  let backendContextTitle = "-";
  let backendContextModel = "-";
  let backendInstructionCount = 0;
  let loadingReady = false;
  let theme: "macchiato" | "latte" = "macchiato";
  let panelState = {
    tree: true,
    editor: true,
    feedback: true
  };

  $: anyCollapsed = Object.values(panelState).some((isOpen) => !isOpen);
  $: panelColumns = [
    panelState.tree ? "260px" : "56px",
    panelState.editor ? "minmax(480px, 1fr)" : "56px",
    panelState.feedback ? "340px" : "56px"
  ].join(" ");

  onMount(() => {
    const saved = localStorage.getItem("essay-theme");
    if (saved === "latte" || saved === "macchiato") {
      theme = saved;
    }
    applyTheme(theme);
  });

  async function checkBackend() {
    loadingReady = true;
    status = "Checking backend";

    try {
      const res = await fetch("/api/v1/ready");
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: ReadyResponse = await res.json();
      backendMessage = data.message;
      backendContextTitle = data.sampleContext.title ?? "(none)";
      backendContextModel = data.sampleContext.model ?? "(none)";
      backendInstructionCount = data.sampleContext.instructions.length;
      model = data.sampleContext.model ?? model;
      status = "Backend ready";
    } catch (err) {
      backendMessage = `Error: ${String(err)}`;
      backendContextTitle = "-";
      backendContextModel = "-";
      backendInstructionCount = 0;
      status = "Backend unavailable";
    } finally {
      loadingReady = false;
    }
  }

  function mockGrade() {
    status = "Streaming grading preview";
    const chunks = [
      "Clarity: strong structure. ",
      "Evidence: add 1-2 citations. ",
      "Argument: tighten thesis language."
    ];

    gradeStream = "";
    for (const chunk of chunks) {
      gradeStream += chunk;
    }
  }

  function saveDraft() {
    status = "Draft saved (stub)";
  }

  function handleModelChange(e: Event) {
    model = (e.target as { value?: string }).value ?? model;
  }

  function handleMarkdownInput(e: Event) {
    markdown = (e.target as { value?: string }).value ?? markdown;
  }

  function togglePanel(panel: keyof typeof panelState) {
    panelState = {
      ...panelState,
      [panel]: !panelState[panel]
    };
  }

  function expandAllPanels() {
    panelState = {
      tree: true,
      editor: true,
      feedback: true
    };
  }

  function applyTheme(next: "macchiato" | "latte") {
    document.documentElement.setAttribute("data-theme", next);
  }

  function toggleTheme() {
    theme = theme === "macchiato" ? "latte" : "macchiato";
    applyTheme(theme);
    localStorage.setItem("essay-theme", theme);
  }
</script>

<main>
  <div class="topbar">
    <div>
      <sl-badge variant="primary" pill>Backend-first UI stub</sl-badge>
      <h1>Essaying Workbench</h1>
    </div>

    <div class="status-row">
      {#if loadingReady}
        <sl-spinner></sl-spinner>
      {/if}
      <sl-badge variant="neutral">{status}</sl-badge>
      <sl-button size="small" variant="default" on:click={toggleTheme}>
        {theme === "macchiato" ? "Switch to Light" : "Switch to Macchiato"}
      </sl-button>
      <sl-button size="small" variant="primary" on:click={checkBackend}>Check API</sl-button>
      {#if anyCollapsed}
        <sl-button size="small" variant="default" on:click={expandAllPanels}>Expand All Panels</sl-button>
      {/if}
    </div>
  </div>

  <div class="grid" style={`--panel-cols: ${panelColumns};`}>
    <sl-card class={`panel ${panelState.tree ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        <h2>{panelState.tree ? "Folder Tree" : "Tree"}</h2>
        <sl-button size="small" variant="default" on:click={() => togglePanel("tree")}>
          {panelState.tree ? "Collapse" : "Expand"}
        </sl-button>
      </div>

      {#if panelState.tree}
        <div class="tree">
          {#each essays as essay}
            <sl-button
              variant={essay === selectedEssay ? "primary" : "default"}
              on:click={() => (selectedEssay = essay)}
            >
              {essay}
            </sl-button>
          {/each}
        </div>

        <p class="footer-note">
          This is a simple interactive stub. Replace with backend-provided tree data later.
        </p>
      {/if}
    </sl-card>

    <sl-card class={`panel ${panelState.editor ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        <h2>{panelState.editor ? "Markdown Editor" : "Editor"}</h2>
        <div class="panel-header-controls">
          {#if panelState.editor}
            <sl-badge>{selectedEssay}</sl-badge>
          {/if}
          <sl-button size="small" variant="default" on:click={() => togglePanel("editor")}>
            {panelState.editor ? "Collapse" : "Expand"}
          </sl-button>
        </div>
      </div>

      {#if panelState.editor}
        <div class="meta">
          <sl-select label="Model" value={model} on:sl-change={handleModelChange}>
            <sl-option value="llama3.1:8b">llama3.1:8b</sl-option>
            <sl-option value="qwen2.5:7b">qwen2.5:7b</sl-option>
            <sl-option value="mistral:7b">mistral:7b</sl-option>
          </sl-select>

          <sl-textarea
            label="Essay Markdown"
            rows="18"
            value={markdown}
            on:sl-input={handleMarkdownInput}
          ></sl-textarea>
        </div>

        <div class="editor-actions">
          <sl-button variant="primary" on:click={saveDraft}>Save Draft</sl-button>
          <sl-button variant="default" on:click={mockGrade}>Grade (mock stream)</sl-button>
        </div>
      {/if}
    </sl-card>

    <sl-card class={`panel ${panelState.feedback ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        <h2>{panelState.feedback ? "AI Feedback" : "Feedback"}</h2>
        <sl-button size="small" variant="default" on:click={() => togglePanel("feedback")}>
          {panelState.feedback ? "Collapse" : "Expand"}
        </sl-button>
      </div>

      {#if panelState.feedback}
        <sl-input label="Backend status" value={backendMessage} readonly></sl-input>

        <div class="backend-meta">
          <sl-badge variant="neutral">Title: {backendContextTitle}</sl-badge>
          <sl-badge variant="neutral">Model: {backendContextModel}</sl-badge>
          <sl-badge variant="neutral">Instructions: {backendInstructionCount}</sl-badge>
        </div>

        <sl-textarea
          style="margin-top: 10px"
          label="Streaming Grade Output"
          rows="14"
          value={gradeStream}
          readonly
        ></sl-textarea>

        <sl-details style="margin-top: 10px" summary="Next wiring">
          <ul>
            <li>Replace mock grading with SSE stream from backend.</li>
            <li>Load folder tree and rubric from REST endpoints.</li>
            <li>Persist markdown with write-through save API.</li>
          </ul>
        </sl-details>
      {/if}
    </sl-card>
  </div>
</main>
