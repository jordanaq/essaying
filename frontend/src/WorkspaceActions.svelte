<script lang="ts">
  import "@shoelace-style/shoelace/dist/components/dropdown/dropdown.js";
  import "@shoelace-style/shoelace/dist/components/menu/menu.js";
  import "@shoelace-style/shoelace/dist/components/menu-item/menu-item.js";
  import "@shoelace-style/shoelace/dist/components/divider/divider.js";
  import "@shoelace-style/shoelace/dist/components/icon-button/icon-button.js";

  export let name: string;
  export let directory = false;
  export let root = false;
  export let onCreateEssay: () => void;
  export let onCreateDirectory: () => void;
  export let onDelete: () => void;

  function handleAction(event: CustomEvent<{ item: { value: string } }>) {
    const action = event.detail.item.value;
    if (action === "essay") onCreateEssay();
    else if (action === "folder") onCreateDirectory();
    else if (action === "delete") onDelete();
  }
</script>

<!-- Keep menu interaction from selecting or expanding its enclosing tree row.
     Shoelace handles keyboard navigation inside the dropdown. -->
<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<span class="tree-item-actions" on:click|stopPropagation on:keydown|stopPropagation>
  <sl-dropdown placement="bottom-end" hoist>
    <sl-icon-button slot="trigger" name="three-dots" label={`Actions for ${name}`} title={`Actions for ${name}`}></sl-icon-button>
    <sl-menu aria-label={`${name} actions`} on:sl-select={handleAction}>
      {#if directory || root}
        <sl-menu-item value="essay">Create essay</sl-menu-item>
        <sl-menu-item value="folder">Create folder</sl-menu-item>
      {/if}
      {#if !root}
        {#if directory}<sl-divider></sl-divider>{/if}
        <sl-menu-item value="delete" class="delete-action">Delete {directory ? "folder" : "essay"}</sl-menu-item>
      {/if}
    </sl-menu>
  </sl-dropdown>
</span>

<style>
  .delete-action { --sl-color-neutral-700: var(--ctp-red); }
</style>
