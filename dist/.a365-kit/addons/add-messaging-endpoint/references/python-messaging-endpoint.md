# Python hosting layer for a blueprint-based Agent 365 agent

Verified 2026-09-04 against `microsoft-agents` **1.6.0** and `microsoft-opentelemetry` **1.3.8** on a real tenant: health 200, anonymous POST 401, dev tunnel end to end, endpoint registered.

> **Why not copy the AI Teammate host?** The Python host `make-ai-teammate` generates uses
> `CloudAdapter.on_activity`, `adapter.authorization` and `MsalConnectionManager.from_environment()`.
> None exist in `microsoft-agents` 1.6.x; that host crashes on startup with
> `AttributeError: type object 'MsalConnectionManager' has no attribute 'from_environment'`.
> The pattern below is the 1.6 one: `AgentApplication` + `start_agent_process` + `jwt_authorization_middleware`.

## Dependencies

Append to `requirements.txt` (or `pyproject.toml`) **and install**:

```
microsoft-agents-hosting-aiohttp>=1.6.0
microsoft-agents-authentication-msal>=1.6.0
```

`microsoft-opentelemetry`, `microsoft-agents-a365-tooling*` and `microsoft-agents-a365-runtime` should already be present from onboarding. If `import` fails on `microsoft_agents_a365.runtime`, add `microsoft-agents-a365-runtime>=1.0.0` -- the tooling wheel imports it without declaring it.

## Files

Three new files. **Do not edit the agent module the onboarding skills produced** (`src/agent.py` in the verified project); import it.

### `agent_interface.py` (project root)

```python
from abc import ABC, abstractmethod
from microsoft_agents.hosting.core import Authorization


class AgentInterface(ABC):
    @abstractmethod
    async def initialize(self) -> None: ...

    @abstractmethod
    async def process_user_message(
        self, message: str, auth: Authorization, auth_handler_name: str | None, context
    ) -> str: ...

    @abstractmethod
    async def cleanup(self) -> None: ...
```

### `src/a365_agent.py` -- the adapter

Wraps the existing agent. Substitute the module (`src.agent`), the agent object (`expenses_agent`) and the WorkIQ helper (`setup_workiq_tools`, written by `add-workiq-tools`; omit the call if WorkIQ was not added).

```python
import logging
import src.agent as core            # importing it initialises observability
from agents import Runner            # OpenAI Agents SDK; use your framework's runner
from agent_interface import AgentInterface

logger = logging.getLogger(__name__)


class HostedAgent(AgentInterface):
    async def initialize(self) -> None:
        pass

    async def process_user_message(self, message, auth, auth_handler_name, context) -> str:
        # WorkIQ tools are per-user (OBO). Anonymous local turns have no token: skip, don't fail.
        try:
            await core.setup_workiq_tools(context, auth, auth_handler_name or "AGENTIC")
        except Exception:
            logger.warning("WorkIQ tools not attached for this turn", exc_info=True)
        # Re-read core.<agent>: setup_workiq_tools replaces the module-level agent.
        result = await Runner.run(core.expenses_agent, message)
        return result.final_output or "Sorry, I couldn't get a response."

    async def cleanup(self) -> None:
        pass
```

### `host_agent_server.py` (project root)

