<script context="module" lang="ts">
  export type WorkspaceNodeType =
    | "WorkspaceDirectoryNode"
    | "WorkspaceEssayNode"
    | { tag: "WorkspaceDirectoryNode" | "WorkspaceEssayNode" };

  export type WorkspaceNode = {
    name: string;
    path: string[];
    nodeType: WorkspaceNodeType;
    children: WorkspaceNode[];
  };
</script>

<script lang="ts">
  import "@shoelace-style/shoelace/dist/components/tree/tree.js";
  import "@shoelace-style/shoelace/dist/components/tree-item/tree-item.js";
  import "@shoelace-style/shoelace/dist/components/icon-button/icon-button.js";

  export let nodes: WorkspaceNode[] = [];
  export let selectedPath: string[] = [];
  export let expandedPaths: string[][] = [];
  export let onSelect: (node: WorkspaceNode) => void;
  export let onSelectRoot: () => void;
  export let onExpansionChange: (path: string[], expanded: boolean) => void;
  export let onCreateDirectory: (path: string[]) => void;
  export let onCreateEssay: (path: string[]) => void;
  export let onDelete: (node: WorkspaceNode) => void;
  export let isRoot = true;

  function samePath(left: string[], right: string[]) {
    return left.length === right.length && left.every((segment, index) => segment === right[index]);
  }

  function isDirectory(node: WorkspaceNode) {
    return (typeof node.nodeType === "string" ? node.nodeType : node.nodeType.tag) === "WorkspaceDirectoryNode";
  }

  function isExpanded(path: string[]) {
    return expandedPaths.some((expandedPath) => samePath(expandedPath, path));
  }

  function findNode(path: string[]): WorkspaceNode | null {
    for (const node of nodes) {
      if (samePath(node.path, path)) {
        return node;
      }

      if (isDirectory(node)) {
        const nested = findNodeIn(node.children, path);
        if (nested) {
          return nested;
        }
      }
    }

    return null;
  }

  function findNodeIn(items: WorkspaceNode[], path: string[]): WorkspaceNode | null {
    for (const node of items) {
      if (samePath(node.path, path)) {
        return node;
      }

      if (isDirectory(node)) {
        const nested = findNodeIn(node.children, path);
        if (nested) {
          return nested;
        }
      }
    }

    return null;
  }

  function handleSelectionChange(event: Event) {
    const selectedItems = (event as CustomEvent<{ selection: Array<HTMLElement & { dataset: DOMStringMap }> }>)
      .detail.selection;
    const selectedItem = selectedItems[0];
    if (!selectedItem?.dataset.path) {
      return;
    }

    const path = JSON.parse(selectedItem.dataset.path) as string[];
    if (path.length === 0) {
      onSelectRoot();
      return;
    }

    const node = findNode(path);
    if (node) {
      onSelect(node);
    }
  }
</script>

