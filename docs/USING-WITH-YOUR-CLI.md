# Using the kit with your CLI

Step-by-step instructions for every supported coding agent, from downloading the kit to the moment onboarding starts.

Every path shares the same first three steps. Only Step 4 differs per CLI.

---

## Which CLIs are supported

The kit ships the skills into the two directories that coding agents actually read, so support is determined by where your CLI looks — not by anything kit-specific:

| Directory the kit ships | CLIs that read it |
|---|---|
| `.claude/skills/` | **Claude Code** |
| `.agents/skills/` | **GitHub Copilot** (CLI, VS Code agent mode, coding agent), **Cursor**, **Codex**, **Gemini CLI**, **Amp**, **Cline**, **OpenCode**, **Warp**, **Antigravity** |
| `.github/copilot-instructions.md` *(opt-in)* | GitHub Copilot — extra grounding, not required |

`.agents/skills/` is the [Agent Skills specification](https://agentskills.io/specification) convention. The list above is GitHub's own project-scope mapping, confirmed by running `gh skill install --help` on gh 2.98.

Anything not listed still works — see [Any other agentic CLI](#any-other-agentic-cli).

> **Verified so far:** Claude Code, end to end (all seven skills discovered, validators firing).
> The `.agents/skills/` placement is confirmed correct by `gh skill install`, but a full
> onboarding run has not yet been driven through a non-Claude CLI. Treat those paths as
> correct-by-construction rather than field-tested.

---

## Step 1 — Get the kit into your project

Download `agent365-onboarding-kit-v<version>.zip` from the [releases page](../../releases) and extract it into the **root of your agent project** — the folder that contains your agent's source.

Extract into the project root itself, not a subfolder. The archive has no wrapper directory, so extracting in place produces:

```
your-agent-project/
  .a365-kit/            skills, shared docs, validators, prereq doctor
  .claude/skills/       Claude Code
  .agents/skills/       Copilot, Cursor, Codex, Gemini, Amp, Cline, OpenCode, Warp
  agent365-kit.ps1      Windows launcher
  agent365-kit.sh       macOS / Linux launcher
  AGENT365-KIT-README.md
  src/  package.json    <- your agent, already here
```

Starting from scratch? Extract into an empty folder. The skills can scaffold a starter agent from Microsoft's samples.

<details>
<summary>Command line, if you prefer</summary>

```powershell
# Windows
cd C:\path\to\your-agent-project
Invoke-WebRequest -Uri "<release-zip-url>" -OutFile kit.zip
Expand-Archive kit.zip -DestinationPath . -Force
Remove-Item kit.zip
```

```bash
# macOS / Linux
cd ~/path/to/your-agent-project
curl -fsSL -o kit.zip "<release-zip-url>"
unzip -o kit.zip && rm kit.zip
chmod +x agent365-kit.sh
```
</details>

## Step 2 — Run the launcher

From the project root:

```powershell
# Windows
.\agent365-kit.ps1
```

```bash
# macOS / Linux
./agent365-kit.sh
```

This changes nothing in your project. It confirms the kit landed correctly, checks every prerequisite, prints the exact install command for anything missing, detects which CLIs you have, and prints the activation steps.

> **Windows: use a normal PowerShell, not an Administrator one.** Claude Code, `gh`, and the `a365` CLI all install per-user, so an elevated shell usually cannot see them — installed tools appear missing. The launcher detects this and warns you.

Fix anything reported missing, then **open a new terminal** so PATH changes take effect, and run it again.

## Step 3 — One-time tenant setup

The `a365` CLI needs a custom Entra app registration in your tenant. This is **once per tenant, not once per developer** — after any admin runs it, everyone inherits the ready state:

```bash
a365 setup requirements
```

Requires **Application Administrator** (the lightest sufficient role), Cloud Application Administrator, or Global Administrator. Global Admin is not required.

If you are a developer without admin rights, skip this and continue. If onboarding later reports `403` or "tenant not ready", send that one command to your tenant admin.

## Step 4 — Start onboarding

The trigger phrase is identical in every CLI:

> **Onboard this agent to Agent 365.**

Pick your CLI below.

---

### Claude Code

Skills in `.claude/skills/` load automatically — no install, no `/plugin`, no `--plugin-dir`.

```bash
cd your-agent-project
claude
```

Then type the trigger phrase. Or skip a step:

```bash
claude "Onboard this agent to Agent 365."
```

The launcher can do it for you:

```powershell
.\agent365-kit.ps1 -Launch claude
```

**Verify the skills loaded** — ask `What Agent 365 skills do you have?` You should see all seven: `a365-setup`, `make-a365-agent`, `make-ai-teammate`, `instrument-observability`, `add-workiq-tools`, `a365-code-validator`, `test-local`.

You can also invoke them directly as slash commands: `/a365-setup`, `/make-ai-teammate`, and so on.

**Claude Code is the only CLI that runs the validator hooks.** After a skill finishes, a Node validator checks the wiring actually landed — the right packages, the entry-point call, the token resolver, the baggage context — and refuses to end the session if something is missing, with a specific reason. Everywhere else the skills still work; you just lose that end-of-session check.

Optional — a notice when Microsoft publishes newer skills than the kit bundles:

```powershell
.\agent365-kit.ps1 -WireClaudeHook
```

It creates `.claude/settings.json` only if you don't already have one. If you do, it tells you which block to merge rather than touching your file.

---

### GitHub Copilot CLI

`gh copilot` launches the agentic Copilot CLI, downloading it on first use if needed. It reads `.agents/skills/`, which the kit already populated.

```bash
cd your-agent-project
gh copilot
```

Then type the trigger phrase.

Requires **gh 2.98 or newer** (`gh --version`). On older gh, `gh copilot` was a separate extension that only suggested shell commands and could not edit files — that version cannot drive onboarding. Upgrade gh, or use the standalone `copilot` CLI.

Optionally add the instructions file for extra grounding. Not required — it repeats the skill catalogue and trigger phrases in the format Copilot reads by default:

```powershell
.\agent365-kit.ps1 -WireCopilot       # Windows
./agent365-kit.sh --wire-copilot      # macOS / Linux
```

This **creates `.github/copilot-instructions.md`, or appends to yours if you already have one.** It never overwrites project-owned instructions.

---

### VS Code — Copilot agent mode

1. Open the project folder in VS Code (`code .` from the project root).
2. Open Copilot Chat.
3. Switch the mode selector to **Agent**.
4. Confirm the skills are visible with `/skills list` — you should see the seven Agent 365 skills.
5. Ask using the trigger phrase.

Skills come from `.agents/skills/`, which VS Code agent mode reads at project scope. If they don't appear, reload the window — VS Code scans the folder at load.

Running `-WireCopilot` (above) also helps here, since Copilot Chat reads `.github/copilot-instructions.md`.

---

### Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp, Antigravity

All of these share `.agents/skills/` at project scope, so **the skills are already where they look — there is nothing to install.**

1. Open the project folder in your tool.
2. Ask using the trigger phrase.

If your tool has a skills listing command (often `/skills list`), use it to confirm the seven skills are visible first.

Two caveats that apply to every non-Claude CLI:

- **No validator hooks.** The end-of-session correctness check is Claude Code specific. The skills still work; nothing verifies the wiring afterwards. Run `a365-code-validator` explicitly, or the validator directly:
  ```bash
  node .a365-kit/hooks/stop/validate-instrument-observability.js
  ```
- **Slash commands may differ.** The skills reference `/a365-setup` style commands. If your CLI doesn't support them, describe what you want instead — the trigger phrases work everywhere.

---

### Any other agentic CLI

The skills are plain Markdown with no runtime dependencies. If your tool can read files and run commands, it can follow them:

> Read `.a365-kit/skills/a365-setup/SKILL.md` and follow it exactly.

That file is the entry point and delegates to the others as needed. Everything it references lives under `.a365-kit/`, addressed relative to the project root — so it resolves from wherever your CLI starts, as long as that is the project root.

If your tool supports the Agent Skills spec but expects a different directory, `gh skill` can place them for you:

```bash
gh skill install --from-local .a365-kit --all --agent cursor --scope project
```

Run `gh skill install --help` for the full list of supported agents (about 40).

---

## What happens next

`a365-setup` runs first regardless of CLI. It verifies prerequisites, asks which capabilities you want, then delegates:

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
```

You'll be asked to choose an agent kind and an auth mode. Two notes worth having in advance:

- **`obo` vs `s2s`** — OBO uses principal-scoped delegated grants and needs no admin consent. S2S needs a Global Admin or a PowerShell fallback. Prefer OBO wherever the scenario allows; it is a materially shorter path.
- Setup writes `.a365-workspace-detection.local.json`, caching what it detected so later skills skip re-detection. It is machine-specific — **do not commit it**. Deleting it is safe; the next run rebuilds it.

The skills are additive, idempotent, and state-aware. Re-running them is safe.

### Running skills directly

Already registered? Skip the entry point:

| Ask for | Skill |
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
| `claude` / `a365` / `gh` "not found" but they are installed | Elevated shell. These install per-user. Re-run from a normal terminal. |
| Prereq check passes, then a tool is missing mid-run | PATH changed after the terminal started. Open a new terminal. |
| The CLI doesn't recognise the trigger phrase | The kit isn't at the project root, or the CLI was started from a different folder. Re-run `agent365-kit` to confirm the layout. |
| Skills don't appear in `/skills list` | Wrong directory for that CLI, or the tool needs a reload. Check `.agents/skills/` exists and reload. |
| `gh copilot` only suggests shell commands | gh older than 2.98, using the legacy extension. Upgrade gh. |
| `a365 setup all` returns 403 or "tenant not ready" | Step 3 hasn't been run. Ask an admin for `a365 setup requirements`. |
| `dotnet tool install` fails | You have the .NET **runtime**, not the **SDK**. Install SDK 8+. |
| A skill stops, asking for the detection cache | Run `a365-setup` to completion first — it writes the cache. |
| A Claude Code session won't end, citing a validator | Working as intended. The validator found incomplete wiring; read its reason and fix it. |

## What to commit

| Path | Commit? |
|---|---|
| `.a365-kit/`, `.claude/skills/`, `.agents/skills/` | Yes — teammates then skip the download entirely. |
| `.github/copilot-instructions.md` | Yes. |
| `.a365-workspace-detection.local.json` | **No** — machine-specific state. |
| `a365.generated.config.json` | **No** — generated tenant identifiers. |
| `.env` | **No.** |

Committing the kit is the recommended end state: the skills then travel with the repository, and nobody else has to download anything.
