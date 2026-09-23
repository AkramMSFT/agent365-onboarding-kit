from __future__ import annotations

import json
import asyncio
import os
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
from aiohttp import web
from aiohttp.test_utils import TestServer
from microsoft_agents.activity import TokenResponse
from microsoft_agents_a365.tooling.services.mcp_tool_server_configuration_service import (
    McpToolServerConfigurationService,
)
from microsoft_agents_a365.tooling.utils.utility import get_mcp_platform_authentication_scope

from agent import MyAgent
from mcp_tool_registration_service import AgentFrameworkMcpTools
from test_python_contracts import (
    AGENT,
    OpenAITransport,
    context,
    isolated_environment,
    model_environment,
)

AUDIENCE = "55555555-5555-4555-8555-555555555555"


class McpTransport:
    def __init__(self):
        self.requests = []
        self.clients = []
        self.fail_initialize_path = None

    def reply(self, request):
        if request.method != "POST":
            return httpx.Response(405)
        body = json.loads(request.content)
        self.requests.append((request.url.path, request.headers["Authorization"], body))
        method = body["method"]
        if method == "initialize" and request.url.path == self.fail_initialize_path:
            return httpx.Response(
                200,
                json={
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "error": {"code": -32603, "message": "offline initialization failure"},
                },
            )
        if "id" not in body:
            return httpx.Response(202)
        if method == "initialize":
            result = {
                "protocolVersion": body["params"]["protocolVersion"],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "offline-mcp", "version": "1.0"},
            }
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "lookup",
                        "description": "Return a fixed offline fixture result",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"query": {"type": "string"}},
                            "required": ["query"],
                        },
                    }
                ]
            }
        elif method == "tools/call":
            result = {
                "content": [{"type": "text", "text": "offline WorkIQ tool result"}],
                "isError": False,
            }
        elif method == "ping":
            result = {}
        else:
            raise AssertionError("Unexpected MCP operation: " + method)
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": body["id"], "result": result})

    def client(self, **kwargs):
        client = httpx.AsyncClient(
            **kwargs, transport=httpx.MockTransport(self.reply), trust_env=False
        )
        self.clients.append(client)
        return client


class McpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.loop_errors = []
        asyncio.get_running_loop().set_exception_handler(
            lambda loop, details: self.loop_errors.append(details)
        )
        self.environment_patch = patch.dict(
            os.environ, isolated_environment({"PYTHON_ENVIRONMENT": "Production"}), clear=True
        )
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        self.gateway_requests = []

        async def gateway(request):
            self.gateway_requests.append((request.match_info["agent"], dict(request.headers)))
            return web.json_response(
                {
                    "mcpServers": [
                        {
                            "mcpServerName": "offline_mail",
                            "mcpServerUniqueName": "offline_mail",
                            "url": "https://offline-mcp.invalid/v1",
                        },
                        {
                            "mcpServerName": "offline_word",
                            "mcpServerUniqueName": "offline_word",
                            "url": "https://offline-mcp.invalid/v2",
                            "audience": AUDIENCE,
                        },
                    ]
                }
            )

        app = web.Application()
        app.router.add_get("/gateway/{agent}", gateway)
        self.gateway = TestServer(app, host="127.0.0.1")
        await self.gateway.start_server()
        self.addAsyncCleanup(self.gateway.close)
        self.gateway_patch = patch(
            "microsoft_agents_a365.tooling.services."
            "mcp_tool_server_configuration_service.get_tooling_gateway_for_digital_worker",
            side_effect=lambda agent: str(self.gateway.make_url("/gateway/" + agent)),
        )
        self.gateway_patch.start()
        self.addCleanup(self.gateway_patch.stop)

        async def token(turn, scopes, handler):
            self.assertEqual(handler, "AGENTIC")
            suffix = "v2" if AUDIENCE in scopes[0] else "v1"
            return TokenResponse(token=f"offline-{turn.activity.id}-{suffix}")

        self.authorization = SimpleNamespace(exchange_token=AsyncMock(side_effect=token))
        self.transport = McpTransport()
        self.provider = AgentFrameworkMcpTools(
            configuration_service=McpToolServerConfigurationService(),
            http_client_factory=self.transport.client,
        )

    async def test_real_gateway_discovery_per_audience_tokens_mcp_and_model_tool_loop(self):
        model = OpenAITransport()
        model.with_tools = True
        agent = MyAgent(
            model_environment() | {"ENABLE_WORKIQ": "true"},
            model_client_factory=model.client,
            mcp_tools=self.provider,
        )
        await agent.initialize()
        self.addAsyncCleanup(agent.cleanup)
        for turn_id in ("one", "two"):
            reply = await agent.process_user_message(
                "Use the offline lookup tool", self.authorization, "AGENTIC", context(turn_id)
            )
            self.assertEqual(reply, "offline-model-answer")
        self.assertEqual([item[0] for item in self.gateway_requests], [AGENT, AGENT])
        self.assertEqual(len(self.transport.clients), 4)
        self.assertTrue(all(client.is_closed for client in self.transport.clients))
        self.assertTrue(all(client.is_closed() for client in model.clients))
        self.assertEqual(len(model.requests), 4)
        advertised = [tool["function"]["name"] for tool in model.requests[0]["tools"]]
        self.assertEqual(len(advertised), len(set(advertised)))
        self.assertEqual(set(advertised), {"offline_mail_lookup", "offline_word_lookup"})
        methods = [request[2]["method"] for request in self.transport.requests]
        self.assertEqual(methods.count("initialize"), 4)
        self.assertEqual(methods.count("tools/call"), 2)
        for path, header, body in self.transport.requests:
            self.assertTrue(header.endswith("-v1" if path == "/v1" else "-v2"))
        self.assertTrue(any("offline-one-v2" in header for _, header, _ in self.transport.requests))
        self.assertTrue(any("offline-two-v2" in header for _, header, _ in self.transport.requests))
        scopes = [call.args[1][0] for call in self.authorization.exchange_token.await_args_list]
        self.assertTrue(any(AUDIENCE in scope and scope.endswith("/.default") for scope in scopes))
        self.assertIn(get_mcp_platform_authentication_scope()[0], scopes)

    async def test_production_requires_real_downstream_authentication_and_token(self):
        with self.assertRaises(ValueError):
            async with self.provider.for_turn(None, "AGENTIC", context()):
                self.fail("Missing authorization must not generate anonymous MCP clients")
        self.authorization.exchange_token.return_value = TokenResponse()
        self.authorization.exchange_token.side_effect = None
        with self.assertRaises(RuntimeError):
            async with self.provider.for_turn(self.authorization, "AGENTIC", context()):
                self.fail("Empty access token must not generate MCP clients")
        self.assertFalse(self.gateway_requests)
        self.assertFalse(self.transport.clients)

    async def test_later_mcp_connection_failure_closes_already_entered_tools_and_clients(self):
        self.transport.fail_initialize_path = "/v2"
        model = OpenAITransport()
        agent = MyAgent(
            model_environment() | {"ENABLE_WORKIQ": "true"},
            model_client_factory=model.client,
            mcp_tools=self.provider,
        )
        await agent.initialize()
        self.addAsyncCleanup(agent.cleanup)
        with self.assertRaises(Exception):
            await agent.process_user_message(
                "offline request", self.authorization, "AGENTIC", context()
            )
        await asyncio.sleep(0)
        self.assertTrue(all(client.is_closed for client in self.transport.clients))
        self.assertTrue(all(client.is_closed() for client in model.clients))
        self.assertFalse(model.requests)
        self.assertFalse(
            any(
                task.get_name().startswith("mcp-lifecycle:") and not task.done()
                for task in asyncio.all_tasks()
            )
        )
        self.assertFalse(self.loop_errors)

    async def test_unset_environment_cannot_trigger_the_sdks_default_development_mode(self):
        with patch.dict(os.environ, isolated_environment({}), clear=True):
            with self.assertRaises(ValueError):
                async with self.provider.for_turn(self.authorization, "AGENTIC", context()):
                    self.fail("Explicit environment selection is required")
