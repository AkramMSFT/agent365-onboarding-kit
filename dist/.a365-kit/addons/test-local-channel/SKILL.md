---
name: test-local-channel
description: >
  Adds a local dev channel so an agent can be chatted with on the developer's own machine
  with no tenant, no dev tunnel, no published manifest and no Teams. Covers the
  blueprint / OBO path, which Microsoft's test-local skill does not: that skill targets AI
  Teammates. Binds a separate loopback-only port, gated behind A365_DEV_CHANNEL=true and
  off by default, and leaves the real /api/messages endpoint fully authenticated. Use when
  the user says "let me test this agent locally", "I can't set up a tunnel", "test without
  Teams", or is blocked from reaching the tenant. Kit add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: port for the dev channel (default 3999)"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
---

# Test an agent through a local dev channel

## When this applies

Microsoft's `test-local` skill opens AgentsPlayground against a running agent, and is written
throughout for the **AI Teammate** path. Agents on the blueprint / OBO path are not covered,
and they are the ones that need it most: their host rejects every unauthenticated request, so
nothing local can talk to them without a Bot Framework token.

Reach for this skill when the user wants to exercise the agent and any of these is true:

- no dev tunnel is possible — corporate network, no `devtunnel` access, offline
- the agent is not published yet, so Teams cannot reach it
- they want a fast loop while changing agent logic, without a tenant round trip

If the agent is an AI Teammate and a tunnel is available, use `test-local` instead.

## The security shape, and why it is not the obvious one

The dev channel bypasses authentication. Three things keep that off the public path, and the
third is the one that matters most.

1. **Off unless asked.** Nothing binds unless `A365_DEV_CHANNEL=true`.
2. **Its own loopback-bound port.** The dev channel listens on `127.0.0.1` on a separate
   port. `/api/messages` is untouched and stays fully authenticated.
3. **Requests carrying forwarding headers are refused.**

Rule 3 exists because the obvious guard does not work. `devtunnel host` runs on the
developer's own machine and forwards to a local port, so a request that arrived from the
public internet still reaches the process with a client address of `127.0.0.1`:

```
local request  ->  peer=127.0.0.1  xff=None
via tunnel     ->  peer=127.0.0.1  xff=40.65.108.177
```

A "loopback only" check would pass tunnelled traffic. The forwarding headers the relay adds
are the only reliable difference, and they are used to **deny**, never to grant — the safe
direction to trust a header in.

**Never present the loopback bind alone as the protection.** Say plainly that the flag must
not be set outside local development and the dev port must never be tunnelled.

## Phase 0: Check what you are working with

1. **Read** `a365.generated.config.json`. Note whether this is a blueprint agent.
2. **Glob** for the host: `host_agent_server.py`, `src/index.ts`, `Program.cs`, or the
   Java `AgentHost`. If there is no host at all, the agent is not reachable by anything —
   run `add-messaging-endpoint` first, then come back.
3. Detect the stack and pick the matching reference:
   - `.a365-kit/addons/test-local-channel/references/python-dev-channel.md`
   - `.a365-kit/addons/test-local-channel/references/nodejs-dev-channel.md`
   - `.a365-kit/addons/test-local-channel/references/dotnet-dev-channel.md`

**TaskCreate** — "Add a local dev channel"

## Phase 1: Add the module

Write the dev-channel module from the reference and start it from the host's existing
startup path, next to where the production listener is bound. It returns immediately without
binding when the flag is absent, so the call is safe to leave in permanently.

Wire its `answer` callback to the same function the production handler calls. The point is to
exercise the real agent, not a copy of it — if the dev channel calls something else, it
proves nothing.

## Phase 2: Add the environment keys

Add to `.env`, both switched off:

```
A365_DEV_CHANNEL=false
A365_DEV_CHANNEL_PORT=3999
```

**Write `false`, not `true`.** The user turns it on for a session when they want it. This is
the one env value in the kit that must not default to on — the opposite of the observability
exporter, and for the opposite reason.

Add the same two keys to `.env.example` if the project has one.

## Phase 3: Prove all four behaviours

Start the agent with the channel on:

```bash
A365_DEV_CHANNEL=true <the project's normal start command>
```

Then check every one of these, and report the results:

| Check | Expected |
|---|---|
| `curl -s http://127.0.0.1:3999/dev/health` | `200` |
| `curl -s -X POST http://127.0.0.1:3999/dev/chat -H "content-type: application/json" -d "{\"text\":\"hello\"}"` | `200` and the agent's reply |
| the same POST with `-H "X-Forwarded-For: 1.2.3.4"` | `403` |
| `curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:<prod-port>/api/messages` | still `401` |

Then restart **without** the flag and confirm the dev port refuses the connection.

If the production endpoint returns anything but 401 to an anonymous request, stop: the dev
channel has leaked into the authenticated path, which is the one outcome this design exists
to prevent.

## Phase 4: Offer AgentsPlayground

If the agent is an AI Teammate as well, AgentsPlayground can drive it over the standard
endpoint — `test-local` covers that and is the better tool. For a blueprint agent the dev
channel is the interactive surface; `curl` or any REST client works against `/dev/chat`.

## Phase 5: Validate

```bash
node .a365-kit/hooks/stop/validate-test-local-channel.js
```

**TaskUpdate** — Mark complete, and tell the user in one line that the channel is off by
default and how to turn it on for a session.
