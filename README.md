# Agent 365 Onboarding Kit

Onboard an existing AI agent to **Microsoft Agent 365** from whichever coding CLI you already use.

Microsoft publishes [`agent365-skills`](https://github.com/microsoft/agent365-skills) as a Claude Code plugin. This kit repackages those skills as a folder you drop into your agent's repository, so any skill-aware CLI picks them up with no install step.

```
download  ->  extract into your agent project  ->  run the launcher  ->  "Onboard this agent to Agent 365."
```

---

## Contents

- [What it does](#what-it-does)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [What you can ask for](#what-you-can-ask-for)
- [What is included](#what-is-included)
- [Supported CLIs](#supported-clis)
- [Language support](#language-support)
- [Relationship to Microsoft's skills](#relationship-to-microsofts-skills)
- [Building and self-hosting](#building-and-self-hosting)
- [Repository layout](#repository-layout)
- [Verification](#verification)
- [Licence](#licence)

---

## What it does

Agent 365 onboarding has roughly ten stages: an Entra blueprint, an agent identity, an agentic user, observability, tools, a messaging endpoint, a published manifest, an admin-centre activation, DLP. Microsoft's skills automate most of it. Getting hold of those skills was the awkward part, because every documented install path assumes a particular host.

| Documented path | Requires |
|---|---|
| `/plugin marketplace add` | a Claude Code host that exposes `/plugin` — several do not |
| `claude --plugin-dir ...` | an absolute path, and a non-elevated shell |
| `gh skill add` | the `gh skill` extension |

Each works on its own; together they turn "try the skills" into a support conversation. This kit removes the install step. The skills travel **with the project**, in the directories each CLI already looks in.

## Prerequisites

Install these before you start. The kit's launcher checks all of them and prints the install command for anything missing.

| | Why |
|---|---|
| **.NET SDK 8+** | the `a365` CLI ships as a .NET global tool — SDK, not just runtime |
| **`a365` CLI** | creates the blueprint and Entra identity |
| **Azure CLI**, signed in | tenant sign-in and app registration |
| **Node.js 18+** | runs the validators bundled with the kit |
| **Git** | scaffolding starter agents |
| **An AI coding CLI** | drives the onboarding — see [Supported CLIs](#supported-clis) |
| **Your agent's own runtime** | Python 3.10+, Node.js, or .NET |

```bash
winget install --id Microsoft.DotNet.SDK.8 -e
dotnet tool install -g Microsoft.Agents.A365.DevTools.Cli
winget install --id Microsoft.AzureCLI -e
az login --allow-no-subscriptions
```

On macOS, substitute `brew install --cask dotnet-sdk` and `brew install azure-cli`.

Then at least one CLI:

```bash
npm install -g @github/copilot
npm install -g @anthropic-ai/claude-code
```

Three things that are easy to miss, all covered in the guide:

- **A one-time tenant step.** An administrator runs `a365 setup requirements` once; every developer in the tenant inherits it.
- **A model provider key.** The kit onboards your agent; it does not give it a model. Your project still needs its own `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or Azure OpenAI settings, or the agent registers successfully and then fails on its first message.
- **On Windows, use a normal terminal.** Per-user tools are invisible to an elevated shell.

## Quick start

Download the release archive, then from your agent project's root:

```powershell
Expand-Archive -Path agent365-onboarding-kit-v0.1.0.zip -DestinationPath . -Force
.\agent365-kit.ps1
```

```bash
unzip agent365-onboarding-kit-v0.1.0.zip -d .
./agent365-kit.sh
```

The launcher checks prerequisites, reports which CLIs it can see, and tells you how to start each one. Then open your CLI:

```bash
copilot
```

and ask for what you want:

```
Onboard this agent to Agent 365.
```

It reads the skills from the folder you just extracted, detects your stack, and works through the stages with you.

**[`GUIDE.md`](GUIDE.md) is the full walkthrough** — ten steps from your agent's source to a registered, observable, tool-enabled agent chatting in Teams with Purview and Defender watching. Start there.

## How it works

A skill is a Markdown file with front matter. CLIs discover skills by looking in known directories, so the kit ships the same content in the directories each one reads:

```
your-agent-project/
  .a365-kit/            canonical: skills, shared docs, validators, prerequisite checker
  .claude/skills/       discovery copy - Claude Code
  .agents/skills/       discovery copy - Copilot, Cursor, Codex, Gemini CLI, and others
  agent365-kit.ps1      launcher: prerequisite check and per-CLI activation (Windows)
  agent365-kit.sh       the same, macOS and Linux
```

The discovery copies are **byte-identical**, because every internal reference points at `.a365-kit/`. That single indirection is what lets one copy serve every CLI, and the build verifies the copies match. [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md) covers the design.

## What you can ask for

Each stage has a phrase. You do not need to know skill names.

| Say this | What happens |
|---|---|
| *Onboard this agent to Agent 365.* | Detects your stack, then creates the blueprint, identity and permissions |
| *Add observability to this agent.* | OpenTelemetry instrumentation and the Agent 365 exporter |
| *Add Work IQ tools to this agent.* | Microsoft 365 data: mail, calendar, Teams, SharePoint, OneDrive |
| *Add an MCP server.* | Any external MCP server: filesystem, git, GitHub, Postgres, Slack, Playwright |
| *Add lab tools.* | Local utilities: web fetch, encoders, hashing, text transforms |
| *Make this agent chattable in Teams.* | HTTP host, dev tunnel, and endpoint registration |
| *Add DLP to this agent.* | Purview evaluation of every prompt and response |
| *Onboard this Java agent.* | Hosting layer and telemetry for Java, which has no Microsoft SDK |
| *Update the Agent 365 kit.* | Updates the kit in place, leaving your agent untouched |

### Example

A TypeScript agent using the OpenAI Agents SDK, with no Agent 365 anything:

```
> Onboard this agent to Agent 365.

  Stack:      OpenAI Agents SDK
  Language:   NodeJS
  Agent type: Agent (Non AI Teammate)
  Blueprint:  none found - will create new

  Which capabilities should I configure?
    1. Register        2. Observability
    3. Work IQ         4. AI Teammate

> 1 and 2

  How will your agent authenticate when calling downstream APIs?
    1. On-behalf-of (OBO)    2. Service-to-service (S2S)

> 1
```

From there it previews `a365 setup all` with `--dry-run`, shows exactly what will be created in your tenant, and asks before committing. Nothing reaches Entra without your explicit confirmation.

## What is included

**Microsoft's seven skills**, unchanged except for the modifications recorded in [`NOTICE.md`](NOTICE.md): `a365-setup`, `make-a365-agent`, `make-ai-teammate`, `instrument-observability`, `add-workiq-tools`, `a365-code-validator`, `test-local`.

**Six add-ons written for this kit**, discovered the same way and clearly separated in `NOTICE.md`:

| Add-on | Fills this gap |
|---|---|
| `add-messaging-endpoint` | Upstream registers a blueprint agent but never hosts it, leaving it reachable by nothing. Adds the `/api/messages` host, the tunnel, and the endpoint registration. |
| `add-purview-dlp` | Upstream has no Purview coverage. Evaluates every prompt and response against tenant DLP through two Graph calls. |
| `add-mcp-server` | Connects the agent to any external MCP server, with the governance boundary stated plainly: these are **not** registered in Agent 365 or gated by Entra. |
| `add-lab-tools` | Local in-process utilities an agent otherwise lacks: web fetch, encoders, hashing, text transforms. Opt-in and dual-use. |
| `add-java-agent` | Java has no Agent 365 SDK. Adds the HTTP host, inbound token validation, and a direct OTLP exporter. |
| `a365-kit` | Kit maintenance from inside your CLI: prerequisites, versions, in-place update, update source. |

An agent gets tools three ways and the kit covers all three: Work IQ MCP servers (Microsoft-hosted, Entra-gated), local function tools, and external MCP servers (the wider ecosystem, ungoverned by Agent 365). Only the first appears in the Agent 365 registry, and the add-ons for the other two say so.

## Supported CLIs

Support follows from where each CLI looks for skills, not from anything kit-specific:

| Directory the kit ships | CLIs that read it | Validator hooks |
|---|---|---|
| `.claude/skills/` | Claude Code | yes |
| `.agents/skills/` | GitHub Copilot (CLI, VS Code agent mode, coding agent), Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp, Antigravity | no |
| `.github/copilot-instructions.md` *(opt-in)* | GitHub Copilot, as extra grounding — not required | no |
| — | anything else: point it at `.a365-kit/skills/a365-setup/SKILL.md` | no |

`.agents/skills/` follows the [Agent Skills specification](https://agentskills.io/specification).

The skills themselves are plain Markdown. Only the validator hooks are Claude Code specific, and they are optional: everything works without them, just without the end-of-session correctness check. [`docs/USING-WITH-YOUR-CLI.md`](docs/USING-WITH-YOUR-CLI.md) covers per-CLI differences.

## Language support

Agent 365 ships SDKs for **Python, Node.js / TypeScript and .NET**. Within those, framework coverage is broad and detected automatically: LangChain, OpenAI Agents SDK, Claude Agent SDK, Google ADK, Semantic Kernel and Microsoft Agent Framework.

Most of onboarding never reads your source. The blueprint, identity, agentic user, endpoint registration, manifest, upload and instance are Entra, CLI and portal operations, so an agent in **any** language can be registered, published and made reachable in Teams. Only observability, Work IQ tools and the generated host are SDK-bound. Java is covered by the `add-java-agent` add-on, and [`GUIDE.md`](GUIDE.md#which-languages-this-covers) documents the wire contract other languages would need.

## Relationship to Microsoft's skills

This is a repackage, not a fork. The build clones upstream fresh on every run and re-applies a fixed set of edits, each of which asserts the upstream text it expects to find. If Microsoft reword a patched passage, the build fails and names the file rather than silently emitting something broken.

Changes fall into two groups, both itemised in [`NOTICE.md`](NOTICE.md):

- **Packaging.** Path tokens, hook commands, the plugin command namespace, and a guard that would otherwise disable itself outside a plugin install. Mechanical, no behaviour change.
- **Defects found while onboarding real agents.** Mostly in the observability path, where several independent faults each left an agent tracing every turn and exporting none of it. Every one is documented with the failure it causes and upstream's own justification for the fix.

Problems with what the skills *do* belong upstream at [microsoft/agent365-skills](https://github.com/microsoft/agent365-skills/issues). Problems with the packaging, launchers, prerequisite checker or build belong here.

## Building and self-hosting

Requires PowerShell 7+, Git and Node.js.

```powershell
.\build\Build-Kit.ps1 -UpstreamPath C:\src\agent365-skills
.\build\Build-Kit.ps1 -Zip
```

The first builds from a local clone of upstream; the second clones upstream itself and produces a release archive. Output lands in `dist/`, and `-Zip` also writes the archive at the repository root.

The build refuses to emit output it cannot prove coherent. It verifies that no `${CLAUDE_PLUGIN_ROOT}` path tokens or `/agent365:` command references survive, that every path a skill references exists, that every bundled JS file parses, that the discovery copies match, and that every hook command was repointed.

**Staying current.** `.github/workflows/refresh-upstream.yml` runs daily, compares upstream `main` against the recorded commit, and when it moves it rebuilds, commits `dist/` and cuts a release. If a fix-up assertion fails it opens an issue instead.

**Updating in place.** `.\agent365-kit.ps1 -Update`, or *"update the Agent 365 kit"* from inside your CLI. Only the kit's own paths are replaced, never your agent, `.env`, config, or skills you added.

**Using your own mirror.** The public release is only the default. Point updates at a URL or a filesystem path:

| Scope | How |
|---|---|
| One call | `-UpdateFrom <zip-or-url>` |
| One shell or CI job | `A365_KIT_UPDATE_SOURCE=<zip-or-url>` |
| One project, whole team | `-SetUpdateSource <zip-or-url>`, which writes `a365-kit.config.json` — commit it |
| Your own build | `.\build\Build-Kit.ps1 -UpdateSource <zip-or-url> -Zip` |

A network share holding `agent365-onboarding-kit-latest.zip` works with no web server at all.

## Repository layout

| Path | Purpose |
|---|---|
| `build/Build-Kit.ps1` | the build — derives `dist/` from upstream |
| `build/kit.version` | this kit's packaging version |
| `payload/` | files authored here and copied into every build: add-ons, validators, launchers, prerequisite checker |
| `dist/` | built output, committed so the repository can be used directly |
| `GUIDE.md` | the end-to-end walkthrough |
| `NOTICE.md` | attribution and every modification made to upstream |
| `docs/` | deeper references: per-CLI setup, lifecycle, design |

`dist/` is generated. Changes to Microsoft's skills go in the fix-up list in `build/Build-Kit.ps1`; changes to the kit's own content go in `payload/`.

## Verification

Built against upstream `agent365-skills` v1.0.2 and verified on Windows 11.

- **Discovery.** Claude Code and GitHub Copilot CLI both list all thirteen skills from the extracted folder with no install step. Copilot loads referenced files by relative path, which is what confirms the path-rewrite strategy works outside Claude Code.
- **Onboarding.** Driven end to end through Copilot CLI against a live tenant on a Python agent: blueprint, agent identity, eleven delegated permission grants, observability instrumentation, Work IQ tool wiring, messaging endpoint, published package, and an agent answering in Teams.
- **Java.** The `add-java-agent` output compiles on JDK 21 and runs: health check returns 200, an anonymous request returns 401, a forged bearer returns 401. Its OTLP encoder was matched field by field against the Python SDK's output.
- **Guard behaviour.** The patched path guard blocks writes into the kit and outside the project, and allows writes to agent source.

Not yet exercised: the `.agents/skills/` path under Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp and Antigravity, and a Java agent taken all the way to a live tenant.

## Licence

This packaging is MIT licensed — see [`LICENSE`](LICENSE). The bundled skills are © Microsoft Corporation, also MIT. [`NOTICE.md`](NOTICE.md) carries the attribution and the full list of modifications.
