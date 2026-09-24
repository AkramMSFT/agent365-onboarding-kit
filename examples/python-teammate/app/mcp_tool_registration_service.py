from __future__ import annotations

import os
from contextlib import AsyncExitStack, asynccontextmanager

import httpx
from agent_framework import MCPStreamableHTTPTool
from microsoft_agents_a365.runtime.utility import Utility
from microsoft_agents_a365.tooling.models import ToolOptions
from microsoft_agents_a365.tooling.services.mcp_tool_server_configuration_service import (
    McpToolServerConfigurationService,
)
from microsoft_agents_a365.tooling.utils.utility import (
    get_mcp_platform_authentication_scope,
)

from observability_tokens import access_token


class AgentFrameworkMcpTools:
    """Agent Framework MCP tools for one turn; SDK discovery picks each audience's token."""

    def __init__(self, configuration_service=None, http_client_factory=httpx.AsyncClient):
        self._configuration_service = (
            configuration_service or McpToolServerConfigurationService()
        )
        self._http_client_factory = http_client_factory

    @asynccontextmanager
    async def for_turn(self, authorization, auth_handler_name, context):
        mode = os.getenv("PYTHON_ENVIRONMENT", "Production").strip().lower()
        if mode not in {"production", "development"}:
            raise ValueError("PYTHON_ENVIRONMENT must be Production or Development")
        # Core discovery defaults to development when this is unset.
        if not os.getenv("PYTHON_ENVIRONMENT"):
            raise ValueError("Set PYTHON_ENVIRONMENT explicitly before enabling WorkIQ")
        token = None
        agent_id = ""
        if mode == "production":
            if authorization is None or not auth_handler_name:
                raise ValueError("Production WorkIQ requires the host authorization handler")
            token = access_token(
                await authorization.exchange_token(
                    context, get_mcp_platform_authentication_scope(), auth_handler_name
                )
            )
            if not token:
                raise RuntimeError("No MCP discovery access token was returned")
            agent_id = Utility.resolve_agent_identity(context, token)
            if not agent_id:
                raise ValueError("No runtime agent identity is available for MCP discovery")
        configs = await self._configuration_service.list_tool_servers(
            agentic_app_id=agent_id,
            auth_token=token,
            options=ToolOptions(orchestrator_name="AgentFramework"),
            authorization=authorization,
            auth_handler_name=auth_handler_name,
            turn_context=context,
        )
        async with AsyncExitStack() as clients:
            tools = []
            for config in configs:
                headers = dict(config.headers or {})
                if mode == "production" and not any(
                    key.lower() == "authorization" and value for key, value in headers.items()
                ):
                    raise RuntimeError("Core discovery did not return this server's auth header")
                headers.setdefault("User-Agent", Utility.get_user_agent_header("AgentFramework"))
                client = await clients.enter_async_context(
                    self._http_client_factory(headers=headers, timeout=90)
                )
                tool = MCPStreamableHTTPTool(
                    name=config.mcp_server_name or config.mcp_server_unique_name,
                    url=config.url,
                    http_client=client,
                    load_prompts=False,
                    tool_name_prefix=config.mcp_server_unique_name or config.mcp_server_name,
                )
                # RawAgent does not close a tool whose __aenter__ failed, so this stack does.
                clients.push_async_callback(tool.close)
                tools.append(tool)
            # Callers must exit RawAgent and its MCP sessions before leaving this context.
            yield tools
