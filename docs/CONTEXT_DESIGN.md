# Context inheritance design

Status: JSON inheritance and account-scoped context APIs implemented; reviewed
2026-10-26. Grading/provider behavior and the remaining UI requirements below
are planned. Contributing-file output is optional stretch scope (L07).

## Purpose and scope

An essay's effective context is assembled from `context.json` files in its
ancestor directories, starting at its account workspace root and ending in its
containing directory. Inner directories can override inherited settings or add
to them, according to each field's merge rule. The effective context supplies
settings and guidance for LLM operations.

Agreed behavior:

- Only directories provide context. Essay-specific overrides are out of scope.
- Appendable fields have an explicit way to replace or clear inherited values.
- Rubrics merge criteria by name and can also be replaced as a whole.
- Context is computed when needed. No generated JSON file is written to disk.
- Invalid context blocks LLM operations, while essay editing and saving remain
  available.

## Resolution

For an essay at `History/French-Revolution/causes.md`, resolve these files in order:

1. `<workspace>/context.json`
2. `<workspace>/History/context.json`
3. `<workspace>/History/French-Revolution/context.json`

A missing file contributes nothing. Never consult directories above the account
workspace, sibling directories, or the essay's contents. An empty JSON object (`{}`) is treated as an empty configuration. An empty file
is invalid JSON. The top-level value must be an object.

For each operation, discover and validate the files, then fold their parsed
layers from outermost to innermost. Validate the resulting context for the
requested operation before contacting the LLM. Each request uses one resolved
context snapshot throughout its execution; edits take effect on the next request.
This is not an atomic snapshot of multiple files edited concurrently.

Initially, resolve from disk on every context inspection and LLM request. Caching
and file watching are unnecessary for the first implementation.

## Fields and merge rules

The table describes effective values. Source files wrap supplied values in the
explicit operations described below.

| Field | Type | Default | Merge behavior |
| --- | --- | --- | --- |
| `title` | Nonempty string or null | Unset | Nearest explicit value wins |
| `audience` | Nonempty string or null | Unset | Nearest explicit value wins |
| `model` | Nonempty string or null | Unset | Nearest explicit value wins |
| `tags` | List of nonempty strings | Empty | Append, then deduplicate |
| `instructions` | List of nonempty strings | Empty | Append in outer-to-inner order |
| `grading_directions` | List of nonempty strings | Empty | Append in outer-to-inner order |
| `rubric` | Map of criterion names to definitions | Empty | Merge by criterion name |

An omitted field always inherits. At the layer's top level, `null` also means
inherit, matching Aeson's ordinary `Maybe` decoding. Clearing a scalar requires
an explicit `ClearScalar` operation. Blank strings are errors rather than an
alternative clear syntax. Collections are cleared using replacement with an
empty array or object.

## JSON representation and Haskell types

Define the types in `backend/src/Essaying/Types/Context.hs`, keeping resolution
and merging in `Essaying.Context`. Use separate records for `ContextLayer` and
`EffectiveContext`, with these operation types:

```haskell
data ScalarOverride a = SetScalar a | ClearScalar
data ListOverride a = AppendList [a] | ReplaceList [a]
data RubricOverride
  = MergeRubric (Map Text RubricCriterion)
  | ReplaceRubric (Map Text RubricCriterion)
```

Each `ContextLayer` field is optional: scalars use
`Maybe (ScalarOverride Text)`, lists use `Maybe (ListOverride Text)`, and the
rubric uses `Maybe RubricOverride`. `Nothing` means inherit. `EffectiveContext`
uses `Maybe Text`, `[Text]`, and `Map Text RubricCriterion` respectively and
contains no operations. Its defaults are unset scalars and empty collections.

Derive `Generic` and use Aeson's generic tagged-object representation for the
operation types: `tag` is the constructor name and `contents` is its payload.
`ClearScalar` has no payload. Keep the JSON field names shown in this document,
including `grading_directions`; if Haskell selectors differ, configure a field
label mapping. For example:

```json
{
  "audience": {"tag": "SetScalar", "contents": "student"},
  "model": {"tag": "ClearScalar"}
}
```

