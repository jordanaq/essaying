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
  import WorkspaceActions from "./WorkspaceActions.svelte";
  import "@shoelace-style/shoelace/dist/components/tree/tree.js";
  import "@shoelace-style/shoelace/dist/components/tree-item/tree-item.js";
  import "@shoelace-style/shoelace/dist/components/icon-button/icon-button.js";

  export let nodes: WorkspaceNode[] = [];
  export let selectedPath: string[] = [];
  export let expandedPaths: string[][] = [];
  export let onSelect: (node: WorkspaceNode) => boolean | void;
  export let onSelectRoot: () => boolean | void;
  export let onExpansionChange: (path: string[], expanded: boolean) => void;
  export let onCreateDirectory: (path: string[]) => void;
  export let onCreateEssay: (path: string[]) => void;
  export let onDelete: (node: WorkspaceNode) => boolean | void;
  export let isRoot = true;

  function samePath(left: string[], right: string[]) {
    return left.length === right.length && left.every((segment, index) => segment === right[index]);
  }

  function isDirectory(node: WorkspaceNode) {
    return (typeof node.nodeType === "string" ? node.nodeType : node.nodeType.tag) === "WorkspaceDirectoryNode";
  }

  $: sortedNodes = [...nodes].sort((left, right) =>
    Number(isDirectory(right)) - Number(isDirectory(left)) || left.name.localeCompare(right.name)
  );

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

  function restoreSelection() {
    queueMicrotask(() => {
      for (const item of document.querySelectorAll<HTMLElement & { selected: boolean }>("sl-tree-item[data-path]")) {
        item.selected = samePath(JSON.parse(item.dataset.path ?? "[]"), selectedPath);
      }
    });
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
      if (onSelectRoot() === false) restoreSelection();
      return;
    }

    const node = findNode(path);
    if (node) {
      if (onSelect(node) === false) restoreSelection();
    }
  }
</script>

{#if isRoot}
  <sl-tree selection="single" on:sl-selection-change={handleSelectionChange}>
    <sl-tree-item class="workspace-root" data-path="[]" selected={selectedPath.length === 0} expanded>
      <span class="tree-item-content">
        <span class="folder-icon" aria-hidden="true"></span>
        <span class="tree-item-name" title="Workspace">Workspace</span>
        <WorkspaceActions name="Workspace" root
          onCreateEssay={() => onCreateEssay([])}
          onCreateDirectory={() => onCreateDirectory([])} onDelete={() => {}} />
      </span>
    {#each sortedNodes as node (node.path.join("/"))}
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
          <WorkspaceActions name={node.name} directory={isDirectory(node)}
            onCreateEssay={() => onCreateEssay(node.path)}
            onCreateDirectory={() => onCreateDirectory(node.path)} onDelete={() => onDelete(node)} />
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
  {#each sortedNodes as node (node.path.join("/"))}
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
        <WorkspaceActions name={node.name} directory={isDirectory(node)}
          onCreateEssay={() => onCreateEssay(node.path)}
          onCreateDirectory={() => onCreateDirectory(node.path)} onDelete={() => onDelete(node)} />
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
