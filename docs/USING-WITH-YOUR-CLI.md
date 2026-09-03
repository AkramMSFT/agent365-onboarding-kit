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

> **Verified:** **Claude Code** (all seven skills discovered, validators firing) and
> **GitHub Copilot CLI 1.0.81** (all seven listed as project skills; a dry run loaded
> `.a365-kit/skills/a365-setup/SKILL.md`, correctly detected Python + OpenAI Agents SDK +
> non-AI-Teammate, and routed to `make-a365-agent`).
>
> The other `.agents/skills/` CLIs are correct-by-construction — the directory is confirmed
> right by `gh skill install`, but no onboarding has been driven through them yet.

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

Copilot CLI discovers project skills from `.github/skills/`, `.agents/skills/`, **or** `.claude/skills/` — confirmed by `copilot skill --help`. The kit populates the last two, so there is nothing to install.

**1. Install the CLI** if you don't have it. `gh copilot` will not fetch it on `--help` or `--version`, so install it directly:

```bash
npm install -g @github/copilot
```

Then `copilot` is on your PATH, and `gh copilot` will use it too.

**2. Confirm the skills are visible** from your project root:

```bash
cd your-agent-project
copilot skill list
```

You should see all seven under **Project skills**. This is the fastest way to prove the kit landed correctly.

**3. Start onboarding:**

```bash
copilot
```

Then type the trigger phrase. Or in one line:

```bash
copilot -p "Onboard this agent to Agent 365." --allow-all-tools
```

`--allow-all-tools` is required for non-interactive mode. Prefer the interactive form for a real run so you can approve each step.

**Dry run first.** Denying the shell tool lets Copilot read your project and explain its plan without touching your tenant:

```bash
copilot -p "Onboard this agent to Agent 365. DRY RUN - do not run commands or modify files. Report which skill you selected, what you detected, and the steps you would perform." --allow-all-tools --deny-tool shell
```

Optionally add the instructions file for extra grounding. Not required — it repeats the skill catalogue and trigger phrases in the format Copilot reads by default:

```powershell
.\agent365-kit.ps1 -WireCopilot       # Windows
./agent365-kit.sh --wire-copilot      # macOS / Linux
```

This **creates `.github/copilot-instructions.md`, or appends to yours if you already have one.** It never overwrites project-owned instructions.

> Older `gh` shipped a `gh copilot` extension that only suggested shell commands and could not
> edit files — it cannot drive onboarding. Use `gh` 2.98+ or the standalone `copilot` CLI above.

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

## The one command you must run yourself

**`a365 setup all` cannot authenticate from inside any agentic CLI** — not Copilot, not Claude Code, not any of the others. This is a property of the a365 CLI, not the kit.

The CLI signs in through WAM, the Windows account broker, which needs an interactive desktop session with a window to attach its prompt to. A shell spawned by a coding agent's tool harness has neither. The failure looks like this, and no amount of re-authenticating elsewhere fixes it:

```
Connect-MgGraph: Authentication timed out after 120 seconds due to inactivity.
ERROR: MSAL authentication failed: Unknown Status: 17
Error: 0x80080300
```

Pre-authenticating with `Connect-MgGraph` or `az login` does **not** help — those populate different token caches. The a365 CLI has its own, and as of 1.1.221 it has no device-code or headless flag.

**What to do.** When your CLI reaches the point of running `a365 setup all`:

1. Copy the exact command from its approval prompt — the flags depend on the capabilities and auth mode you chose, so don't retype it from memory.
2. Decline it in the CLI.
3. Open a second, normal (non-elevated) terminal in the same project folder, paste the command, and answer its prompts — including the broker pop-up.
4. Back in your CLI: *"`a365 setup all` completed in a separate terminal. Read `a365.generated.config.json` and continue."*

It picks up the blueprint ID and carries on. The step takes under a minute once the prompt has a window to appear in.

## After a first run — two things to check

Verified on a real onboarding: the skills get the tenant side and the code scaffolding right, and leave two things for you.

**The packages aren't installed.** The skill edits `requirements.txt` (or `pyproject.toml`) but doesn't always run the install, so the new imports break the module until you do:

```bash
python -m pip install -r requirements.txt
python -c "import src.agent"        # or wherever your agent module lives
```

**Observability may be half-wired.** Run the validator; if it reports the exporter, token resolver and baggage present but no `InvokeAgentScope`, re-invoke the skill — it's idempotent and adds only what's missing:

```bash
node .a365-kit/hooks/stop/validate-instrument-observability.js
```

```
Add observability to this agent.
```

Then re-run the validator and the import check. Both must pass.

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
