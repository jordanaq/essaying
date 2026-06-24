# Project Layout

This repository is a monorepo with a local-first architecture.

## Directories

- backend/: Haskell API server and backend logic
- frontend/: Elm UI application
- shared/: cross-stack schemas, fixtures, and docs
- docs/: architecture and planning documents
- nix/: reusable Nix modules and scripts

## Build Entrypoints

- nix build .#default: build backend default package
- nix run .#default: run backend default app
- nix develop: open monorepo development shell

## Notes

- haskell-flake is configured with projectRoot = ./backend
- backend remains cabal-described, while Nix/flake controls reproducible environment
