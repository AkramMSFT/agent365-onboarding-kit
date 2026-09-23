# Agent 365 Onboarding Kit

## Observability consent administrator handoff

When setup reports:

```text
Custom permission configuration requires tenant admin action.
An administrator must grant the blueprint consent for maven-prod [Agent365.Observability.OtelWrite] via the Entra portal.
```

Have the administrator create an access package with **Resource: maven-prod**,
**Type: OAuthApplication**, **Sub Type: API**, and
**Role: Agent365.Observability.OtelWrite**. Create an initial policy, assign the
package to the correct blueprint, and wait until that assignment is **Delivered**
before resuming the affected setup step. Approval or policy creation is not delivery.
See [.a365-kit/shared/observability-access-package.md](.a365-kit/shared/observability-access-package.md).

Use `node .\.a365-kit\run-a365.mjs setup ...` for consent-aware setup in PowerShell
(Bash: `node ./.a365-kit/run-a365.mjs setup ...`), keeping the same approved arguments.
It preserves CLI failures and returns 2 for this pending handoff even if the CLI
returns zero. It does not create assignments or change permissions automatically.

Drop-in skills that walk your coding CLI through onboarding an agent to **Microsoft Agent 365** — registering it, giving it an Entra identity, instrumenting observability, and wiring WorkIQ tools.

No plugin install. No marketplace. Extract, then point your CLI at it.

The skills themselves are Microsoft's official [`agent365-skills`](https://github.com/microsoft/agent365-skills), repackaged so they load from a project folder instead of requiring a plugin install. See `.a365-kit/KIT-VERSION.json` for the exact upstream version bundled here.

## Prepare information and permissions

Have your project/stack/start command, target tenant/account, owner/sponsor, capability/auth-mode choices, and runtime model configuration ready. Model access can use an API key or supported inference-authorized identity; it is separate from your coding CLI subscription. For optional messaging/tools/DLP, also collect approved resources/scopes, hosting URL/port, publishing audience, policy owner and relevant licences/billing. Keep real credentials out of source control.

| Action | Required access or handoff |
|---|---|
| Extract/build/launch locally | Project filesystem and software-execution rights; no Entra administrator or Azure subscription role merely to copy the kit. |
| CLI readiness | Current documentation prefers Microsoft's managed client. Use a consented tenant-owned public client only if needed; never supply a client secret for the interactive public CLI client. |
| Register blueprint/identity | Agent ID Developer/appropriate ownership, or wider Agent ID administration. Client consent and runtime grants are separate; **OBO is not consent-free**. |
| Consent | The current CLI's automatic consent flow is Global Administrator-gated. Manual delegated consent can use an authorized app administrator; Microsoft Graph application consent needs a suitably privileged role such as Privileged Role Administrator. |
| Observability/Work IQ | Runtime grants, correct identity/data access, and applicable entitlements. Observability needs an assigned Agent 365/E7 user in the tenant; Work IQ requires the appropriate Copilot entitlement and delegated user context. |
| Publish/instance | Local ZIP creation is not approval. Current general Microsoft 365 agent-management roles are AI Administrator/Global Administrator; the chosen agent-user experience also needs its Frontier/service licences and tenant policies. |
| Purview | Both runtime API consent and Purview DLP policy authority, the correct user/application context, and any required PAYG billing. A collection/IRM policy or HTTP 200 alone is not blocking DLP. |
| Azure hosting, if chosen | Appropriate deployment RBAC; assigning runtime roles requires role-assignment authority separately. Hosting need not be on Azure. |

