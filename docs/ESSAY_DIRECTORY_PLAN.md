# Essay directory storage and completed migration

Status: M01–M04 complete under the revised migration scope, 2026-10-30.
The filename is retained for existing links; this document describes the current
storage contract. The existing cache is converted. No reusable converter,
legacy-layout scan, restart gate, or backup/restore rehearsal is required to
close this migration.

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
  root-level essay operations are rejected.
- The directory name supplies the title in the explorer. It is the canonical
  identity, represented by workspace-relative directory path segments, e.g.
  `["History", "My Essay"]`. Internal filenames are not part of that identity.
- Essays appear as leaf nodes. Discovery does not descend into them. Creating
  folders or essays inside an essay is rejected, including through direct API
  requests. Unexpected existing child files/directories are preserved; loading,
  saving, creating, and deleting nested essay targets are rejected.
- `essay.md` contains only the draft. `prompt.md` contains only the assignment.
  Missing and empty prompts both mean no assignment for AI purposes. Prompt text
  is local to the essay and does not inherit from parent directories.
- `context.json` retains its current schema and merge rules. The assignment is
  stored separately from context. Resolve root context, enclosing folder layers,
  then the essay's own context layer. A missing layer contributes nothing; invalid context continues
  to block AI actions while draft and prompt editing/saving remain available.
- The directory name supplies the explorer title even when effective context has
  a different `title`; that inherited field remains descriptive AI context.
- Creation publishes an essay directory only after `essay.md` exists. Optional
  files need not be created until first saved. An empty prompt save writes an
  empty `prompt.md`; it does not require a separate delete operation.
- Essay deletion removes the whole essay directory, including extra files. The
  UI explicitly describes that scope. Folder deletion rejects an essay target.
  Rename/move, when implemented under L02, must operate on the whole directory.
- Loose Markdown outside essay directories is not an essay and is omitted from
  discovery. The existing cache conversion is complete; no further legacy scan
  or conversion step is required.

## Implemented API contract

The account-scoped `/workspace/essays` route family uses directory identities
in both backend and frontend. Old `.md` path aliases and dual-format support
are not implemented. See [the API reference](BACKEND_API_SKETCH.md) for route examples.

- Tree nodes retain `WorkspaceEssayNode`, use the directory name and directory
  path, and have no children. Organizational folders retain their current type.
- Essay GET returns `{ path, title, markdown, prompt }`; `prompt` is a string and
  defaults to `""` if the file is absent. Unreadable prompts are errors, not empty
  values; the frontend must not substitute an empty prompt after a failed load.
- Essay PUT accepts independently optional `markdown` and `prompt` strings.
  An omitted field is unchanged, an empty string is saved, and null/unknown
  fields and empty update objects are rejected. The UI saves one field per
  request; requests containing both fields are rejected, so there is no
  implied atomic two-file save. Return the updated essay representation.
- Essay POST keeps `parentPath`, `essayName`, and optional initial `markdown`,
  and accepts optional initial `prompt`. Absence produces an empty draft and no
  prompt file. Creation must not overwrite any existing file or directory at
  the destination. A failed create must not expose a partial essay.
- Essay DELETE targets the directory identity. Workspace target checks reject
  unsafe paths, nesting, and symlinks; broader boundary hardening remains E11.
- Effective-context GET and AI request `path` values use the same directory
  identity. Context layer CRUD continues to use explicit `context.json` paths.
- Backend grading loads the saved draft, saved assignment, and resolved context
  as separate inputs. Without an assignment it grades using context and rubric.
  Prompt generation uses context and optional instructions without loading the
  draft, returning candidates without saving them. The frontend supports
  candidate adoption into the assignment editor followed by explicit prompt saving.
- Draft and prompt have separate dirty/saving/error state. Successful draft
  saves must not replace unsaved prompt text from the response, or vice versa.
  Frontend grading requires pending edits to be saved or explicitly discarded;
  candidate adoption confirms replacement of unsaved assignment text.

## Completion record

- M01: backend storage/API uses essay directories, independent draft/assignment
  saves, essay-local context, validated targets, and failed-creation cleanup.
- M02: user revised scope to direct conversion instead of a reusable tool.
  Conversion completed 2026-10-29 with a verified backup and manifest. The
  2026-10-30 read-only audit found all eight mapped files still matched their
  original hashes.
- M03: explorer and editors use directory identities, independent save/discard
  state, stale-response protection, and unsaved-edit navigation/reload guards.
- M04: documentation reconciled with the implemented format. On 2026-10-30 the
  user removed further legacy-layout, restart, and restore checks from migration
  acceptance because the cache was already updated. No new migration tooling or
  user-data conversion is pending.

Recorded implementation verification passed 232 regular backend cases, 16
frontend component cases, a typechecked frontend build, and 35 browser scenarios.
These are prior passing runs, not new tests performed for this documentation
update. Existing provider samples and recorded-response fixtures already use
`essay.md` markers and separate assignments where relevant.

## Remaining feature work

E07 prompt generation/adoption, E08/E09 grading/results, and E10 editor
reliability/polish are complete with user acceptance on 2026-10-30. Latest recorded
frontend verification passed 47 component cases, 39 affected mocked-API browser
scenarios, and a production build with zero Svelte diagnostics.

E11 filesystem/API hardening is next. E12 retains complete isolated-cache,
restart, account-isolation, and provider workflow checks; E13 retains fresh-setup
validation and final documentation reconciliation after those checks. These do
not reopen migration.

Rename/move, attachments, reusable prompts, optimistic concurrency, and streaming
remain later scope. The deferred save/reload acknowledgment issue stays L11.
