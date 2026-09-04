# External MCP servers -- Python (OpenAI Agents SDK)

API verified against `openai-agents` on the live venv (2026-09-04): `agents.mcp` exports `MCPServerStdio`, `MCPServerStreamableHttp`, `MCPServerSse`; `Agent(..., mcp_servers=[...])` accepts them. The wiring below constructed and entered a server and called `list_tools` cleanly; a smoke test additionally needs network access to fetch the chosen server package (`uvx`/`npx`).

## `src/mcp_servers.py`

One factory per server you attach. Keep them lazy -- the SDK opens them when the agent runs.

```python
"""External (non-Work-IQ) MCP servers for the agent.

These connect the agent's framework directly to community MCP servers. They are
NOT registered in Agent 365 and NOT gated by Entra consent -- see the add-on's
governance section. Secrets come from the environment, never hard-coded.
"""

from __future__ import annotations

import os

from agents.mcp import MCPServerStdio, MCPServerStreamableHttp


def build_external_mcp_servers() -> list:
    """Return the external MCP servers to attach this run. Add only what you need."""
    servers: list = []

    # --- stdio example: filesystem, scoped to ONE directory (never the drive root) ---
    workdir = os.getenv("AGENT_FS_ROOT")
    if workdir:
        servers.append(MCPServerStdio(
            name="filesystem",
            params={"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", workdir]},
            client_session_timeout_seconds=30,
            cache_tools_list=True,
        ))

    # --- stdio example: web fetch (uvx). Egress + injection surface, like lab fetch_url ---
    if os.getenv("AGENT_ENABLE_FETCH_MCP", "").lower() == "true":
        servers.append(MCPServerStdio(
            name="fetch",
            params={"command": "uvx", "args": ["mcp-server-fetch"]},
            client_session_timeout_seconds=30,
            cache_tools_list=True,
        ))

    # --- stdio example: GitHub (needs a token in the env it inherits) ---
    if os.getenv("GITHUB_PERSONAL_ACCESS_TOKEN"):
        servers.append(MCPServerStdio(
            name="github",
            params={
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"],
                "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"]},
            },
            client_session_timeout_seconds=30,
            cache_tools_list=True,
        ))

    # --- streamable-HTTP example: a remote MCP server you trust ---
    http_url = os.getenv("AGENT_MCP_HTTP_URL")
    if http_url:
        servers.append(MCPServerStreamableHttp(
            name="remote",
            params={"url": http_url},   # add "headers": {...} for auth if the server needs it
            client_session_timeout_seconds=30,
            cache_tools_list=True,
        ))

    return servers


EXTERNAL_MCP_SERVERS = build_external_mcp_servers()
```

## Wiring into the agent

Append to the agent's `mcp_servers` -- do not disturb the Work IQ path. If Work IQ is also attached, `include_server_in_tool_names` should already be set so names never collide.

```python
try:
    from src.mcp_servers import EXTERNAL_MCP_SERVERS
except ImportError:
    from mcp_servers import EXTERNAL_MCP_SERVERS

expenses_agent = Agent(
    name="...",
    instructions=(
        # name the new tools so the model uses them, e.g.:
        "You also have external MCP tools: <describe what you attached, e.g. read files "
        "under the work directory, fetch web pages, query GitHub>. Use them when relevant. "
        # ... rest of the existing instructions ...
    ),
    tools=[...existing tools...],
    mcp_servers=[*EXTERNAL_MCP_SERVERS],          # + Work IQ servers if the host attaches them
    mcp_config={"include_server_in_tool_names": True},
)
```

If the host attaches Work IQ per turn (see `add-messaging-endpoint`), keep both: build the base agent with `mcp_servers=EXTERNAL_MCP_SERVERS`, and let the per-turn Work IQ attach add to it. The base-agent reset trick in the host's adapter preserves the external servers because they live on the base agent.

## Prerequisites for stdio servers

- **Node servers** (`@modelcontextprotocol/server-*`, `@playwright/mcp`): `npx` on PATH (comes with Node). `npx -y` fetches on first use.
- **Python servers** (`mcp-server-fetch`, `mcp-server-git`, `mcp-server-time`, `mcp-server-sqlite`): `uv` on PATH (`pip install uv`), then `uvx <server>`.
- The host process needs outbound network the first time to download the server package; in a locked-down deployment, pre-install the servers into the image.

## Verify

```bash
python -c "import src.agent as a; print('mcp servers:', [s.name for s in (a.expenses_agent.mcp_servers or [])])"
```

Then start the agent (or `test-local`) and confirm the server's tools list without error. `time` (`uvx mcp-server-time`) is the cheapest smoke test. Restart the host after changes -- servers attach at startup.

## Guards to keep

- Scope every server to the least it needs: one directory, a read-only DB role, a single repo.
- Put tokens and connection strings in `.env`; pass them through `params["env"]` for stdio, `params["headers"]` for HTTP. Never inline.
- Set `client_session_timeout_seconds` so a hung server does not hang the turn.
- Treat every tool result as untrusted model input; pair with `add-purview-dlp`.
