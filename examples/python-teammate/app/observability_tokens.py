from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any

from microsoft.opentelemetry.a365.runtime import get_observability_authentication_scope

logger = logging.getLogger(__name__)


def access_token(response: Any) -> str | None:
    value = response if isinstance(response, str) else getattr(response, "token", None)
    return value if isinstance(value, str) and value.strip() else None


def runtime_identity(context: Any) -> tuple[str, str] | None:
    recipient = getattr(context.activity, "recipient", None)
    agent_id = getattr(recipient, "agentic_app_id", None)
    tenant_id = getattr(recipient, "tenant_id", None)
    if not all(isinstance(value, str) and value.strip() for value in (agent_id, tenant_id)):
        return None
    return agent_id, tenant_id


@dataclass(frozen=True)
class _Binding:
    context: Any
    authorization: Any
    handler: str
    expires_at: float


class TurnTokenStore:
    def __init__(self, *, timeout: float = 15, ttl: float = 1800, capacity: int = 512):
        self.timeout = timeout
        self.ttl = ttl
        self.capacity = capacity
        self._lock = threading.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._bindings: OrderedDict[tuple[str, str], _Binding] = OrderedDict()
        self._pending: set[concurrent.futures.Future] = set()
        self._tasks: set[asyncio.Task] = set()

    def bind_loop(self) -> None:
        loop = asyncio.get_running_loop()
        with self._lock:
            if self._loop is not None and self._loop is not loop and self._loop.is_running():
                raise RuntimeError("A token store cannot serve two live host loops")
            self._loop = loop

    def register_turn(self, context: Any, authorization: Any, handler: str | None) -> bool:
        identity = runtime_identity(context)
        if identity is None or not handler or authorization is None:
            return False
        now = time.monotonic()
        with self._lock:
            if self._loop is None or not self._loop.is_running():
                return False
            expired = [key for key, binding in self._bindings.items() if binding.expires_at <= now]
            for key in expired:
                del self._bindings[key]
            self._bindings[identity] = _Binding(context, authorization, handler, now + self.ttl)
            self._bindings.move_to_end(identity)
            while len(self._bindings) > self.capacity:
                self._bindings.popitem(last=False)
        return True

    async def _exchange(self, binding: _Binding) -> str | None:
        if self._loop is not asyncio.get_running_loop():
            return None
        task = asyncio.current_task()
        self._tasks.add(task)
        try:
            response = await binding.authorization.exchange_token(
                binding.context, get_observability_authentication_scope(), binding.handler
            )
            return access_token(response)
        finally:
            self._tasks.discard(task)

    def resolve(self, agent_id: str, tenant_id: str) -> str | None:
        try:
            current_loop = asyncio.get_running_loop()
        except RuntimeError:
            current_loop = None
        with self._lock:
            loop = self._loop
            binding = self._bindings.get((agent_id, tenant_id))
            if (
                loop is None
                or not loop.is_running()
                or loop.is_closed()
                or loop is current_loop
                or binding is None
                or binding.expires_at <= time.monotonic()
            ):
                return None
            coroutine = self._exchange(binding)
            try:
                future = asyncio.run_coroutine_threadsafe(coroutine, loop)
            except RuntimeError:
                coroutine.close()
                return None
            self._pending.add(future)
        try:
            return future.result(timeout=self.timeout)
        except Exception as error:
            future.cancel()
            logger.warning("Observability token unavailable (%s)", type(error).__name__)
            return None
        finally:
            with self._lock:
                self._pending.discard(future)

    async def aclose(self) -> None:
        with self._lock:
            self._loop = None
            pending = tuple(self._pending)
            self._bindings.clear()
        for future in pending:
            future.cancel()
        # Let already-scheduled thread-safe callbacks create/cancel their tasks.
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        tasks = tuple(self._tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        with self._lock:
            self._pending.clear()


# Both the host producer and exporter consumer import this module, never __main__.
TOKEN_STORE = TurnTokenStore()
token_resolver = TOKEN_STORE.resolve
