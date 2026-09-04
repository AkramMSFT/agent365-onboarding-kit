---
name: add-messaging-endpoint
description: >
  Makes an already-registered, blueprint-based (non-AI-Teammate) Agent 365 agent reachable
  from Microsoft Teams and Microsoft 365 Copilot. Adds an HTTP hosting layer serving
  /api/messages (Python aiohttp, Node.js Express, or ASP.NET Core), exposes it through a dev
  tunnel or a cloud URL, registers the endpoint on the blueprint with
  `a365 setup blueprint --update-endpoint ... --m365`, and hands off the one step that needs
  the Windows broker (`a365 setup permissions bot`). Use when the agent was onboarded with
  make-a365-agent and has no host, when "completed" is false in a365.generated.config.json,
  or when the user says "make this agent chattable in Teams". Not for AI Teammates -- their
  hosting layer comes from make-ai-teammate. Kit add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: public HTTPS URL if already hosted"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
hooks:
  preToolUse:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/preToolUse/path-guard.js"
      timeout: 5000
  stop:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/stop/validate-add-messaging-endpoint.js"
      timeout: 15000
---

# Add a messaging endpoint (Teams / Copilot reachability)

> **Trigger phrases:**
> - "make this agent chattable in Teams"
> - "add a messaging endpoint"
> - "expose this agent to Teams and Copilot"
> - "add the hosting layer"
> - "register the endpoint"

> **This is a kit add-on**, written and verified by the Agent 365 Onboarding Kit against a real tenant on 2026-09-04. It is not one of Microsoft's seven skills. Report issues to the kit repository, not upstream.

## Why this exists

`make-a365-agent` registers a blueprint-based agent and asks for a messaging endpoint, but it **does not create the HTTP host** -- it assumes one already listens on port 3978. An agent that started life as a CLI, a script, or a library therefore ends up registered but unreachable, with `completed: false` in `a365.generated.config.json`. This add-on closes that gap without changing the agent's identity model.

**Not for AI Teammates.** If `.a365-workspace-detection.local.json` says `agentType: ai-teammate`, stop and tell the user: *"AI Teammates get their hosting layer from `make-ai-teammate` Phase 9. This add-on is for blueprint-based agents."*

---

## Phase 0 -- Detect state (read-only)

1. **Read** `.a365-workspace-detection.local.json`. Require `agentType` = `system-agent` (or absent with `a365.config.json` showing `aiTeammate: false`). Note `programmingLanguage`.
2. **Read** `a365.generated.config.json`. Capture `agentBlueprintId`, `messagingEndpoint`, `completed`. If it does not exist, stop: *"Run `a365-setup` first -- there is no blueprint to attach an endpoint to."*
3. **Detect an existing host** by language:
   - Python: `host_agent_server.py` at the root, or any `.py` containing `/api/messages`.
   - Node.js: `src/index.ts` (or `.js`) containing `/api/messages`.
   - .NET: `Program.cs` containing `MapAgentApplicationEndpoints` or `/api/messages`.
4. **Detect the port.** `PORT` in `.env`, else language default (3978 Python/Node, 5000 .NET). Check it is free:
   - Windows: `netstat -ano | findstr :<port>` -- macOS/Linux: `lsof -i :<port>`.
   If taken, choose the next free port and write `PORT=<n>` to `.env`. Do not stop another process.

Tell the user what you found in three lines: agent kind, host present or not, port.

## Phase 1 -- Add the hosting layer (skip if a host exists)

**Read** the reference for the detected language and follow it exactly:

- Python: `.a365-kit/addons/add-messaging-endpoint/references/python-messaging-endpoint.md`
- Node.js: `.a365-kit/addons/add-messaging-endpoint/references/nodejs-messaging-endpoint.md`
- .NET: `.a365-kit/addons/add-messaging-endpoint/references/dotnet-messaging-endpoint.md`

Rules that apply to every language:

- **Never modify the file the onboarding skills generated for the agent's logic.** Put the host and any adapter in new files that import it.
- Add the hosting packages to the dependency file **and run the install** -- the onboarding skills edit the file without installing; do not repeat that.
- Keep `/api/health` unauthenticated and JWT-protect `/api/messages`.

## Phase 2 -- Start the host and prove the wiring

Start the host in the background, then check, in this order:

```bash
curl -s http://localhost:<port>/api/health          # expect 200
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:<port>/api/messages \
  -H "Content-Type: application/json" -d '{"type":"message","text":"hi"}'
```

The POST **must return 401**. That is the JWT middleware rejecting an anonymous call and is the proof the pipeline is wired. A 200 here means auth is off; a 500 means the middleware was handed the raw config instead of the resolved `AgentAuthConfiguration` (Python) -- see the reference.

If the host exits on startup with `AttributeError: ... 'MsalConnectionManager' has no attribute 'from_environment'` (Python) the host was written against a pre-1.6 SDK; the reference has the current pattern.

## Phase 3 -- A public HTTPS URL

Ask the user (AskUserQuestion):

> Where should Teams reach this agent?
> 1. **Dev tunnel** -- for development now; free; disappears when the session closes
> 2. **Already hosted** -- I have a public HTTPS URL

**Option 1 -- dev tunnel.** Verify `devtunnel --version`; if missing: Windows `winget install Microsoft.devtunnel`, macOS `brew install --cask devtunnel`, Linux `curl -sL https://aka.ms/DevTunnelCliInstall | bash`. Verify `devtunnel user show`; if not signed in, `devtunnel user login` and wait for the user. Then, idempotently (treat "already exists" as success):

