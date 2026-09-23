---
name: add-purview-dlp
description: >
  Adds Microsoft Purview processContent hooks for prompts (uploadText) and responses
  (downloadText), enforcing returned block actions where supported policies apply.
  Collection, Insider Risk visibility and blocking have separate policy and billing
  prerequisites. Two Microsoft Graph REST operations, no Graph SDK dependency; supports
  Python, Node.js and .NET. Grants the delegated scopes the actual OAuth client needs,
  wires the turn hooks, and hands off policy setup to an admin. Use when the
  user says "add DLP", "add Purview", "govern prompts and responses", or "make this agent
  visible to Insider Risk". Kit add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: protected Entra appId (confirmed Purview policy location)"
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

> **Kit runtime corrections:** Read `.a365-kit/shared/local-runtime-lessons.md` first.
> Check current/PIM admin roles as well as the management token's permission.
> Keep protected app, OAuth client and user oid separate. Reuse the extended
> .NET starter's pre-model/pre-send guard and stateful sequencing when present.
> `evaluateOffline`/200 is not inline blocking: inspect or create the approved
> app-scoped rule, then prove a benign allow and a synthetic block without model
> egress. Existing policy names are inspected, never overwritten implicitly.

> **Trigger phrases:**
> - "add DLP to this agent"
> - "add Purview"
> - "govern the prompts and responses"
> - "make this agent visible to Insider Risk Management"

> **This is a kit add-on.** The Python implementation is adapted from the author's own Agent 365 deployment (not published), which ran against a live tenant; the .NET and Node.js ports use the same two REST operations. Not one of Microsoft's skills.

## What it does, in one paragraph

