---
name: add-mcp-server
description: >
  Connects an Agent 365 agent to an external / community MCP server -- anything beyond
  Microsoft's Work IQ set: filesystem, git, GitHub, Postgres/SQLite, web fetch and search,
  Slack, Playwright browser, memory, time, and any other Model Context Protocol server.
  Wires it as an stdio (npx/uvx) or streamable-HTTP server on the agent's framework, so its
  tools appear alongside the built-in, Work IQ and lab tools. Use when the user says "add an
  MCP server", "connect the filesystem/github/postgres MCP", "give the agent web search", or
  names any community MCP server. IMPORTANT: external MCP servers are NOT governed by Agent
  365's Entra model -- see the governance section. Supports Python, Node.js and .NET. Kit
  add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: the server (e.g. filesystem, github, fetch) or its command/URL"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
hooks:
  preToolUse:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/preToolUse/path-guard.js"
      timeout: 5000
  stop:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/stop/validate-add-mcp-server.js"
      timeout: 15000
---

# Add an external MCP server

> **Trigger phrases:**
> - "add an MCP server" / "connect the <name> MCP server"
> - "give the agent filesystem / git / github / postgres / web search / browser access"
> - "add a community MCP tool"

> **Kit add-on, and a governance boundary.** Work IQ MCP servers (`add-workiq-tools`) are
> registered in Agent 365 and gated by Entra per-tool consent. An **external** MCP server is
> not: the agent's framework connects to it directly, and the Agent 365 registry has no
> record of what it can do. That is a real change in the agent's risk surface. Add external
> servers only for agents you operate, prefer servers you trust or run yourself, treat their
> output as untrusted input to the model, and pair this with `add-purview-dlp` so the content
> flowing through the agent is still evaluated. Not part of Microsoft's seven skills.

## How external MCP differs from Work IQ

| | Work IQ (`add-workiq-tools`) | External MCP (this add-on) |
|---|---|---|
| Server | Microsoft-hosted, 9 fixed | any MCP server, anywhere |
| Transport | streamable-HTTP with per-audience OBO tokens | stdio (`npx`/`uvx`) or streamable-HTTP/SSE |
| Registered in Agent 365 | yes (`ToolingManifest.json`, Entra grants) | **no** |
| Governed by Entra consent | yes | **no** |
| Governed at runtime | observability + DLP | observability + DLP only if you added them |

Use Work IQ for Microsoft 365 data. Use this for everything else.

## A catalogue to offer

Widely-used servers, all runnable with no build via `npx -y` (Node) or `uvx` (Python). Present a few relevant ones; do not add any the user did not ask for.

| Server | Command (stdio) | Gives the agent | Notes |
|---|---|---|---|
| Filesystem | `npx -y @modelcontextprotocol/server-filesystem <dir>` | read/write files under one directory | scope to a single dir; never the drive root |
| Fetch | `uvx mcp-server-fetch` | fetch and convert a web page to markdown | web egress + injection surface, like lab `fetch_url` |
| Git | `uvx mcp-server-git --repository <path>` | inspect/commit a local repo | |
| GitHub | `npx -y @modelcontextprotocol/server-github` | issues, PRs, repo contents | needs `GITHUB_PERSONAL_ACCESS_TOKEN` |
| Postgres | `npx -y @modelcontextprotocol/server-postgres <conn>` | read-only SQL over a database | prefer a read-only role |
| SQLite | `uvx mcp-server-sqlite --db-path <file>` | query a local SQLite file | |
| Memory | `npx -y @modelcontextprotocol/server-memory` | a persistent knowledge graph | |
| Time | `uvx mcp-server-time` | timezone-aware date/time | harmless; good smoke test |
| Playwright | `npx -y @playwright/mcp` | drive a real browser | powerful; high risk, use deliberately |

Confirm exact package names against the server's own docs before wiring — the ecosystem moves. The Model Context Protocol reference servers live at `github.com/modelcontextprotocol/servers`.

## Phase 0 -- Detect and choose

1. **Read** `.a365-workspace-detection.local.json` for `programmingLanguage`; fall back to project files.
2. Confirm `npx` (Node) and/or `uvx` (Python `pip install uv`) are available for stdio servers, or take a URL for an HTTP server.
3. **Ask** which server, and for its parameters (a directory to scope, a connection string, a token env var). If the server carries obvious risk (filesystem at a broad path, Playwright, an HTTP server on a URL you do not control), say so in one line and confirm.

## Phase 1 -- Wire it

**Read** the reference for the language and follow it exactly:

- Python: `.a365-kit/addons/add-mcp-server/references/python-mcp-server.md`
- Node.js: `.a365-kit/addons/add-mcp-server/references/nodejs-mcp-server.md`
- .NET: `.a365-kit/addons/add-mcp-server/references/dotnet-mcp-server.md`

Rules, every language:

- Put the server wiring in a **new module**; do not edit the file the onboarding skills own.
- **Append** to the agent's `mcp_servers` list. Do NOT touch the Work IQ path -- the two coexist. If Work IQ is present, `include_server_in_tool_names` should already be set; keep it, so external and Work IQ tools do not collide.
- Give each server a distinct `name`; use it to scope the connection (directory, DB, repo).
- Prefer **stdio** for local tools and **streamable-HTTP** for remote ones. Set a connect timeout and a tool-list cache where the SDK supports it.
- Secrets (tokens, connection strings) go in `.env` and are read from the environment -- never hard-coded, never printed.

## Phase 2 -- Verify

1. Import/build check: the agent module still loads.
2. Start the agent (or `test-local`) and confirm the new server's tools list without error. Watch for a non-zero tool count from that server.
3. Run the validator: `node .a365-kit/hooks/stop/validate-add-mcp-server.js`.
4. If hosted, restart -- new servers are attached at startup.

## Phase 3 -- Governance (do not skip)

Tell the user plainly:

- This capability is **invisible to the Agent 365 registry**. An admin asking "what can this agent reach?" will not see it in Entra. Record it wherever your team tracks agent capability.
- The server runs with the **host's** privileges (stdio) or against whatever the URL/credentials allow (HTTP). A filesystem server scoped to `/` or a Postgres server with a write role is a real exposure.
- Tool output is **untrusted model input**. A fetched page or a database row can carry a prompt injection. `add-purview-dlp` evaluates content on the turn; add it if this agent now pulls external data.

## Summary to show the user

```
Server      <name>   <stdio cmd | http url>   scope: <dir/db/repo>
Transport   stdio (npx/uvx) | streamable-http
Agent       mcp_servers <before> -> <after>   (Work IQ preserved)
Governance  NOT Entra-gated; runs at host privilege; pair with add-purview-dlp
Verified    tools listed; validator ok
Next        restart the host if it is running
```
