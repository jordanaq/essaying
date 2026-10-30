# Context error handling

Status: implemented backend contract, reviewed 2026-10-30. This describes handled
context API errors and Servant JSON/query decoding failures. It does not promise
this envelope for unrelated routes or framework errors such as unsupported media
types. See [CONTEXT_DESIGN.md](CONTEXT_DESIGN.md#backend-and-ui-integration) for
routes, write bodies, and success responses.

Errors use `Content-Type: application/json` and the existing envelope:

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

Clients can branch on `code`. `details` is always an object, including `{}` when
no details are known. Available members are:

| Member | Current behavior |
| --- | --- |
| `path` | Safe workspace-relative file or failing component; omitted for rejected paths and the workspace root. Never an absolute root or symlink destination. |
| `field` | Location within the context layer, when known, such as `instructions.contents[1]`. Punctuation in keys uses JSON brackets: `rubric.contents["use.of.sources"].weight`. |
| `parameter` | `path` for invalid-path errors; `contextLayer` for submitted-layer validation errors. Generic request-envelope failures currently have empty details. |

Fields are relative to the layer, without a `contextLayer` prefix. Syntax and
duplicate-key errors have no reliable field location. Line/column coordinates
are not currently emitted.

| HTTP | Code | Trigger and current message |
| --- | --- | --- |
| 400 | `INVALID_REQUEST` | Malformed request JSON, missing required query/body members, or invalid envelope. “Provide a valid request with the required path and context layer.” |
| 400 | `INVALID_ACCOUNT_ID` | Unsafe account ID. “Select a valid account.” |
| 400 | `INVALID_CONTEXT_PATH` | Unsafe path, wrong target filename, or missing parent directory for a layer operation. “Use an existing directory and a workspace-relative context.json path.” |
| 400 | `INVALID_ESSAY_PATH` | Unsafe effective-context target, including the workspace root or a nested essay. The current message still says “Use a workspace-relative markdown essay path.”; supply an essay directory such as `History/Causes`, without `/essay.md`. |
| 403 | `CONTEXT_SYMBOLIC_LINK` | A checked essay/context path component or workspace root is a symlink. “Context paths must not pass through symbolic links.” |
| 404 | `ACCOUNT_NOT_FOUND` | Missing or invalid selected account profile. “Select an existing account.” |
| 404 | `ESSAY_NOT_FOUND` | No existing essay at a valid path. “Essay does not exist.” |
| 404 | `CONTEXT_NOT_FOUND` | Layer GET/PUT/DELETE targets an absent file. “Context does not exist.” |
| 409 | `CONTEXT_EXISTS` | POST targets an existing layer, including malformed stored JSON. “Context already exists.” |
| 422 | `INVALID_CONTEXT` | Stored or submitted layer fails validation. An allowlisted validation message is returned; other decoder failures use “Context field has an invalid type, shape, or value.” |
| 500 | `CONTEXT_IO_ERROR` | Handled filesystem/account access failure. “Unable to access the context file.”, “Unable to resolve essay context.”, or “Unable to access the selected account.” |

Malformed stored JSON, duplicate keys, and trailing input use 422 with
“Context must contain one valid JSON document with unique object keys.”
Syntactically malformed request JSON uses 400. POST/PUT decode the envelope into
`ContextWriteRequest`, then validate its raw `contextLayer` in the handler so an
invalid layer returns 422. Stored files use the strict duplicate-checking decoder;
this does not imply duplicate-key rejection by the standard request JSON decoder.

The envelope is decoded before the handler resolves the selected account.
POST/PUT validate the submitted layer before checking its target; callers should
correct the first returned error rather than rely on precedence for multiple
invalid inputs. With a valid submitted layer, an existing POST target returns
409 even if its stored JSON is malformed. PUT can repair malformed stored JSON.
Mutations acknowledge success only after persistence succeeds.

Missing layers during effective resolution are skipped. If all are absent,
resolution succeeds with defaults. Existing invalid or unreadable layers are
errors. Resolution checks layers from root through the essay directory and stops at the first
broken one, even if a child would replace its values. No partial effective
context is returned.

For example, an absolute or traversing layer path submitted with an otherwise
valid request returns:

```json
{
  "error": {
    "code": "INVALID_CONTEXT_PATH",
    "message": "Use an existing directory and a workspace-relative context.json path.",
    "details": {"parameter": "path"}
  }
}
```

The response omits the rejected input. Symlink errors identify only the link's
workspace-relative location. Public messages omit OS exceptions, raw decoder
excerpts, and context values. The context loader logs file labels without raw
parser excerpts. Complete account/filesystem-boundary and concurrency hardening
remains E11.

## Frontend behavior and remaining work

The Context panel currently displays `error.message`. File/field details are
available in the Network response but are not rendered by the panel. Failed
effective previews have `Retry preview`; layer/inherited-list reads have `Reload`.
`Refresh preview` rereads saved effective context without discarding layer edits.
The mock Grade action requires successful resolution for the current account and
essay; loading and failures disable it, and retry after repair restores it.
Selection changes invalidate eligibility and late responses are ignored.
Collapsing the Context panel preserves resolution state. Rendering file/field
details (L09) and in-app malformed-layer repair (L08) remain post-MVP.

Draft and assignment loading/editing/saving remain independent of context
resolution. Backend prompt and grading handlers independently resolve and
validate context before provider calls. The frontend Grade action still uses
mock feedback; real frontend AI integration remains E07–E09.

Ordered contributing-file output and its tests are deferred to stretch task L07;
they are not required to finish E04. Per-field provenance remains L01.

## Verification

`backend/test/ContextErrors.hs` has eight HTTP regression cases against the actual
Servant application. They cover stored/submitted field and list-index locations,
punctuation in criterion names, malformed envelopes and encoded routes, rejected
paths, missing resources, absent layers, malformed/duplicate/trailing documents,
symlink/I/O redaction, create collisions, malformed-layer repair, and successful
essay saving with a broken ancestor.

Historical context implementation verification passed 64 backend cases and
four browser scenarios (`3194ad2`). Subsequent recorded verification passed
232 regular backend cases, 16 frontend component cases, a typechecked frontend
build, and 35 browser scenarios. These are prior passing runs; this documentation
update does not rerun application tests or claim complete E11 hardening.