Model traffic is not automatically evaluated by the tenant's Purview policies. The agent
uses two Graph **operations**: `dataSecurityAndGovernance/protectionScopes/compute` to obtain
the user's scopes and an ETag, then `dataSecurityAndGovernance/processContent` for the prompt
(`uploadText`) and response (`downloadText`). The first turn normally makes **three**
requests; cached scopes avoid recomputation until invalidated. Purview's `restrictAccess/block`
action means the agent must not proceed. Collection/IRM visibility also requires successful
processing and the corresponding tenant policies; a failed-open API call does not ingest
content. These two turn hooks do **not** inspect intermediate tool arguments or tool results.
The current [custom Entra-app DLP documentation](https://learn.microsoft.com/en-us/purview/ai-entra-registered)
documents sensitive-information **prompt blocking** and requires pay-as-you-go billing.
Sending responses to `processContent` does not establish universal response-blocking
coverage. Verify supported policies, billing and licensing with the tenant's policy owner;
collection/IRM ingestion is not evidence that blocking DLP is configured.

## Phase 0 -- Detect (read-only)

1. **Read** `.a365-workspace-detection.local.json` for `programmingLanguage`, `agentType`, `authMode`.
2. **Identify the OAuth client and confirm the protected app separately.**
   - For a blueprint-based agent (`agentType: system-agent`), inspect `agenticAppId` in
     `a365.generated.config.json` and the auth handler's actual token-exchange identity.
   - For an AI Teammate, inspect the instance identity created by the admin. A discovery
     query is `az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=servicePrincipalType eq 'ServiceIdentity' and startswith(displayName,'<agent name>')&\$select=appId,displayName"`.
     If the required OAuth client identity does not exist yet, complete instance creation first.
   - Confirm the **protected Entra application appId** used by the Purview policy's
     application location. That is `PURVIEW_APP_LOCATION_ID`; it is not a service-principal
     object ID or user ID, and need not equal whichever client/agent appId was discovered.
     The policy location and `protectedAppMetadata.applicationLocation` must match.
3. **Auth mode matters.** The generated wrappers implement the *delegated* `obo` /
   `agentic-user` path. With `s2s`, stop: Graph also documents application permissions, but
   app-only calls need an explicit target user and the corresponding application grant.
   Supplying an arbitrary service-principal token to this delegated wrapper is not that
   implementation. Do not use an app/service-principal `oid` as a `/users/{id}`.
4. Detect whether DLP is already wired: a file named `purview_dlp.py` / `purview-dlp.ts` / `PurviewDlp.cs`, and `uploadText` + `downloadText` in the agent code. If both present, report and skip to Phase 4.

## Phase 1 -- Grant the two scopes on the identity

The actual OAuth client's service principal needs delegated `ProtectionScopes.Compute.User`
and `Content.Process.User` on Microsoft Graph. Verify its effective permissions rather than
assuming a blueprint grant covers it. Both scopes require admin consent.

Grant management has **two** prerequisites: an authorized admin role (typically Cloud
Application Administrator or Application Administrator for these delegated grants, subject
to tenant consent policy), and a management client/token with permission to create
`oauth2PermissionGrants` (`DelegatedPermissionGrant.ReadWrite.All` is the documented
least-privileged permission). `az login` or an admin role alone does not supply that client
permission. If the Azure CLI context cannot perform the operation, use an approved,
consented admin client; do not grant this administrative permission to the runtime agent.
Graph **application** consent is a separate flow requiring an appropriately privileged
admin such as Privileged Role Administrator, not the delegated procedure below.

See [create oauth2PermissionGrant](https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-post).
Its `clientId` and `resourceId` are service-principal **object IDs**, not appIds.

```bash
APP=<OAuth client appId>
SP=$(az ad sp show --id "$APP" --query id -o tsv)
GRAPH=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
# existing grant from this SP to Graph?
GRANT=$(az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$SP' and resourceId eq '$GRAPH' and consentType eq 'AllPrincipals'" --query "value[0]" -o json)
```

If the parsed `GRANT` JSON is an object with an `id` (not the JSON value `null`),
**PATCH** its `scope` to the de-duplicated union of its existing scopes and the two scopes.
Never overwrite an unrelated per-user (`Principal`) grant or drop existing permissions.
Otherwise **POST**:

```json
{ "clientId": "<SP>", "consentType": "AllPrincipals", "resourceId": "<GRAPH>",
  "scope": "ProtectionScopes.Compute.User Content.Process.User" }
```

to `https://graph.microsoft.com/v1.0/oauth2PermissionGrants`. Re-query and show the user the resulting `scope` string. This step uses the Azure CLI context only; it does not need the Windows broker.

## Phase 2 -- Configuration

Append to `.env` (or `appsettings.json` for .NET) if absent:

```
ENABLE_PURVIEW_DLP=true
PURVIEW_APP_LOCATION_ID=<confirmed protected-app appId>
PURVIEW_FAIL_MODE=open        # open = allow on API/token error and log; closed = block
```

Recommend `open` for the first deployment: a Purview outage should cost governance, not availability. Explain the trade-off in one line.

## Phase 3 -- Code

**Read** the reference for the language and follow it exactly:

- Python: `.a365-kit/addons/add-purview-dlp/references/python-dlp.md`
- Node.js: `.a365-kit/addons/add-purview-dlp/references/nodejs-dlp.md`
- .NET: `.a365-kit/addons/add-purview-dlp/references/dotnet-dlp.md`

Three invariants, every language:

1. **For these delegated wrappers, `/users/{id}` is the token's user object ID** (`oid`),
   not a client/app ID, blueprint ID, or pairwise `sub`. OBO can represent the human caller;
   agentic-user auth can represent a different user. Do not assume either. Decoding the
   already-acquired token is only a routing hint, not a replacement for JWT validation.
2. **Two hook points**: evaluate the prompt before the model (`uploadText`) and the response
   before sending it (`downloadText`). The stateless examples use one fresh correlation ID
   per prompt/reply pair and sequences 0/1. Stateful conversations must keep a stable
   conversation correlation ID and monotonically increasing sequence numbers.
3. **Never crash the turn on a governance call.** Token, HTTP and processing errors follow
   `PURVIEW_FAIL_MODE`; `closed` must not silently allow a failed token exchange. Successful
   202/204 responses have no body. Disabled DLP is a deliberate bypass, not a successful check.

Put the DLP module in a new file; edit the agent's turn handler only to add the two calls and the block check. If the host add-on's `_run_turn` exists, that is the right place.

## Phase 4 -- Verify

1. Run the validator: `node .a365-kit/hooks/stop/validate-add-purview-dlp.js` -- module present, both activities referenced, env set.
2. **Live scope check** (proves grant + identity + URL): with the host running, send one message and look for the log line `Purview protectionScopes/compute -> 200: N scope(s)`. `N = 0` is correct until a policy targets the app location -- it means the calls work and nothing is scoped yet.
3. Hand off the portal steps (below), then re-send a message and expect `N >= 1` and a `processContent` line with `state=` and any `policyActions`.

## Phase 5 -- Policy setup (admin handoff)

Tell the user, verbatim:

> In **Microsoft Purview** (`https://purview.microsoft.com`):
> 1. **Settings → Audit** -- make sure auditing is on.
> 2. Follow the current [Purview API policy setup](https://learn.microsoft.com/en-us/purview/developer/use-the-api)
> for the confirmed protected-app location `<appId>` and **UploadText / DownloadText** collection.
> For blocking DLP rules on Entra-registered apps, the current documentation requires
> **`New-DlpComplianceRule` in Exchange Online PowerShell**; the portal does not create
> those app-targeted rules. Verify that the rule is enabled in **DSPM → Collection policies**.
> Use the documented **Applications** workload, the protected appId as the location, and
> **Application** enforcement plane; the older **Entra** enforcement plane is deprecated.
> Confirm the required pay-as-you-go billing and supported prompt-blocking policy coverage.
> 3. **Insider Risk Management → Policies** -- new policy from the **Risky Agents (preview)** template; scope its Agents to all or to this agent; enable the **Exposing agent to risky prompt** indicator.
> 4. **IRM settings → Defender XDR alert sharing** -- on.
>
> Allow time for the first offline evaluation. To block rather than only collect, the admin
> must configure a **Restrict access** rule for the same app location using the supported
> policy-management path above. The code honors `restrictAccess/block` when returned.

The REST contract and success codes are documented under
[processContent](https://learn.microsoft.com/en-us/graph/api/userdatasecurityandgovernance-processcontent).
No local validator proves tenant grants, policy coverage, Activity Explorer ingestion or IRM alerts.

## Summary to show the user

```
Protected app location   <confirmed appId>
Grants                    ProtectionScopes.Compute.User  Content.Process.User   on <SP>
Config                    ENABLE_PURVIEW_DLP=true  PURVIEW_FAIL_MODE=<mode>
Code                      <module>  hooks: uploadText -> model -> downloadText
Verified                  protectionScopes/compute -> 200 (<N> scopes)
Your step                 Admin: billing + supported blocking rule (PowerShell), collection/IRM policies
```