This deliberately replaces the earlier bare-scalar, plain-list, and direct-map
source forms. There is only one representation for each supplied operation.
Generic decoding supplies the structural decoding, but ordinary
`deriving anyclass (FromJSON)` alone does not enforce this entire contract.
Use `genericParseJSON` with `rejectUnknownFields = True` for records and
operation types, with matching generic encoding options. Additional validation
must reject unexpected payloads on nullary operations, duplicate JSON keys,
blank required strings, and invalid weights. Duplicate-key checking must happen
before keys are collapsed into an Aeson object. Keep this validation separate
from inheritance; choosing JSON does not eliminate it.

Tags use exact, case-sensitive equality, retaining the first occurrence and its
position. Instruction and grading-direction duplicates are retained. Strings
containing only whitespace are invalid; otherwise their contents are preserved.

Merge behavior belongs to the schema, not a generic recursive JSON merge. Future
fields must declare their type, default, validation, and merge rule explicitly.

## Appending, replacing, and clearing lists

Every supplied list uses an operation object:

```json
{
  "tags": {"tag": "AppendList", "contents": ["history", "causes"]},
  "instructions": {
    "tag": "AppendList",
    "contents": ["Distinguish social, political, and economic factors."]
  },
  "grading_directions": {
    "tag": "ReplaceList",
    "contents": ["Grade only the strength of the causal argument."]
  }
}
```

Allowed tags are `AppendList` and `ReplaceList`. Both `tag` and `contents` are
required. `AppendList` with `contents: []` adds nothing; `ReplaceList` with
`contents: []` clears the inherited list. Subsequent descendant layers can
append to the replacement normally. Plain arrays are not accepted in layers.

Replacement is independent for each field. Replacing `grading_directions` does
not remove general `instructions`. Removing an individual inherited list item
is out of scope; replace the list with the desired contents instead.

## Rubrics

Every supplied rubric uses an explicit merge or replacement operation:

```json
{
  "rubric": {
    "tag": "MergeRubric",
    "contents": {
      "clarity": {"weight": 2, "description": "The argument is easy to follow."},
      "evidence": {"weight": 3, "description": "Claims have relevant support."}
    }
  }
}
```

A child's criterion definition replaces the entire parent definition with the
same name. Criteria absent from the child remain inherited. This avoids silently
combining a new criterion description with an old weight. Each definition must
include a finite, nonnegative `weight`; `description` is optional text or null.

To replace the whole rubric, use `ReplaceRubric`:

```json
{
  "rubric": {
    "tag": "ReplaceRubric",
    "contents": {
      "argumentation": {"weight": 1, "description": "Builds a defensible thesis."}
    }
  }
}
```

`ReplaceRubric` with `contents: {}` clears the rubric. Both `tag` and `contents`
are required. Criterion names live inside `contents`, so no criterion names are
reserved for operation fields. Direct rubric maps are not accepted in layers.
Individual criterion deletion is out of scope; use replacement.

Weights are relative and need not sum to one. At grading time, normalize by the
sum of effective weights. Rubric-based grading requires at least one criterion
with positive weight. An empty or all-zero rubric can be inspected and used for
non-grading operations, but blocks rubric-based grading.

## Worked example

Workspace root (`context.json`):

```json
{
  "audience": {
    "tag": "SetScalar",
    "contents": "student"
  },
  "model": {
    "tag": "SetScalar",
    "contents": "local-model-a"
  },
  "tags": {
    "tag": "AppendList",
    "contents": [
      "writing"
    ]
  },
  "instructions": {
    "tag": "AppendList",
    "contents": [
      "Use clear prose."
    ]
  },
  "grading_directions": {
    "tag": "AppendList",
    "contents": [
      "Assess the structure."
    ]
  },
  "rubric": {
    "tag": "MergeRubric",
    "contents": {
      "clarity": {
        "weight": 1,
        "description": "Easy to follow."
      },
      "evidence": {
        "weight": 1,
        "description": "Supports claims."
      }
    }
  }
}
```

`History/context.json`:

```json
{
  "audience": {
    "tag": "SetScalar",
    "contents": "advanced-high-school"
  },
  "tags": {
    "tag": "AppendList",
    "contents": [
      "history",
      "writing"
    ]
  },
  "instructions": {
    "tag": "AppendList",
    "contents": [
      "Prioritize historical accuracy."
    ]
  },
  "rubric": {
    "tag": "MergeRubric",
    "contents": {
      "evidence": {
        "weight": 2,
        "description": "Uses relevant historical sources."
      }
    }
  }
}
```

