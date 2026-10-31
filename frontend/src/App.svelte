<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import ContextPanel from "./ContextPanel.svelte";
  import PromptGenerator from "./PromptGenerator.svelte";
  import GradeFeedback from "./GradeFeedback.svelte";
  import MarkdownEditor from "./MarkdownEditor.svelte";
  import { gradeEssay, type GradeResult } from "./grading-api";
  import { defaultModel, providerModels } from "./provider-models";
  import { createContextPreview, contextSelection } from "./context-preview";
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
    prompt: string;
  };

  type CreateWorkspaceDirectoryRequest = {
    parentPath: string[];
    directoryName: string;
  };

  type CreateWorkspaceEssayRequest = {
    parentPath: string[];
    essayName: string;
    markdown: string;
    prompt: string;
  };

  type SaveWorkspaceEssayRequest = { markdown: string } | { prompt: string };

  type UiLogLevel = "info" | "warn" | "error";
  const uiLoggingEnabled = import.meta.env.MODE !== "test";

  let workspaceTree: WorkspaceNode[] = [];
  let expandedWorkspaceDirectories: string[][] = [];
  let workspaceLoading = false;
  let workspaceError = "";
  let selectedWorkspaceDirectoryPath: string[] = [];
  let selectedWorkspaceEssay: WorkspaceEssayContent | null = null;
  let markdown = "";
  let prompt = "";
  let assignmentEditor: { focus: () => void } | undefined;
  let assignmentSection: HTMLDetailsElement | undefined;
  let savingPrompt = false;
  let essayLoading = false;
  let loadingEssayPath: string[] | null = null;
  let contextDirty = false;
  let contextBusy = false;
  let contextPanel: { discardChanges: () => void } | undefined;
  let draftError = "";
  let promptError = "";
  let draftNotice = "";
  let promptNotice = "";
  let essayController: AbortController | undefined;
  let workspaceController: AbortController | undefined;
  let essayRevision = 0;
  $: draftDirty = selectedWorkspaceEssay !== null && markdown !== selectedWorkspaceEssay.markdown;
  $: promptDirty = selectedWorkspaceEssay !== null && prompt !== selectedWorkspaceEssay.prompt;
  $: draftSaveStatus = essayLoading ? "Loading draft…" : !selectedWorkspaceEssay ? "Select an essay"
    : savingDraft ? "Saving draft…" : draftError ? "Draft not saved. Your edits are still here; try saving again."
    : draftDirty ? "Unsaved draft changes" : draftNotice || "Draft saved";
  $: promptSaveStatus = essayLoading ? "Loading prompt…" : !selectedWorkspaceEssay ? "Select an essay"
    : savingPrompt ? "Saving prompt…" : promptError ? "Prompt not saved. Your edits are still here; try saving again."
    : promptDirty ? "Unsaved prompt changes" : promptNotice || "Prompt saved";
  $: hasUnsavedChanges = draftDirty || promptDirty || contextDirty;
  $: operationPending = savingDraft || savingPrompt || contextBusy || workspaceCreateBusy || workspaceDeleteBusy;
  $: rubricWeights = Object.values($contextPreview.context?.rubric ?? {}).map((criterion) => criterion.weight);
  $: rubricTotal = rubricWeights.reduce((total, weight) => total + weight, 0);
  $: gradeUnavailable = !selectedWorkspaceEssay ? "Select an essay to grade."
    : essayLoading || workspaceLoading ? "Wait for the essay to finish loading."
    : operationPending ? "Wait for the current save or workspace change to finish."
    : hasUnsavedChanges ? "Save or discard your changes before grading."
    : !contextReady ? contextUnavailable
    : !selectedWorkspaceEssay.markdown.trim() ? "Write and save a nonblank draft before grading."
    : !rubricWeights.length ? "Add at least one rubric criterion in Context, or inherit a rubric from a parent folder."
    : rubricWeights.some((weight) => !Number.isFinite(weight) || weight < 0) || !Number.isFinite(rubricTotal) || rubricTotal <= 0
      ? "The effective rubric needs a finite, positive total weight."
    : !($contextPreview.context?.model ?? activeAccount?.preferredModel)?.trim()
      ? "Select a model in Context or your account preferences."
    : "";
  $: canGrade = !gradeUnavailable && !grading;
  let accounts: AccountProfile[] = [];
  let loadingAccounts = false;
  let creatingAccount = false;
  let accountError = "";
  let newAccountName = "";
  let newAccountModel = defaultModel;
  let activeAccountId: string | null = null;
  const contextPreview = createContextPreview();
  $: contextReady = selectedWorkspaceEssay !== null
    && $contextPreview.selection === contextSelection(activeAccountId, selectedWorkspaceEssay.path)
    && $contextPreview.status === "ready";
  $: contextUnavailable = !selectedWorkspaceEssay ? "Select an essay to grade."
    : $contextPreview.selection !== contextSelection(activeAccountId, selectedWorkspaceEssay.path) || $contextPreview.status === "loading" || $contextPreview.status === "idle"
      ? "Checking writing context…"
      : "Grading is unavailable until writing context resolves. Retry in the Context panel.";
  let grading = false;
  let gradeResult: GradeResult | null = null;
  let gradeError = "";
  let gradeController: AbortController | undefined;
  let gradedInputs = "";
  $: currentGradeInputs = JSON.stringify([activeAccountId, selectedWorkspaceEssay?.path, essayRevision,
    markdown, prompt, $contextPreview.context, activeAccount?.preferredModel]);
  $: gradeStale = gradeResult !== null && (gradedInputs !== currentGradeInputs || !contextReady || contextDirty || contextBusy);
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

  onDestroy(() => {
    gradeController?.abort();
    essayController?.abort();
    workspaceController?.abort();
    contextPreview.cancel();
  });

  function confirmNavigation() {
    if (operationPending) {
      status = "Wait for the current save or workspace change to finish.";
      return false;
    }
    if (!hasUnsavedChanges) return true;
    if (!window.confirm("Discard unsaved draft, prompt, or context changes?")) return false;
    if (contextDirty) contextPanel?.discardChanges();
    return true;
  }

  function handleBeforeUnload(event: BeforeUnloadEvent) {
    if (hasUnsavedChanges || operationPending) {
      event.preventDefault();
      event.returnValue = "";
    }
  }

  function invalidateEssayLoad() {
    gradeController?.abort();
    gradeResult = null;
    gradeError = "";
    grading = false;
    gradedInputs = "";
    essayRevision += 1;
    essayController?.abort();
    essayLoading = false;
    loadingEssayPath = null;
    contextPreview.cancel();
  }

  function setLoadedEssay(essay: WorkspaceEssayContent) {
    selectedWorkspaceEssay = essay;
    selectedWorkspaceDirectoryPath = essay.path.slice(0, -1);
    markdown = essay.markdown;
    prompt = essay.prompt;
    draftError = promptError = draftNotice = promptNotice = "";
  }

  function reloadWorkspace() {
    if (activeAccountId && confirmNavigation()) void loadWorkspace(activeAccountId);
  }

  function resetWorkspaceState() {
    invalidateEssayLoad();
    workspaceController?.abort();
    prompt = "";
    contextDirty = contextBusy = false;
    draftError = promptError = draftNotice = promptNotice = "";
    workspaceTree = [];
    expandedWorkspaceDirectories = [];
    workspaceLoading = false;
    workspaceError = "";
    selectedWorkspaceDirectoryPath = [];
    selectedWorkspaceEssay = null;
    markdown = "";
    workspaceCreateKind = null;
    workspaceCreateName = "";
    workspaceDeleteTarget = null;
  }

  async function loadWorkspace(accountId: string) {
    workspaceController?.abort();
    invalidateEssayLoad();
    const controller = new AbortController();
    workspaceController = controller;
    workspaceLoading = true;
    workspaceError = "";
    uiLog("info", "Loading workspace", { accountId });

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace`, { signal: controller.signal });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: WorkspaceTreeResponse = await res.json();
      if (controller.signal.aborted || activeAccountId !== accountId) return;
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
      if (controller.signal.aborted || activeAccountId !== accountId) return;
      workspaceError = `Could not load workspace: ${String(err)}`;
      workspaceTree = [];
      selectedWorkspaceEssay = null;
      selectedWorkspaceDirectoryPath = [];
      uiLog("error", "Failed to load workspace", err);
    } finally {
      if (!controller.signal.aborted && activeAccountId === accountId) workspaceLoading = false;
    }
  }

  async function loadWorkspaceEssay(accountId: string, essayPath: string[], shouldLog = true) {
    invalidateEssayLoad();
    const controller = new AbortController();
    essayController = controller;
    const revision = essayRevision;
    essayLoading = true;
    loadingEssayPath = essayPath;
    workspaceError = "";
    const encodedPath = essayPath.map((segment) => encodeURIComponent(segment)).join("/");
    if (shouldLog) {
      uiLog("info", "Loading essay", { accountId, essayPath });
    }

    try {
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/essays/${encodedPath}`, { signal: controller.signal });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const data: WorkspaceEssayContent = await res.json();
      if (controller.signal.aborted || revision !== essayRevision || accountId !== activeAccountId) return;
      setLoadedEssay(data);
      status = `Loaded ${data.title}`;
      uiLog("info", "Essay loaded", { accountId, essayPath: data.path });
    } catch (err) {
      if (controller.signal.aborted || revision !== essayRevision || accountId !== activeAccountId) return;
      workspaceError = `Could not load essay: ${String(err)}`;
      uiLog("error", "Failed to load essay", err);
    } finally {
      if (!controller.signal.aborted && revision === essayRevision) { essayLoading = false; loadingEssayPath = null; }
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
      invalidateEssayLoad();
      selectedWorkspaceEssay = null;
      markdown = prompt = "";
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
      markdown: "",
      prompt: ""
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
      invalidateEssayLoad();
      setLoadedEssay(created);
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
    if (!confirmNavigation()) return;
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

    if (!confirmNavigation()) return;
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
    if (!confirmNavigation()) return;
    resetWorkspaceState();
    uiLog("info", "Logging in", { accountId });
    activeAccountId = accountId;
    localStorage.setItem("essay-account-id", accountId);
    status = `Logged in as ${accountId}`;
  }

  function logout() {
    if (!confirmNavigation()) return;
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

  async function requestGrade() {
    if (!canGrade || !activeAccountId || !selectedWorkspaceEssay || !$contextPreview.context) return;
    const request = new AbortController();
    gradeController = request;
    gradedInputs = currentGradeInputs;
    grading = true;
    gradeResult = null;
    gradeError = "";
    activeFeedbackTab = "feedback";
    panelState = { ...panelState, feedback: true };
    status = `Grading ${selectedWorkspaceEssay.title}`;
    try {
      const result = await gradeEssay(activeAccountId, selectedWorkspaceEssay.path,
        Object.keys($contextPreview.context.rubric), request.signal);
      if (request.signal.aborted) return;
      gradeResult = result;
      status = "Grading complete";
    } catch (cause) {
      if (request.signal.aborted) return;
      gradeError = cause instanceof Error ? cause.message : String(cause);
      status = "Grading failed";
    } finally {
      if (!request.signal.aborted) grading = false;
    }
  }

  async function saveEssayField(field: "markdown" | "prompt") {
    if (!activeAccountId || !selectedWorkspaceEssay || essayLoading) return;
    if (field === "markdown" ? savingDraft : savingPrompt) return;
    const accountId = activeAccountId;
    const essayPath = selectedWorkspaceEssay.path;
    const revision = essayRevision;
    const value = field === "markdown" ? markdown : prompt;
    const body: SaveWorkspaceEssayRequest = field === "markdown" ? { markdown: value } : { prompt: value };
    if (field === "markdown") { savingDraft = true; draftError = draftNotice = ""; }
    else { savingPrompt = true; promptError = promptNotice = ""; }
    try {
      const encodedPath = essayPath.map(encodeURIComponent).join("/");
      const res = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/workspace/essays/${encodedPath}`, {
        method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
      });
      if (!res.ok) {
        let message = await res.text();
        try { message = JSON.parse(message).error?.message ?? message; } catch { /* Plain HTTP error. */ }
        throw new Error(message || `HTTP ${res.status}`);
      }
      const saved: WorkspaceEssayContent = await res.json();
      if (accountId !== activeAccountId || revision !== essayRevision || !selectedWorkspaceEssay
          || !samePath(essayPath, selectedWorkspaceEssay.path)) return;
      // Only update the saved baseline for this field. A response may contain
      // older sibling content, and typing may continue while this request runs.
      selectedWorkspaceEssay = { ...selectedWorkspaceEssay, [field]: saved[field] };
      if (field === "markdown") draftNotice = "Draft saved.";
      else promptNotice = "Prompt saved.";
      const newerEdits = (field === "markdown" ? markdown : prompt) !== saved[field];
      status = `${field === "markdown" ? "Draft" : "Prompt"} saved for ${pathToLabel(essayPath)}${newerEdits ? ". Newer changes are still unsaved." : ""}`;
    } catch (err) {
      if (accountId !== activeAccountId || revision !== essayRevision) return;
      const message = `Could not save ${field === "markdown" ? "draft" : "prompt"}: ${err instanceof Error ? err.message : String(err)}`;
      if (field === "markdown") draftError = message;
      else promptError = message;
    } finally {
      if (field === "markdown") savingDraft = false;
      else savingPrompt = false;
    }
  }

  function adoptPrompt(candidate: string) {
    if (!selectedWorkspaceEssay || !contextReady || contextDirty || operationPending || essayLoading || workspaceLoading) return;
    if (candidate === prompt) return;
    if (promptDirty && !window.confirm("Replace your unsaved assignment prompt changes with this generated prompt?")) return;
    // Update only the editor value. The saved baseline stays unchanged so normal
    // dirty-state, discard, navigation protection, and Save Prompt still apply.
    prompt = candidate;
    promptError = "";
    promptNotice = "Generated prompt applied. Save Prompt to keep it.";
    status = "Generated prompt applied. Save Prompt to keep it.";
    if (assignmentSection) assignmentSection.open = true;
    assignmentEditor?.focus();
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
    if (selectedWorkspaceEssay && samePath(node.path, selectedWorkspaceEssay.path)) return true;
    if (!confirmNavigation()) return false;
    if (isDirectoryNode(node)) {
      invalidateEssayLoad();
      selectedWorkspaceDirectoryPath = node.path;
      selectedWorkspaceEssay = null;
      markdown = prompt = "";
    } else if (activeAccountId) {
      void loadWorkspaceEssay(activeAccountId, node.path);
    }
    return true;
  }

  function selectWorkspaceRoot() {
    if (!confirmNavigation()) return false;
    invalidateEssayLoad();
    selectedWorkspaceDirectoryPath = [];
    selectedWorkspaceEssay = null;
    markdown = prompt = "";
    return true;
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

<svelte:window on:beforeunload={handleBeforeUnload} />

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
              {#each providerModels as modelId}
                <sl-option value={modelId}>{modelId}</sl-option>
              {/each}
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
            on:click={reloadWorkspace}
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
            selectedPath={loadingEssayPath ?? selectedWorkspaceEssay?.path ?? selectedWorkspaceDirectoryPath}
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
      {:else}
        <p class="create-dialog-location">This permanently deletes the essay, assignment prompt, context settings, and any other files in this essay.</p>
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
          <details class="writing-section assignment-editor" open bind:this={assignmentSection}>
            <summary aria-label="Assignment prompt section">
              <span class="writing-section-title">Assignment prompt</span>
              <span class="writing-section-status" role="status" aria-label="Prompt save status" aria-atomic="true">{promptSaveStatus}</span>
            </summary>
            <div class="writing-section-body">
              <MarkdownEditor bind:this={assignmentEditor} label="Assignment prompt" rows={5} bind:value={prompt}
                documentKey={JSON.stringify([activeAccountId, selectedWorkspaceEssay?.path])}
                disabled={!selectedWorkspaceEssay || essayLoading || workspaceLoading || workspaceCreateBusy || workspaceDeleteBusy}
                onChange={() => { promptNotice = ""; }}
                placeholder="Describe the assignment, question, or requirements." />
              <div class="editor-actions">
                <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
                <sl-button variant="default" on:click={() => saveEssayField("prompt")}
                  disabled={savingPrompt || essayLoading || !selectedWorkspaceEssay}>
                  {savingPrompt ? "Saving prompt…" : "Save Prompt"}
                </sl-button>
                <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
                <sl-button variant="text" disabled={!promptDirty || savingPrompt}
                  on:click={() => { prompt = selectedWorkspaceEssay?.prompt ?? ""; promptError = promptNotice = ""; }}>Discard prompt changes</sl-button>
              </div>
              {#if promptError}<p class="login-error" role="alert">{promptError}</p>{/if}
              {#if activeAccountId && selectedWorkspaceEssay}
                {#key JSON.stringify([activeAccountId, selectedWorkspaceEssay.path, essayRevision])}
                  <PromptGenerator accountId={activeAccountId} essayPath={selectedWorkspaceEssay.path}
                    {contextReady} {contextDirty}
                    onAdopt={adoptPrompt}
                    unavailableReason={essayLoading || workspaceLoading ? "Wait for the essay to finish loading."
                      : operationPending ? "Wait for the current save or workspace change to finish." : ""} />
                {/key}
              {/if}
            </div>
          </details>
          <details class="writing-section" open>
            <summary aria-label="Essay draft section">
              <span class="writing-section-title">Essay draft</span>
              <span class="writing-section-status" role="status" aria-label="Draft save status" aria-atomic="true">{draftSaveStatus}</span>
            </summary>
            <div class="writing-section-body">
              <MarkdownEditor
                label="Essay Markdown"
                rows={18}
                bind:value={markdown}
                documentKey={JSON.stringify([activeAccountId, selectedWorkspaceEssay?.path])}
                disabled={!selectedWorkspaceEssay || essayLoading || workspaceLoading || workspaceCreateBusy || workspaceDeleteBusy}
                onChange={() => { draftNotice = ""; }}
              />
              <div class="editor-actions">
                <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
                <sl-button variant="primary" on:click={() => saveEssayField("markdown")} disabled={savingDraft || essayLoading || selectedWorkspaceEssay === null}>
                  {savingDraft ? "Saving draft…" : "Save Draft"}
                </sl-button>
                <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
                <sl-button variant="text" disabled={!draftDirty || savingDraft}
                  on:click={() => { markdown = selectedWorkspaceEssay?.markdown ?? ""; draftError = draftNotice = ""; }}>Discard draft changes</sl-button>
              </div>
              {#if draftError}<p class="login-error" role="alert">{draftError}</p>{/if}
            </div>
          </details>
        </div>

        <div class="editor-actions">
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-button variant="default" on:click={requestGrade} disabled={!canGrade} aria-describedby={canGrade ? undefined : "grade-context-status"}>{grading ? "Grading…" : "Grade essay"}</sl-button>
        </div>
        {#if essayLoading}<p class="footer-note" role="status">Loading essay…</p>{/if}
        {#if !canGrade}<p id="grade-context-status" class="footer-note" role="status">{grading ? "Grading your saved essay…" : gradeUnavailable}</p>{/if}
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

      <div hidden={!panelState.feedback}>
        <div id="context-tabpanel" role="tabpanel" aria-labelledby="context-tab" tabindex="0" hidden={activeFeedbackTab !== "context"}>
          <fieldset class="context-navigation-guard" disabled={essayLoading || workspaceLoading || workspaceCreateBusy || workspaceDeleteBusy}>
          {#key activeAccountId}
            <ContextPanel
              bind:this={contextPanel}
              preview={contextPreview}
              accountId={activeAccount.accountId.unAccountId}
              directoryPath={selectedWorkspaceEssay?.path ?? selectedWorkspaceDirectoryPath}
              bind:dirty={contextDirty}
              bind:busy={contextBusy}
              essayPath={selectedWorkspaceEssay?.path ?? null}
            />
          {/key}
          </fieldset>
        </div>
        <div id="feedback-tabpanel" role="tabpanel" aria-labelledby="feedback-tab" tabindex="0" hidden={activeFeedbackTab !== "feedback"}>
          <GradeFeedback result={gradeResult} loading={grading} error={gradeError} stale={gradeStale}
            essayTitle={selectedWorkspaceEssay?.title ?? ""} />
        </div>
      </div>
    </sl-card>
  </div>
  {/if}
</main>
