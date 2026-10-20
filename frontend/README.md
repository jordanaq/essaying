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
- Interactive markdown editor panel
- AI feedback panel with mock streaming preview
- API handshake button for `/api/v1/ready`
- Folder context editor for title, audience, model, tags, instructions, grading directions, and weighted rubric criteria
- Context inheritance controls (inherit, set/clear, append/replace, merge/replace) and a saved effective-context preview for the selected essay
- Create, update, and remove folder context layers through `/api/v1/accounts/:accountId/workspace/context`

Select a folder or essay to edit its folder settings in **Context & Feedback**. Use the scope selector to edit an ancestor or the workspace root. Save or discard pending edits before changing scope. The effective-context preview refreshes after saves and removals; select an essay to view it.

## Next steps

- Replace mock grade stream with SSE endpoint
