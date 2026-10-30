# Frontend

Minimal interactive frontend for the essay platform.

## Stack

- Svelte + TypeScript + Vite
- Shoelace Web Components for out-of-the-box UI
- No heavy architecture required to start

## Why this setup

- Very low frontend maintenance
- Feature-rich components immediately
- Functional/declarative style without complex boilerplate

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
- Independent assignment-prompt and draft editors with save/discard controls
- AI feedback panel with mock grading feedback
- API handshake button for `/api/v1/ready`
- Folder context editor for title, audience, model, tags, instructions, grading directions, and weighted rubric criteria
- Context inheritance controls (inherit, set/clear, append/replace, merge/replace) and a saved effective-context preview for the selected essay
- Create, update, and remove folder context layers through `/api/v1/accounts/:accountId/workspace/context`

Essays are directories containing a required `essay.md` draft and optional
`prompt.md` assignment. The explorer displays the directory as a leaf; deletion
removes the whole essay directory. Each editor saves one field at a time and
preserves unsaved sibling edits. Navigation and page reload protect unsaved
draft, assignment, and context changes.

Select a folder or essay to edit its context in **Context & Feedback**. An essay
selection defaults to its own context layer. Use the scope selector to edit an ancestor or the workspace root. Save or discard pending edits before changing scope. The effective-context preview refreshes after saves and removals; select an essay to view it.

## Next steps

- Connect prompt generation/adoption and grading/results to the implemented
  complete-response backend endpoints (E07–E09). Streaming is post-MVP L10.
