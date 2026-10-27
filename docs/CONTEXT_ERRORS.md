# Context error handling draft

Status: contract with an initial backend implementation, 2026-10-20.
This describes the error-handling portion of E04 and extends the existing
`error.code`, `error.message`, and `error.details` response envelope.

All context endpoints return errors as `Content-Type: application/json`.
Clients branch on `code`; messages explain the correction the user can make.
Return the first failure encountered, without partial effective context.

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

`details` is always an object. Its members are optional:

| Member | Meaning |
| --- | --- |
| `path` | Validated workspace-relative source file or failing path component. Never an absolute path or a symlink target. |
| `field` | Location within the context layer; for example, `instructions.contents[1]`. Use bracketed JSON strings for keys containing punctuation, such as `rubric.contents["use.of.sources"].weight`. |
| `line`, `column` | One-based source coordinates, included together only when the decoder supplies reliable positions. |
| `parameter` | Request input to correct, such as `path` or `contextLayer`. |

Omit unknown locations rather than inventing them. Request-envelope fields use
`parameter`; `field` is always relative to the layer, without a `contextLayer`
prefix. Coordinates refer to the decoded document: the context file for disk
errors, or the complete request body for request errors.

| HTTP | Code | Trigger and user-facing message |
| --- | --- | --- |
| 400 | `INVALID_REQUEST` | Malformed request JSON, missing required query/body members, or an invalid request envelope. “Provide a valid request with the required path and context layer.” |
| 400 | `INVALID_CONTEXT_PATH` | Absolute/traversing/empty path, wrong target filename, or missing parent directory for a layer operation. “Use a workspace-relative context.json path in an existing folder.” |
| 400 | `INVALID_ESSAY_PATH` | Unsafe path or non-markdown target for effective context. “Use a workspace-relative markdown essay path.” |
| 403 | `CONTEXT_SYMBOLIC_LINK` | An essay, context file, ancestor, or workspace root is a symbolic link. “Context paths must not pass through symbolic links.” |
| 404 | `ACCOUNT_NOT_FOUND` | The selected account does not exist. “Select an existing account.” |
| 404 | `ESSAY_NOT_FOUND` | A valid essay path has no existing essay file. “The essay no longer exists. Refresh the workspace.” |
| 404 | `CONTEXT_NOT_FOUND` | Layer GET, PUT, or DELETE targets an absent context file. “No context layer exists here. Create one or use inherited settings.” |
| 409 | `CONTEXT_EXISTS` | POST targets an existing context file, including malformed context. “A context layer already exists. Update or remove it.” |
| 422 | `INVALID_CONTEXT` | Stored context or a syntactically valid submitted layer fails context validation. Use a specific, application-owned message and available field location. |
| 500 | `CONTEXT_IO_ERROR` | An unexpected read, write, delete, or filesystem inspection failure. “Unable to access the context file. Check its permissions and try again.” Effective resolution may use “Unable to resolve essay context. Check folder permissions and try again.” |

Missing layers during effective-context resolution contribute nothing and are
successful, including when every layer is absent. An unreadable layer is an
error. Inspect layers from workspace root to essay parent and stop at the first
broken layer, even if a child would replace its values.

For malformed stored JSON, retain `INVALID_CONTEXT`/422 with a message such as
“Context must contain one valid JSON document.” Duplicate keys, unknown fields,
invalid operations, blank values, and rubric validation failures also use 422.
Malformed request-body JSON is instead `INVALID_REQUEST`/400. A valid JSON body
containing an invalid `contextLayer` uses 422; this distinction requires changes
to the current Servant decoding boundary.

Validate the account and request envelope before filesystem access. Validate
path syntax before resolving a target. Then inspect filesystem components and
perform the operation. At an existing POST target, return 409 even if the stored
JSON is malformed. PUT may repair malformed stored context with a valid layer.
Validate submitted layers before writing; acknowledge mutations only after the
filesystem operation succeeds. Existing filesystem race hardening remains E11.

Never echo a rejected path. For example, `/home/user/private/context.json` and
`../other-account/context.json` both produce:

```json
{
  "error": {
    "code": "INVALID_CONTEXT_PATH",
    "message": "Use a workspace-relative context.json path in an existing folder.",
    "details": { "parameter": "path" }
  }
}
```

For paths accepted by syntax validation, report only workspace-relative labels
produced by the resolver. An offending link is labeled by its location inside
the workspace, never by its destination; omit `path` for the workspace root.
Never expose OS exception text, raw parser excerpts, absolute roots, or context
values in public messages. Do not write raw request bodies or context contents
to diagnostic logs.

Preserve structured decoder paths instead of discarding Aeson's path component.
Semantic validation must attach the offending key/index while validating the
value; a generic failure after decoding a whole rubric loses that information.
Only allowlisted application-owned validation messages are returned; other
decoder failures use a fixed type/shape/value message. Never extract public
messages from raw decoder excerpts. Syntax or duplicate-key errors may omit `field`
when the parser cannot identify the location reliably.

Implementation changes belong in the context types/decoder, persistence loader,
handler response mapping, and Servant request decoding/error formatting. Keep
one formatter for the error envelope so framework failures use the same JSON
shape. Preserve existing codes where their meaning already matches this draft.

The UI displays the message with the file/field location and offers retry after
the user fixes the source. Context failures block AI actions while loading,
editing, and saving essays remain available. The backend independently validates
context before provider calls. UI wiring is E05; provider enforcement is E06/E08.

HTTP acceptance coverage should exercise the actual Servant application:

- Invalid/missing query parameters and malformed request bodies return JSON 400.
- Invalid submitted layers return 422 with a field; invalid stored layers name
  their source file, including a broken ancestor overridden by a child.
- A rubric key containing punctuation and a bad list item retain precise fields.
- Absolute paths and traversal are absent from every returned message/detail.
- Symlink failures return 403 with no destination; missing accounts/essays/layers
  return the appropriate 404; an absent effective layer remains successful.
- POST collisions return 409, and PUT can repair malformed stored context.
- Controlled I/O failures return 500 without OS text; failed writes never return
  success. Avoid tests that depend on permission bits when running as root.
- Existing editing/saving operations still succeed with broken context.

Do not mark E04 complete from this draft: contributing-path output and the
implemented, verified diagnostic/error behavior are still required.

Implementation evidence (2026-10-20): ContextDiagnostic preserves Aeson field
paths, context persistence shares the strict decoder, ContextError formats
responses and redacts invalid paths, and Servant formatters handle invalid
request envelopes. POST/PUT use a raw-layer request DTO with the same JSON wire
shape so layer validation can return 422. Context routes also validate account
selection and return structured missing-account errors. Eight new HTTP
regression cases run against the actual Servant application.

Source coordinates remain omitted because this parser does not provide reliable
positions. UI validity wiring, provider enforcement, complete filesystem race
hardening, and contributing-path output retain their separate board scope.
