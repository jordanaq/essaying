<script lang="ts">
  import { onMount } from "svelte";
  import ContextPanel from "./ContextPanel.svelte";
  import WorkspaceTree, { type WorkspaceNode, type WorkspaceNodeType } from "./WorkspaceTree.svelte";
  import "@shoelace-style/shoelace/dist/components/badge/badge.js";
  import "@shoelace-style/shoelace/dist/components/button/button.js";
  import "@shoelace-style/shoelace/dist/components/card/card.js";
  import "@shoelace-style/shoelace/dist/components/details/details.js";
  import "@shoelace-style/shoelace/dist/components/dialog/dialog.js";
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

  type SaveWorkspaceEssayRequest = {
    markdown: string;
  };

  type UiLogLevel = "info" | "warn" | "error";
  const uiLoggingEnabled = import.meta.env.MODE !== "test";

  let workspaceTree: WorkspaceNode[] = [];
  let expandedWorkspaceDirectories: string[][] = [];
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
  let workspaceCreateKind: "folder" | "essay" | null = null;
  let workspaceCreateParentPath: string[] = [];
  let workspaceCreateName = "";
  let workspaceCreateBusy = false;
  let workspaceDeleteTarget: WorkspaceNode | null = null;
  let workspaceDeleteBusy = false;
  let savingDraft = false;
  let theme: "macchiato" | "latte" = "macchiato";
  let activeFeedbackTab: "context" | "feedback" = "context";
  let panelState = {
    tree: true,
    editor: true,
    feedback: true
  };

  $: anyCollapsed = Object.values(panelState).some((isOpen) => !isOpen);
  $: panelColumns = [
    panelState.tree ? "260px" : "56px",
    panelState.editor ? "minmax(480px, 1fr)" : "56px",
    panelState.feedback ? "380px" : "56px"
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
    expandedWorkspaceDirectories = [];
    workspaceLoading = false;
    workspaceError = "";
    selectedWorkspaceDirectoryPath = [];
    selectedWorkspaceEssay = null;
    markdown = "# Essay Draft\n\nWrite your introduction here.";
    workspaceCreateKind = null;
    workspaceCreateName = "";
    workspaceDeleteTarget = null;
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
        expandedWorkspaceDirectories = directoryAncestors(preferredPath);
        await loadWorkspaceEssay(accountId, preferredPath, false);
      } else {
        expandedWorkspaceDirectories = [];
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
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/essays/${encodedPath}`);
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

  async function createWorkspaceDirectory(parentPath: string[], inputName: string): Promise<boolean> {
    const directoryName = inputName.trim();
    if (!activeAccountId) {
      workspaceError = "Please log in first.";
      return false;
    }
    if (!directoryName) {
      workspaceError = "Please enter a folder name.";
      return false;
    }

    const body: CreateWorkspaceDirectoryRequest = {
      parentPath,
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
      expandWorkspaceDirectory(body.parentPath);
      selectedWorkspaceDirectoryPath = created.path;
      status = `Created folder ${created.name}`;
      uiLog("info", "Workspace directory created", { path: created.path });
      return true;
    } catch (err) {
      workspaceError = `Could not create folder: ${String(err)}`;
      uiLog("error", "Failed to create workspace directory", err);
      return false;
    }
  }

  async function createWorkspaceEssay(parentPath: string[], inputName: string): Promise<boolean> {
    const essayName = inputName.trim();
    if (!activeAccountId) {
      workspaceError = "Please log in first.";
      return false;
    }
    if (!essayName) {
      workspaceError = "Please enter an essay name.";
      return false;
    }

    const body: CreateWorkspaceEssayRequest = {
      parentPath,
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
      expandWorkspaceDirectory(body.parentPath);
      selectedWorkspaceEssay = created;
      selectedWorkspaceDirectoryPath = created.path.slice(0, -1);
      markdown = created.markdown;
      workspaceTree = insertWorkspaceNode(workspaceTree, body.parentPath, {
        name: created.title,
        path: created.path,
        nodeType: { tag: "WorkspaceEssayNode" },
        children: []
      });
      status = `Created essay ${created.title}`;
      uiLog("info", "Workspace essay created", { path: created.path });
      return true;
    } catch (err) {
      workspaceError = `Could not create essay: ${String(err)}`;
      uiLog("error", "Failed to create workspace essay", err);
      return false;
    }
  }

  function openWorkspaceCreate(kind: "folder" | "essay", parentPath: string[]) {
    workspaceCreateKind = kind;
    workspaceCreateParentPath = parentPath;
    workspaceCreateName = "";
    workspaceError = "";
  }

  function openWorkspaceDelete(node: WorkspaceNode) {
    workspaceDeleteTarget = node;
    workspaceError = "";
  }

  async function submitWorkspaceCreate() {
    workspaceCreateBusy = true;
    const created = workspaceCreateKind === "folder"
      ? await createWorkspaceDirectory(workspaceCreateParentPath, workspaceCreateName)
      : workspaceCreateKind === "essay"
        ? await createWorkspaceEssay(workspaceCreateParentPath, workspaceCreateName)
        : false;
    workspaceCreateBusy = false;

    if (created) {
      workspaceCreateKind = null;
      workspaceCreateName = "";
    }
  }

  async function deleteWorkspaceItem() {
    if (!activeAccountId || !workspaceDeleteTarget) {
      return;
    }

    const target = workspaceDeleteTarget;
    const resource = isDirectoryNode(target) ? "directories" : "essays";
    const encodedPath = target.path.map(encodeURIComponent).join("/");
    workspaceDeleteBusy = true;
    workspaceError = "";

    try {
      const res = await fetch(
        `/api/v1/accounts/${encodeURIComponent(activeAccountId)}/workspace/${resource}/${encodedPath}`,
        { method: "DELETE" }
      );
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      workspaceDeleteTarget = null;
      await loadWorkspace(activeAccountId);
      status = `Deleted ${isDirectoryNode(target) ? "folder" : "essay"} ${target.name}`;
      uiLog("info", "Workspace item deleted", { path: target.path, type: resource });
    } catch (err) {
      workspaceError = `Could not delete ${isDirectoryNode(target) ? "folder" : "essay"}: ${String(err)}`;
      uiLog("error", "Failed to delete workspace item", { path: target.path, error: err });
    } finally {
      workspaceDeleteBusy = false;
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

  async function saveDraft() {
    if (!activeAccountId || selectedWorkspaceEssay === null) {
      workspaceError = "Select a persisted essay before saving.";
      return;
    }

    const essayPath = selectedWorkspaceEssay.path;
    const encodedPath = essayPath.map((segment) => encodeURIComponent(segment)).join("/");
    const body: SaveWorkspaceEssayRequest = { markdown };
    savingDraft = true;
    workspaceError = "";
    uiLog("info", "Saving essay", { accountId: activeAccountId, essayPath });

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(activeAccountId)}/workspace/essays/${encodedPath}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(body)
      });

      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const saved: WorkspaceEssayContent = await res.json();
      selectedWorkspaceEssay = saved;
      markdown = saved.markdown;
      status = `Draft saved for ${pathToLabel(saved.path)}`;
      uiLog("info", "Essay saved", { accountId: activeAccountId, essayPath: saved.path });
    } catch (err) {
      workspaceError = `Could not save essay: ${String(err)}`;
      uiLog("error", "Failed to save essay", err);
    } finally {
      savingDraft = false;
    }
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

  function handleFeedbackTabKeydown(event: KeyboardEvent) {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    activeFeedbackTab = event.key === "Home" ? "context"
      : event.key === "End" ? "feedback"
      : activeFeedbackTab === "context" ? "feedback" : "context";
    const tab = (event.currentTarget as HTMLElement).parentElement?.querySelector<HTMLButtonElement>(
      `#${activeFeedbackTab}-tab`
    );
    tab?.focus();
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
    return workspaceNodeTypeTag(node.nodeType) === "WorkspaceDirectoryNode";
  }

  function workspaceNodeTypeTag(nodeType: WorkspaceNodeType) {
    return typeof nodeType === "string" ? nodeType : nodeType.tag;
  }

  function directoryAncestors(path: string[]): string[][] {
    return Array.from({ length: Math.max(0, path.length - 1) }, (_, index) => path.slice(0, index + 1));
  }

  function isWorkspaceDirectoryExpanded(path: string[]) {
    return expandedWorkspaceDirectories.some((expandedPath) => samePath(expandedPath, path));
  }

  function expandWorkspaceDirectory(path: string[]) {
    if (path.length > 0 && !isWorkspaceDirectoryExpanded(path)) {
      expandedWorkspaceDirectories = [...expandedWorkspaceDirectories, path];
    }
  }

  function updateWorkspaceDirectoryExpansion(path: string[], expanded: boolean) {
    expandedWorkspaceDirectories = expanded
      ? isWorkspaceDirectoryExpanded(path)
        ? expandedWorkspaceDirectories
        : [...expandedWorkspaceDirectories, path]
      : expandedWorkspaceDirectories.filter((expandedPath) => !samePath(expandedPath, path));
  }

  function selectWorkspaceNode(node: WorkspaceNode) {
    if (isDirectoryNode(node)) {
      selectedWorkspaceDirectoryPath = node.path;
      selectedWorkspaceEssay = null;
    } else if (activeAccountId) {
      void loadWorkspaceEssay(activeAccountId, node.path);
    }
  }

  function selectWorkspaceRoot() {
    selectedWorkspaceDirectoryPath = [];
    selectedWorkspaceEssay = null;
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
      <sl-badge variant="primary" pill>Writing workspace</sl-badge>
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
      <div slot="header" class={`panel-header tree-panel-header ${panelState.tree ? "" : "is-tree-collapsed"}`}>
        {#if panelState.tree}
          <div><h2>Folder Tree</h2></div>
        {/if}
        <div class="tree-toolbar">
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-icon-button
            name="arrow-clockwise"
            label="Reload workspace"
            title="Reload workspace"
            disabled={workspaceLoading}
            on:click={() => activeAccountId && void loadWorkspace(activeAccountId)}
          ></sl-icon-button>
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-icon-button
            name={panelState.tree ? "chevron-bar-left" : "chevron-bar-right"}
            label={panelState.tree ? "Collapse folder tree" : "Expand folder tree"}
            title={panelState.tree ? "Collapse folder tree" : "Expand folder tree"}
            on:click={() => togglePanel("tree")}
          ></sl-icon-button>
        </div>
      </div>

      {#if panelState.tree}
        {#if workspaceLoading}
          <div class="login-loading">
            <sl-spinner></sl-spinner>
            <span>Loading workspace...</span>
          </div>
        {:else}
          {#if workspaceError}
            <p class="login-error">{workspaceError}</p>
          {/if}
          <WorkspaceTree
            nodes={workspaceTree}
            selectedPath={selectedWorkspaceEssay?.path ?? selectedWorkspaceDirectoryPath}
            expandedPaths={expandedWorkspaceDirectories}
            onSelect={selectWorkspaceNode}
            onSelectRoot={selectWorkspaceRoot}
            onExpansionChange={updateWorkspaceDirectoryExpansion}
            onCreateDirectory={(path) => openWorkspaceCreate("folder", path)}
            onCreateEssay={(path) => openWorkspaceCreate("essay", path)}
            onDelete={openWorkspaceDelete}
          />
          {#if workspaceTree.length === 0}
            <p class="footer-note">This workspace is empty. Use the actions beside Workspace to get started.</p>
          {/if}
        {/if}
      {/if}
    </sl-card>

    <sl-dialog
      open={workspaceCreateKind !== null}
      label={workspaceCreateKind === "folder" ? "Create folder" : "Create essay"}
      on:sl-request-close={() => (workspaceCreateKind = null)}
    >
      <p class="create-dialog-location">In {pathToLabel(workspaceCreateParentPath)}</p>
      <sl-input
        label={workspaceCreateKind === "folder" ? "Folder name" : "Essay name"}
        value={workspaceCreateName}
        on:sl-input={(event: Event) => (workspaceCreateName = (event.target as { value?: string }).value ?? "")}
      ></sl-input>
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button slot="footer" variant="default" on:click={() => (workspaceCreateKind = null)} disabled={workspaceCreateBusy}>
        Cancel
      </sl-button>
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button
        slot="footer"
        variant="primary"
        on:click={submitWorkspaceCreate}
        disabled={!workspaceCreateName.trim() || workspaceCreateBusy}
        loading={workspaceCreateBusy}
      >
        Create {workspaceCreateKind === "folder" ? "Folder" : "Essay"}
      </sl-button>
    </sl-dialog>

    <sl-dialog
      open={workspaceDeleteTarget !== null}
      label={`Delete ${workspaceDeleteTarget?.name ?? "workspace item"}`}
      on:sl-request-close={() => (workspaceDeleteTarget = null)}
    >
      <p class="create-dialog-location">
        Delete {workspaceDeleteTarget?.name}? This cannot be undone.
      </p>
      {#if workspaceDeleteTarget && isDirectoryNode(workspaceDeleteTarget)}
        <p class="create-dialog-location">This also permanently deletes everything inside the folder.</p>
      {/if}
      {#if workspaceError}
        <p class="login-error">{workspaceError}</p>
      {/if}
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button
        slot="footer"
        variant="default"
        on:click={() => (workspaceDeleteTarget = null)}
        disabled={workspaceDeleteBusy}
      >
        Cancel
      </sl-button>
      <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
      <sl-button
        slot="footer"
        variant="danger"
        on:click={deleteWorkspaceItem}
        loading={workspaceDeleteBusy}
      >
        Delete
      </sl-button>
    </sl-dialog>

    <sl-card class={`panel ${panelState.editor ? "" : "is-collapsed"}`}>
      <div slot="header" class="panel-header">
        {#if panelState.editor}<h2>Markdown Editor</h2>{/if}
        <div class="panel-header-controls">
          {#if panelState.editor}
            <sl-badge>{workspaceSelectionLabel}</sl-badge>
          {/if}
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          {#if panelState.editor}
            <sl-button size="small" variant="default" on:click={() => togglePanel("editor")}>
              Collapse
            </sl-button>
          {:else}
            <sl-icon-button name="chevron-bar-right" label="Expand markdown editor" title="Expand markdown editor" on:click={() => togglePanel("editor")}></sl-icon-button>
          {/if}
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
          <sl-button variant="primary" on:click={saveDraft} disabled={savingDraft || selectedWorkspaceEssay === null}>
            {savingDraft ? "Saving..." : "Save Draft"}
          </sl-button>
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
        {#if panelState.feedback}
          <div class="panel-tabs" role="tablist" aria-label="Context and feedback">
            <button
              type="button" role="tab" id="context-tab" aria-controls="context-tabpanel"
              aria-selected={activeFeedbackTab === "context"} tabindex={activeFeedbackTab === "context" ? 0 : -1}
              on:click={() => activeFeedbackTab = "context"} on:keydown={handleFeedbackTabKeydown}
            >Context</button>
            <button
              type="button" role="tab" id="feedback-tab" aria-controls="feedback-tabpanel"
              aria-selected={activeFeedbackTab === "feedback"} tabindex={activeFeedbackTab === "feedback" ? 0 : -1}
              on:click={() => activeFeedbackTab = "feedback"} on:keydown={handleFeedbackTabKeydown}
            >Feedback</button>
          </div>
        {/if}
        <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
        {#if panelState.feedback}
          <sl-button size="small" variant="default" on:click={() => togglePanel("feedback")}>
            Collapse
          </sl-button>
        {:else}
          <sl-icon-button name="chevron-bar-left" label="Expand context and feedback" title="Expand context and feedback" on:click={() => togglePanel("feedback")}></sl-icon-button>
        {/if}
      </div>

      {#if panelState.feedback}
        <div id="context-tabpanel" role="tabpanel" aria-labelledby="context-tab" tabindex="0" hidden={activeFeedbackTab !== "context"}>
          {#key activeAccountId}
            <ContextPanel
              accountId={activeAccount.accountId.unAccountId}
              directoryPath={selectedWorkspaceDirectoryPath}
              essayPath={selectedWorkspaceEssay?.path ?? null}
            />
          {/key}
        </div>
        <div id="feedback-tabpanel" role="tabpanel" aria-labelledby="feedback-tab" tabindex="0" hidden={activeFeedbackTab !== "feedback"}>
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

          <p class="footer-note">Grading is a preview with sample feedback.</p>
        </div>
      {/if}
    </sl-card>
  </div>
  {/if}
</main>
