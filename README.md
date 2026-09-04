# Agent 365 Onboarding Kit

Microsoft's [`agent365-skills`](https://github.com/microsoft/agent365-skills), repackaged as a **drop-in folder**.

Download, extract into your agent project, run one script. No plugin install, no marketplace step, and no dependency on which coding CLI you use.

```
Download  ->  extract into your agent project  ->  ./agent365-kit.ps1  ->  "Onboard this agent to Agent 365."
```

---

## Why this exists

The upstream skills are excellent, but every documented install path assumes a specific host:

| Path | Requires |
|---|---|
| `/plugin marketplace add` | A Claude Code host that exposes `/plugin` — several do not |
| `claude --plugin-dir ...` | Knowing an absolute path, and a non-elevated shell |
| `gh skill add` | The `gh skill` extension |

Each is fine on its own; together they make "just try the skills" a support conversation. This kit removes the install step entirely: the skills travel **with the project**, in the locations each CLI already looks in.

It is a **faithful repackage**. The skill content is Microsoft's, unmodified except for the mechanical rewrites in [`NOTICE.md`](NOTICE.md).

## What a user gets

```
your-agent-project/
  .a365-kit/            canonical: skills, shared docs, validators, doctor
  .claude/skills/       discovery copy -- Claude Code
  .agents/skills/       discovery copy -- VS Code agent mode, Copilot cloud agent, gh skill
  agent365-kit.ps1      prereq check + per-CLI activation steps (Windows)
  agent365-kit.sh       same, macOS/Linux
  AGENT365-KIT-README.md
```

Skill files are byte-identical across all three locations, because every internal reference points at `.a365-kit/`. See [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md).

## Supported CLIs

Support is determined by where each CLI looks for skills, not by anything kit-specific:

| Discovery path the kit ships | CLIs that read it | Validator hooks |
|---|---|---|
| `.claude/skills/` | **Claude Code** | Yes |
| `.agents/skills/` | **GitHub Copilot** (CLI, VS Code agent mode, coding agent), **Cursor**, **Codex**, **Gemini CLI**, **Amp**, **Cline**, **OpenCode**, **Warp**, **Antigravity** | No |
| `.github/copilot-instructions.md` *(opt-in)* | GitHub Copilot — extra grounding, not required | No |
| — | Anything else: point it at `.a365-kit/skills/a365-setup/SKILL.md` | No |

