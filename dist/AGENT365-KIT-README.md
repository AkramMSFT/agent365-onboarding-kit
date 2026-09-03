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

### Claude Code

Project skills in `.claude/skills/` load automatically. From your project root:

```bash
claude
```

Then type the trigger phrase. The validator hooks bundled with the kit run here too, checking the wiring before the session ends.

### VS Code agent mode / Copilot cloud agent

Skills in `.agents/skills/` follow the open agent-skills convention and are discovered automatically. Open the project in VS Code, switch Copilot Chat to **Agent** mode, confirm with `/skills list`, then ask using the trigger phrase.

### GitHub Copilot CLI

Copilot reads `.github/copilot-instructions.md`. Wire it once:

```bash
# Windows
.\agent365-kit.ps1 -WireCopilot

# macOS / Linux
./agent365-kit.sh --wire-copilot
```

This **creates the file, or appends to it** if you already have one — it never overwrites your project's instructions. Then:

```bash
gh copilot suggest "Onboard this agent to Agent 365."
```

### Any other agentic CLI

The skills are plain Markdown. Point your tool at `.a365-kit/skills/a365-setup/SKILL.md` and tell it to follow that file. Everything except the optional validator hooks is CLI-neutral.

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
