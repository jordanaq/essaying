# Recorded provider response

`gpt-6.1-sol-prompt-options.response.json` is the unchanged JSON response body
from the user's successful OpenAI Chat Completions smoke test, captured for this
test on 2026-10-29. The request asked for three distinct assignments comparing
Hume and Kierkegaard on religion, using the structured `prompts` array format.

`gpt-6.1-sol-prompt-options.expected.json` contains those three Markdown strings,
extracted separately when the fixture was created. The test compares the whole
decoded list against this snapshot, checking content and order, not just count.

Only the response body was copied. No request headers, credentials, or
environment values are included. Tests read these local fixtures and make no
live provider requests; they do not depend on the original files in `/tmp`.

## Grading smoke response

`gpt-6.1-sol-grade.response.json` is the unchanged response body from the user's
successful grading request captured on 2026-10-30. It completed with `stop` and
returned the four expected criterion assessments for the Hume/Kierkegaard sample.

`gpt-6.1-sol-grade.request.json` is the exact credential-free request body generated
by `examples/grade-smoke/BuildGradeRequest.hs` for that call. `grade-workspace/`
freezes the original context layer, assignment, and draft so later sample edits
cannot silently change the test inputs. The endpoint test compares its entire
outgoing provider request against the recorded request, including the task,
resolved context, saved text, model, and dynamically generated schema. Intentional
changes to that request contract require reviewing/updating this snapshot.

`gpt-6.1-sol-grade.expected.json` preserves the response's scores and feedback,
adding independently specified normalized weights (argument 0.2, comparison 0.3,
evidence 0.2, interpretation 0.3) and an expected overall score of 79.3. The scores
are respectively 81, 85, 65, and 82. This expected result was not produced by the
normalization function under test.

The grading endpoint test calls the real Servant app and production grading
adapter, using an isolated temporary account/workspace and a loopback provider
with the literal fake key `test-key`. It checks the final normalized response and
that grading leaves saved files unchanged. Temporary environment changes and
servers are cleaned up. No live API or `/tmp` capture files are needed for tests.
The fixture demonstrates compatibility and preserves one real assessment; it
does not establish agreement with a human grader.

## Failure and deadline checks

`GradeFailures` exercises the real application routing and grading handler with
temporary sample workspaces and a local fake provider. The regular suite covers
blank drafts, invalid rubrics/context, absent models/accounts/drafts, unsafe
paths, unreadable or symlinked assignment files, missing/invalid provider setup,
upstream HTTP failures, and invalid provider grades. Rejected inputs must make
zero provider requests; public errors must omit private diagnostics and keys.
A missing assignment is allowed and has a successful regression case.

Run all fast grading checks from `backend/` inside the development environment:

```sh
cabal test haskell-essaying-test --offline --test-options=--grade --test-show-details=failures
```

The production deadline is fixed at 120 seconds. Its slow regression test is
explicitly separate from the default suite so normal runs stay fast:

```sh
cabal test haskell-essaying-test --offline --test-options=--grade-deadline --test-show-details=direct
```

This test calls the real `generateGrade` wrapper against a loopback provider that
sends a whitespace heartbeat every second. That prevents the 60-second idle
timeout from masking the overall deadline. It requires the specific grading
`ProviderTimedOut` error at roughly 120 seconds, with one provider request and no retries.
A 135-second test watchdog bounds a regression. No production timeout setting or
backend implementation is changed to make the test pass.
