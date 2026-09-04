---
name: add-java-agent
description: >
  Onboards a Java agent to Agent 365. Microsoft ships no Java SDK, so this builds the
  three things the SDKs would otherwise provide: an HTTP host serving /api/messages with
  inbound JWT validation, replies through the Connector API, and a direct OTLP exporter
  for the Agent 365 observability endpoint. Registration, identity, publishing and the
  admin-centre steps are language-agnostic and handled by the standard skills -- use those
  first and this one only for the code. Use when the project is Java (pom.xml or
  build.gradle) and the user says "onboard this Java agent" or "make this Java agent
  reachable in Teams". Kit add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: public HTTPS URL if already hosted"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
---

# Add a Java agent to Agent 365

## What this covers, and what it does not

Agent 365 ships SDKs for Python, Node.js and .NET only. Everything that runs against the
tenant rather than against your code works for Java unchanged:

| Step | Who does it | Java? |
|---|---|---|
| Blueprint, Agent ID, agentic user | `a365-setup` skill, `a365` CLI | yes, unchanged |
| Messaging endpoint registration | `a365 setup blueprint --update-endpoint` | yes, unchanged |
| Publish, upload, activate, instance | `a365 publish` + admin centre | yes, unchanged |
| **HTTP host and inbound auth** | **this skill** | no SDK -- built here |
| **Observability export** | **this skill** | no SDK -- built here |
| Work IQ tools | no Java SDK | out of scope, see Phase 6 |

**Run `a365-setup` first.** This skill writes code against an agent that already has a
blueprint and an identity. If `a365.generated.config.json` does not exist, stop and run
the `a365-setup` skill.

## Phase 0: Confirm the stack

1. **Glob** for `pom.xml` and `build.gradle` / `build.gradle.kts`. Neither means this is not
   a Java project -- stop and route to the normal skills.
2. **Read** `a365.generated.config.json`. Take `agentBlueprintId`, `agenticAppId` and the
   tenant id. If the file is missing, stop as above.
3. Note the build tool -- Maven and Gradle dependency snippets both appear in the reference.

**TaskCreate** -- "Add Agent 365 hosting and observability to the Java agent"

## Phase 1: Dependencies

Add a JSON mapper and a JWT library. Read
`.a365-kit/addons/add-java-agent/references/java-endpoint.md` for the exact Maven and
Gradle blocks. Java 17 or later is required -- the reference uses `java.net.http.HttpClient`
and records.

## Phase 2: The host

Write the four classes from `java-endpoint.md`:

| Class | Responsibility |
|---|---|
| `TokenProvider` | client-credentials tokens for the blueprint app, cached, refreshed early |
| `InboundTokenValidator` | validates the bearer token on every inbound activity |
| `ConnectorClient` | posts the reply back to the channel's `serviceUrl` |
| `AgentHost` | serves `/api/health` and `/api/messages`, calls your agent |

Replace `AgentHost.answer(String)` with the call into the user's existing agent code --
that method is the only seam this skill expects them to fill in.

**Inbound validation is not optional.** The endpoint is public the moment it is tunnelled.
Without the validator any request that reaches the URL is treated as a real turn from Teams.

## Phase 3: Prove it locally

```bash
mvn compile
mvn dependency:build-classpath -Dmdep.outputFile=cp.txt
java -cp "target/classes;$(cat cp.txt)" com.example.a365.AgentHost
```

Then, in another shell:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3978/api/health
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:3978/api/messages \
  -H "content-type: application/json" -d '{"type":"message","text":"hi"}'
```

Expect **200** then **401**. A 200 on the second call means the validator is not wired --
fix that before exposing the endpoint.

## Phase 4: Register the endpoint

Expose the port with a dev tunnel or a cloud host, then hand the URL to the standard
`add-messaging-endpoint` flow, or run it directly:

```bash
a365 setup blueprint --update-endpoint https://<host>/api/messages --m365
```

`--m365` is required or Teams routing is silently skipped. Confirm
`a365.generated.config.json` then shows your URL under `messagingEndpoint` and
`"completed": true`.

`a365 setup permissions bot` needs the Windows broker -- hand it to the user to run in
their own terminal.

## Phase 5: Observability

Write `ObservabilityExporter` from
`.a365-kit/addons/add-java-agent/references/java-observability.md` and export one span per
turn. Set `ENABLE_A365_OBSERVABILITY_EXPORTER=true` -- **set it, do not preserve a `false`
written by `a365 setup`**, or the agent traces every turn and exports none of it.

Tell the user the exporter is on and that the value is read at startup.

## Phase 6: Tools -- what is possible

Work IQ tools have no Java SDK. The servers are MCP over HTTP behind Entra, so a Java agent
can call them with an MCP client and a per-audience token, but nothing here generates that.
State this plainly rather than implying tools work.

External MCP servers are reachable from Java the same as from any language, and are
governed by neither Entra nor Agent 365 -- pair them with DLP.

## Phase 7: Validate

```bash
node .a365-kit/hooks/stop/validate-add-java-agent.js
```

Fix anything it reports, then re-run until clean.

**TaskUpdate** -- Mark complete, and tell the user which of Phases 1-6 were applied.
