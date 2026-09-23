---
name: grant-observability-access
description: >
  Checks and grants the Agent 365 observability permission (Agent365.Observability.OtelWrite
  on the Observability API, which some tenants show as "maven-prod") for an onboarded agent:
  the delegated consent on the blueprint and the application role on the agent identity, and
  on the blueprint when the agent's exporter signs in with the blueprint's own credentials
  (Java, Go, Rust, or any client-credentials exporter). Read-only check first; the grant needs
  an administrator signed in to az, who confirms it. Use when setup says "An administrator must
  grant the blueprint consent for maven-prod [Agent365.Observability.OtelWrite]", when span
  export returns 401 or 403, or when the user says "grant observability access", "fix the
  maven permission" or "the agent's telemetry is not authorised". Kit add-on, not part of
  Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: identity | blueprint | identity,blueprint"
allowed-tools: Read, Bash, AskUserQuestion
model: sonnet
hooks:
  preToolUse:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/preToolUse/path-guard.js"
      timeout: 5000
---

# Grant the Agent 365 observability permission

> **Trigger phrases:**
> - "grant observability access to this agent"
> - "fix the maven-prod permission"
> - "the blueprint needs consent for Agent365.Observability.OtelWrite"
> - "telemetry export returns 401 / 403"

> **This is a kit add-on.** It does what `a365 setup all` does for this one permission when the
> person running setup is a Global Administrator, and it hands the rest to an administrator
> when they are not. Not one of Microsoft's skills.

## What it grants, and to whom

| Grant | Needed by | Principal |
|---|---|---|
| Delegated consent for `Agent365.Observability.OtelWrite`, tenant-wide | OBO and agentic-user agents | the blueprint; agent identities inherit it |
| Application role `Agent365.Observability.OtelWrite` | S2S agents using the SDK token chain | the agent identity |
| Application role `Agent365.Observability.OtelWrite` | exporters that sign in with the blueprint's client id and secret | the blueprint |

The Java add-on's `TokenProvider` signs in as the blueprint, and so do the Go and Rust examples
when wired the same way. Their spans are rejected until the **blueprint** holds the role.

An Entra access package can deliver the same role with approvals and expiry. That is a
governance choice, not a requirement. `.a365-kit/shared/observability-access-package.md` covers it.

## Phase 1 -- Check (read-only)

1. Confirm `a365.generated.config.json` exists in the project root. Without it, stop: run
   `a365-setup` first.
2. Choose the principals:
   - `identity` by default.
   - Add `blueprint` when the project is Java, Go or Rust, or when its exporter reads the
     blueprint client secret (`AGENT365_CLIENT_SECRET`, `agentBlueprintClientSecret`).
   - Say which you chose and why.
3. Run the check. It only reads from Microsoft Graph:

   ```bash
   node .a365-kit/grant-observability.mjs --check --principals <choice>
   ```

   It uses the account `az` is signed in with. Exit 0 means everything is in place: stop here
   and tell the user. Exit 3 lists what is missing. Exit 2 is a sign-in or configuration problem;
   show the message, which names the fix.

## Phase 2 -- Grant (administrator)

The grant writes to the tenant, so an administrator signs in and confirms it, as with blueprint
and Agent ID creation. Tell the user, verbatim, filling in the principals:

> An administrator runs this in a terminal in this folder. It needs Global Administrator for the
> delegated consent; Application Administrator is enough for the application role alone.
>
> ```
> az login --tenant <tenantId from a365.config.json>
> node .a365-kit/grant-observability.mjs --grant --principals <choice>
> ```
>
> It shows what it will grant and asks before changing anything. If the account lacks a role,
> it prints an admin-consent link and a PowerShell alternative to hand to someone who has it.

If the signed-in user is that administrator and says so, you may run the command yourself with
`--yes` after they approve in chat. Never pass `--yes` without that approval.

Do not use `a365 setup all` again to fix only this permission: it can issue a new client secret.

## Phase 3 -- Verify

1. Run the Phase 1 check again. Every line must read `granted`.
2. If it reports `Inherited by agent identities  no`, the delegated consent will not reach agent
   identities. An Agent ID Administrator or Global Administrator re-runs the permissions step of
   `a365 setup`.
3. Restart the agent, so it requests a new token that carries the role, and send one message.
   The exporter should log a 2xx for the span batch. Activity can take several minutes to appear.

## Summary to show the user

```
Observability API     <display name> (<object id>)
Delegated consent     granted | missing        blueprint <appId>
Application role      granted | missing        agent identity <object id>
Application role      granted | missing | n/a  blueprint <object id>
Next                  restart the agent and send a test message
```
