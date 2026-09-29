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

  type WorkspaceNodeType =
    | { tag: "WorkspaceDirectoryNode" }
    | { tag: "WorkspaceEssayNode" };

  type WorkspaceNode = {
    name: string;
    path: string[];
    nodeType: WorkspaceNodeType;
    children: WorkspaceNode[];
  };

  type WorkspaceTreeResponse = {
    tree: WorkspaceNode[];
  };

  type WorkspaceEssayContent = {
    path: string[];
    title: string;
    markdown: string;
  };

  type CreateWorkspaceDirectoryRequest = {
    parentPath: string[];
    directoryName: string;
  };

  type CreateWorkspaceEssayRequest = {
    parentPath: string[];
    essayName: string;
    markdown: string | null;
  };

  type WorkspaceDisplayItem = {
    name: string;
    path: string[];
    depth: number;
    nodeType: WorkspaceNodeType;
  };

  type UiLogLevel = "info" | "warn" | "error";
  const uiLoggingEnabled = import.meta.env.MODE !== "test";

  let workspaceTree: WorkspaceNode[] = [];
  let workspaceLoading = false;
  let workspaceError = "";
  let selectedWorkspaceDirectoryPath: string[] = [];
  let selectedWorkspaceEssay: WorkspaceEssayContent | null = null;
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
  let newWorkspaceDirectoryName = "";
  let newWorkspaceEssayName = "";
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

  $: workspaceSelectionLabel =
    selectedWorkspaceEssay !== null
      ? pathToLabel(selectedWorkspaceEssay.path)
      : selectedWorkspaceDirectoryPath.length > 0
        ? pathToLabel(selectedWorkspaceDirectoryPath)
        : "Workspace root";

  $: if (activeAccountId) {
    void loadWorkspace(activeAccountId);
  } else {
    resetWorkspaceState();
  }

  function uiLog(level: UiLogLevel, message: string, details?: unknown) {
    if (!uiLoggingEnabled) {
      return;
    }

    const prefix = `[frontend-ui] ${new Date().toISOString()}`;
    if (details === undefined) {
      if (level === "error") {
        console.error(prefix, message);
      } else if (level === "warn") {
        console.warn(prefix, message);
      } else {
        console.info(prefix, message);
      }
      return;
    }

    if (level === "error") {
      console.error(prefix, message, details);
    } else if (level === "warn") {
      console.warn(prefix, message, details);
    } else {
      console.info(prefix, message, details);
    }
  }

  async function initializeApp() {
    const savedTheme = localStorage.getItem("essay-theme");
    if (savedTheme === "latte" || savedTheme === "macchiato") {
      theme = savedTheme;
    }
    applyTheme(theme);

    const savedAccountId = localStorage.getItem("essay-account-id");
    uiLog("info", "Initializing app", {
      savedTheme,
      savedAccountId
    });
    await loadAccounts(savedAccountId);
  }

  async function loadAccounts(savedAccountId: string | null = activeAccountId) {
    uiLog("info", "Loading accounts", { savedAccountId });
    loadingAccounts = true;
    accountError = "";

    try {
      const res = await fetch("/api/v1/accounts");
      uiLog("info", "Accounts request completed", { status: res.status });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: AccountProfile[] = await res.json();
      accounts = data;

      if (savedAccountId && data.some((account) => account.accountId.unAccountId === savedAccountId)) {
        activeAccountId = savedAccountId;
        status = `Logged in as ${savedAccountId}`;
        uiLog("info", "Restored active account", { accountId: savedAccountId });
      } else {
        activeAccountId = null;
        localStorage.removeItem("essay-account-id");
        uiLog("info", "No saved account restored");
      }
    } catch (err) {
      accountError = `Could not load accounts: ${String(err)}`;
      accounts = [];
      activeAccountId = null;
      uiLog("error", "Failed to load accounts", err);
    } finally {
      loadingAccounts = false;
    }
  }

  function resetWorkspaceState() {
    workspaceTree = [];
    workspaceLoading = false;
    workspaceError = "";
    selectedWorkspaceDirectoryPath = [];
    selectedWorkspaceEssay = null;
    markdown = "# Essay Draft\n\nWrite your introduction here.";
    newWorkspaceDirectoryName = "";
    newWorkspaceEssayName = "";
  }

  async function loadWorkspace(accountId: string) {
    workspaceLoading = true;
    workspaceError = "";
    uiLog("info", "Loading workspace", { accountId });

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace`);
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: WorkspaceTreeResponse = await res.json();
      workspaceTree = data.tree;

      const preferredPath =
        selectedWorkspaceEssay !== null && pathExists(workspaceTree, selectedWorkspaceEssay.path)
          ? selectedWorkspaceEssay.path
          : findFirstEssayPath(workspaceTree);

      if (preferredPath) {
        await loadWorkspaceEssay(accountId, preferredPath, false);
      } else {
        selectedWorkspaceDirectoryPath = [];
        selectedWorkspaceEssay = null;
      }

      uiLog("info", "Workspace loaded", { accountId, rootCount: data.tree.length });
    } catch (err) {
      workspaceError = `Could not load workspace: ${String(err)}`;
      workspaceTree = [];
      selectedWorkspaceEssay = null;
      selectedWorkspaceDirectoryPath = [];
      uiLog("error", "Failed to load workspace", err);
    } finally {
      workspaceLoading = false;
    }
  }

  async function loadWorkspaceEssay(accountId: string, essayPath: string[], shouldLog = true) {
    const encodedPath = essayPath.map((segment) => encodeURIComponent(segment)).join("/");
    if (shouldLog) {
      uiLog("info", "Loading essay", { accountId, essayPath });
    }

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/essay/${encodedPath}`);
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: WorkspaceEssayContent = await res.json();
      selectedWorkspaceEssay = data;
      selectedWorkspaceDirectoryPath = data.path.slice(0, -1);
      markdown = data.markdown;
      status = `Loaded ${data.title}`;
      uiLog("info", "Essay loaded", { accountId, essayPath: data.path });
    } catch (err) {
      workspaceError = `Could not load essay: ${String(err)}`;
      uiLog("error", "Failed to load essay", err);
    }
  }

  async function createWorkspaceDirectory() {
    const directoryName = newWorkspaceDirectoryName.trim();
    if (!activeAccountId) {
      workspaceError = "Please log in first.";
      return;
    }
    if (!directoryName) {
      workspaceError = "Please enter a folder name.";
      return;
    }

    const body: CreateWorkspaceDirectoryRequest = {
      parentPath: selectedWorkspaceDirectoryPath,
      directoryName
    };

    workspaceError = "";
    uiLog("info", "Creating workspace directory", body);

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(activeAccountId)}/workspace/directories`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(body)
      });

      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const created: WorkspaceNode = await res.json();
      workspaceTree = insertWorkspaceNode(workspaceTree, body.parentPath, created);
      selectedWorkspaceDirectoryPath = created.path;
      newWorkspaceDirectoryName = "";
      status = `Created folder ${created.name}`;
      uiLog("info", "Workspace directory created", { path: created.path });
    } catch (err) {
      workspaceError = `Could not create folder: ${String(err)}`;
      uiLog("error", "Failed to create workspace directory", err);
    }
  }

  async function createWorkspaceEssay() {
    const essayName = newWorkspaceEssayName.trim();
    if (!activeAccountId) {
      workspaceError = "Please log in first.";
      return;
    }
    if (!essayName) {
      workspaceError = "Please enter an essay name.";
      return;
    }

    const body: CreateWorkspaceEssayRequest = {
      parentPath: selectedWorkspaceDirectoryPath,
      essayName,
      markdown: markdown.trim() ? markdown : null
    };

    workspaceError = "";
    uiLog("info", "Creating workspace essay", body);

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(activeAccountId)}/workspace/essays`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(body)
      });

      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const created: WorkspaceEssayContent = await res.json();
      selectedWorkspaceEssay = created;
      selectedWorkspaceDirectoryPath = created.path.slice(0, -1);
      markdown = created.markdown;
      workspaceTree = insertWorkspaceNode(workspaceTree, body.parentPath, {
        name: created.title,
        path: created.path,
        nodeType: { tag: "WorkspaceEssayNode" },
        children: []
      });
      newWorkspaceEssayName = "";
      status = `Created essay ${created.title}`;
      uiLog("info", "Workspace essay created", { path: created.path });
    } catch (err) {
      workspaceError = `Could not create essay: ${String(err)}`;
      uiLog("error", "Failed to create workspace essay", err);
    }
  }

  function loginAs(accountId: string) {
    uiLog("info", "Logging in", { accountId });
    activeAccountId = accountId;
    localStorage.setItem("essay-account-id", accountId);
    status = `Logged in as ${accountId}`;
  }

  function logout() {
    uiLog("info", "Logging out", { accountId: activeAccountId });
    activeAccountId = null;
    localStorage.removeItem("essay-account-id");
    resetWorkspaceState();
    status = "Logged out";
  }

  async function createAccount() {
    const trimmed = newAccountName.trim();
    if (!trimmed) {
      accountError = "Please enter an account name.";
      uiLog("warn", "Create account blocked: empty display name");
      return;
    }

    creatingAccount = true;
    accountError = "";

    const body: CreateAccountRequest = {
      displayName: trimmed,
      preferredModel: newAccountModel.trim() ? newAccountModel : null
    };
    uiLog("info", "Creating account", body);

    try {
      const res = await fetch("/api/v1/accounts", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(body)
      });
      uiLog("info", "Create account request completed", { status: res.status });

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
      uiLog("info", "Account created", { accountId: created.accountId.unAccountId });

      newAccountName = "";
      loginAs(created.accountId.unAccountId);
    } catch (err) {
      accountError = `Could not create account: ${String(err)}`;
      uiLog("error", "Failed to create account", err);
    } finally {
      creatingAccount = false;
    }
  }

  async function checkBackend() {
    uiLog("info", "Checking backend readiness");
    loadingReady = true;
    status = "Checking backend";

    try {
      const res = await fetch("/api/v1/ready");
      uiLog("info", "Ready request completed", { status: res.status });
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
      uiLog("info", "Backend ready", {
        message: data.message,
        model: data.sampleContext.model,
        instructionCount: data.sampleContext.instructions.length
      });
    } catch (err) {
      backendMessage = `Error: ${String(err)}`;
      backendContextTitle = "-";
      backendContextModel = "-";
      backendInstructionCount = 0;
      status = "Backend unavailable";
      uiLog("error", "Backend ready check failed", err);
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
    if (selectedWorkspaceEssay !== null) {
      selectedWorkspaceEssay = {
        ...selectedWorkspaceEssay,
        markdown
      };
      status = `Draft saved locally for ${workspaceSelectionLabel}`;
      return;
    }

    status = "Draft saved locally";
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

  function isDirectoryNode(node: WorkspaceNode) {
    return node.nodeType.tag === "WorkspaceDirectoryNode";
  }

  function isDirectoryNodeType(nodeType: WorkspaceNodeType) {
    return nodeType.tag === "WorkspaceDirectoryNode";
  }

  function flattenWorkspaceNodes(nodes: WorkspaceNode[], depth = 0): WorkspaceDisplayItem[] {
    return nodes.flatMap((node) => [
      {
        name: node.name,
        path: node.path,
        depth,
        nodeType: node.nodeType
      },
      ...(isDirectoryNode(node) ? flattenWorkspaceNodes(node.children, depth + 1) : [])
    ]);
  }

  function samePath(left: string[], right: string[]) {
    return left.length === right.length && left.every((segment, index) => segment === right[index]);
  }

  function pathToLabel(path: string[]) {
    return path.length === 0 ? "Workspace root" : path.join("/");
  }

  function findFirstEssayPath(nodes: WorkspaceNode[]): string[] | null {
    for (const node of nodes) {
      if (isDirectoryNode(node)) {
        const nested = findFirstEssayPath(node.children);
        if (nested) {
          return nested;
        }
      } else {
        return node.path;
      }
    }

    return null;
  }

  function pathExists(nodes: WorkspaceNode[], path: string[]): boolean {
    for (const node of nodes) {
      if (samePath(node.path, path)) {
        return true;
      }

      if (isDirectoryNode(node) && pathExists(node.children, path)) {
        return true;
      }
    }

    return false;
  }

  function insertWorkspaceNode(nodes: WorkspaceNode[], parentPath: string[], createdNode: WorkspaceNode): WorkspaceNode[] {
    if (parentPath.length === 0) {
      return [...nodes, createdNode];
    }

    return nodes.map((node) => {
      if (!isDirectoryNode(node)) {
        return node;
      }

      if (samePath(node.path, parentPath)) {
        return {
          ...node,
          children: [...node.children, createdNode]
        };
      }

      return {
        ...node,
        children: insertWorkspaceNode(node.children, parentPath, createdNode)
      };
    });
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
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-button size="small" variant="default" on:click={toggleTheme}>
            {theme === "macchiato" ? "Switch to Light" : "Switch to Macchiato"}
          </sl-button>
        </div>
      </div>

      <div class="login-grid">
        <sl-card>
          <div slot="header" class="panel-header">
            <h2>Choose Account</h2>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
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
                <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
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
              on:sl-input={(e: Event) => (newAccountName = (e.target as { value?: string }).value ?? "")}
            ></sl-input>

            <sl-select
              label="Preferred Model"
              value={newAccountModel}
              on:sl-change={(e: Event) => (newAccountModel = (e.target as { value?: string }).value ?? "")}
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
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
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
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button size="small" variant="default" on:click={toggleTheme}>
        {theme === "macchiato" ? "Switch to Light" : "Switch to Macchiato"}
      </sl-button>
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button size="small" variant="primary" on:click={checkBackend}>Check API</sl-button>
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button size="small" variant="danger" on:click={logout}>Log Out</sl-button>
      {#if anyCollapsed}
        <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
        <sl-button size="small" variant="default" on:click={expandAllPanels}>Expand All Panels</sl-button>
      {/if}
    </div>
  </div>

  <div class="grid" style={`--panel-cols: ${panelColumns};`}>
    <sl-card class={`panel ${panelState.tree ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        <div>
          <h2>{panelState.tree ? "Folder Tree" : "Tree"}</h2>
          <sl-badge variant="neutral">Target: {workspaceSelectionLabel}</sl-badge>
        </div>
        <div class="panel-header-controls">
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-button size="small" variant="default" on:click={() => activeAccountId && void loadWorkspace(activeAccountId)}>
            Reload Workspace
          </sl-button>
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-button size="small" variant="default" on:click={() => togglePanel("tree")}>
            {panelState.tree ? "Collapse" : "Expand"}
          </sl-button>
        </div>
      </div>

      {#if panelState.tree}
        {#if workspaceLoading}
          <div class="login-loading">
            <sl-spinner></sl-spinner>
            <span>Loading workspace...</span>
          </div>
        {:else if workspaceError}
          <p class="login-error">{workspaceError}</p>
        {:else if workspaceTree.length === 0}
          <p class="footer-note">This workspace is empty. Create a folder or essay to begin.</p>
        {:else}
          <div class="tree">
            {#each flattenWorkspaceNodes(workspaceTree) as item}
              <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
              <sl-button
                variant={
                  isDirectoryNodeType(item.nodeType)
                    ? samePath(item.path, selectedWorkspaceDirectoryPath)
                      ? "primary"
                      : "default"
                    : selectedWorkspaceEssay !== null && samePath(item.path, selectedWorkspaceEssay.path)
                      ? "primary"
                      : "default"
                }
                on:click={() =>
                  isDirectoryNodeType(item.nodeType)
                    ? (selectedWorkspaceDirectoryPath = item.path)
                    : activeAccountId && void loadWorkspaceEssay(activeAccountId, item.path)
                }
                style={`margin-left: ${item.depth * 18}px;`}
              >
                {isDirectoryNodeType(item.nodeType) ? "📁" : "📝"} {item.name}
              </sl-button>
            {/each}
          </div>

          <div class="workspace-actions">
            <sl-input
              label="New Folder"
              value={newWorkspaceDirectoryName}
              on:sl-input={(e: Event) => (newWorkspaceDirectoryName = (e.target as { value?: string }).value ?? "")}
            ></sl-input>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
            <sl-button variant="primary" on:click={createWorkspaceDirectory}>Create Folder</sl-button>

            <sl-input
              label="New Essay"
              value={newWorkspaceEssayName}
              on:sl-input={(e: Event) => (newWorkspaceEssayName = (e.target as { value?: string }).value ?? "")}
            ></sl-input>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
            <sl-button variant="primary" on:click={createWorkspaceEssay}>Create Essay</sl-button>
          </div>

          <p class="footer-note">
            New items are created under {pathToLabel(selectedWorkspaceDirectoryPath)}.
          </p>
        {/if}
      {/if}
    </sl-card>

    <sl-card class={`panel ${panelState.editor ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        <h2>{panelState.editor ? "Markdown Editor" : "Editor"}</h2>
        <div class="panel-header-controls">
          {#if panelState.editor}
            <sl-badge>{workspaceSelectionLabel}</sl-badge>
          {/if}
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
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
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-button variant="primary" on:click={saveDraft}>Save Draft</sl-button>
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-button variant="default" on:click={mockGrade}>Grade (mock stream)</sl-button>
        </div>
        {#if selectedWorkspaceEssay}
          <p class="footer-note">Currently editing {pathToLabel(selectedWorkspaceEssay.path)}.</p>
        {:else}
          <p class="footer-note">Select an essay in the tree to load its markdown.</p>
        {/if}
      {/if}
    </sl-card>

    <sl-card class={`panel ${panelState.feedback ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        <h2>{panelState.feedback ? "AI Feedback" : "Feedback"}</h2>
        <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
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
