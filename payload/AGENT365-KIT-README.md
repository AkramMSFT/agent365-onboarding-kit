# Agent 365 Onboarding Kit

Drop-in skills that walk your coding CLI through onboarding an agent to **Microsoft Agent 365** — registering it, giving it an Entra identity, instrumenting observability, and wiring WorkIQ tools.

No plugin install. No marketplace. Extract, then point your CLI at it.

The skills themselves are Microsoft's official [`agent365-skills`](https://github.com/microsoft/agent365-skills), repackaged so they load from a project folder instead of requiring a plugin install. See `.a365-kit/KIT-VERSION.json` for the exact upstream version bundled here.

---

## 1. Put it in your agent project

Extract this kit into the **root of your agent project** — the folder containing your agent's source:

```
your-agent-project/
  .a365-kit/            <- skills, shared docs, validators
  .claude/skills/       <- discovery copy: Claude Code
  .agents/skills/       <- discovery copy: VS Code agent mode, gh skill
  agent365-kit.ps1      <- prereq check + activation steps (Windows)
  agent365-kit.sh       <- same, macOS/Linux
  src/ package.json ... <- your agent
```

Starting from nothing? Extract into an empty folder — the skills can scaffold a starter agent from Microsoft's samples.

## 2. Check your prerequisites

```bash
# Windows
.\agent365-kit.ps1

# macOS / Linux
chmod +x agent365-kit.sh && ./agent365-kit.sh
```

This checks every prerequisite, prints the exact install command for anything missing, detects which CLIs you have, and prints the activation steps below. It does not change your project.

> **Windows:** run it from a **normal** PowerShell, not an Administrator one. Claude Code, `gh`, and the `a365` CLI install per-user, so an elevated shell usually cannot see them — tools that are installed will look missing. The script warns you if it detects this.

**Required:** Node.js 18+, .NET SDK 8+ (not just the runtime), the `a365` CLI, Azure CLI, Git, and your chosen coding CLI.
**Also needed:** a Microsoft Agent 365 tenant with developer access.

### One-time tenant setup (admin)

The `a365` CLI needs a custom Entra app registration in your tenant. This is **once per tenant, not once per developer** — after any admin runs it, everyone inherits the ready state:

```bash
a365 setup requirements
```

Requires **Application Administrator** (lightest sufficient role), Cloud Application Administrator, or Global Administrator. If you are a developer without admin rights and setup reports `403` or "tenant not ready", send that command to your tenant admin.

## 3. Start onboarding with your CLI

The trigger phrase is the same everywhere:

> **Onboard this agent to Agent 365.**

Which CLIs work is determined by where they look for skills — the kit ships into both standard locations:

| Directory | CLIs that read it |
|---|---|
| `.claude/skills/` | **Claude Code** |
| `.agents/skills/` | **GitHub Copilot** (CLI, VS Code agent mode, coding agent), **Cursor**, **Codex**, **Gemini CLI**, **Amp**, **Cline**, **OpenCode**, **Warp**, **Antigravity** |

### Claude Code

Skills in `.claude/skills/` load automatically — no `/plugin`, no `--plugin-dir`. From your project root:

```bash
claude
```

Then type the trigger phrase, or `claude "Onboard this agent to Agent 365."` in one go.

Claude Code is the only CLI that runs the bundled **validator hooks**: after a skill finishes, a check confirms the wiring actually landed and refuses to end the session if something is missing. Elsewhere the skills still work — you just lose that final check.

### GitHub Copilot CLI

Reads `.agents/skills/`, which is already populated. Install the CLI if you don't have it — `gh copilot` won't fetch it for you:

```bash
npm install -g @github/copilot
```

Confirm the kit landed, then start:

```bash
cd your-agent-project
copilot skill list     # all seven should appear under "Project skills"
copilot                # then type the trigger phrase
```

To see what it would do without touching your tenant:

```bash
copilot -p "Onboard this agent to Agent 365. DRY RUN - do not run commands or modify files. Report which skill you selected, what you detected, and the steps you would perform." --allow-all-tools --deny-tool shell
```