`History/French-Revolution/context.json`:

```json
{
  "model": {
    "tag": "SetScalar",
    "contents": "local-model-b"
  },
  "tags": {
    "tag": "AppendList",
    "contents": [
      "causes"
    ]
  },
  "grading_directions": {
    "tag": "ReplaceList",
    "contents": [
      "Evaluate causal reasoning."
    ]
  }
}
```

Any essay directly in that final directory receives the following effective
values, illustrated as JSON but held in memory:

```json
{
  "title": null,
  "audience": "advanced-high-school",
  "model": "local-model-b",
  "tags": [
    "writing",
    "history",
    "causes"
  ],
  "instructions": [
    "Use clear prose.",
    "Prioritize historical accuracy."
  ],
  "grading_directions": [
    "Evaluate causal reasoning."
  ],
  "rubric": {
    "clarity": {
      "weight": 1,
      "description": "Easy to follow."
    },
    "evidence": {
      "weight": 2,
      "description": "Uses relevant historical sources."
    }
  }
}
```

## Validation and failures

Reject malformed JSON, duplicate object keys, unknown fields, wrong value types,
unknown operation tags, incomplete operation objects, unexpected operation
payloads, and invalid criterion definitions.
Validate every present layer even if a descendant would replace its values; an
override must not hide a broken ancestor configuration.

Unreadable files and filesystem failures are errors, not missing context. Resolve
only validated account and workspace-relative paths. Reject context resolution
through symbolic links, including ancestor directories and context files, so
inheritance cannot cross workspace boundaries.

Context errors include a safe message and workspace-relative file/field details
when known. Rejected paths and raw OS/parser messages are omitted. Source
line/column coordinates are not currently emitted. For example:

```json
{
  "error": {
    "code": "INVALID_CONTEXT",
    "message": "Rubric weight must be a finite, nonnegative number.",
    "details": {
      "path": "History/context.json",
      "field": "rubric.contents.evidence.weight"
    }
  }
}
```

The UI currently displays error messages; file/field details are available in
the HTTP response but are not rendered by the panel (post-MVP L09). The mock
grading button requires a successful context resolution for the current account
and essay; loading and errors disable it. Future provider handlers
must independently validate context before calling a provider (E06/E08).
Writing, loading, and saving essays do not depend on context resolution.
See [Context error handling](CONTEXT_ERRORS.md) for the implemented error contract.

## LLM behavior

Provider scope (clarified 2026-10-27): support any provider implementing the
required OpenAI-compatible API, using a configurable provider base URL and API
key. OpenAI hosting is not required. Provider connection settings belong to the
backend environment, not inherited context or browser requests. Proposed names
are `OPENAI_BASE_URL` and `OPENAI_API_KEY`; these are planned E06 settings, not
implemented configuration. Model IDs are interpreted by the configured provider.
Compatibility is operation-specific: unsupported endpoints or capabilities must
produce actionable errors rather than assuming all providers support the same
API features. Send essay text and relevant context only when an AI action is
requested; local editing and saving remain independent of provider access.

- Use the effective `model`; when unset, fall back to the account's preferred
  model. If neither is set, block the request with an actionable error.
- Apply general `instructions` and `audience` to all essay LLM operations.
- Apply `grading_directions` and the effective rubric to grading operations.
- Treat `title` and `tags` as labeled metadata rather than executable directions.
- Keep essay text separate from configuration guidance in request construction.
- Resolve context in the backend; never trust a client-supplied effective context.

Provider-specific prompt formatting is a separate implementation concern. Later
context edits do not change an in-flight generation or grading request.

## Backend and UI integration

The implemented base is
`/api/v1/accounts/:accountId/workspace/context`. The account is selected by the
URL, without an `X-Account-Id` header. Paths use forward slashes, are relative to
that account's workspace, and should be URL-encoded in query parameters.

| Method and suffix | Input | Success |
| --- | --- | --- |
| GET `?path=History/context.json` | Existing folder's layer path | 200, a `ContextLayer` containing saved operations |
| GET `/effective?path=History/essay.md` | Existing markdown essay path | 200, an `EffectiveContext` containing resolved values |
| POST | JSON `{"path":"History/context.json","contextLayer":{...}}` | 201, the persisted `ContextLayer` |
| PUT | Same body as POST | 200, the persisted `ContextLayer` |
| DELETE | JSON `{"path":"History/context.json"}` | 204, no response body |

