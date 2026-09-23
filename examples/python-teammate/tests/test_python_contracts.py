from __future__ import annotations

import asyncio
import json
import os
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
import jwt
from aiohttp.test_utils import TestClient, TestServer
from cryptography.hazmat.primitives.asymmetric import rsa
from microsoft_agents.activity import Activity, ResourceResponse, TokenResponse
from microsoft_agents.authentication.msal.msal_auth import MsalAuth
from microsoft_agents.hosting.core import Authorization
from microsoft_agents.hosting.core._oauth import _FlowStateTag
from microsoft_agents.hosting.core.app.oauth._sign_in_response import _SignInResponse
from microsoft_agents.hosting.core.authorization.jwt import JwtTokenValidator
from microsoft.opentelemetry.a365.runtime import get_observability_authentication_scope
from microsoft.opentelemetry.a365.constants import GEN_AI_AGENT_ID_KEY, TENANT_ID_KEY
from opentelemetry import baggage
from openai import AsyncAzureOpenAI

import host_agent_server
import observability_bootstrap
import observability_tokens
from agent import MyAgent
from agent_interface import AgentInterface
from host_agent_server import GenericAgentHost
from observability_tokens import TOKEN_STORE, TurnTokenStore, access_token

BLUEPRINT = "11111111-1111-4111-8111-111111111111"
AGENT = "22222222-2222-4222-8222-222222222222"
TENANT = "33333333-3333-4333-8333-333333333333"
USER = "44444444-4444-4444-8444-444444444444"
SERVICE_URL = "https://smba.trafficmanager.net/teams/"


def host_environment():
    return {
        "AUTH_HANDLER_NAME": "AGENTIC",
        "PYTHON_ENVIRONMENT": "Production",
        "ENABLE_A365_OBSERVABILITY_EXPORTER": "false",
        "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__TYPE": "AgenticUserAuthorization",
        "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES": "https://graph.microsoft.com/.default",
        "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID": BLUEPRINT,
        "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET": "offline-test-not-a-credential",
        "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID": TENANT,
        "CONNECTIONSMAP__0__SERVICEURL": "*",
        "CONNECTIONSMAP__0__CONNECTION": "SERVICE_CONNECTION",
    }


def isolated_environment(values):
    system_keys = ("SYSTEMROOT", "WINDIR", "SYSTEMDRIVE", "COMSPEC", "PATH", "PATHEXT")
    work = Path(__file__).parents[1] / "runtime-work"
    work.mkdir(exist_ok=True)
    return (
        {key: os.environ[key] for key in system_keys if key in os.environ}
        | {
            "TEMP": str(work),
            "TMP": str(work),
            "MICROSOFT_OTEL_SDKSTATS_DISABLED": "true",
        }
        | values
    )


def message(turn_id="turn-one", name="Offline User"):
    return {
        "id": turn_id,
        "type": "message",
        "channelId": "msteams",
        "serviceUrl": SERVICE_URL,
        "from": {"id": "29:offline-user", "name": name, "aadObjectId": USER},
        "recipient": {
            "id": BLUEPRINT,
            "role": "agenticUser",
            "agenticAppId": AGENT,
            "agenticUserId": USER,
            "tenantId": TENANT,
        },
        "conversation": {"id": "offline-conversation", "tenantId": TENANT},
        "text": "Hello from an offline test",
    }


def context(turn_id="turn-one", name="Offline User"):
    return SimpleNamespace(activity=Activity.model_validate(message(turn_id, name)))


class BusinessAgent(AgentInterface):
    def __init__(self):
        self.initialized = False
        self.cleaned = False
        self.calls = []
        self.fail = False
        self.identities = []

    async def initialize(self):
        self.initialized = True

    async def process_user_message(self, text, auth, handler, turn):
        self.identities.append(
            (baggage.get_baggage(GEN_AI_AGENT_ID_KEY), baggage.get_baggage(TENANT_ID_KEY))
        )
        self.calls.append(("message", text, auth, handler, turn))
        if self.fail:
            raise RuntimeError("offline business failure")
        return "offline-message-reply"

    async def handle_agent_notification_activity(self, kind, payload, turn, auth, handler):
        self.identities.append(
            (baggage.get_baggage(GEN_AI_AGENT_ID_KEY), baggage.get_baggage(TENANT_ID_KEY))
        )
        self.calls.append(("notification", kind, payload, auth, handler, turn))
        return "offline-notification-reply"

    async def cleanup(self):
        self.cleaned = True


class HostTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.environment_patch = patch.dict(
            os.environ, isolated_environment(host_environment()), clear=True
        )
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        self.business = BusinessAgent()
        self.host = GenericAgentHost(self.business)
        self.sent = []
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.service_token_patch = patch.object(
            MsalAuth, "get_agentic_user_token", AsyncMock(return_value="offline-service-token")
        )
        self.service_token_patch.start()
        self.addCleanup(self.service_token_patch.stop)
        self.jwk_patch = patch.object(
            JwtTokenValidator._jwk_client_manager,
            "get_signing_key",
            AsyncMock(return_value=self.key.public_key()),
        )
        self.jwk_lookup = self.jwk_patch.start()
        self.addCleanup(self.jwk_patch.stop)
        self.auth_handler = self.host.agent_application.auth._handlers["AGENTIC"]
        self.auth_handler._sign_in = AsyncMock(
            return_value=_SignInResponse(
                TokenResponse(token="offline-signin-token"), _FlowStateTag.COMPLETE
            )
        )

        async def refreshed(turn, exchange_connection, scopes):
            return TokenResponse(token="offline-observability-" + turn.activity.id)

        self.auth_handler.get_refreshed_token = AsyncMock(side_effect=refreshed)

        async def send(turn, activities):
            self.sent.extend(activities)
            return [ResourceResponse(id=f"offline-{index}") for index in range(len(activities))]

        self.host._adapter.send_activities = AsyncMock(side_effect=send)
        self.client = TestClient(TestServer(self.host.create_application(), host="127.0.0.1"))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    def bearer(self, **overrides):
        claims = {
            "aud": BLUEPRINT,
            "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
            "tid": TENANT,
            "appid": BLUEPRINT,
            "serviceurl": SERVICE_URL,
            "exp": int(time.time()) + 600,
            "nbf": int(time.time()) - 10,
        }
        claims.update(overrides)
        encoded = jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": "offline-test-key"})
        return {"Authorization": "Bearer " + encoded}

    async def test_health_is_200_and_other_anonymous_routes_are_protected(self):
        response = await self.client.get("/api/health")
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())["status"], "healthy")
        response = await self.client.post("/api/health")
        self.assertEqual(response.status, 401)
        self.assertTrue(self.business.initialized)
        self.assertFalse(self.host.auth_configuration.ANONYMOUS_ALLOWED)

    async def test_anonymous_message_is_401_before_any_business_or_key_lookup(self):
        response = await self.client.post("/api/messages", json=message())
        self.assertEqual(response.status, 401)
        self.assertFalse(self.business.calls)
        self.auth_handler._sign_in.assert_not_awaited()
        self.jwk_lookup.assert_not_awaited()

    async def test_wrong_audience_and_expired_tokens_are_401(self):
        for headers in (self.bearer(aud=AGENT), self.bearer(exp=int(time.time()) - 3600)):
            response = await self.client.post("/api/messages", json=message(), headers=headers)
            self.assertEqual(response.status, 401)
        self.assertFalse(self.business.calls)

    async def test_authenticated_message_uses_real_auth_and_shared_resolver_after_turn(self):
        response = await self.client.post("/api/messages", json=message(), headers=self.bearer())
        self.assertEqual(response.status, 202, await response.text())
        self.assertEqual(len(self.business.calls), 1)
        self.assertIs(self.business.calls[0][2], self.host.agent_application.auth)
        self.assertIsInstance(self.business.calls[0][2], Authorization)
        self.assertEqual(self.business.calls[0][3], "AGENTIC")
        self.assertEqual(self.business.identities, [(AGENT, TENANT)])
        self.assertEqual([activity.type for activity in self.sent], ["message", "typing", "message"])
        self.assertEqual(self.sent[-1].text, "offline-message-reply")
        self.assertIs(host_agent_server.TOKEN_STORE, observability_tokens.TOKEN_STORE)
        self.assertIs(observability_bootstrap.token_resolver.__self__, TOKEN_STORE)
        token = await asyncio.to_thread(
            observability_bootstrap.token_resolver, *self.business.identities[-1]
        )
        self.assertEqual(token, "offline-observability-turn-one")
        self.assertEqual(
            self.auth_handler.get_refreshed_token.await_args.args[2],
            get_observability_authentication_scope(),
        )
        response = await self.client.post(
            "/api/messages", json=message("turn-two"), headers=self.bearer()
        )
        self.assertEqual(response.status, 202)
        self.assertEqual(
            await asyncio.to_thread(observability_tokens.token_resolver, AGENT, TENANT),
            "offline-observability-turn-two",
        )

    async def test_authenticated_email_notification_wins_over_generic_message_route(self):
        notification = message("notification-one")
        notification.update(
            {
                "channelId": "agents:email",
                "name": "emailNotification",
                "entities": [
                    {
                        "type": "emailNotification",
                        "id": "offline-email",
                        "conversationId": "offline-email-conversation",
                        "htmlBody": "<p>Offline notification content.</p>",
                    }
                ],
            }
        )
        response = await self.client.post(
            "/api/messages", json=notification, headers=self.bearer()
        )
        self.assertEqual(response.status, 202, await response.text())
        self.assertEqual(len(self.business.calls), 1)
        call = self.business.calls[0]
        self.assertEqual(call[:2], ("notification", "emailNotification"))
        self.assertEqual(call[2]["id"], "offline-email")
        self.assertIs(call[3], self.host.agent_application.auth)
        self.assertEqual(call[4], "AGENTIC")
        self.assertEqual(self.business.identities, [(AGENT, TENANT)])
        self.assertEqual(self.sent[-1].text, "offline-notification-reply")
        self.assertEqual(
            await asyncio.to_thread(observability_tokens.token_resolver, AGENT, TENANT),
            "offline-observability-notification-one",
        )

    async def test_authenticated_http_turn_reaches_actual_framework_and_model_transport(self):
        transport = OpenAITransport()
        agent = MyAgent(model_environment(), model_client_factory=transport.client)
        await agent.initialize()
        self.host._agent = agent
        response = await self.client.post(
            "/api/messages", json=message("full-framework-turn"), headers=self.bearer()
        )
        self.assertEqual(response.status, 202, await response.text())
        self.assertEqual(self.sent[-1].text, "offline-model-answer")
        self.assertEqual(len(transport.requests), 1)
        self.assertTrue(transport.clients[0].is_closed())
        self.assertEqual(
            await asyncio.to_thread(observability_tokens.token_resolver, AGENT, TENANT),
            "offline-observability-full-framework-turn",
        )

    async def test_typing_task_is_drained_on_business_error(self):
        self.business.fail = True
        response = await self.client.post("/api/messages", json=message(), headers=self.bearer())
        self.assertEqual(response.status, 202)
        self.assertEqual(len(self.business.calls), 1)
        self.assertEqual(self.sent[-1].text, "Sorry, I could not complete that request.")
        await asyncio.sleep(0)
        self.assertFalse(
            any("typing_loop" in task.get_coro().__qualname__ for task in asyncio.all_tasks())
        )

    async def test_cleanup_flushes_on_live_loop_then_closes_agent_and_cache(self):
        events = []

        async def flush():
            events.append(("flush", TOKEN_STORE._loop.is_running()))

        async def agent_cleanup():
            events.append(("agent", TOKEN_STORE._loop.is_running()))

        with (
            patch.object(host_agent_server, "shutdown_observability", flush),
            patch.object(self.business, "cleanup", agent_cleanup),
        ):
            await self.client.close()
        self.assertEqual(events, [("flush", True), ("agent", True)])
        self.assertIsNone(TOKEN_STORE._loop)
        self.assertFalse(TOKEN_STORE._pending)
        self.assertFalse(TOKEN_STORE._tasks)


class TokenStoreTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.store = TurnTokenStore(timeout=0.1)
        self.store.bind_loop()
        self.addAsyncCleanup(self.store.aclose)
        self.auth = SimpleNamespace(exchange_token=AsyncMock())

    async def test_normalizes_real_token_response_and_string_only(self):
        self.assertEqual(access_token(TokenResponse(token="offline-token")), "offline-token")
        self.assertEqual(access_token("offline-token"), "offline-token")
        for invalid in (TokenResponse(), None, object(), {"token": "not-a-contract"}, 3):
            self.assertIsNone(access_token(invalid))
        self.store.register_turn(context(), self.auth, "AGENTIC")
        for value in (TokenResponse(token="offline-token"), "offline-token"):
            self.auth.exchange_token.return_value = value
            self.assertEqual(
                await asyncio.to_thread(self.store.resolve, AGENT, TENANT), "offline-token"
            )

    async def test_latest_context_and_handler_replace_earlier_binding(self):
        self.auth.exchange_token.return_value = TokenResponse(token="current")
        older, newer = context("older"), context("newer")
        self.store.register_turn(older, self.auth, "OLD_HANDLER")
        self.store.register_turn(newer, self.auth, "NEW_HANDLER")
        self.assertEqual(await asyncio.to_thread(self.store.resolve, AGENT, TENANT), "current")
        self.auth.exchange_token.assert_awaited_once_with(
            newer, get_observability_authentication_scope(), "NEW_HANDLER"
        )

    async def test_missing_runtime_identity_never_uses_blueprint_environment(self):
        turn = context()
        turn.activity.recipient.agentic_app_id = None
        with patch.dict(os.environ, {"agent365Observability__agentId": BLUEPRINT}):
            self.assertFalse(self.store.register_turn(turn, self.auth, "AGENTIC"))
        self.assertIsNone(await asyncio.to_thread(self.store.resolve, BLUEPRINT, TENANT))
        self.assertFalse(self.store.register_turn(context(), self.auth, None))
        self.auth.exchange_token.assert_not_awaited()

    async def test_sync_resolver_on_host_loop_returns_without_deadlock(self):
        self.store.register_turn(context(), self.auth, "AGENTIC")
        self.assertIsNone(self.store.resolve(AGENT, TENANT))
        self.auth.exchange_token.assert_not_awaited()

    async def test_exchange_error_is_nonfatal(self):
        self.store.register_turn(context(), self.auth, "AGENTIC")
        self.auth.exchange_token.side_effect = RuntimeError("offline token service error")
        self.assertIsNone(await asyncio.to_thread(self.store.resolve, AGENT, TENANT))

    async def test_timeout_cancels_the_underlying_exchange(self):
        cancelled = asyncio.Event()

        async def blocked(*args):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.auth.exchange_token.side_effect = blocked
        self.store.register_turn(context(), self.auth, "AGENTIC")
        self.assertIsNone(await asyncio.to_thread(self.store.resolve, AGENT, TENANT))
        await asyncio.wait_for(cancelled.wait(), timeout=1)
        self.assertFalse(self.store._pending)

    async def test_shutdown_cancels_and_drains_active_exchange(self):
        started = asyncio.Event()
        cancelled = asyncio.Event()

        async def blocked(*args):
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        self.auth.exchange_token.side_effect = blocked
        self.store.register_turn(context(), self.auth, "AGENTIC")
        resolver = asyncio.create_task(asyncio.to_thread(self.store.resolve, AGENT, TENANT))
        await started.wait()
        await self.store.aclose()
        self.assertIsNone(await resolver)
        self.assertTrue(cancelled.is_set())
        self.assertFalse(self.store._tasks)
        self.assertFalse(self.store._pending)
        self.assertFalse(self.store.register_turn(context(), self.auth, "AGENTIC"))
        self.assertIsNone(await asyncio.to_thread(self.store.resolve, AGENT, TENANT))

    async def test_expiration_capacity_and_scope_override(self):
        limited = TurnTokenStore(ttl=0, capacity=1)
        limited.bind_loop()
        self.addAsyncCleanup(limited.aclose)
        limited.register_turn(context(), self.auth, "AGENTIC")
        self.assertIsNone(await asyncio.to_thread(limited.resolve, AGENT, TENANT))
        limited.ttl = 10
        limited.register_turn(context(), self.auth, "AGENTIC")
        other = context()
        other.activity.recipient.agentic_app_id = BLUEPRINT
        limited.register_turn(other, self.auth, "AGENTIC")
        self.assertEqual(len(limited._bindings), 1)
        self.assertNotIn((AGENT, TENANT), limited._bindings)
        self.auth.exchange_token.return_value = TokenResponse(token="scope-token")
        with patch.dict(os.environ, {"A365_OBSERVABILITY_SCOPE_OVERRIDE": "api://offline/scope"}):
            self.assertEqual(
                await asyncio.to_thread(limited.resolve, BLUEPRINT, TENANT), "scope-token"
            )
            self.assertEqual(
                self.auth.exchange_token.await_args.args[1], ["api://offline/scope"]
            )


