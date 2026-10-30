// Curated GPT-6.1, GPT-6 and GPT-5.6 choices from the OpenAI /v1/models
// snapshot fetched 2026-10-30. Only gpt-6.1-sol has been smoke-tested in this app.
// Automatic endpoint-specific discovery is tracked as L13.
export const providerModels: string[] = [
  "gpt-6.1-sol",
  "gpt-6.1-terra",
  "gpt-6-astra",
  "gpt-6-sol",
  "gpt-6-luna",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna"
];

export const defaultModel = "gpt-6.1-sol";
