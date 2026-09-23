from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import Mapping
from contextlib import suppress
from datetime import datetime, timezone
from typing import Type

from aiohttp import web
from microsoft_agents.activity import (
    Activity,
    ActivityTypes,
    ChannelId,
    ConversationUpdateTypes,
    load_configuration_from_env,
)
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.aiohttp import CloudAdapter, jwt_authorization_middleware
from microsoft_agents.hosting.core import AgentApplication, MemoryStorage, RouteRank
from microsoft_agents_a365.notifications import AgentNotification

from agent_interface import AgentInterface
from observability_bootstrap import Agents16BaggageMiddleware, shutdown_observability
from observability_tokens import TOKEN_STORE

logger = logging.getLogger(__name__)


@web.middleware
async def protected_routes(request: web.Request, handler):
    if request.method == "GET" and request.path == "/api/health":
        return await handler(request)
    return await jwt_authorization_middleware(request, handler)


class GenericAgentHost:
    def __init__(self, agent: AgentInterface, environment: Mapping[str, str] | None = None):
        self._agent = agent
        self.environment = dict(os.environ if environment is None else environment)
        self.auth_handler_name = self.environment.get("AUTH_HANDLER_NAME", "").strip()
        if not self.auth_handler_name:
            raise ValueError("The authenticated teammate host requires AUTH_HANDLER_NAME")
        configuration = load_configuration_from_env(self.environment)
        self.connection_manager = MsalConnectionManager(**configuration)
        self.auth_configuration = self.connection_manager.get_default_connection_configuration()
        if not self.auth_configuration.CLIENT_ID:
            raise ValueError("Configure the SERVICE_CONNECTION client ID before starting")
        self.auth_configuration.ANONYMOUS_ALLOWED = False
        self._adapter = CloudAdapter(connection_manager=self.connection_manager)
        self._adapter.use(Agents16BaggageMiddleware())

        async def on_turn_error(context, error):
            logger.error("Agent turn failed", exc_info=(type(error), error, error.__traceback__))
            try:
                await context.send_activity("Sorry, I could not complete that request.")
            except Exception:
                logger.exception("Unable to send the failure response")

        self._adapter.on_turn_error = on_turn_error
        self.agent_application = AgentApplication(
            storage=MemoryStorage(),
            adapter=self._adapter,
            connection_manager=self.connection_manager,
            **configuration,
        )
        self._closed = False
        self._setup_handlers()
        self._app = web.Application(middlewares=[protected_routes])
        self._app["agent_configuration"] = self.auth_configuration
        self._app.router.add_get("/api/health", self._handle_health)
        self._app.router.add_post("/api/messages", self._handle_messages)
        self._app.cleanup_ctx.append(self._lifetime)

    def create_application(self) -> web.Application:
        return self._app

    def _register_turn(self, context) -> None:
        TOKEN_STORE.register_turn(
            context, self.agent_application.auth, self.auth_handler_name
        )

    def _setup_handlers(self) -> None:
        handlers = [self.auth_handler_name]
        notifications = AgentNotification(self.agent_application)

        @notifications.on_agent_notification(
            ChannelId(channel="agents", sub_channel="*"),
            rank=RouteRank.FIRST,
            auth_handlers=handlers,
        )
        async def on_notification(context, state, notification):
            self._register_turn(context)
            kind = notification.notification_type
            if notification.email is not None:
                payload = notification.email.model_dump(by_alias=True)
            elif notification.wpx_comment is not None:
                payload = notification.wpx_comment.model_dump(by_alias=True)
            else:
                payload = notification.value
            reply = await self._agent.handle_agent_notification_activity(
                kind.value if kind is not None else None,
                payload,
                context,
                self.agent_application.auth,
                self.auth_handler_name,
            )
            if reply:
                await context.send_activity(reply)

        @self.agent_application.conversation_update(
            ConversationUpdateTypes.MEMBERS_ADDED, auth_handlers=handlers
        )
        async def on_members_added(context, state):
            self._register_turn(context)
            for member in context.activity.members_added or []:
                if member.id != context.activity.recipient.id:
                    await context.send_activity("Hello! I can help you today.")

        @self.agent_application.activity(
            ActivityTypes.installation_update, auth_handlers=handlers
        )
        async def on_installation_update(context, state):
            self._register_turn(context)
            if context.activity.action == "add":
                await context.send_activity("Thank you for hiring me!")

        @self.agent_application.activity(ActivityTypes.message, auth_handlers=handlers)
        async def on_message(context, state):
            self._register_turn(context)
            await context.send_activity("Got it — working on it…")
            await context.send_activity(Activity(type=ActivityTypes.typing))

            async def typing_loop():
                while True:
                    await asyncio.sleep(4)
                    await context.send_activity(Activity(type=ActivityTypes.typing))

            typing_task = asyncio.create_task(typing_loop())
            try:
                reply = await self._agent.process_user_message(
                    context.activity.text or "",
                    self.agent_application.auth,
                    self.auth_handler_name,
                    context,
                )
                if reply:
                    await context.send_activity(reply)
            finally:
                typing_task.cancel()
                with suppress(asyncio.CancelledError):
                    await typing_task

    async def _lifetime(self, app):
        TOKEN_STORE.bind_loop()
        try:
            await self._agent.initialize()
            yield
        finally:
            await self.cleanup()

    async def start_server(self) -> None:
        runner = web.AppRunner(self._app, handle_signals=True)
        try:
            await runner.setup()
            site = web.TCPSite(
                runner,
                self.environment.get("HOST", "0.0.0.0"),
                int(self.environment.get("PORT", "3978")),
            )
            await site.start()
            logger.info("Authenticated agent host ready")
            await asyncio.Event().wait()
        finally:
            await runner.cleanup()

    async def _handle_messages(self, request: web.Request) -> web.Response:
        try:
            return await self._adapter.process(request, self.agent_application)
        except Exception:
            logger.exception("Agent turn failed")
            return web.json_response({"error": "Internal server error"}, status=500)

    async def _handle_health(self, request: web.Request) -> web.Response:
        return web.json_response(
            {"status": "healthy", "timestamp": datetime.now(timezone.utc).isoformat()}
        )

    async def cleanup(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            await shutdown_observability()
        finally:
            try:
                await self._agent.cleanup()
            finally:
                await TOKEN_STORE.aclose()


def create_and_run_host(agent_class: Type[AgentInterface]) -> None:
    async def run():
        await GenericAgentHost(agent_class()).start_server()

    try:
        asyncio.run(run())
    except (KeyboardInterrupt, web.GracefulExit):
        pass


def main() -> None:
    from dotenv import load_dotenv

    load_dotenv()
    os.environ.setdefault("PYTHON_ENVIRONMENT", "Production")
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    from observability_bootstrap import configure_observability

    configure_observability()
    # Instrumentation must precede imports of Agent Framework/OpenAI.
    from agent import MyAgent

    create_and_run_host(MyAgent)


if __name__ == "__main__":
    main()