class InitializationTests(unittest.IsolatedAsyncioTestCase):
    async def test_failed_agent_startup_cleans_the_host_and_shared_store(self):
        business = BusinessAgent()
        business.initialize = AsyncMock(side_effect=RuntimeError("offline initialization failure"))
        host = GenericAgentHost(business, host_environment())
        client = TestClient(TestServer(host.create_application(), host="127.0.0.1"))
        try:
            with self.assertRaisesRegex(RuntimeError, "offline initialization failure"):
                await client.start_server()
        finally:
            await client.close()
        self.assertTrue(business.cleaned)
        self.assertIsNone(TOKEN_STORE._loop)
        self.assertFalse(TOKEN_STORE._bindings)

    async def test_actual_distro_middleware_needs_the_agents16_callback_bridge(self):
        from microsoft.opentelemetry.a365.hosting.middleware.baggage_middleware import (
            BaggageMiddleware,
        )

        seen = []

        async def requires_context(turn):
            seen.append(turn)

        turn = context()
        with self.assertRaises(TypeError):
            await BaggageMiddleware().on_turn(turn, requires_context)
        await observability_bootstrap.Agents16BaggageMiddleware().on_turn(turn, requires_context)
        self.assertEqual(seen, [turn])


class OpenAITransport:
    def __init__(self):
        self.requests = []
        self.urls = []
        self.clients = []
        self.with_tools = False

    def reply(self, request):
        self.requests.append(json.loads(request.content))
        self.urls.append(str(request.url))
        body = self.requests[-1]
        tool_result = any(item.get("role") == "tool" for item in body["messages"])
        if self.with_tools and body.get("tools") and not tool_result:
            answer = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "offline-tool-call",
                        "type": "function",
                        "function": {
                            "name": body["tools"][0]["function"]["name"],
                            "arguments": json.dumps({"query": "offline query"}),
                        },
                    }
                ],
            }
            finish = "tool_calls"
        else:
            answer = {"role": "assistant", "content": "offline-model-answer"}
            finish = "stop"
        return httpx.Response(
            200,
            json={
                "id": "chatcmpl-offline",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": "offline-deployment",
                "choices": [{"index": 0, "message": answer, "finish_reason": finish}],
                "usage": {"prompt_tokens": 4, "completion_tokens": 3, "total_tokens": 7},
            },
        )

    def client(self):
        client = AsyncAzureOpenAI(
            api_key="offline-test-not-a-credential",
            azure_endpoint="https://offline-model.invalid",
            api_version="2024-10-21",
            http_client=httpx.AsyncClient(
                transport=httpx.MockTransport(self.reply), trust_env=False
            ),
            max_retries=0,
        )
        self.clients.append(client)
        return client


