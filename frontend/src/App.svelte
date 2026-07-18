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

  type AccountProfile = {
    accountId: {
      unAccountId: string;
    };
    displayName: string;
    preferredModel: string | null;
  };

  type CreateAccountRequest = {
    displayName: string;
    preferredModel: string | null;
  };

  const essays = [
    "History/Project-Alpha/French-Revolution-Outline.md",
    "Literature/Poetry/Romanticism-Draft.md",
    "Science/Biology/Evolution-Notes.md"
  ];

  let selectedEssay = essays[0];
  let markdown = "# Essay Draft\n\nWrite your introduction here.";
  let model = "llama3.1:8b";
  let accounts: AccountProfile[] = [];
  let loadingAccounts = false;
  let creatingAccount = false;
  let accountError = "";
  let newAccountName = "";
  let newAccountModel = "llama3.1:8b";
  let activeAccountId: string | null = null;
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
    void initializeApp();
  });

  $: activeAccount =
    activeAccountId === null
      ? null
      : accounts.find((account) => account.accountId.unAccountId === activeAccountId) ?? null;

  async function initializeApp() {
    const savedTheme = localStorage.getItem("essay-theme");
    if (savedTheme === "latte" || savedTheme === "macchiato") {
      theme = savedTheme;
    }
    applyTheme(theme);

    const savedAccountId = localStorage.getItem("essay-account-id");
    await loadAccounts(savedAccountId);
  }

  async function loadAccounts(savedAccountId: string | null = activeAccountId) {
    loadingAccounts = true;
    accountError = "";

    try {
      const res = await fetch("/api/v1/accounts");
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: AccountProfile[] = await res.json();
      accounts = data;

      if (savedAccountId && data.some((account) => account.accountId.unAccountId === savedAccountId)) {
        activeAccountId = savedAccountId;
        status = `Logged in as ${savedAccountId}`;
      } else {
        activeAccountId = null;
        localStorage.removeItem("essay-account-id");
      }
    } catch (err) {
      accountError = `Could not load accounts: ${String(err)}`;
      accounts = [];
      activeAccountId = null;
    } finally {
      loadingAccounts = false;
    }
  }

  function loginAs(accountId: string) {
    activeAccountId = accountId;
    localStorage.setItem("essay-account-id", accountId);
    status = `Logged in as ${accountId}`;
  }

  function logout() {
    activeAccountId = null;
    localStorage.removeItem("essay-account-id");
    status = "Logged out";
  }

  async function createAccount() {
    const trimmed = newAccountName.trim();
    if (!trimmed) {
      accountError = "Please enter an account name.";
      return;
    }

    creatingAccount = true;
    accountError = "";

    const body: CreateAccountRequest = {
      displayName: trimmed,
      preferredModel: newAccountModel.trim() ? newAccountModel : null
    };

    try {
      const res = await fetch("/api/v1/accounts", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(body)
      });

      if (res.status === 409) {
        throw new Error("That account already exists.");
      }
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const created: AccountProfile = await res.json();
      accounts = [...accounts, created].sort((a, b) =>
        a.accountId.unAccountId.localeCompare(b.accountId.unAccountId)
      );

      newAccountName = "";
      loginAs(created.accountId.unAccountId);
    } catch (err) {
      accountError = `Could not create account: ${String(err)}`;
    } finally {
      creatingAccount = false;
    }
  }

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
  {#if !activeAccount}
    <div class="login-shell">
      <div class="topbar">
        <div>
          <sl-badge variant="primary" pill>Account login required</sl-badge>
          <h1>Welcome to Essaying</h1>
        </div>

        <div class="status-row">
          <sl-button size="small" variant="default" on:click={toggleTheme}>
            {theme === "macchiato" ? "Switch to Light" : "Switch to Macchiato"}
          </sl-button>
        </div>
      </div>

      <div class="login-grid">
        <sl-card>
          <div slot="header" class="panel-header">
            <h2>Choose Account</h2>
            <sl-button size="small" variant="default" on:click={() => loadAccounts()}>
              Refresh
            </sl-button>
          </div>

          {#if loadingAccounts}
            <div class="login-loading">
              <sl-spinner></sl-spinner>
              <span>Loading accounts...</span>
            </div>
          {:else if accounts.length === 0}
            <p class="footer-note">No accounts found yet. Create your first account.</p>
          {:else}
            <div class="account-list">
              {#each accounts as account}
                <sl-button
                  variant="default"
                  on:click={() => loginAs(account.accountId.unAccountId)}
                >
                  {account.displayName}
                </sl-button>
              {/each}
            </div>
          {/if}
        </sl-card>

        <sl-card>
          <div slot="header" class="panel-header">
            <h2>Create Account</h2>
          </div>

          <div class="meta">
            <sl-input
              label="Display Name"
              value={newAccountName}
              on:sl-input={(e) => (newAccountName = (e.target as { value?: string }).value ?? "")}
            ></sl-input>

            <sl-select
              label="Preferred Model"
              value={newAccountModel}
              on:sl-change={(e) => (newAccountModel = (e.target as { value?: string }).value ?? "")}
            >
              <sl-option value="llama3.1:8b">llama3.1:8b</sl-option>
              <sl-option value="qwen2.5:7b">qwen2.5:7b</sl-option>
              <sl-option value="mistral:7b">mistral:7b</sl-option>
            </sl-select>
          </div>

          {#if accountError}
            <p class="login-error">{accountError}</p>
          {/if}

          <div class="editor-actions">
            <sl-button variant="primary" on:click={createAccount} disabled={creatingAccount}>
              {creatingAccount ? "Creating..." : "Create Account"}
            </sl-button>
          </div>
        </sl-card>
      </div>
    </div>
  {:else}
  <div class="topbar">
    <div>
      <sl-badge variant="primary" pill>Backend-first UI stub</sl-badge>
      <h1>Essaying Workbench</h1>
      <p class="session-hint">Logged in as {activeAccount.displayName} ({activeAccount.accountId.unAccountId})</p>
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
      <sl-button size="small" variant="danger" on:click={logout}>Log Out</sl-button>
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
  {/if}
</main>
