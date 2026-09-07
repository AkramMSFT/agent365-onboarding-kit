# Security

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub's [security advisory](../../security/advisories/new) form rather than a public issue.

If the issue is in Microsoft's skills rather than this packaging, report it to Microsoft through the [Microsoft Security Response Center](https://msrc.microsoft.com/report). If you are unsure which it is, report it here and it will be forwarded.

## What this kit touches

Onboarding an agent to Agent 365 creates real objects in your tenant and writes real credentials to disk. Worth knowing before you run it:

- **`a365 setup all` creates an Entra app registration, a service principal and a client secret.** The secret is written into your project's configuration. Treat that project directory as credential-bearing: do not commit `.env` or `a365.generated.config.json`, and do not share them in screenshots or logs.
- **The prerequisite checker masks your tenant id** in its output, because it is frequently run on a screen share.
- **A messaging endpoint is public once tunnelled.** Any host serving `/api/messages` must validate the inbound bearer token. The generated hosts do; if you write your own, the token validation is not optional, and the kit's validators check for it.

## Guardrails in the kit

The bundled `path-guard.js` prevents a skill from writing outside your project or into the kit's own files. Upstream makes that check conditional on an environment variable set only by a plugin install, which means it silently disables itself in a drop-in install; this kit restores it. See section 3 of [`NOTICE.md`](NOTICE.md).

## Dual-use components

Two add-ons deliberately expand what an agent can reach. Both are opt-in and neither is installed unless you ask for it.

- **`add-lab-tools`** includes a web fetch and page summariser. That is outbound network access and a prompt-injection surface: content the agent fetches is untrusted input.
- **`add-mcp-server`** connects the agent to external Model Context Protocol servers. These are **not** registered in Agent 365 and **not** gated by Entra, so they sit outside the governance model the rest of the kit works within.

Both are worth pairing with `add-purview-dlp`, which evaluates every prompt and response against tenant policy. The add-ons say so in their own documentation.

## Supported versions

The kit tracks upstream `agent365-skills`. Fixes are applied to the current release; older release archives are not patched. If you mirror the kit internally, re-run the build against current upstream to pick up fixes.
