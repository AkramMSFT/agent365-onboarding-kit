---
name: add-purview-dlp
description: >
  Adds Microsoft Purview runtime data-loss prevention to an Agent 365 agent so every prompt
  (uploadText) and every response (downloadText) is evaluated against the tenant's DLP,
  sensitivity and collection policies, with block-on-policy and Insider Risk Management
  feeding. Two Microsoft Graph REST calls, no SDK dependency, so the same pattern applies
  to Python, Node.js and .NET. Grants the two delegated scopes the agent identity needs,
  wires the hooks into the turn, and hands off the portal-only policy setup. Use when the
  user says "add DLP", "add Purview", "govern prompts and responses", or "make this agent
  visible to Insider Risk". Kit add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: agent identity appId (Purview app location)"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
hooks:
  preToolUse:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/preToolUse/path-guard.js"
      timeout: 5000
  stop:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/stop/validate-add-purview-dlp.js"
      timeout: 15000
---

# Add Purview runtime DLP

> **Trigger phrases:**
> - "add DLP to this agent"
> - "add Purview"
> - "govern the prompts and responses"
> - "make this agent visible to Insider Risk Management"

> **This is a kit add-on.** The Python implementation is adapted from the Agent 365 + Claude reference deployment that ran against a live tenant; the .NET and Node.js ports are the same two REST calls. Not one of Microsoft's seven skills.

## What it does, in one paragraph

Inference runs outside the Microsoft 365 compliance boundary -- at OpenAI, Anthropic, or your own model host. Purview cannot see it unless the agent asks. So on each turn the agent calls Graph twice: `dataSecurityAndGovernance/protectionScopes/compute` once per user (which policies apply, plus an ETag), then `dataSecurityAndGovernance/processContent` for the prompt (`uploadText`) and for the response (`downloadText`). Purview returns `policyActions`; `restrictAccess/block` means the agent must not proceed. Either way the content lands in Activity Explorer and, with a Risky Agents policy, in Insider Risk Management and Defender XDR.

## Phase 0 -- Detect (read-only)

1. **Read** `.a365-workspace-detection.local.json` for `programmingLanguage`, `agentType`, `authMode`.
2. **Find the agent identity's appId** -- this is the Purview *app location* that policies target:
   - Blueprint-based (`agentType: system-agent`): `agenticAppId` in `a365.generated.config.json`. The identity was created at setup.
   - AI Teammate: the instance identity, created when the admin made the instance. Find it: `az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=servicePrincipalType eq 'ServiceIdentity' and startswith(displayName,'<agent name>')&\$select=appId,displayName"`. If none exists yet, stop: *"DLP targets the agent's identity, which does not exist until the instance is created (LIFECYCLE Phase D2). Do that first."*
3. **Auth mode matters.** The Graph calls need a *delegated* token for the identity the URL addresses. With `obo` / `agentic-user` the agent exchanges a token via its auth handler -- the pattern below. With `s2s` there is no per-user delegated token; tell the user DLP on the S2S path needs a different token strategy and stop unless they want to proceed with a service-principal token they supply.
4. Detect whether DLP is already wired: a file named `purview_dlp.py` / `purview-dlp.ts` / `PurviewDlp.cs`, and `uploadText` + `downloadText` in the agent code. If both present, report and skip to Phase 4.

## Phase 1 -- Grant the two scopes on the identity

The identity service principal needs delegated `ProtectionScopes.Compute.User` and `Content.Process.User` on Microsoft Graph. Instances do not inherit the blueprint's grants, so this is per identity. Requires an `az login` that can create `oauth2PermissionGrants` (Application Administrator or above).

```bash
APP=<identity appId>
SP=$(az ad sp show --id $APP --query id -o tsv)
GRAPH=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
# existing grant from this SP to Graph?
GRANT=$(az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$SP' and resourceId eq '$GRAPH'" --query "value[0]" -o json)
```

