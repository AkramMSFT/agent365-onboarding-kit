# Go console tool agent

Requires Go 1.24 or newer. Uses the standard library only. The agent has two
in-process tools: `count_words` and `reverse_text`. Both mock and live modes use
the same bounded model/tool/model loop.

From the prepared workspace:

```powershell
go test
go test -run TestWordCount
go run . --mock "Hello Agent 365"
```

Mock mode counts the supplied text using an in-memory model and reports
`aiInference: false`. Tests use in-memory models and loopback HTTP; no tenant or
external model calls are made.

## Opt-in live inference

Set process environment variables in your terminal; `.env.example` is a reference
and is not automatically loaded by this program:

```powershell
$env:MODEL_PROVIDER = "mistral"
$env:MISTRAL_API_KEY = "<your key, kept local>"
$env:MISTRAL_MODEL = "ministral-3b-2512"
go run . --live "Count the words in Hello Agent 365"
```

Other choices are `openai` with `OPENAI_API_KEY`/`OPENAI_MODEL`, and `gemini` with
`GEMINI_API_KEY`/`GEMINI_MODEL`. Credentials are never reused across providers.
Live inference sends your prompt to the selected provider and may incur charges.
Model availability and quota must be confirmed separately.

The loop permits six model responses and at most sixteen tool calls per response.
Prompts are limited to 4,000 Unicode characters; tool text to 100,000 UTF-8 bytes;
model responses to 2 MiB. HTTP redirects are disabled, requests time out after
15 seconds, and the complete Go run has a 90-second deadline. Errors do not fall
back to mock mode or print credential values.

## Agent 365 boundary

This is a standalone console agent, not a Teams host or an onboarded Agent 365
identity. The bundled onboarding validators do not implement a Go integration.
Use the manual Agent ID/HTTP/OTLP contracts with verified SDK/service documentation;
do not interpret an unknown-language validator's `ok` result as readiness. The kit
is copied alongside the example for reference, not as proof that Go onboarding is
automated. Do not switch this project to another framework silently.
