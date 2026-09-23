# .NET Agent 365 local lab

Optional extended starter for this local bundle revision. It preserves the console
word-count example and adds opt-in model-provider selection, authenticated Teams
hosting, Work IQ, an agent mailbox, Purview checks, and offline regression fixtures.
It is not pre-onboarded, a multi-user production host, or proof of tenant entitlement.
It is an unconfigured system-agent, OBO-oriented starter. Confirm the intended
identity/auth mode with the operator; shipped optional host/telemetry classes do
not mean those capabilities have already been configured.

## Offline first

From this prepared workspace with the .NET 8 SDK:

```powershell
dotnet restore --locked-mode
dotnet run -- --self-test
dotnet run -- --mock "Hello from Agent 365"
.\Test-Agent365TokenPlan.ps1
```

These checks do not contact models or tenant services. They exercise SDK tool loops,
identity/token guards, HTTP contracts, tracing scopes, DLP boundaries, and lab limits.

## Model-only live mode

Copy `.env.example` to `.env` only if `.env` does not exist. Set `MODEL_PROVIDER` to
`mistral`, `openai`, or `gemini`, and supply that provider's key/model. No key is
automatically reused for a different provider. Model availability, quota and billing
are external prerequisites. The listed model IDs are defaults, not entitlements.

```powershell
dotnet run -- --live "Count the words in Hello Agent 365"
```

Live inference sends content to the selected provider and may be billed. Purview
applies when explicitly enabled; it is disabled in the shipped environment example.

## Register and establish local identities

Follow the kit's `a365-setup` playbook and
`.a365-kit\shared\local-runtime-lessons.md`. Do not use a made-up tenant/app ID.
After the CLI has generated configuration, initialize local runtime identity:

```powershell
.\Initialize-LocalAgent.ps1 -ExpectedUser "<operator UPN>" -AgentIdentityId "<child agent appId>"
```

The helper checks the active operator, child-to-blueprint binding, and the reviewed
tenant-owned public client. Specify `-OperatorClientAppId` when discovery is ambiguous.
It refuses to overwrite an existing local config. The child override protects
runtime identity when endpoint/publish commands restamp generated settings.

To use an agent's own mailbox, provide `-AgentMailboxUserId` at initialization.
The helper verifies its linked instance belongs to the blueprint. Verify Exchange
service-plan/mailbox provisioning separately. Without that choice, Mail tools use
the operator's delegated identity. Other tools remain operator-delegated.

## Work IQ and telemetry

Use the CLI's live catalog and `add-workiq-tools` to create `ToolingManifest.json`
and grant approved permissions. Do not copy catalog URLs/audiences from another tenant.

```powershell
.\Refresh-Agent365Tokens.ps1 -PlanOnly
.\Refresh-Agent365Tokens.ps1
dotnet run -- --a365-check
```

Refresh groups enabled scopes by audience. `-Servers` refreshes selected resources;
`-TelemetryOnly` refreshes only the user-to-blueprint assertion. SDK-managed Mail
does not use a human device-code token. Tokens are local and git-ignored.
The runtime uses the exact configured account/client's encrypted cache for silent
renewal where possible and never falls back to another user/mailbox.

The check discovers tools and emits synthetic telemetry without invoking Work IQ
tools or calling a model. HTTP 200 with rejected/unrouted spans is a failure.
Portal visibility is a separate check. Work IQ is optional: absent tooling manifests
are reported as not configured, not as successfully connected.

Add unavailable servers to `Agent365Local:DisabledWorkIqServers` only by explicit
operator choice; they remain in the CLI-owned manifest. Do not bypass tenant policy.

## Teams test host

```powershell
dotnet run -- --teams
```

The host binds to loopback PORT (default 5000), requires signed JWTs on `/api/messages`,
and accepts only the configured operator and tenant. Known Microsoft Messaging Bot
delivery is distinguished from the human sender. Health is public.
Never remove the owner guard while retaining operator-scoped credentials.

Follow `add-messaging-endpoint` for a dev tunnel (HTTP port protocol), endpoint
registration, Developer Portal verification, current CLI package-format validation,
admin upload/activation and a real Teams reply. Use actual tunnel output, not a
name-derived URL. Keep host and tunnel processes running.

## Mail

Mail tool names are namespaced, e.g. `MailTools_SendEmailWithAttachments`.
Ask for clear recipient/subject/body details and report real tool outcomes only.

```powershell
dotnet run -- --mail-diagnose
```

This is a billable routing-only model probe with synthetic data and tool execution
disabled. It does not send an email. Verify any real send only with explicit approval.
Sent Items and a Delivered trace can still lead to recipient Junk/quarantine.
`Trace-DiagnosticMail.ps1` requires the exact approved sender, recipient and message ID.

## Purview

Confirm the protected app location separately from the OAuth client. Grant the two
runtime Graph scopes with an active authorized admin role; management permissions
must not be granted to the runtime agent. See `Grant-PurviewPermissions.ps1`.

Set `ENABLE_PURVIEW_DLP=true`, the confirmed `PURVIEW_APP_LOCATION_ID`, and an explicit
`PURVIEW_FAIL_MODE=open` or `closed`, then restart the host.
Prompt/reply hooks apply to Teams and both live console modes. Fail-open warns and
allows API/token errors; returned policy blocks always win.

```powershell
dotnet run -- --dlp-check
```

Collection/evaluateOffline is not inline blocking. Confirm billing and app-targeted
Applications/Application policy rules using current Purview PowerShell guidance.
The policy helper defaults to inspection and refuses to overwrite existing names.
Test a benign prompt and synthetic policy-matching content before claiming enforcement.
Tool arguments/results and external egress are not protected by these two hooks.

## Local files and compatibility

Never commit `.env`, `appsettings.json`, generated identity config, `.a365-runtime.local.json`,
or `.a365-tokens.local.json`. No tenant/operator IDs or tokens are shipped.
The runtime uses the pinned SDK matrix in the lockfile; do not substitute latest packages.
The encrypted-cache compatibility bridge uses a deprecated Azure Identity credential
with explicit account/client selection; migrate deliberately rather than replacing it
with a default credential that might choose a different account.

The .NET live patterns were exercised in a single local test deployment. The generic
version is validated offline; no claims are made about another tenant's consent,
mail delivery, policy coverage, billing, licences or production security.