```bash
devtunnel create <agent-name>-tunnel --allow-anonymous
devtunnel port create <agent-name>-tunnel -p <port> --protocol http
devtunnel host <agent-name>-tunnel        # run in the background; keep this session open
```

`--protocol http` is required -- without it the relay attempts TLS to the plain-HTTP host and Teams sees 502. **Take the public URL from the `Connect via browser:` line that `devtunnel host` prints** (`https://<id>-<port>.<cluster>.devtunnels.ms`). Do not build it from the tunnel name: the cluster is assigned at creation, and a deleted-and-recreated tunnel can land in a different cluster, so a name-derived URL silently stops resolving and the registered endpoint goes dark. Then prove it end to end:

```bash
curl -s https://<tunnel-url>/api/health      # expect the same 200 as locally
```

**Option 2.** Take the URL; it must be HTTPS and end in `/api/messages` when registered. `curl` its `/api/health` before continuing.

## Phase 4 -- Register the endpoint on the blueprint

```bash
a365 setup blueprint --update-endpoint https://<host>/api/messages --m365
```

**`--m365` is required.** Without it the CLI silently skips the Teams Graph registration and Teams keeps routing to nothing. Run it unconditionally even if the config already shows the value -- the disk copy can be stale, and it is idempotent.

**This command runs fine from inside your shell** (verified): it authenticates with the cached Azure CLI context and never touches the Windows broker. Expect `Registered successfully`, a re-stamped `.env` (a user-added `PORT` line survives), and `a365.generated.config.json` now showing the endpoint with `completed: true`. Re-read the file and confirm both to the user.

## Phase 5 -- Hand off the one step that needs the broker

Blueprint-based agents need the Messaging Bot API grant. **This half-completes from an agent's shell** -- inheritable permissions land, then the OAuth2 grant fails with `MSAL authentication failed: Unknown Status: 17` and a `[y/N]` prompt gets EOF. Do not run it. Tell the user verbatim:

> One command needs your own terminal, in this folder. It creates the Messaging Bot API grant and asks before adding an application permission -- answer `y`:
>
> ```
> a365 setup permissions bot
> ```
>
> Then verify in the Teams Developer Portal that **Agent Type = API Based** and **Notification URL** = `<messagingEndpoint>`:
> `https://dev.teams.microsoft.com/tools/agent-blueprint/<agentBlueprintId>/configuration`

Wait for the user to confirm both before Phase 6.

## Phase 6 -- Package for Teams and Copilot

**Verified on a real run: an endpoint alone does not make the agent visible in Teams.** It needs the app package uploaded and activated in the admin centre, on this path as much as for an AI Teammate. Plain `a365 publish` refuses here because `a365.config.json` says `useBlueprint: true`; the flag below selects the package format without changing the agent's kind (confirm afterwards that `aiTeammate` is still `false` in `a365.config.json`).

`a365 publish` block-buffers under chat tools, so **hand it to the user** verbatim:

> Package it, in your own terminal in this folder:
>
> ```
> a365 publish --aiteammate true
> ```
>
> It writes `manifest/manifest.json` and `manifest/manifest.zip`. If you want a better display name (`name.short`, 30 chars max), description or icons, edit `manifest/manifest.json` and run it again. Then paste the last lines of its output back here.

When the user reports success, **Read** `manifest/manifest.json` and confirm: `id` equals `agentBlueprintId`, and `agenticUserTemplates[0]` points at `agenticUserTemplateManifest.json` whose `agentIdentityBlueprintId` is the same id. Report `name.short` and its length.

Then hand off the upload:

> An admin uploads `manifest/manifest.zip` at **Microsoft 365 admin center → Agents → All agents → Upload custom agent**, activates it for an audience (start with yourself), and creates the instance if offered. It can take a few minutes to appear in Teams.

## Phase 7 -- Smoke test

**AgentsPlayground** works before the upload (no Teams needed; the npm package is `@microsoft/m365agentsplayground` -- the name some references give, `@microsoft/agentsplayground`, does not exist):

```bash
npm install -g @microsoft/m365agentsplayground
agentsplayground
```

Connect to `http://localhost:<port>/api/messages`, send *Hello*. Watch the host log for `process_user_message called` (Python) or the equivalent.

**Teams** (after the upload and activation): search for the agent by name and send *Hello*. If it is not listed, the package has not been uploaded or activated. If it is listed but nothing reaches the host, the Notification URL does not match `messagingEndpoint` -- re-run Phase 4 and re-verify the portal.

## What this add-on does not do

- It does not run `a365 publish` or upload the package: the first block-buffers under chat tools and the second has no API. It prepares everything and hands both to the user with exact instructions.
- It does not change auth mode or identity. The agent keeps the OBO/S2S model `make-a365-agent` set up; `--aiteammate true` on `publish` is a package-format switch only.
- It does not stop other processes to free a port; it picks another port.

## Summary to show the user

```
Host          <file>  on port <n>   health 200 / anonymous POST 401
Public URL    <url>                 (dev tunnel -- keep this session open | hosted)
Endpoint      registered on blueprint <id>   completed: true
Your steps    1. a365 setup permissions bot      2. Dev Portal check
              3. a365 publish --aiteammate true  4. admin centre: upload, activate
Next          agentsplayground now; Teams after step 4
```