Needs **gh 2.98+** if you launch via `gh copilot` — older versions shipped an extension that only suggested shell commands and cannot edit files.

Optionally add the instructions file for extra grounding (not required):

```bash
.\agent365-kit.ps1 -WireCopilot       # Windows
./agent365-kit.sh --wire-copilot      # macOS / Linux
```

It **creates `.github/copilot-instructions.md`, or appends to yours** — it never overwrites project-owned instructions.

### VS Code — Copilot agent mode

Open this folder in VS Code, open Copilot Chat, switch the mode selector to **Agent**, confirm with `/skills list`, then ask using the trigger phrase.

### Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp, Antigravity

These share `.agents/skills/` at project scope, so the skills are already where they look. Open the folder and use the trigger phrase — there is nothing to install.

### Any other agentic CLI

The skills are plain Markdown with no runtime dependencies. Tell your tool:

> Read `.a365-kit/skills/a365-setup/SKILL.md` and follow it exactly.

Or let `gh skill` place them wherever your tool expects:

```bash
gh skill install --from-local .a365-kit --all --agent cursor --scope project
```

`gh skill install --help` lists around 40 supported agents.

---

## What happens next

`a365-setup` is the entry point. It verifies the CLI and Azure prerequisites, asks which capabilities you want, then hands off:

```
a365-setup
│
├─ AI Teammate            -> make-ai-teammate
│                              ├─ instrument-observability   (automatic)
│                              └─ add-workiq-tools           (offered)
│
└─ Agent (non-Teammate)   -> make-a365-agent
                               ├─ instrument-observability   (optional)
                               └─ add-workiq-tools           (optional, OBO only)

test-local            standalone -- run the agent locally against AgentsPlayground
a365-code-validator   standalone -- diagnose telemetry that isn't reaching MAC Activity
```

Setup writes `.a365-workspace-detection.local.json`, which caches what it detected about your agent so later skills don't redo the work. It is machine-specific — keep it out of source control. Deleting it is safe; the next run rebuilds it.

The skills are **additive, idempotent, and state-aware**. Re-running them is safe.

### Already registered?

Skip the entry point and ask directly:

| Ask for this | Skill |
|---|---|
| "Make this agent an AI Teammate" | `make-ai-teammate` |
| "Add observability to this agent" | `instrument-observability` |
| "Add WorkIQ tools to this agent" | `add-workiq-tools` |
| "Validate A365 code" | `a365-code-validator` |
| "Test this agent locally" | `test-local` |

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `claude` / `a365` / `gh` "not found" but they are installed | You are in an **elevated** shell. These install per-user. Re-run from a normal terminal. |
| Prereq check passes, then a tool is missing mid-run | PATH was updated after your terminal started. Open a new terminal. |
| `a365 setup all` returns 403 or "tenant not ready" | The one-time tenant prerequisite has not been run. Ask an admin for `a365 setup requirements`. |
| `dotnet tool install` fails | You have the .NET **runtime**, not the **SDK**. Install the SDK 8+. |
| The CLI doesn't recognise the trigger phrase | The kit is not at your project root, or you started the CLI from a different folder. Re-run `agent365-kit` to confirm the layout. |
| A skill stops asking for the detection cache | Run `a365-setup` to completion first — it writes `.a365-workspace-detection.local.json`. |
| A Claude Code session won't end, citing a validator | That is intentional. The validator found the wiring incomplete; read its reason and fix it. |

---

## What is safe to commit

| Path | Commit? |
|---|---|
| `.a365-kit/`, `.claude/skills/`, `.agents/skills/` | Yes — sharing them means teammates skip the download. |
| `.github/copilot-instructions.md` | Yes. |
| `.a365-workspace-detection.local.json` | **No** — machine-specific state. |
| `a365.generated.config.json` | **No** — contains generated tenant identifiers. |
| `.env` | **No.** |

---

## Licence and provenance

The bundled skills are © Microsoft Corporation, MIT licensed, from
[microsoft/agent365-skills](https://github.com/microsoft/agent365-skills). This kit repackages them
unmodified except for path rewrites needed to load them without a plugin install. See `NOTICE.md`
in the kit repository for details of exactly what was changed.
