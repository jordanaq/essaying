# Essay directory migration plan

Status: agreed storage direction; implementation planned, not started.
Date: 2026-10-27 (America/New_York).

This plan changes the workspace model before prompt generation and grading.
Backend implementation and migration tooling remain user-owned under AGENTS.md;
this document does not authorize their implementation or conversion of user data.

## Storage contract

```text
History/
├── context.json
└── My Essay/
    ├── essay.md
    ├── prompt.md       # optional
    └── context.json    # optional
```

- A non-root directory containing a regular, non-symlink `essay.md` is an essay.
  An empty `essay.md` is valid. The account workspace root is always a container;
  a legacy root-level `essay.md` must be handled by migration before cutover.
- The directory name supplies the title in the explorer. It is the canonical
  identity, represented by workspace-relative directory path segments, e.g.
  `["History", "My Essay"]`. Internal filenames are not part of that identity.
- Essays appear as leaf nodes. Discovery does not descend into them. Creating
  folders or essays inside an essay is rejected, including through direct API
  requests. Unexpected existing child files/directories are preserved; nested
  essay markers are reported during migration/preflight rather than hidden.
- `essay.md` contains only the draft. `prompt.md` contains only the assignment.
  Missing and empty prompts both mean no assignment for AI purposes. Prompt text
  is local to the essay and does not inherit from parent directories.
- `context.json` retains its current schema and merge rules. No `prompt` field is
  added. Resolve root context, enclosing folder layers, then the essay's own
  context layer. A missing layer contributes nothing; invalid context continues
  to block AI actions while draft and prompt editing/saving remain available.
- The directory name supplies the explorer title even when effective context has
  a different `title`; that inherited field remains descriptive AI context.
- Creation publishes an essay directory only after `essay.md` exists. Optional
  files need not be created until first saved. An empty prompt save writes an
  empty `prompt.md`; it does not require a separate delete operation.
- Essay deletion removes the whole essay directory, including extra files. The
  UI explicitly describes that scope. Folder deletion rejects an essay target.
  Rename/move, when implemented under L02, must operate on the whole directory.
- Loose Markdown outside essay directories is not an essay after cutover. Report
  unmigrated candidates rather than silently claiming migration succeeded.

## Proposed API contract

Keep the existing account-scoped `/workspace/essays` route family, but change
essay path semantics to the directory identity. Coordinate backend and frontend
cutover; old `.md` path aliases and permanent dual-format support are out of scope.

- Tree nodes retain `WorkspaceEssayNode`, use the directory name and directory
  path, and have no children. Organizational folders retain their current type.
- Essay GET returns `{ path, title, markdown, prompt }`; `prompt` is a string and
  defaults to `""` if the file is absent. Unreadable prompts are errors, not empty
  values; the frontend must not substitute an empty prompt after a failed load.
- Essay PUT accepts independently optional `markdown` and `prompt` strings.
  An omitted field is unchanged, an empty string is saved, and null/unknown
  fields and empty update objects are rejected. The UI saves one field per
  request; initially reject requests containing both fields so there is no
  implied atomic two-file save. Return the updated essay representation.
- Essay POST keeps `parentPath`, `essayName`, and optional initial `markdown`,
  and adds optional initial `prompt`. Absence produces an empty draft and no
  prompt file. Creation must not overwrite any existing file or directory at
  the destination. A failed create must not expose a partial essay.
- Essay DELETE targets the directory identity. All operations validate the
  selected account, path, ancestor types, and symlinks, including internal files.
- Effective-context GET and AI request `path` values use the same directory
  identity. Context layer CRUD continues to use explicit `context.json` paths.
- AI operations load the saved draft, saved prompt, and resolved context on the
  backend. Keep these inputs separate. E07 generation returns a candidate;
  “Use this prompt” puts it into the editable prompt field, and saving persists
  it. E08 grading uses the saved assignment when present; without an assignment,
  grading remains available using context/rubric and makes that state clear.
- Draft and prompt have separate dirty/saving/error state. Successful draft
  saves must not replace unsaved prompt text from the response, or vice versa.
  AI actions require relevant pending edits to be saved or explicitly discarded.

## Implementation sequence and cards

### M01 — Adopt essay directories in backend storage and API

User-owned backend work; use the contract above as the review target.

Touch points: `Types/Workspace.hs`, `Persistence/Workspace.hs`,
`Handler/Workspace.hs`, `API/V1.hs`, `Persistence/Context.hs`, context path error
messages, and AI path types/contracts. Keep context merge logic unchanged.

Acceptance:

- Discover essay directories as leaves; distinguish folders consistently across
  list/create/load/save/delete. Reject nesting and root essay operations.