If `GRANT` is non-empty, **PATCH** its `scope` to the existing value plus the two scopes (never drop existing ones). Otherwise **POST**:

```json
{ "clientId": "<SP>", "consentType": "AllPrincipals", "resourceId": "<GRAPH>",
  "scope": "ProtectionScopes.Compute.User Content.Process.User" }
```

to `https://graph.microsoft.com/v1.0/oauth2PermissionGrants`. Re-query and show the user the resulting `scope` string. This step uses the Azure CLI context only; it does not need the Windows broker.

## Phase 2 -- Configuration

Append to `.env` (or `appsettings.json` for .NET) if absent:

```
ENABLE_PURVIEW_DLP=true
PURVIEW_APP_LOCATION_ID=<identity appId>
PURVIEW_FAIL_MODE=open        # open = allow on API/token error and log; closed = block
```

Recommend `open` for the first deployment: a Purview outage should cost governance, not availability. Explain the trade-off in one line.

## Phase 3 -- Code

**Read** the reference for the language and follow it exactly:

- Python: `.a365-kit/addons/add-purview-dlp/references/python-dlp.md`
- Node.js: `.a365-kit/addons/add-purview-dlp/references/nodejs-dlp.md`
- .NET: `.a365-kit/addons/add-purview-dlp/references/dotnet-dlp.md`

Three invariants, every language:

1. **The URL's `users/{id}` must be the token's subject** (`oid` claim), not the human caller's id. The token the agent exchanges resolves to the *agent identity*; addressing the caller yields Graph 400 *"UserId in token didn't match the UserId in the request uri"*. Read the `oid` from the token; do not assume.
2. **Two hook points**: evaluate the prompt before the model call (`uploadText`, sequence 0) and the response after it (`downloadText`, sequence 1), sharing one `correlationId` per turn (the conversation id).
3. **Never crash the turn on a governance call.** Errors follow `PURVIEW_FAIL_MODE`.

Put the DLP module in a new file; edit the agent's turn handler only to add the two calls and the block check. If the host add-on's `_run_turn` exists, that is the right place.

## Phase 4 -- Verify

1. Run the validator: `node .a365-kit/hooks/stop/validate-add-purview-dlp.js` -- module present, both activities referenced, env set.
2. **Live scope check** (proves grant + identity + URL): with the host running, send one message and look for the log line `Purview protectionScopes/compute -> 200: N scope(s)`. `N = 0` is correct until a policy targets the app location -- it means the calls work and nothing is scoped yet.
3. Hand off the portal steps (below), then re-send a message and expect `N >= 1` and a `processContent` line with `state=` and any `policyActions`.

## Phase 5 -- Portal steps (hand off; no API)

Tell the user, verbatim:

> In **Microsoft Purview** (`https://purview.microsoft.com`):
> 1. **Settings → Audit** -- make sure auditing is on.
> 2. **Data Loss Prevention → Collection policies** -- create a policy that captures AI app interactions (**UploadText** and **DownloadText**) scoped to the agent's app location `<identity appId>`, so prompts and responses appear in Activity Explorer.
> 3. **Insider Risk Management → Policies** -- new policy from the **Risky Agents (preview)** template; scope its Agents to all or to this agent; enable the **Exposing agent to risky prompt** indicator.
> 4. **IRM settings → Defender XDR alert sharing** -- on.
>
> Allow up to 24 hours for the first offline evaluation. To block rather than record, add a DLP policy with a **Restrict access** action targeting the same location -- the agent already honours `restrictAccess/block`.

## Summary to show the user

```
Identity (app location)   <appId>
Grants                    ProtectionScopes.Compute.User  Content.Process.User   on <SP>
Config                    ENABLE_PURVIEW_DLP=true  PURVIEW_FAIL_MODE=<mode>
Code                      <module>  hooks: uploadText -> model -> downloadText
Verified                  protectionScopes/compute -> 200 (<N> scopes)
Your step                 Purview Collection policy + Risky Agents IRM policy (portal)
```
