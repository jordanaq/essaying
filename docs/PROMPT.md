# Research Context

Date: 2026-06-24

This is the historical research brief, retained for design background. The
overrides below supersede conflicting requirements in the original research.
For current behavior and setup, start with [README.md](../README.md), the
[API contract](BACKEND_API_SKETCH.md), and the
[context contract](CONTEXT_DESIGN.md). The original roadmap and dependency
recommendations below are historical, rather than an implementation status report.

## Current provider scope (2026-10-27)

The Ollama-only/local-AI requirements below are historical and superseded.
Essaying will support any provider implementing the required OpenAI-compatible
API, with a configurable provider base URL, API key, and model ID. OpenAI hosting
is not required. Provider connection settings stay in the backend environment;
credentials never belong in browser code, context files, logs, or source control.
AI actions send relevant essay text and context to the selected provider; local
editing and saving do not need provider access. Provider capabilities must be
checked for the requested operation. Provider integration is implemented; see
the API contract for supported operations and limitations, and
`CONTEXT_DESIGN.md` for the JSON context contract, which supersedes the older
YAML examples below.

## Current MVP response scope (2026-10-27)

Streaming and user-initiated cancellation are post-MVP stretch L10. MVP prompt
and grading requests use bounded non-streaming provider calls and return one
complete JSON result or an actionable HTTP error. The UI shows pending,
success, and failure states while editing remains usable. The streaming/SSE
requirements in the historical research below do not apply to the MVP.

## Current essay storage (2026-10-30)

The essay-directory migration is complete and the existing cache is converted.
An essay is identified by its workspace-relative directory, such as
`History/Causes`, with a required `essay.md` draft, optional `prompt.md`
assignment, and optional essay-local `context.json`. Context inheritance includes
that local layer. Essays appear as explorer leaves; draft and assignment save
independently, and essay deletion removes the whole directory. Older file-based
essay descriptions below are historical. The current contracts are in
[ESSAY_DIRECTORY_PLAN.md](ESSAY_DIRECTORY_PLAN.md) and
[BACKEND_API_SKETCH.md](BACKEND_API_SKETCH.md). No further legacy-layout checks
or migration tooling are required.

## Original Query

### Role

You are an expert Haskell/Svelte software architect, local-first application designer, and AI-LLM integration specialist. Conduct deep research and produce a concrete, phased implementation plan for the project below. Only reference current (2024-2026) stable releases and official documentation.

### Project Overview

A local-first web app hosted on a local server for essay prompting, writing, and grading.

- Storage and account model:
	- Support local user accounts.
	- Store account data, filesystem tree, and essay folders under a user-configurable cache root.
	- Read cache root from `HESSAY_CACHE`; default to `~/.cache/hessaying` when unset.
- Core architecture:
	- Haskell backend handles logic, file-system management, and Ollama integration.
	- Svelte frontend handles UI.
- Frontend goal:
	- Out-of-the-box, polished UI using high-quality web components.
	- Minimal low-level CSS/DOM work in Svelte.
- Key features:
	- AI prompt generation via Ollama.
	- Simple markdown editor.
	- AI grading using dynamic rubrics.
	- Folder navigation: Subjects -> Projects -> Essays.
- Context logic:
	- Each directory can contain context.yaml.
	- Metadata and instructions trickle down to sub-items unless overridden.

### Research Objectives and Deliverables

Provide a structured plan covering:

- Architecture and tech stack:
	- Haskell packages for server, directory walking, and YAML parsing.
	- Svelte libraries or patterns for out-of-the-box UI.
- Data model:
	- context.yaml schema and rubric schema.
	- Inheritance rules from parent to child folders.
- Ollama integration:
	- API handshake.
	- Model selection (global vs per-project).
	- Streaming from backend to frontend.
- System flow:
	- Protocol choices between Svelte and Haskell (REST/JSON vs WebSockets).
	- Real-time grading and text editing updates.
- Roadmap:
	- Phased MVP -> V2 plan.
	- Complexity level per phase.
	- Initial setup checklist.
	- State-sync risk assessment.

### Output Format Requirements

- Use clear headings and bullet points.
- Recommend specific packages and version ranges.
- Provide a one-page Sprint 1 checklist (the Starting Line).

## Research Summary

- Duration: 995.8s
- Rounds: 2
- Queries: 4
- URLs analyzed: 14

## Executive Summary

The project combines Haskell, Svelte, and Ollama to build a local-first essay platform with strong type safety, predictable UI state, and local AI execution. The key architectural idea is contextual inheritance via context.yaml files so folder-level guidance cascades downward into projects and essays.

The backend is centered on a typed Servant API, while the frontend uses Svelte + TypeScript + Vite plus Web Components for a polished out-of-the-box experience. The system design emphasizes write-through persistence to the local file system and streamed AI responses so the UI remains responsive during generation and grading.

## 1. Architecture and Tech Stack

### Why Haskell + Svelte

- Haskell provides robust modeling for:
	- Typed API contracts.
	- Context merge logic.
	- Streaming AI response handling.
- Svelte provides low-boilerplate component composition, reactive state, and straightforward TypeScript integration.