{#if isRoot}
  <sl-tree selection="single" on:sl-selection-change={handleSelectionChange}>
    <sl-tree-item class="workspace-root" data-path="[]" expanded>
      <span class="tree-item-content">
        <span class="folder-icon" aria-hidden="true"></span>
        <span class="tree-item-name" title="Workspace">Workspace</span>
        <span class="tree-item-actions" aria-label="Workspace actions">
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-icon-button
            name="folder-plus"
            label="Create folder in Workspace"
            title="Create folder in Workspace"
            on:click|stopPropagation={() => onCreateDirectory([])}
          ></sl-icon-button>
          <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
          <sl-icon-button
            name="file-earmark-plus"
            label="Create essay in Workspace"
            title="Create essay in Workspace"
            on:click|stopPropagation={() => onCreateEssay([])}
          ></sl-icon-button>
        </span>
      </span>
    {#each nodes as node (node.path.join("/"))}
      <sl-tree-item
        data-path={JSON.stringify(node.path)}
        expanded={isExpanded(node.path)}
        selected={samePath(node.path, selectedPath)}
        on:sl-expand={() => onExpansionChange(node.path, true)}
        on:sl-collapse={() => onExpansionChange(node.path, false)}
      >
        <span class="tree-item-content">
          <span class:folder-icon={isDirectory(node)} class:file-icon={!isDirectory(node)} aria-hidden="true"></span>
          <span class="tree-item-name" title={node.name}>{node.name}</span>
          {#if isDirectory(node)}
            <span class="tree-item-actions" aria-label={`${node.name} actions`}>
              <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
              <sl-icon-button
                name="folder-plus"
                label={`Create folder in ${node.name}`}
                title={`Create folder in ${node.name}`}
                on:click|stopPropagation={() => onCreateDirectory(node.path)}
              ></sl-icon-button>
              <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
              <sl-icon-button
                name="file-earmark-plus"
                label={`Create essay in ${node.name}`}
                title={`Create essay in ${node.name}`}
                on:click|stopPropagation={() => onCreateEssay(node.path)}
              ></sl-icon-button>
              <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
              <sl-icon-button
                name="trash"
                label={`Delete folder ${node.name}`}
                title={`Delete folder ${node.name}`}
                on:click|stopPropagation={() => onDelete(node)}
              ></sl-icon-button>
            </span>
          {:else}
            <span class="tree-item-actions" aria-label={`${node.name} actions`}>
              <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
              <sl-icon-button
                name="trash"
                label={`Delete essay ${node.name}`}
                title={`Delete essay ${node.name}`}
                on:click|stopPropagation={() => onDelete(node)}
              ></sl-icon-button>
            </span>
          {/if}
        </span>
        {#if isDirectory(node) && node.children.length > 0}
          <svelte:self
            nodes={node.children}
            selectedPath={selectedPath}
            expandedPaths={expandedPaths}
            onSelect={onSelect}
            onSelectRoot={onSelectRoot}
            onExpansionChange={onExpansionChange}
            onCreateDirectory={onCreateDirectory}
            onCreateEssay={onCreateEssay}
            onDelete={onDelete}
            isRoot={false}
          />
        {/if}
      </sl-tree-item>
    {/each}
    </sl-tree-item>
  </sl-tree>
{:else}
  {#each nodes as node (node.path.join("/"))}
    <sl-tree-item
      data-path={JSON.stringify(node.path)}
      expanded={isExpanded(node.path)}
      selected={samePath(node.path, selectedPath)}
      on:sl-expand={() => onExpansionChange(node.path, true)}
      on:sl-collapse={() => onExpansionChange(node.path, false)}
    >
      <span class="tree-item-content">
        <span class:folder-icon={isDirectory(node)} class:file-icon={!isDirectory(node)} aria-hidden="true"></span>
        <span class="tree-item-name" title={node.name}>{node.name}</span>
        {#if isDirectory(node)}
          <span class="tree-item-actions" aria-label={`${node.name} actions`}>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
            <sl-icon-button
              name="folder-plus"
              label={`Create folder in ${node.name}`}
              title={`Create folder in ${node.name}`}
              on:click|stopPropagation={() => onCreateDirectory(node.path)}
            ></sl-icon-button>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
            <sl-icon-button
              name="file-earmark-plus"
              label={`Create essay in ${node.name}`}
              title={`Create essay in ${node.name}`}
              on:click|stopPropagation={() => onCreateEssay(node.path)}
            ></sl-icon-button>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
            <sl-icon-button
              name="trash"
              label={`Delete folder ${node.name}`}
              title={`Delete folder ${node.name}`}
              on:click|stopPropagation={() => onDelete(node)}
            ></sl-icon-button>
          </span>
        {:else}
          <span class="tree-item-actions" aria-label={`${node.name} actions`}>
            <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
            <sl-icon-button
              name="trash"
              label={`Delete essay ${node.name}`}
              title={`Delete essay ${node.name}`}
              on:click|stopPropagation={() => onDelete(node)}
            ></sl-icon-button>
          </span>
        {/if}
      </span>
      {#if isDirectory(node) && node.children.length > 0}
        <svelte:self
          nodes={node.children}
          selectedPath={selectedPath}
          expandedPaths={expandedPaths}
          onSelect={onSelect}
          onSelectRoot={onSelectRoot}
          onExpansionChange={onExpansionChange}
          onCreateDirectory={onCreateDirectory}
          onCreateEssay={onCreateEssay}
          onDelete={onDelete}
          isRoot={false}
        />
      {/if}
    </sl-tree-item>
  {/each}
{/if}