For example, POST or PUT accepts:

```json
{
  "path": "History/context.json",
  "contextLayer": {
    "audience": {"tag": "SetScalar", "contents": "Students"},
    "instructions": {"tag": "AppendList", "contents": ["Use sources."]}
  }
}
```

POST requires an absent layer; PUT requires an existing layer and can repair
malformed stored JSON. Parent directories must exist. No filesystem root is
accepted in the body. POST/PUT accept only `path` and `contextLayer`; DELETE
accepts only `path`. Writes are validated and persisted before success is returned.

A layer response contains the saved operation objects, with unset fields encoded
as `null`. Effective context is returned directly, without an enclosing wrapper:

```json
{
  "title": null,
  "audience": "Students",
  "model": null,
  "tags": [],
  "instructions": ["Use sources."],
  "grading_directions": [],
  "rubric": {}
}
```

A missing layer GET returns 404; missing layers during effective resolution are
skipped, and no layers yields the default effective context. Invalid paths
return 400, symlinks 403, missing resources 404, create collisions 409, invalid
context 422, and handled I/O failures 500. Error details are documented in
[CONTEXT_ERRORS.md](CONTEXT_ERRORS.md).

The effective response does not include contributing-file paths or field
provenance. Ordered contributing-file output and its tests are stretch task L07,
deferred by user decision on 2026-10-26; per-field provenance remains optional
under L01. Neither is required for E04.

The Context tab already provides folder-layer editing, ancestor scope selection,
inherited list previews, create/update/delete, and an effective essay preview.
The preview loads on essay selection and refreshes after context mutations.
`Reload` reloads the layer and inherited lists; `Retry preview` retries a failed
effective-context request. `Refresh preview` rereads saved effective context
without discarding unsaved layer edits. Grading is gated on successful resolution
for the current account/essay, including while the Context panel is collapsed.
Late responses from old selections are ignored. Context errors leave essay
editing/saving usable; retry after repair restores grading eligibility. Error
messages are displayed, but file/field display (L09) and in-app repair of malformed
layers (L08) remain post-MVP.

Each future LLM request must resolve context again and hold one snapshot for
that operation, independently of any frontend preview. Provider calls are not
implemented yet.

## Implementation status

Implemented: separate `ContextLayer`/`EffectiveContext` types; strict JSON layer
loading; ordered inheritance; account-scoped context reads and mutations;
structured context errors; folder-layer editor and effective preview; migrated
JSON sample fixtures. Readiness returns default sample context without loading
user context, so malformed configuration does not fail readiness.

Sample YAML and shorthand layers have been migrated to operation-based JSON.
The resolver does not support those older source formats. Missing layer fields
decode to `Nothing`; resolved collection defaults are assigned by the resolver.

Pending: E05 UI refresh/gating behavior and E06/E08 provider enforcement and
grading validation/normalization. Contributing paths are stretch scope L07;
caching/file watching and per-field provenance remain optional.

## Acceptance checks

These include implemented resolver checks and planned provider/UI requirements;
provider-related checks are not claims of completed functionality.

- Root-only, nested, missing-file, and empty-object cases resolve predictably.
- Nearest scalar operations win; omission and top-level field null inherit;
  `ClearScalar` clears and `SetScalar` sets.
- Empty files, non-object documents, shorthand values, unknown fields/tags,
  duplicate keys, missing payloads, and unexpected payloads are rejected.
- Generic encoding and decoding round-trip valid layers, including clear and
  replacement operations, using the documented JSON representation.
- Lists append in order; replace and clear work independently at every depth.
- Tags deduplicate deterministically; instruction duplicates remain intact.
- Named rubric overrides preserve unrelated criteria; whole-rubric replacement
  and clearing work; grading checks and weight normalization are correct.
- A broken ancestor blocks LLM actions even when a child replaces that field.
- Invalid paths, symbolic links, and cross-account escapes are rejected.
- Changes to a parent file affect the next resolution without writing an artifact.
- Editing and saving remain usable when context resolution fails.
- LLM handlers make no provider call on invalid context and hold one effective
  context for the duration of each request.