`.agents/skills/` is the [Agent Skills specification](https://agentskills.io/specification) convention; the CLI list is GitHub's own project-scope mapping, confirmed against `gh skill install --help` on gh 2.98.

The skills are plain Markdown. Only the Node validator hooks are Claude Code specific, and they are optional — the skills work without them, just without the end-of-session correctness check.

**Three guides, three questions:**

- **[`docs/STEP-BY-STEP.md`](docs/STEP-BY-STEP.md)** — *what do I say, in what order?* The phrase that starts each stage — register, chat in Teams and Copilot, Purview DLP — the questions each asks, and the four moments you run one command in your own terminal. Start here.
- **[`docs/USING-WITH-YOUR-CLI.md`](docs/USING-WITH-YOUR-CLI.md)** — *how do I start?* From the zip to the moment onboarding begins, per CLI.
- **[`docs/LIFECYCLE.md`](docs/LIFECYCLE.md)** — *how do I finish?* The complete path from a custom agent to one chatting in Teams and Copilot with Defender and Purview watching: agent kinds and identity, the two commands you always run yourself, hosting and the messaging endpoint, `a365 publish` and the manifest, admin-centre activation, DLP, teardown. Each step says whether the skills do it, you do it, or an admin does it in a portal.

---

## Kit add-ons

Two skills the kit adds beside Microsoft's seven, discovered the same way, clearly separated in `NOTICE.md`. Both were built from what the live runs showed was missing.

| Add-on | Say | What it does |
|---|---|---|
| `add-messaging-endpoint` | *"make this agent chattable in Teams"* | For blueprint-based agents, which upstream registers but never hosts: adds the `/api/messages` host (Python verified on SDK 1.6; Node/.NET via upstream's references), exposes it through a dev tunnel or your URL, registers the endpoint with `--m365`, and hands off `a365 setup permissions bot` — the one part that needs the Windows broker. |
| `add-purview-dlp` | *"add DLP to this agent"* | Purview runtime DLP on every prompt and response: two Graph REST calls, so one pattern for Python, Node.js and .NET. Grants the two delegated scopes on the agent identity, wires the hooks with the token-subject rule that otherwise yields Graph 400, and hands off the portal policy. Python is from a live reference deployment; the ports are transcriptions awaiting a tenant run. |

## Building

Requires PowerShell 7+, Git, and Node.js.

```powershell
# Build from a local clone of upstream
.\build\Build-Kit.ps1 -UpstreamPath C:\src\agent365-skills

# Or let it shallow-clone upstream itself, and produce a release zip
.\build\Build-Kit.ps1 -Zip
```

Output lands in `dist/`. With `-Zip` you also get `agent365-onboarding-kit-v<version>.zip` at the repo root, ready to attach to a GitHub release.

### Refreshing when Microsoft ships a new version

It happens by itself. `.github/workflows/refresh-upstream.yml` runs daily, compares upstream `main` with the commit recorded in `KIT-VERSION.json`, and when it has moved: rebuilds, commits `dist/`, and cuts a release with the zip attached — both `agent365-onboarding-kit-v<version>.zip` and a stable `agent365-onboarding-kit-latest.zip`. If a fix-up assertion fails because upstream reworded a patched passage, the job fails and opens (or comments on) an issue labelled `upstream-refresh` naming the file. Trigger it by hand from the Actions tab, optionally pinning `upstream_ref` to a tag.

Locally it is one command:

```powershell
.\build\Build-Kit.ps1 -Zip
```

The build re-derives everything from upstream; nothing is hand-maintained. Bump `build/kit.version` if the kit's own packaging changed.

**Users update in place** with `.\agent365-kit.ps1 -Update` (or `./agent365-kit.sh --update`) — or, from inside their CLI, *"update the Agent 365 kit"* (the `a365-kit` add-on). It replaces only the kit's own paths — never the agent, `.env`, config, `.claude/settings.json`, or skills the user added. The Claude Code session-start notice tells users when upstream has moved.

### Hosting the kit yourself

The public GitHub release is only the default. Organisations that mirror the kit — internal GitHub, an artifact server, a file share — choose where updates come from at whichever level fits:

| Level | How | Wins over |
|---|---|---|
| One call | `-UpdateFrom <zip-or-url>` / `--update-from` | everything below |
| One shell or CI job | `A365_KIT_UPDATE_SOURCE=<zip-or-url>` | everything below |
| One project, whole team | `.\agent365-kit.ps1 -SetUpdateSource <zip-or-url>` → writes `a365-kit.config.json` at the project root, outside the paths an update replaces; **commit it** | everything below |
| Your own build of the kit | `.\build\Build-Kit.ps1 -UpdateSource <zip-or-url> -Zip` → baked into `KIT-VERSION.json` | the public default |

A filesystem path is as valid as a URL, so a network share with `agent365-onboarding-kit-latest.zip` on it works with no web server at all.

The build **fails loudly** rather than shipping something subtly broken. It verifies that:

- no `${CLAUDE_PLUGIN_ROOT}` path tokens survive (they resolve to nothing without a plugin)
- no `/agent365:` plugin command references survive (that namespace does not exist here)
- every `.a365-kit/...` path a skill references actually exists in the output
- every bundled JS file parses
- the discovery copies match the canonical skill set
- every hook command was repointed to `${CLAUDE_PROJECT_DIR}`

It also asserts that its own targeted text fix-ups still match upstream. If Microsoft rewords a passage the kit patches, the build stops and names the file, instead of silently emitting nonsense.

## Repository layout

| Path | Purpose |
|---|---|
| `build/Build-Kit.ps1` | The build. Derives `dist/` from upstream. |
| `build/kit.version` | This kit's packaging version. |
| `payload/` | Hand-written files copied into every build — launchers, doctor, README. |
| `dist/` | Built output. Committed so the repo can be downloaded and used directly. |
| `docs/USING-WITH-YOUR-CLI.md` | End-user walkthrough, step by step, per CLI — how to start. |
| `docs/LIFECYCLE.md` | The complete path to an agent chatting in Teams and Copilot — hosting, endpoint, manifest, activation, DLP, teardown — how to finish. |
| `docs/HOW-IT-WORKS.md` | The repackaging design and why each rewrite is needed. |

## Status

Verified on Windows 11 against upstream v1.0.2:

**Build**
- builds clean with all verification passing
- the patched path guard blocks writes into the kit and outside the project, and allows writes to agent source
- stop validators run and correctly report an un-instrumented project
- Copilot wiring creates the instructions file, and appends to a pre-existing one without data loss

**Claude Code**
- discovers all seven skills from `.claude/skills/` with no plugin install

**GitHub Copilot CLI 1.0.81**
- `copilot skill list` shows all seven under *Project skills* from `.agents/skills/`
- a dry run loaded `.a365-kit/skills/a365-setup/SKILL.md` **by relative path**, confirming the path-rewrite strategy works outside Claude Code
- correctly detected Python + OpenAI Agents SDK + non-AI-Teammate, and routed to `make-a365-agent`
- produced the full question sequence and step plan, with zero file changes

**Live onboarding through Copilot CLI, real tenant** (existing Python / OpenAI Agents SDK project, `src/` layout, `requirements.txt`, AI Teammate path)
- blueprint and service principal created, all five resource consents granted
- hosting layer, `AgentInterface` adapter, notification handler, `.env` and `requirements.txt` all written correctly
- `validate-make-ai-teammate.js` passes — after the three fix-ups in `NOTICE.md` §8, which this run surfaced
- two things a first run leaves for the user: `pip install` (the skill edits `requirements.txt` but doesn't install), and the observability scopes (re-invoke `instrument-observability`); both documented in the kit README
- **`a365 setup all` must be run in the user's own terminal**, not through any agentic CLI — it authenticates via the Windows broker, which needs an interactive desktop session. This is a property of the a365 CLI, not the kit; see `docs/USING-WITH-YOUR-CLI.md`

**Second live run, non-AI-Teammate path** (same project, fresh folder; Register + Observability + WorkIQ, OBO)
- with the own-terminal instruction in place, the `a365 setup all` step that stalled for an hour in run 1 took about a minute
- blueprint created **and an agent identity auto-created** — for the blueprint-only path `a365 setup all` provisions the identity service principal itself, so the agent is in the registry with an Entra identity without an admin-centre step
- all 11 delegated OAuth2 grants materialised in the tenant (Graph, seven WorkIQ MCP servers, observability, connectivity)
- `InvokeAgentScope`, the token cache and the WorkIQ `McpToolRegistrationService` all wired into the agent; `ToolingManifest.json` written
- all four applicable validators pass: `a365-setup`, `make-a365-agent`, `instrument-observability`, `add-workiq-tools`
- `completed: false` in the generated config on this path means the Azure hosting/endpoint step is outstanding, not that consent is — the validator's own warning says so
- the one gap reproduced from run 1: the skill edits `requirements.txt` but does not run `pip`; documented in the kit README as a post-run check

Not yet exercised: the post-provisioning half of the lifecycle (public hosting → messaging endpoint → `a365 publish` → admin-center instance), and the `.agents/skills/` path under the other CLIs (Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp, Antigravity).

## Licence

This packaging is MIT licensed — see [`LICENSE`](LICENSE). The bundled skills are © Microsoft Corporation, also MIT. See [`NOTICE.md`](NOTICE.md) for attribution and the exact list of modifications.