For current details, read [CLI setup](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/reference/cli/setup), [agent administrator roles](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms), and [custom-app Purview configuration](https://learn.microsoft.com/en-us/purview/developer/configurepurview). The repository README has the complete input checklist and permissions by onboarding step.

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

> **Windows:** use your normal interactive PowerShell for onboarding. Approve OS elevation only for installers that require it; elevated sessions can use a different profile, PATH or sign-in context.

**Required:** Node.js 18+, .NET SDK 8+ (not just the runtime), the `a365` CLI, Azure CLI, Git, and your chosen coding CLI.
**Also needed:** a Microsoft Agent 365 tenant with developer access.

**New Python AI Teammates:** the verified generated profile requires **Python 3.12** and the pinned Agent Framework/Agents SDK dependencies in its reference. Other Python framework examples are migration references, not verified scaffolds for that matrix. Existing apps should not be silently migrated. The Python host keeps `/api/messages` authenticated even in Development; unsigned AgentsPlayground requests return 401.

### Validate tenant/client readiness

Run the installed CLI's readiness check:

```bash
a365 setup requirements
```

If a custom client is required, manual configuration/delegated consent can use Cloud Application Administrator or Application Administrator; automatic creation/consent is currently Global Administrator-gated. Shared client readiness does not give every developer roles, resource consent or licences. Use an administrator handoff rather than granting the developer broad permanent privileges.

## 3. Start onboarding with your CLI

Three stages, each started by one phrase typed to your CLI. Stop at whichever finish line you need:

| Stage | You say | Then you, in your own terminal |
|---|---|---|
| **1. Register** — blueprint, identity, permissions, telemetry | *Onboard this agent to Agent 365.* | `a365 setup all …` when it asks (copy from the prompt); then install packages |
| **2. Chat** in Teams & Copilot | *Make this agent chattable in Teams.* (blueprint path) or *Make this agent an AI Teammate.* | review bot grants with the administrator, confirm a supported publishing experience, then package/upload/approve |
| **3. Govern** with Purview DLP | *Add DLP to this agent.* | authorized API consent, billing/entitlements and an app-scoped blocking policy via the documented Purview PowerShell workflow |

Between stages: *Validate A365 code.*, *Add observability to this agent.*, *Test this agent locally.*, *Update the Agent 365 kit.* The full sequence with every question and hand-off is `docs/STEP-BY-STEP.md` in the kit repository.

The Stage 1 phrase is the same everywhere:

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
copilot skill list     # fifteen skills in this build
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

## The one command you must run yourself

**Run interactive `a365 setup all` authentication in your own terminal.** Windows broker flows can fail in headless coding-agent shells with an authentication timeout or `MSAL ... Status: 17`. Azure CLI and A365 can use different token caches; follow the installed CLI's supported sign-in flow and tenant Conditional Access policy.

When your CLI reaches that command: **copy it exactly from the approval prompt, decline it, run it in a second normal terminal in the same folder, then tell your CLI to continue from `a365.generated.config.json`.** Under a minute once the prompt has a window to appear in.

## After a first run

Two things the skills leave for you — check both before calling it done:

1. **Install the packages.** The skill edits `requirements.txt` but doesn't always run the install. `pip install -r requirements.txt`, then confirm your agent module still imports.
   - **Python + WorkIQ:** if the import then fails with `No module named 'microsoft_agents_a365.runtime'`, add `microsoft-agents-a365-runtime>=1.0.0` to `requirements.txt` and install again. The `microsoft-agents-a365-tooling` wheel (1.0.0) imports it but doesn't declare it, so pip never pulls it in.
2. **Check observability is complete.** `node .a365-kit/hooks/stop/validate-instrument-observability.js` — if it reports no `InvokeAgentScope`, ask your CLI to *"Add observability to this agent"* and re-run the validator. The skill is idempotent; it adds only what's missing.

---

## After onboarding — making it chat in Teams and Copilot

Registration and reachability are separate. To answer in Teams/Microsoft 365 Copilot, the agent additionally needs hosting, a supported package, approval, audience policies and appropriate entitlements:

| Step | Command or place | Who |
|---|---|---|
| 1. Host `/api/messages` | AI Teammate path scaffolds it; otherwise add the hosting layer | you |
| 2. Public HTTPS URL | `devtunnel` for dev, any HTTPS host for prod | you |
| 3. Register the endpoint | `a365 setup blueprint --update-endpoint <url> --m365`; keep the flag explicit for compatibility, although current endpoint-only updates infer it. | authorized blueprint operator |
| 4. Bot API permissions *(blueprint-based / CEA)* | `a365 setup permissions bot`; review the actual Messaging Bot API/other resource grants before approval. | authorized consent administrator |
| 5. Manifest + package | `a365 publish` for the supported experience. `--aiteammate true` selects an AI Teammate template branch, not a universally neutral OBO conversion. | you, own terminal |
| 6. Upload, activate, create instance | Microsoft 365 admin-center approval and audience configuration; instance/user creation and service licences are separate and experience-dependent. | AI Administrator/GA and allowed requester, as applicable |
| 7. Test | `agentsplayground` (`npm i -g @microsoft/m365agentsplayground`) against your host; Teams chat; Copilot agent picker | you |

Like `a365 setup all`, run `a365 publish` and `a365 setup permissions bot` in your own terminal — the first block-buffers under chat tools, the second needs the Windows broker for its grant step.

> **If your generated Python host crashes on startup** with `AttributeError: ... 'MsalConnectionManager' has no attribute 'from_environment'`, the reference it was built from predates `microsoft-agents` 1.6. `docs/LIFECYCLE.md` C1 has the working 1.6 pattern.

The full walkthrough with every choice explained — agent kinds, identity, dev tunnel vs cloud, Purview DLP, teardown — is **`docs/LIFECYCLE.md`** in the kit repository.

## Keeping the kit current — from your CLI

Say *"update the Agent 365 kit"* (or run `.\agent365-kit.ps1 -Update` / `./agent365-kit.sh --update`). Only kit-owned files should be replaced. To use a mirror, set `-SetUpdateSource <zip-or-url>` or `A365_KIT_UPDATE_SOURCE`. Share a project configuration only if the URL/path is credential-free and approved for source control; this repository ignores `a365-kit.config.json` by default. *"Check the kit prerequisites"* and *"which kit version is installed"* work the same way.

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
with path rewrites so they load without a plugin install, plus itemised defect corrections.
`.a365-kit/NOTICE.md` lists every change and the failure it prevents. Microsoft's licence is in
`.a365-kit/LICENSE-agent365-skills` and the kit's in `.a365-kit/LICENSE`.
