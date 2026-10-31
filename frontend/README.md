# Frontend

Svelte 5 and TypeScript UI for local accounts, essay directories, inherited
context, prompt generation, and grading. Vite handles development/builds,
Shoelace supplies UI components, Vitest checks components, and Playwright checks
browser workflows.

## Run

Single command from repo root:

```
nix --accept-flake-config run .#frontend
```

Start backend + frontend together from repo root:

```
nix --accept-flake-config run .#dev
```

Frontend will run on http://127.0.0.1:4173 and proxies `/api` to backend on `127.0.0.1:8080`.

## Current UI includes

- Interactive folder tree panel
- Ellipsis menus for workspace/folder creation and folder/essay deletion, with
  keyboard navigation and popup colors that follow the selected theme
- Independent assignment-prompt and draft editors with save/discard controls,
  rendered Markdown by default, a raw Markdown toggle, live save/error states,
  soft wrapping, and vertical resizing (L21)
- Collapsible prompt generation with optional instructions and numbered candidates;
  double-click a candidate or choose **Use this prompt** to apply it to the
  assignment editor, then **Save Prompt** to persist it
- Real grading with overall score, per-criterion scores/weights/feedback, and
  provider error/retry handling
- API handshake button for `/api/v1/ready`
- Folder context editor for title, audience, model, tags, instructions, grading directions, and weighted rubric criteria
- Context inheritance controls (inherit, set/clear, append/replace, merge/replace) and a saved effective-context preview for the selected essay
- Context error messages include a collapsed Details section with File and Field when available (L09)
- Create, update, and remove folder context layers through `/api/v1/accounts/:accountId/workspace/context`

Essays are directories containing a required `essay.md` draft and optional
`prompt.md` assignment. The explorer displays the directory as a leaf; deletion
removes the whole essay directory. Each editor saves one field at a time and
preserves unsaved sibling edits. Navigation and page reload protect unsaved
draft, assignment, and context changes.

Select a folder or essay to edit its context in **Context & Feedback**. An essay
selection defaults to its own context layer. Use the scope selector to edit an ancestor or the workspace root. Save or discard pending edits before changing scope. The effective-context preview refreshes after saves and removals; select an essay to view it.

The draft and assignment use a shared Svelte/Tiptap editor. The toolbar offers
bold, italic, headings 1–6, bulleted/numbered lists, undo, and redo. Ctrl+B/I
(Cmd+B/I on Mac) toggles bold/italic; Ctrl+Z and Ctrl+Shift+Z undo/redo. List
shortcuts are Ctrl+Shift+8 for bullets and Ctrl+Shift+7 for numbers, with Cmd on
Mac. Typing `- ` or `1. ` starts a list; Enter continues it, Tab/Shift+Tab
indents/outdents, and Enter on an empty item exits. Raw Markdown mode edits the
source directly. Viewing or switching modes alone preserves exact source and
does not mark a saved document dirty. Rendered edits serialize Markdown and can
normalize equivalent syntax and whitespace.

Tables, images, task checkboxes, and raw HTML use source editing to preserve
their content. The editor explains when this is needed. Save/discard, generated
prompt adoption, and independent draft/assignment states work in both modes.
Document changes reset rich-text undo history; each editor retains its selected
view until it is remounted or the page reloads.

Assignment prompt and Essay draft expand/collapse independently using their
section headers (click, Enter, or Space). Both start expanded. Collapsing keeps
the editor mounted, preserving unsaved text, the chosen view, and undo history.
Save status remains visible in the collapsed header; expand to save, discard,
or inspect an error. Grade essay remains outside both collapsible sections.

## Next steps

- Streaming is post-MVP L10.
- Add explorer/folder entry for prompt generation after rubric generation
  (stretch L15, after L12). Generation from the current
  essay and adoption are connected. Generation requires resolved, saved context; a future
  workflow should also support generating a rubric when context is not ready.

**Grade essay** uses the saved draft, optional saved assignment, and resolved
effective context. Inherited context/rubrics are sufficient: no essay-local
context file is needed. Grading requires a nonblank saved draft, at least one
rubric criterion with a finite positive total weight, and a model in effective
context or the account preference. Save or discard pending edits before grading.
Starting grading opens Feedback. Editing remains available during the request;
feedback is labeled as applying to earlier saved inputs if they change. Switching
essays/accounts clears feedback and prevents late responses from replacing it.

Model choices are curated to eight GPT-6.1, GPT-6, and GPT-5.6 IDs from the
OpenAI `/v1/models` snapshot fetched on 2026-10-30. The context Model field offers the same IDs as suggestions and still
accepts custom IDs for other providers. A listed ID does not guarantee support
for Chat Completions and strict JSON-schema output. The saved context model
takes precedence over the account preference. Model selection is configured in
Context or account preferences; the unused editor selector has been removed. Automatic
endpoint-specific discovery is tracked as L13 on the local completion board.


## Checks

To review the L21 component independently, run the frontend from the repository
root and open the component fixture (no backend is needed):

```bash
nix --accept-flake-config run .#frontend
```

Open http://127.0.0.1:4173/e2e/fixtures/markdown-editor.html. The fixture edits
stay in the page and do not save to the workspace. For automated component and
mocked-API app browser checks, run `npx playwright test --config=playwright.editor.config.ts`
from `frontend/` in the Nix development shell; Playwright starts and stops its
own temporary frontend server.

`e2e/editor-app.spec.ts` exercises both app editors: toolbar controls, Ctrl and
Cmd keymaps (Mac platform emulated in Chromium), heading and list shortcuts,
nesting, soft breaks, raw/rendered round trips, save failures/retries, concurrent
edits, reloads, generated prompt adoption, history isolation, independent section
collapse with preserved editing state, and narrow layouts.
This config also runs the affected navigation, grading, and context regressions.

From a repository-root Nix development shell:

```bash
(cd frontend && npm ci)
(cd frontend && npm test)
(cd frontend && npm run build)
```

`npm run build` runs Svelte/TypeScript checking before producing `frontend/dist`.
For browser checks, stop any backend on port 8080, then use an isolated cache:

```bash
HESSAY_CACHE="$(mktemp -d /tmp/essaying-e2e.XXXXXX)" bash -c 'cd frontend && npm run e2e'
```

Playwright starts the backend and a temporary frontend on 4175, with an optional
`PLAYWRIGHT_FRONTEND_PORT` override. Outside CI, an existing backend is reused
and retains its own cache setting. Live account/context scenarios mutate test
accounts; the editor/grading scenarios use mock responses. See the
[root verification guide](../README.md#build-and-verify) for prerequisites and
limits of this coverage.
