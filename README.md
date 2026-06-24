# Essaying Monorepo

Local-first essay platform with a Haskell backend and Svelte frontend.

## Start Components

Run all commands from the repository root.

### Backend (API)

Start backend with Nix:

```bash
nix --accept-flake-config run .#backend
```

Default backend app command also works:

```bash
nix --accept-flake-config run .#default
```

Backend serves on `127.0.0.1:8080`.

### Frontend (UI)

Start frontend with Nix:

```bash
nix --accept-flake-config run .#frontend
```

Frontend serves on `127.0.0.1:4173` and proxies `/api` to backend on `127.0.0.1:8080`.

### Backend + Frontend Together

Start both components at once:

```bash
nix --accept-flake-config run .#dev
```

### Optional: Start Without Nix (Manual)

Backend:

```bash
cd backend
cabal run haskell-essaying
```

Frontend:

```bash
cd frontend
npm install
npm run dev -- --host 127.0.0.1 --port 4173
```

## Useful Development Commands

Open development shell:

```bash
nix develop
```

Build backend package:

```bash
nix build .#default
```