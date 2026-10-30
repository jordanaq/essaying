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
