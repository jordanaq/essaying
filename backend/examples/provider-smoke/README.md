# Prompt provider smoke test

This sample uses `gpt-6.1-sol` and generates an assignment comparing Hume and
Kierkegaard on religion. It uses the existing context resolver and request-body
builder. No application route, provider implementation, or account data changes
are needed. `workspace/Religion/essay.md` is an empty essay marker; assignment
generation does not send a draft.

- `workspace/context.json`: actual operation-based context layer.
- `extra-instructions.txt`: guidance for this generation only.
- `BuildRequest.hs`: resolves the layer and writes a provider request.
- Generated `effective-context.json`: resolved values, not a saved context layer.
- Generated `request.json`: the complete Chat Completions request body.

Run from the repository root (requires Nix, curl, and jq):

```bash
nix --accept-flake-config develop -c bash -c 'cd backend && cabal exec --offline -- runghc -isrc examples/provider-smoke/BuildRequest.hs /tmp/essaying-provider-smoke'
jq . /tmp/essaying-provider-smoke/request.json
jq -r '.messages[1].content | fromjson' /tmp/essaying-provider-smoke/request.json
```

The first command only generates JSON; it makes no network calls. After changing
the sample context, instructions, or task constant, run it again.

In Bash, configure OpenAI and enter your key without putting it into a file:

```bash
export OPENAI_BASE_URL='https://api.openai.com/v1'
read -rsp 'OpenAI API key: ' OPENAI_API_KEY
printf '\n'
export OPENAI_API_KEY
```

Send one paid API request:

```bash
curl --fail-with-body --silent --show-error \
  --connect-timeout 10 --max-time 120 \
  --request POST \
  --header "Authorization: Bearer ${OPENAI_API_KEY:?Set OPENAI_API_KEY}" \
  --header 'Content-Type: application/json' \
  --data-binary @/tmp/essaying-provider-smoke/request.json \
  --output /tmp/essaying-provider-smoke/response.json \
  --write-out '\nHTTP %{http_code}\n' \
  "${OPENAI_BASE_URL%/}/chat/completions"
```

Show the generated assignment only if the first choice finished normally:

```bash
jq -er '.choices[0] | select(.finish_reason == "stop") | .message.content | select(type == "string" and length > 0)' /tmp/essaying-provider-smoke/response.json
```

Inspect the full response if that fails:

```bash
jq . /tmp/essaying-provider-smoke/response.json
```

Expect HTTP 200 and a complete assignment, not an essay or clarification question.
401 indicates an authentication problem; 404 may indicate unavailable model or
endpoint; 429 may indicate a rate or quota limit. A `length` finish reason means
the output was incomplete. Model access is specific to your provider/account.

For another provider, change the base URL and key and select its exact accessible
model ID in `workspace/context.json`, then regenerate the request. Do not assume
Nous Portal uses OpenAI's model IDs. This sample targets the Chat Completions
wire format; it does not validate the unfinished application integration.

Run the existing automated provider tests separately:

```bash
nix --accept-flake-config develop -c bash -c 'cd backend && cabal test haskell-essaying-test --offline --test-options=--provider --test-show-details=direct'
```
