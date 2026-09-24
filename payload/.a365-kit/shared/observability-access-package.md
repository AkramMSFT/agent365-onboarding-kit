# maven-prod observability consent: administrator handoff

Use this recovery workflow **when setup emits this specific message**:

```text
Custom permission configuration requires tenant admin action.
An administrator must grant the blueprint consent for maven-prod [Agent365.Observability.OtelWrite] via the Entra portal.
```

This is pending tenant administration, not evidence of a broken model, an invalid
API key, or a need to recreate the blueprint. Do not substitute this diagnosis for
unrelated 401/403 errors, token-identity mismatches, or missing licences.

## Grant it directly (recommended)

This is what `a365 setup all` does itself when a Global Administrator runs it. From the
agent project folder:

```
node .a365-kit/grant-observability.mjs --check
```

The check only reads. It reports the delegated consent on the blueprint and the application
role on the agent identity, plus the blueprint with `--principals identity,blueprint`, which
Java, Go and Rust exporters need because they sign in as the blueprint. An administrator then
signs in and grants what is missing, confirming at the prompt:

```
az login --tenant <tenant id>
node .a365-kit/grant-observability.mjs --grant --principals identity,blueprint
```

The delegated consent needs Global Administrator; the application role needs Application
Administrator or Global Administrator. Without the role, the tool prints an admin-consent link
and PowerShell to hand to someone who has it. Re-run `--check` afterwards and restart the agent.

## Or deliver it with an access package

Use this route when the tenant wants approvals, expiry or access reviews on the permission.
It needs Entra ID Governance licensing and a Global Administrator to add the API resource.

### Create and assign the access package

1. Have an authorized administrator sign in to [Microsoft Entra admin center](https://entra.microsoft.com)
   in the blueprint's tenant and open **ID Governance > Entitlement management >
   Access packages > New access package**. Select the appropriate catalog, name and
   description. If a suitable package already exists, inspect its resource, role,
   policy and assignment rather than creating duplicate assignments.
2. Add the resource role with these exact values:

   | Field | Value |
   | --- | --- |
   | Resource | `maven-prod` |
   | Type | `OAuthApplication` |
   | Sub Type | `API` |
   | Role | `Agent365.Observability.OtelWrite` |

   This is an **API permission** resource, not a similarly named application
   sign-in role. If the resource or role is not available, the catalog/tenant
   administrator must resolve that; do not invent IDs, rename another resource,
   or bypass the tenant's resource-owner controls.
3. **Create an initial policy** for the access package. It must allow the intended
   blueprint/service-principal assignment (including direct administrator assignment
   if that is the chosen workflow). Configure approvals, expiration and lifecycle
   according to the tenant's requirements; do not disable approval to speed up setup.
4. Under the access package's **Assignments**, create an assignment using that policy
   and select **the blueprint that requires consent**. Verify its application ID
   against `agentBlueprintId` in the CLI-generated `a365.generated.config.json` and
   the Entra blueprint. Do not select the interactive CLI app, human operator,
   unrelated agent user or a different child identity simply because a name matches.
5. **Wait for the blueprint's access-package assignment status to show `Delivered`.**
   Refresh the assignment/request details after a short wait. Propagation time varies:
   `Approved`, `Pending`, `Delivering`, or merely creating the policy is not enough.
   `Delivered` describes the resource assignment, not just the policy definition.
   If delivery stalls or fails, inspect **Requests/Assignments** and have the
   administrator resolve the delivery error before continuing.
6. After **Delivered**, resume the affected setup/permission step using the same
   blueprint and account, verify the effective permission, acquire a fresh runtime
   token if necessary, and check actual telemetry ingestion. Do not blindly rerun
   all provisioning: that can issue additional secrets. Do not edit generated
   manifests or mark local setup complete to work around pending delivery.

The exact `maven-prod` labels above are the requested operational recovery for this
message. Current Microsoft documentation describes the general agent/API access-
package workflow. It requires an appropriate active admin role and entitlement-
management availability; adding OAuth API resource roles can make the catalog
privileged and currently requires Global Administrator/resource-owner authorization.
Being an agent developer or having a token scope alone is not sufficient.

## Guarded setup command

From the prepared agent workspace, use the bundled runner in place of `a365` for
setup operations, retaining the same approved arguments:

```powershell
node .\.a365-kit\run-a365.mjs setup all --agent-name <your-agent-name> --dry-run
# Run this only after you review and approve the dry-run preview.
node .\.a365-kit\run-a365.mjs setup all --agent-name <your-agent-name>
```

In Bash use `node ./.a365-kit/run-a365.mjs setup ...`. Existing assistant choices
such as tenant, auth mode and M365 flags still apply; the runner does not choose them.
To view the handoff after a direct CLI call without rerunning provisioning:

```powershell
node .\.a365-kit\run-a365.mjs --explain-observability-consent
```

The runner forwards stdout/stderr and stdin, recognizes the resource-specific
message even with colored/chunked output, then prints the administrator steps.
It preserves a nonzero CLI exit status. If the CLI exits zero while emitting this
handoff, it returns **2 (administrator action pending)** so automation cannot
mistake the handoff for completed setup.

This runner does **not** create access packages, sign in, grant permissions, poll
assignments, persist command output, or bypass consent. Granting is done by
`grant-observability.mjs`, run by an administrator. Direct `a365` calls remain
unmodified. CLI behavior that depends on a TTY can differ because output is piped.
An assistant must still surface the same handoff when the message appears outside
the runner and must not report completion until delivery and the affected flow
have been verified.

## Sources and verification boundaries

- [Access packages for agent identities](https://learn.microsoft.com/en-us/entra/agent-id/agent-access-packages)
- [API permission resource roles](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-resources#add-an-api-permission-preview)
- [Direct assignments and Delivered state](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-assignments)

The bundle's offline tests verify message recognition, forwarding, exit-status
behavior and packaging. They do not prove that a customer's access package has
been created, assigned, or delivered, or that their exporter reaches the backend.
