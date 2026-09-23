# Rust console tool agent

Requires Rust/Cargo 1.88 or newer and a working platform linker. `Cargo.lock` is
included. HTTPS uses native TLS with normal certificate validation (SChannel on
Windows; OpenSSL development libraries/pkg-config may be needed on Linux).

From the prepared workspace:

```powershell
cargo test --locked
cargo test --locked word_count
cargo run --locked -- --mock "Hello Agent 365"
```

The `count_words` and `reverse_text` tools run through the same model/tool/model
loop used in live mode. Mock mode is deterministic and reports `aiInference: false`.
Tests use a fake model and loopback HTTP only; restoring crates is an online step.

## Opt-in live inference

Export process environment variables; the `.env.example` file is documentation,
not an automatically loaded configuration:

```powershell
$env:MODEL_PROVIDER = "mistral"
$env:MISTRAL_API_KEY = "<your key, kept local>"
$env:MISTRAL_MODEL = "ministral-3b-2512"
cargo run --locked -- --live "Count the words in Hello Agent 365"
```

Alternatives are `openai` with `OPENAI_API_KEY`/`OPENAI_MODEL` and `gemini` with
`GEMINI_API_KEY`/`GEMINI_MODEL`. No provider's key is used for another provider.
Live inference sends content externally and may incur charges.

The loop permits six model responses and sixteen tool calls per response.
Prompts are capped at 4,000 Unicode characters, tool text at 100,000 UTF-8 bytes,
and HTTP responses at 2 MiB. HTTP redirects are disabled and requests have a
15-second timeout. Failure never silently becomes a mock success.

## Agent 365 boundary

This is not a Teams host or a preconfigured Agent 365 identity. The bundled
onboarding validators do not implement Rust integration. Use reviewed manual
Agent ID/HTTP/OTLP integration and validate each tenant capability independently.
An unknown-language static validator passing is not proof that Rust is onboarded.
Keep the Rust architecture; do not silently regenerate it as another language.

If you export telemetry with the blueprint's client id and secret, the blueprint needs the
`Agent365.Observability.OtelWrite` application role, which some tenants show as "maven-prod".
Ask your CLI: *Grant observability access to this agent.* and include the blueprint.