def model_environment():
    return {
        "AZURE_OPENAI_API_KEY": "offline-test-not-a-credential",
        "AZURE_OPENAI_ENDPOINT": "https://offline-model.invalid",
        "AZURE_OPENAI_DEPLOYMENT": "offline-deployment",
        "AZURE_OPENAI_API_VERSION": "2024-10-21",
        "ENABLE_WORKIQ": "false",
    }


class FrameworkTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_raw_agent_azure_client_two_turns_and_owned_cleanup(self):
        transport = OpenAITransport()
        agent = MyAgent(model_environment(), model_client_factory=transport.client)
        await agent.initialize()
        self.addAsyncCleanup(agent.cleanup)
        results = await asyncio.gather(
            agent.process_user_message("hello one", None, None, context("one", "Alice")),
            agent.process_user_message("hello two", None, None, context("two", "Bob")),
        )
        self.assertEqual(results, ["offline-model-answer", "offline-model-answer"])
        self.assertEqual(len(transport.requests), 2)
        self.assertTrue(
            all("/chat/completions?api-version=2024-10-21" in url for url in transport.urls)
        )
        self.assertTrue(all(client.is_closed() for client in transport.clients))
        for request in transport.requests:
            text = json.dumps(request["messages"])
            self.assertNotEqual("Alice" in text, "Bob" in text)
            self.assertEqual(request["model"], "offline-deployment")
        self.assertNotIn("Alice", agent.instructions)
        self.assertNotIn("Bob", agent.instructions)

    async def test_real_framework_notification_contract(self):
        transport = OpenAITransport()
        agent = MyAgent(model_environment(), model_client_factory=transport.client)
        await agent.initialize()
        self.addAsyncCleanup(agent.cleanup)
        reply = await agent.handle_agent_notification_activity(
            "emailNotification", {"id": "offline-email"}, context(), None, None
        )
        self.assertEqual(reply, "offline-model-answer")
        self.assertIn("offline-email", json.dumps(transport.requests[0]))
        self.assertIsNone(
            await agent.handle_agent_notification_activity(
                "agentLifecycle", {}, context(), None, None
            )
        )
