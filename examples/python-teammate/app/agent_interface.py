from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from microsoft_agents.hosting.core import Authorization, TurnContext


class AgentInterface(ABC):
    @abstractmethod
    async def initialize(self) -> None: ...

    @abstractmethod
    async def process_user_message(
        self,
        message: str,
        auth: Authorization,
        auth_handler_name: str | None,
        context: TurnContext,
    ) -> str: ...

    @abstractmethod
    async def cleanup(self) -> None: ...

    async def handle_agent_notification_activity(
        self,
        notification_type: str | None,
        payload: Any,
        context: TurnContext,
        auth: Authorization,
        auth_handler_name: str | None,
    ) -> str | None:
        return None