- Create/read/update draft and prompt independently; empty text survives reload.
- Root-to-essay context includes the local essay layer and retains strict errors.
- Broken context does not prevent draft/prompt persistence.
- Verify collisions, unsafe paths, symlink ancestors/internal files, wrong target
  types, missing/unreadable files, failed writes, and cross-account isolation.
- Focused persistence and HTTP regression tests pass; backend build passes.

### M02 — Add an explicit legacy migration tool

Depends on M01; user-owned backend/tooling work. No automatic startup migration.

For each confirmed legacy essay `History/My Essay.md`, propose
`History/My Essay/essay.md`. Do not extract a prompt from draft contents, create
an empty local context layer, or change enclosing context files. The new missing
local layer preserves the old effective context.

Acceptance:

1. Read-only dry run enumerates selected account roots and source/destination
   mappings. Let the operator exclude Markdown documents that are not essays.
2. Preflight the whole selected set before mutation: destination collisions,
   symlinks, unreadable sources, names/paths, nested markers, and ambiguous
   directories already containing `essay.md`. A folder with `essay.md` may be a
   legacy folder containing an essay named `essay`; require explicit resolution
   rather than assuming it is already migrated.
3. Require the app to be stopped and take a verified backup outside workspaces
   before applying. Never overwrite or merge into an existing destination.
4. Prepare each destination outside the visible workspace, preserving source
   bytes; verify the copy before publication. Use no-clobber operations. Record
   per-item progress in a migration manifest outside the workspace and retain
   originals until their published copies are verified. Define interruption
   recovery before implementing the tool; migration is not an all-account
   atomic transaction.
5. An interrupted/repeated run uses the manifest to distinguish completed,
   pending, and conflicting items, verifies files, and never guesses or deletes
   conflicting content. Provide explicit recovery and backup-restore instructions.
6. Verify draft bytes, essay counts, old-to-new identities, and unchanged
   effective context for every migrated essay. Start the new app only after
   unresolved collisions/ambiguities are cleared. Preserve a mapping for resetting
   any saved client selections that refer to old `.md` paths.

Migration tests use isolated temporary workspaces: empty/Unicode drafts,
multi-account/nested folders, filename `essay.md`, existing destinations,
already-converted directories, symlinks, permission/write failures, interruption,
and repeated runs. No live user data is converted as part of implementation tests.

### M03 — Switch explorer and editors to directory identities

Depends on M01's agreed contract. Frontend can be developed against mocks before
backend completion; integrated acceptance follows M01.

Touch points: `App.svelte`, `WorkspaceTree.svelte`, `ContextPanel.svelte`,
`context-preview.ts`, component fixtures, and browser scenarios.

Acceptance:

- Explorer shows `My Essay` as an essay leaf; internal files do not appear.
  Creation uses folder names without appending `.md`, and essays cannot be used
  as parents. Delete confirmation explains whole-directory deletion.
- Selection, load/save/delete, and context preview use directory identities.
  Context scope choices include the selected essay directory itself.
- Provide an assignment prompt editor with independent save/error/dirty states.
  Preserve sibling unsaved edits during any save and prevent stale account or
  essay responses from replacing current drafts/prompts.
- Protect prompt, draft, and context edits on navigation/account change/reload.
  Move this prerequisite portion of E10 forward; E10 retains broader polish.
- Verify absent/empty prompts, empty drafts, context errors, reload persistence,
  switching accounts/essays, failed saves, and desktop/mobile usability.
- Frontend component tests, typechecked build, and relevant browser tests pass.

### M04 — Validate cutover and reconcile documentation

Depends on M01–M03. In an isolated cache, dry-run/apply the migration, launch the
new app, and verify discovery, draft/prompt saves, essay-local rubric inheritance,
restart persistence, account isolation, deletion scope, and failure recovery.
Record evidence and a manual backup/restore rehearsal. Update sample files and
their fixture expectations, README, context design, context error docs, and API
sketch to describe the implemented format; label this document planned until then.

Backend tests/build, frontend tests/build, relevant live-API browser scenarios,
and `git diff --check` must pass. Existing passing evidence for the old layout is
historical and does not satisfy this gate. Actual user-data conversion is a
separate explicit action after review of the dry-run report and backup.

## Relationship to existing work

- M01–M04 precede the integrated E07/E08 workflows. E06 provider plumbing can
  proceed independently once it uses the agreed directory identity contract.
- E07 includes candidate adoption and prompt persistence through normal saving.
- E08 uses the saved prompt alongside effective context and draft; E09 presents
  those results without overwriting either saved file.
- E10 retains UI polish and navigation protection not already covered by M03;
  E11 still covers broader filesystem hardening. M01/M02 safety is required now.
- E12 adds migration/restart and saved-prompt grading to full workflow checks.
- Shared/reusable prompts, attachments UI, nested essays, optimistic concurrency,
  and rename/move implementation remain later scope. Extra files are preserved
  by ordinary draft/prompt saves and travel with directory operations.
