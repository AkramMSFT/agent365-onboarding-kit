# Python — local dev channel

Verified by running it: with `A365_DEV_CHANNEL` unset the port refuses connections; with it
set, `/dev/health` returns 200, `/dev/chat` answers without a token, a request carrying
`X-Forwarded-For` is refused 403, the listener is bound to `127.0.0.1` and not `0.0.0.0`,
and the production `/api/messages` still returns 401 to an anonymous POST.

Requires `aiohttp`, which the Agent 365 Python hosting layer already depends on.

## The module

Write this as `dev_channel.py` beside the host.

```python
"""Local dev channel for an Agent 365 agent.

Lets AgentsPlayground (or curl) talk to the agent with no tenant, no tunnel and
no Bot Framework token, without weakening the real /api/messages endpoint.

Three things keep it off the public path:

  1. It only starts when A365_DEV_CHANNEL=true. Absent or anything else, nothing binds.
  2. It binds its own port on 127.0.0.1, separate from the production listener.
  3. It refuses any request carrying proxy/tunnel forwarding headers.

Rule 3 matters more than it looks. `devtunnel host` runs on the developer's own
machine and forwards to a local port, so a request that arrived from the public
internet still reaches the process with client_address == 127.0.0.1. A loopback
check alone would therefore pass tunnelled traffic. The forwarded headers the
relay adds are the only reliable signal, and they are used here to DENY, never
to grant -- which is the safe direction to trust a header in.
"""

from __future__ import annotations

import logging
import os
from typing import Awaitable, Callable

from aiohttp import web

logger = logging.getLogger(__name__)

FORWARDING_HEADERS = (
    "x-forwarded-for",
    "x-forwarded-host",
    "x-forwarded-proto",
    "forwarded",
)

DEFAULT_DEV_PORT = 3999


def dev_channel_enabled() -> bool:
    return os.getenv("A365_DEV_CHANNEL", "").strip().lower() == "true"


def _looks_proxied(request: web.Request) -> bool:
    return any(h in request.headers for h in FORWARDING_HEADERS)


def build_dev_channel_app(
    answer: Callable[[str], Awaitable[str]] | Callable[[str], str],
) -> web.Application:
    """An aiohttp app exposing POST /dev/chat and GET /dev/health."""

    async def chat(request: web.Request) -> web.Response:
        if _looks_proxied(request):
            logger.warning(
                "Dev channel refused a request carrying forwarding headers from %s",
                request.remote,
            )
            return web.json_response(
                {"error": "dev channel is local only and refuses proxied requests"},
                status=403,
            )
        try:
            payload = await request.json()
        except Exception:
            return web.json_response({"error": "body must be JSON"}, status=400)

        text = str(payload.get("text", "")).strip()
        if not text:
            return web.json_response({"error": "field 'text' is required"}, status=400)

        result = answer(text)
        if hasattr(result, "__await__"):
            result = await result
        return web.json_response({"text": result})

    async def health(request: web.Request) -> web.Response:
        return web.json_response({"status": "ok", "channel": "dev"})

    app = web.Application()
    app.router.add_post("/dev/chat", chat)
    app.router.add_get("/dev/health", health)
    return app


async def start_dev_channel(
    answer: Callable[[str], Awaitable[str]] | Callable[[str], str],
    port: int | None = None,
) -> web.AppRunner | None:
    """Start the dev channel if enabled. Returns None when it is not."""
    if not dev_channel_enabled():
        return None

    port = port or int(os.getenv("A365_DEV_CHANNEL_PORT", DEFAULT_DEV_PORT))
    runner = web.AppRunner(build_dev_channel_app(answer))
    await runner.setup()
    # 127.0.0.1, never 0.0.0.0: nothing off this machine can reach it directly.
    await web.TCPSite(runner, "127.0.0.1", port).start()

    logger.warning(
        "DEV CHANNEL ENABLED on http://127.0.0.1:%d/dev/chat -- authentication is "
        "bypassed on this port. Never set A365_DEV_CHANNEL=true outside local "
        "development, and never point a tunnel at this port.",
        port,
    )
    return runner
```

## Starting it

Call it from the host's startup coroutine, after the production listener is bound. It returns
`None` immediately when the flag is absent, so the call can stay in permanently.

```python
from dev_channel import start_dev_channel

async def start_server(self) -> None:
    # ... existing setup, production site started ...
    await start_dev_channel(self._answer)
```

`self._answer` must be the same function the production handler calls. Wiring the dev channel
to a separate code path would make it prove nothing.

If the agent's answer function is synchronous, pass it unchanged — the module awaits the
result only when it is awaitable.

## Checking it

```bash
A365_DEV_CHANNEL=true python host_agent_server.py
```

```bash
curl -s http://127.0.0.1:3999/dev/health
curl -s -X POST http://127.0.0.1:3999/dev/chat \
  -H "content-type: application/json" -d '{"text":"hello"}'
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:3999/dev/chat \
  -H "content-type: application/json" -H "X-Forwarded-For: 1.2.3.4" -d '{"text":"hello"}'
```

Expect `200`, the agent's reply, then `403`.

On Windows PowerShell, quoting a JSON body inline is awkward; put it in a file and use
`--data @body.json`.

## Turning it off

Unset `A365_DEV_CHANNEL` or set it to anything other than `true`, and restart. Confirm the
port refuses the connection rather than assuming it.
