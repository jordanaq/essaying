# Grade provider smoke request

This original sample compares Hume and Kierkegaard on religion. It has a saved
assignment, a draft with room for improvement, and four weighted rubric criteria.
There is no predetermined correct grade. The sample selects `gpt-6.1-sol`.

`BuildGradeRequest.hs` uses the actual context resolver, essay loader, and
`buildGradeRequestBody`. It writes the exact JSON body the grading worker would
send, including the current grading task and rubric-specific response schema.
It never loads provider settings or credentials and makes no network requests.
It does not execute the HTTP handler, provider transport, or grade decoder.

Run from the repository root; these commands also work in Fish:

```fish
nix --accept-flake-config develop -c bash -c 'cd backend && cabal exec --offline -- runghc -isrc examples/grade-smoke/BuildGradeRequest.hs /tmp/essaying-grade-smoke'
jq . /tmp/essaying-grade-smoke/request.json
jq -r '.messages[1].content | fromjson' /tmp/essaying-grade-smoke/request.json
```

After changing sample files or production builders, rerun the generator. Generated
files are outside the repository and do not include credentials. `saved-essay.json`
is diagnostic output; the provider input includes only context, assignment, and
draft, omitting the essay's storage path and explorer title.

Use an existing exported key, or load your own key file in Fish (replace the
placeholder path with the actual path; do not add the key to source files):

```fish
set -gx OPENAI_BASE_URL https://api.openai.com/v1
set -gx OPENAI_API_KEY (string trim < /tmp/YOUR_KEY_FILE)
```

Send the request yourself:

```fish
set provider_base_url (string trim --right --chars=/ -- $OPENAI_BASE_URL)
curl --fail-with-body --silent --show-error \
  --connect-timeout 10 --max-time 120 \
  --request POST \
  --header "Authorization: Bearer $OPENAI_API_KEY" \
  --header 'Content-Type: application/json' \
  --data-binary @/tmp/essaying-grade-smoke/request.json \
  --output /tmp/essaying-grade-smoke/response.json \
  --write-out '\nHTTP %{http_code}\n' \
  "$provider_base_url/chat/completions"
```

The request body is identical to the builder output. Curl's timeout flags are
manual test settings, rather than an exact reproduction of http-client's timeout
behavior. Curl does not follow redirects unless explicitly requested.

Show the parsed provider grade after a normal completion:

```fish
jq -e '.choices[0] | select(.finish_reason == "stop") | .message.content | fromjson' /tmp/essaying-grade-smoke/response.json
```

Expect overall `feedback` and a `criteria` object containing `argument`,
`comparison`, `evidence`, and `interpretation`, each with a score and feedback.
The provider returns no overall score or weights; the application calculates
those later. On an HTTP error, inspect the saved response with `jq .` instead.

For a different compatible provider, change its URL/key and the model in the
sample context, then regenerate the JSON. Model IDs and structured-output support
are provider-specific.
