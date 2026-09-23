# Agent example catalog

Prepare one example into a NEW directory outside the bundle:

```powershell
node .\tools\prepare-workspace.mjs --list
node .\tools\prepare-workspace.mjs --example java-tool-agent --destination ..\my-java-agent
```

| Example ID | Language | Runtime | What it demonstrates |
| --- | --- | --- | --- |
| `dotnet-tool-agent` | C# | .NET 8 | Small Agent Framework console agent and offline SDK test |
| `dotnet-agent365-lab` | C# | .NET 8 | Extended opt-in Teams, Work IQ, telemetry, agent mailbox and Purview patterns |
| `nodejs-tool-agent` | JavaScript | Node.js 24+ | OpenAI Agents SDK tools and an in-memory model/tool/model turn |
| `python-teammate` | Python | Python 3.12 | Authenticated aiohttp host and pinned Agent Framework/SDK contracts |
| `java-tool-agent` | Java | JDK 21, Maven 3.9+ | Gson/HttpClient console model/tool loop with JUnit/loopback tests |
| `go-tool-agent` | Go | Go 1.24+ | Standard-library HTTP/JSON model/tool loop with Go tests |
| `rust-tool-agent` | Rust | Rust/Cargo 1.88+ and linker | Native-TLS/serde_json model/tool loop with Cargo tests |

`blank` is also available for a kit-only workspace.

## New Java, Go and Rust examples

Each has `count_words` and `reverse_text`, an offline mock mode, and a live
OpenAI-compatible model/tool loop. The tool loop is real application logic; the
mock model makes it deterministic without sending traffic to a provider.
Tests include Unicode, error handling, provider-key separation, turn limits and
HTTP contract checks against loopback.

Run from the selected prepared workspace:

| Language | Tests | Single test | Offline demo |
| --- | --- | --- | --- |
| Java | `mvn test` | `mvn "-Dtest=AgentTest#wordCount" test` | `mvn exec:java "-Dexec.args=--mock Hello Agent 365"` |
| Go | `go test` | `go test -run TestWordCount` | `go run . --mock "Hello Agent 365"` |
| Rust | `cargo test --locked` | `cargo test --locked word_count` | `cargo run --locked -- --mock "Hello Agent 365"` |

Live mode is explicitly opt-in and potentially billable. These three examples read
process environment variables, not `.env` automatically. Set `MODEL_PROVIDER` to
`mistral`, `openai`, or `gemini`, and only that provider's API key/model variables.
Use synthetic prompts until provider access and governance are configured.

## Support boundaries

The new console examples are not pre-hosted Teams agents, do not contain tenant
identities, and do not automatically export telemetry or enforce Purview.
Java has kit-specific integration guidance, but its custom HttpClient loop is not
LangChain4j and must not be silently replaced. Go and Rust are manual-integration
stacks for the bundled kit: an unknown-language validator returning `ok` is not
evidence of successful onboarding.

Use the extended .NET example when you want the widest executable Agent 365
integration coverage in this revision. Preserve each chosen framework and verify
authentication, tools, delivery and policy separately.
