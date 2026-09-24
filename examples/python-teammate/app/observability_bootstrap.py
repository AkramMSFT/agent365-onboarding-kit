from __future__ import annotations

import asyncio
import os

from observability_tokens import token_resolver

_configured = False


class Agents16BaggageMiddleware:
    async def on_turn(self, context, logic) -> None:
        from microsoft.opentelemetry.a365.hosting.middleware.baggage_middleware import (
            BaggageMiddleware,
        )

        # Distro 1.2 middleware calls next(), but Agents 1.6 expects next(context).
        await BaggageMiddleware().on_turn(context, lambda: logic(context))


def configure_observability() -> None:
    global _configured
    if _configured:
        return
    from microsoft.opentelemetry import use_microsoft_opentelemetry

    enabled = os.getenv("ENABLE_A365_OBSERVABILITY_EXPORTER", "false").strip().lower()
    if enabled not in {"true", "false"}:
        raise ValueError("ENABLE_A365_OBSERVABILITY_EXPORTER must be true or false")
    use_microsoft_opentelemetry(
        enable_a365=True,
        a365_enable_observability_exporter=(enabled == "true"),
        enable_console=(enabled == "false"),
        a365_token_resolver=token_resolver,
        instrumentation_options={
            "openai_agents": {"enabled": False},
            "langchain": {"enabled": False},
        },
    )
    _configured = True


async def shutdown_observability() -> None:
    if not _configured:
        return
    from opentelemetry import metrics, trace
    from opentelemetry._logs import get_logger_provider

    providers = (
        trace.get_tracer_provider(),
        metrics.get_meter_provider(),
        get_logger_provider(),
    )

    def finish() -> None:
        for provider in providers:
            flush = getattr(provider, "force_flush", None)
            shutdown = getattr(provider, "shutdown", None)
            try:
                if callable(flush):
                    flush(timeout_millis=5000)
            finally:
                if callable(shutdown):
                    shutdown()

    # Flush on a worker thread: the exporter may still need the host loop for tokens.
    await asyncio.to_thread(finish)