### Backend Recommendations

- Web/API: Servant + Warp
- JSON: Aeson
- YAML: yaml (Data.Yaml)
- File operations: directory + filepath
- Environment/config: base (`System.Environment`) and `xdg-basedir` or equivalent path resolution helper

Key approach:

- Define API contracts as types in Servant for compile-time safety.
- Use a translation layer to map backend records to frontend-friendly JSON.
- Resolve runtime storage root at startup:
	- `HESSAY_CACHE` if set.
	- Otherwise `~/.cache/hessaying` (expand `~` to user home).

### Frontend Recommendations

- Svelte 5 with TypeScript for application state and component architecture.
- Vite 5 for local dev server and production builds.
- Shoelace (`@shoelace-style/shoelace`) for polished UI primitives.
- Keep frontend code in `frontend/src` and use Vite scripts (`dev`, `build`, `preview`) from `frontend/package.json`.

## 2. Data Model and Context Inheritance

### Contextual Inheritance Model

- Treat the folder tree as context hierarchy.
- On load, backend walks from root to current folder.
- Merge context.yaml files using child-overrides-parent semantics.

### Suggested context.yaml Blocks

- Metadata:
	- title, tags, audience, and similar descriptors.
- Instructions:
	- String or list of strings for system guidance.
- Rubric:
	- Structured criteria with weights.

Example shape:

- clarity: 0.4
- originality: 0.6

### Account and Storage Layout

- Add account identity and directory ownership to backend state.
- Recommended on-disk layout:
	- `<cacheRoot>/hessaying/users/<accountId>/`
	- `<cacheRoot>/hessaying/users/<accountId>/workspace/...`
	- `<cacheRoot>/hessaying/users/<accountId>/profile.json`
- Treat each account workspace as the root for context inheritance and folder browsing.

## 3. Ollama Integration

### Core Integration Behavior

- Keep all AI calls local via Ollama.
- Support real-time token streaming to frontend.
- Handle optional model reasoning fields safely.

### Model Selection

- Global default model at workspace level.
- Optional per-folder or per-project override in context.yaml.
- Use fast models for drafting and larger models for grading when needed.

## 4. System Flow and Communication

### Request Modes

- REST/JSON for stateful operations:
	- Load tree/context.
	- Save drafts.
	- Update rubrics.
- SSE for AI streaming operations:
	- Prompt generation.
	- Drafting help.
	- Grading feedback.

### State Sync Principle

- File system is source of truth.
- Frontend does not write files directly.
- Backend validates and writes to disk before confirming success.
- All reads/writes are constrained to the resolved account cache root to avoid cross-account leakage.

## 5. Roadmap

### Phase 1: Foundation (Complexity: Low)

- Set up Servant + Warp backend shell.
- Implement initial context.yaml parsing and merge path.
- Build basic Svelte navigation view.
- Validate API handshake with a System Ready endpoint.
- Implement storage-root resolution from `HESSAY_CACHE` (fallback to `~/.cache/hessaying`).
- Create initial account bootstrap and per-account workspace directories.

### Phase 2: Core Features (Complexity: Medium)

- Add Ollama bridge and streaming pipeline.
- Integrate markdown editor.
- Activate context-aware prompt/rubric behavior.
- Scope all file operations by authenticated/selected local account.

### Phase 3: Advanced Features (Complexity: High)

- Implement grading engine against dynamic rubrics.
- Improve polished UI behavior with component-level refinement.
- Harden error handling for file and LLM edge cases.

## Risk Assessment

| Risk | Impact | Mitigation |
| --- | --- | --- |
| State desync | High | Write-through persistence: backend writes to disk before success response. |
| Ollama latency | Medium | Stream partial responses via SSE for immediate feedback. |
| Context complexity | Low | Use strictly typed context records and validated parsing. |
| Cache root misconfiguration | Medium | Validate `HESSAY_CACHE` at startup, create directories eagerly, and fail fast with actionable error messages. |
| Cross-account data leakage | High | Enforce per-account root scoping and path normalization for every filesystem operation. |

## Conclusion

This architecture uses typed backend contracts, predictable frontend state, and local AI inference to deliver a robust writing platform. Context inheritance and write-through persistence reduce user friction while preserving reliability. Streaming responses improve perceived speed and interaction quality.

## Starting Line: Sprint 1 Checklist

- Haskell environment:
	- Initialize with cabal or stack.
	- Include servant, warp, aeson.
- Runtime storage config:
	- Read `HESSAY_CACHE` with fallback to `~/.cache/hessaying`.
	- Expand and normalize the path, then ensure it exists.
- Account bootstrapping:
	- Define account ID format and local profile schema.
	- Create per-account workspace root under cache directory.
- YAML parsing:
	- Create sample context.yaml.
	- Parse it into typed Haskell records.
- Svelte foundation:
	- Initialize or maintain Svelte + TypeScript + Vite app.
	- Validate one Shoelace web-component integration.
- API handshake:
	- Add GET endpoint returning System Ready with sample rubric payload.
- Ollama connectivity:
	- Verify local Ollama by calling /api/generate successfully.