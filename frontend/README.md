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

## Current stub includes

- Interactive folder tree panel
- Interactive markdown editor panel
- AI feedback panel with mock streaming preview
- API handshake button for `/api/ready`

## Next steps

- Replace mock grade stream with SSE endpoint
- Load real tree/context/rubric from backend endpoints
- Add write-through save integration
