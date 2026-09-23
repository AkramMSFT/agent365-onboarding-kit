# Java console tool agent

Requires JDK 21 and Maven 3.9+. Gson and test/build plugins are explicitly versioned
in `pom.xml`. This is a small Java HttpClient agent, not a LangChain4j application.
Its tools are `count_words` and `reverse_text`.

From the prepared workspace:

```powershell
mvn test
mvn "-Dtest=AgentTest#wordCount" test
mvn exec:java "-Dexec.args=--mock Hello Agent 365"
```

Mock mode executes the actual model/tool/model loop with an in-memory model and
reports `aiInference: false`. Tests also exercise the real HTTP adapter against
loopback. Dependency restore is online; tests make no external model/tenant calls.

## Opt-in live inference

The program reads process environment variables. `.env.example` documents them
but is not automatically loaded:

```powershell
$env:MODEL_PROVIDER = "mistral"
$env:MISTRAL_API_KEY = "<your key, kept local>"
$env:MISTRAL_MODEL = "ministral-3b-2512"
mvn exec:java "-Dexec.args=--live Count the words in Hello Agent 365"
```

Select `openai` with `OPENAI_API_KEY`/`OPENAI_MODEL` or `gemini` with
`GEMINI_API_KEY`/`GEMINI_MODEL` instead if desired. Live calls are separately
authorized, provider-billed inference; keys/models are provider-specific.

The loop is capped at six model responses and sixteen tool calls per response.
Prompts are capped at 4,000 Unicode characters, tool text at 100,000 UTF-8 bytes,
and HTTP bodies at 2 MiB. Requests have a fifteen-second deadline, redirects are
disabled, and model errors are reported rather than replaced with mock results.

## Agent 365 boundary

The kit's `add-java-agent` guidance describes Java hosting and telemetry, but this
console starter is not already hosted or registered. Its custom model loop does
not establish a LangChain4j contract. Adapt the hosting/authentication seam
deliberately without replacing the agent's framework. Tenant consent, Teams replies,
Work IQ, telemetry delivery and Purview are separate integrations and verifications.

If you export telemetry with the blueprint's client id and secret, the blueprint needs the
`Agent365.Observability.OtelWrite` application role, which some tenants show as "maven-prod".
Ask your CLI: *Grant observability access to this agent.* and include the blueprint.
