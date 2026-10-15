# Context inheritance design

Status: draft for review. The inheritance behavior below reflects the agreed
product decisions; JSON syntax, field names, and API details are proposed.

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

## Proposed fields and merge rules

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

Report workspace-relative file path, field path, a useful message, and source
line/column when available. For example:

```json
{
  "error": {
    "code": "INVALID_CONTEXT",
    "message": "Rubric weight must be nonnegative.",
    "details": {
      "path": "History/context.json",
      "field": "rubric.contents.evidence.weight"
    }
  }
}
```

The UI displays context errors alongside the selected essay and disables LLM
actions. The backend independently enforces the same validation before any
provider call. Writing, loading, and saving essays do not depend on successful
context resolution.

## LLM behavior

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

Proposed read endpoint, following the implemented account-scoped API layout:

`GET /api/v1/accounts/:accountId/workspace/context?path=History/French-Revolution/causes.md`

The path identifies an existing essay; the backend resolves its containing
directory. Return the effective context and an ordered list of contributing
workspace-relative context file paths. Return 400 for invalid paths, 404 for
missing accounts or essays, 422 for invalid context, and a structured server error
for unexpected I/O failures. Do not expose absolute filesystem paths.

The UI loads this endpoint when selecting an essay and can refresh the context
inspection manually. Each LLM request resolves again, so a stale preview cannot
determine the request's behavior. Field-level provenance and an in-app context
editor are deferred; users initially edit source JSON files directly.

## Implementation plan

1. Define separate `ContextLayer` and `EffectiveContext` types in
   `Essaying.Types.Context`, along with the operation types and `RubricCriterion`.
   Register the module in both Cabal component module lists. Parsed layers
   preserve omitted fields, scalar clears, and collection operations; resolved
   values contain no merge directives.
2. Implement generic JSON decoding with strict options and additional validation.
   Add a pure, explicitly ordered `applyLayer parent layer` function. Replace the current ambiguous `Semigroup`
   merge; its scalar and rubric precedence should not define the new contract.
3. Replace the `loadEffectiveContext` stub with account-rooted discovery,
   validation, and resolution returning structured errors.
4. Add the read endpoint and context inspection/error states in the frontend.
   Adapt the ready/sample handler to the new resolver without tying liveness
   checks to a user's context validity.
5. Integrate the resolver into future LLM handlers before provider requests.

Migrate existing sample YAML files to `context.json` and wrap their values in
explicit operations. YAML files and the earlier shorthand forms are not supported
by the new resolver; this is a format migration, not backward compatibility.
Update sample-loading code and fixtures alongside that implementation. Missing
layer fields decode to `Nothing`; effective collection defaults are assigned by
the resolver rather than inferred from generic decoding.

## Acceptance checks

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
