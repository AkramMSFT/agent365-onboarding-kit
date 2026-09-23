# Purview DLP: kit notes

Read this with Microsoft's `purview-dlp-integration` skill, before its Step 2. It adds what the kit learned on live tenants. Where anything here seems to differ from the skill, the skill's guard, scripts and wiring win.

## Projects already wired by the kit

Kit 0.2.1 and earlier shipped an `add-purview-dlp` add-on with its own module and settings. Before copying the skill's guard, look for any of these:

- a module named `purview_dlp.py`, `purview-dlp.ts` or `PurviewDlp.cs`
- `ENABLE_PURVIEW_DLP` or `PURVIEW_APP_LOCATION_ID` in `.env`, `appsettings.json` or the host settings

If one is present, stop and ask the user which gate to keep. Never wire both: every prompt would be evaluated twice, DLP for AI apps is metered, and the two gates use different settings. To move to the skill's guard, remove the old module, its calls in the turn handler and its settings, then continue at Step 2. The old delegated grant included `ProtectionScopes.Compute.User`, which the skill's guard does not use; an administrator can remove it.

## What the gate does not inspect

The input gate evaluates the user's prompt before the model, and the optional output check audits the reply. Nothing in between is evaluated. When the agent also uses `add-mcp-server` or `add-lab-tools`, tool arguments and tool results reach the model with no Purview check. Say so in the summary, and do not describe the gate as a tool-boundary control or an egress filter.

## Match the application id

The guard sends `applicationLocation`, and a policy only matches when its Applications location contains the same app id. The guard defaults to `agentBlueprintId`. If the policy owner scoped a different app id, set `PURVIEW_APP_ID` to that value. Confirm the id with the policy owner rather than inferring it. A mismatch shows up as `allowed (... 0 policyAction(s) ... errors=0)` on every turn.

## Fail mode

`PURVIEW_FAIL_MODE=closed` is the default: a Purview error or timeout blocks the turn. `open` keeps the agent answering during a Purview outage, and those turns go unevaluated. Make that choice with the policy owner, record it in the summary, and never switch it to make a test pass.

## Admin roles

Each script needs a signed-in administrator whose role is active, not merely eligible. If the tenant uses Privileged Identity Management, activate the role first.

| Script | Typical role |
|---|---|
| `Grant-DelegatedGraphScope.ps1` | Cloud Application Administrator or Application Administrator |
| `Grant-ContentProcessAppRole.ps1` (S2S) | Privileged Role Administrator, because it grants a Microsoft Graph application permission |
| `New-AiAppDlpPolicy.ps1` | A Purview role with DLP Compliance Management, such as Compliance Administrator |

## Insider Risk visibility

The skill covers blocking and audit. For Insider Risk Management to see the agent, an administrator also needs to:

1. Turn on auditing in Purview under **Settings → Audit**.
2. Create an Insider Risk Management policy from the **Risky Agents (preview)** template, scoped to this agent, with the **Exposing agent to risky prompt** indicator.
3. Turn on **Defender XDR alert sharing** in the Insider Risk Management settings.

Audit records, collection and Insider Risk signals are not evidence that a blocking rule is in place. Only a synthetic matching prompt that is blocked before the model call proves that.