```python
from __future__ import annotations
import asyncio, json, logging, os
from typing import Type
from dotenv import load_dotenv
load_dotenv()

import src.agent as core  # FIRST: runs use_microsoft_opentelemetry() before aiohttp imports

from aiohttp import web
from microsoft_agents.activity import ActivityTypes, load_configuration_from_env
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.aiohttp import CloudAdapter, jwt_authorization_middleware, start_agent_process
from microsoft_agents.hosting.core import AgentApplication, ApplicationOptions, AuthHandler, Authorization, MemoryStorage, TurnState
from microsoft.opentelemetry.a365.core import AgentDetails, CallerDetails, Channel, InvokeAgentScope, InvokeAgentScopeDetails, Request, UserDetails
from microsoft.opentelemetry.a365.core.middleware.baggage_builder import BaggageBuilder
from microsoft.opentelemetry.a365.hosting import ObservabilityHostingManager, ObservabilityHostingOptions
from agent_interface import AgentInterface

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

AUTH_HANDLER_NAME = os.getenv("AUTH_HANDLER_NAME", "AGENTIC")   # matches AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__<NAME>__* in .env
AGENT_NAME = os.getenv("AGENT365OBSERVABILITY__AGENTNAME", "My Agent")
AGENT_BLUEPRINT_ID = os.getenv("AGENT365OBSERVABILITY__AGENTBLUEPRINTID", "")
TENANT_ID_FALLBACK = os.getenv("AGENT365OBSERVABILITY__TENANTID", "")
AGENT_ID_FALLBACK = os.getenv("AGENT365OBSERVABILITY__AGENTID", "")


def _attr(obj, name, default=None):
    v = getattr(obj, name, None)
    return default if v is None else v


def _patch_a365_middleware_arity(middleware_set) -> None:
    """hosting-core calls the next middleware as logic(ctx); microsoft-opentelemetry's A365
    middleware calls logic() -- every inbound activity dies with 'missing ... ctx'. Wrap each
    middleware so logic tolerates both. Idempotent; a no-op once the packages agree."""
    for mw in getattr(middleware_set, "_middleware", []):
        orig = getattr(mw, "on_turn", None)
        if orig is None or getattr(mw, "_a365_arity_patched", False):
            continue
        def _wrap(original):
            async def patched(context, logic):
                async def flexible(ctx=None):
                    await logic(context if ctx is None else ctx)
                await original(context, flexible)
            return patched
        mw.on_turn = _wrap(orig)
        mw._a365_arity_patched = True


class GenericAgentHost:
    def __init__(self, agent: AgentInterface):
        self._agent = agent
        self._adapter: CloudAdapter | None = None
        self._app: AgentApplication | None = None

    def _build_authorization_handlers(self) -> dict[str, AuthHandler] | None:
        if not AUTH_HANDLER_NAME:
            return None
        p = f"AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__{AUTH_HANDLER_NAME}__SETTINGS__"
        scopes = os.getenv(p + "SCOPES", "https://graph.microsoft.com/.default")
        return {AUTH_HANDLER_NAME: AuthHandler(
            name=AUTH_HANDLER_NAME,
            auth_type=os.getenv(p + "TYPE", "AgenticUserAuthorization"),
            scopes=[s.strip() for s in scopes.split(",") if s.strip()],
        )}

    @property
    def _authorization(self) -> Authorization | None:
        return getattr(self._app, "auth", None)

    def _setup_handlers(self) -> None:
        app = self._app
        auth_handlers = [AUTH_HANDLER_NAME] if AUTH_HANDLER_NAME else None

        @app.conversation_update("membersAdded")
        async def on_members_added(context, state: TurnState):
            rid = _attr(context.activity.recipient, "id")
            for m in context.activity.members_added or []:
                if m.id != rid:
                    await context.send_activity("Hello! How can I help?")

        @app.activity(ActivityTypes.message, auth_handlers=auth_handlers)
        async def on_message(context, state: TurnState):
            await self._run_turn(context, context.activity.text or "")

    async def _run_turn(self, context, text: str) -> None:
        logger.info("process_user_message called")
        a = context.activity
        recipient, sender = _attr(a, "recipient"), _attr(a, "from_property")
        tenant_id = _attr(recipient, "tenant_id") or TENANT_ID_FALLBACK
        agent_id = _attr(recipient, "agentic_app_id") or AGENT_ID_FALLBACK or AGENT_BLUEPRINT_ID
        conversation_id = str(_attr(_attr(a, "conversation"), "id", "") or "")
        channel_name = str(_attr(a, "channel_id", "unknown"))

        agent_details = AgentDetails(agent_id=agent_id, agent_name=AGENT_NAME,
                                     agent_description=os.getenv("AGENT365OBSERVABILITY__AGENTDESCRIPTION", ""),
                                     agent_blueprint_id=AGENT_BLUEPRINT_ID, tenant_id=tenant_id)
        caller = CallerDetails(user_details=UserDetails(user_id=str(_attr(sender, "id", "")),
                                                        user_name=str(_attr(sender, "name", "")),
                                                        user_email=str(_attr(sender, "email", "") or "")))
        request = Request(content=text, session_id=conversation_id or "session",
                          conversation_id=conversation_id or "conversation", channel=Channel(name=channel_name))

        # Park an OBO-exchanged token for the span exporter. The observability skill wires the
        # AgenticTokenCache as resolver but nothing registers a token per turn without this.
        if AUTH_HANDLER_NAME and tenant_id and agent_id and self._authorization is not None:
            try:
                from microsoft.opentelemetry.a365.hosting.token_cache_helpers import AgenticTokenStruct
                from microsoft_agents_a365.runtime.environment_utils import get_observability_authentication_scope
                core._token_cache.register_observability(agent_id, tenant_id,
                    AgenticTokenStruct(authorization=self._authorization, turn_context=context, auth_handler_name=AUTH_HANDLER_NAME),
                    get_observability_authentication_scope())
            except Exception as err:
                logger.warning("Observability token not registered for this turn: %s", err)

        typing = True
        async def typing_loop():
            while typing:
                await context.send_activity({"type": "typing"}); await asyncio.sleep(4)
        task = asyncio.create_task(typing_loop())
        try:
            baggage = (BaggageBuilder().tenant_id(tenant_id).agent_id(agent_id)
                       .agent_blueprint_id(AGENT_BLUEPRINT_ID).agent_name(AGENT_NAME).channel_name(channel_name))
            if conversation_id: baggage = baggage.conversation_id(conversation_id)
            u = caller.user_details
            if u.user_id: baggage = baggage.user_id(u.user_id)
            if u.user_name: baggage = baggage.user_name(u.user_name)
            with baggage.build():   # baggage MUST wrap the scope or spans partition into "0 identity groups"
                with InvokeAgentScope.start(request, InvokeAgentScopeDetails(), agent_details, caller) as scope:
                    scope.record_input_messages([text])
                    reply = await self._agent.process_user_message(text, self._authorization, AUTH_HANDLER_NAME or None, context)
                    scope.record_output_messages([reply])
            await context.send_activity(reply)
        except Exception:
            logger.exception("turn failed")
            await context.send_activity("Sorry - I hit an error working that out. Please try again.")
        finally:
            typing = False; task.cancel()

    async def start_server(self) -> None:
        await self._agent.initialize()
        cfg = load_configuration_from_env(os.environ)        # driven by CONNECTIONS__* / CONNECTIONSMAP__* in .env
        cm = MsalConnectionManager(**cfg)
        self._adapter = CloudAdapter(connection_manager=cm)
        ObservabilityHostingManager.configure(self._adapter.middleware_set, ObservabilityHostingOptions(enable_baggage=True))
        _patch_a365_middleware_arity(self._adapter.middleware_set)
        self._app = AgentApplication[TurnState](
            ApplicationOptions(adapter=self._adapter, storage=MemoryStorage(),
                               authorization_handlers=self._build_authorization_handlers()),
            connection_manager=cm, **cfg)
        self._setup_handlers()

        @web.middleware
        async def _auth_except_health(request: web.Request, handler):
            if request.path.rstrip("/") == "/api/health":
                return await handler(request)
            return await jwt_authorization_middleware(request, handler)

        web_app = web.Application(middlewares=[_auth_except_health])
        web_app.router.add_post("/api/messages", self._handle_messages)
        web_app.router.add_get("/api/health", self._handle_health)
        web_app["agent_configuration"] = cm.get_default_connection_configuration()   # NOT the raw dict: that 500s every request
        web_app["agent_app"] = self._app
        web_app["adapter"] = self._adapter

        port = int(os.getenv("PORT", "3978"))
        runner = web.AppRunner(web_app); await runner.setup()
        await web.TCPSite(runner, "0.0.0.0", port).start()
        logger.info("listening on http://localhost:%s/api/messages", port)
        try:
            await asyncio.Event().wait()
        finally:
            await self._agent.cleanup(); await runner.cleanup()

    async def _handle_messages(self, request: web.Request) -> web.Response:
        try:
            return await start_agent_process(request, self._app, self._adapter)
        except Exception:
            logger.exception("[/api/messages] agent process raised")
            return web.Response(status=500, text=json.dumps({"error": "Internal server error"}), content_type="application/json")

    async def _handle_health(self, request: web.Request) -> web.Response:
        return web.json_response({"status": "healthy", "agent": AGENT_NAME})


def create_and_run_host(agent_class: Type[AgentInterface]) -> None:
    asyncio.run(GenericAgentHost(agent_class()).start_server())


if __name__ == "__main__":
    from src.a365_agent import HostedAgent
    create_and_run_host(HostedAgent)
```

## Run and verify

```bash
python -u host_agent_server.py                 # -u: unbuffered logs
curl -s http://localhost:3978/api/health       # {"status": "healthy", ...}
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3978/api/messages -H "Content-Type: application/json" -d '{"type":"message","text":"hi"}'   # 401
```

## Gotchas seen on the verified run

| Symptom | Cause |
|---|---|
| `AttributeError ... from_environment` | Host written against pre-1.6 SDK. Use the pattern above. |
| Every request 500s | `web_app["agent_configuration"]` was the raw env dict; it must be `cm.get_default_connection_configuration()`. |
| `missing 1 required positional argument: 'ctx'` on every turn | Middleware arity mismatch; `_patch_a365_middleware_arity` handles it. |
| `AssertionError` in `find_dotenv` when running from stdin | `load_dotenv()` walks the caller frame; pass `load_dotenv(".env")` or run from a file. |
| Port already in use | Another agent on the machine. Set `PORT` in `.env`; use that port for the tunnel. |
| Health JSON shows the *identity* name | `AGENT365OBSERVABILITY__AGENTNAME` holds the identity display name; cosmetic. |
