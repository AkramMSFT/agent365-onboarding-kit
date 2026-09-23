# Purview runtime DLP -- Python

Adapted from `purview_dlp.py` in the author's own Agent 365 deployment (not published), which ran against a live tenant with Purview collection and Risky Agents policies. Transport is `httpx`; the caller supplies the Graph bearer token.

## `purview_dlp.py` (project root)

```python
"""Runtime Microsoft Purview data-security integration for an Agent 365 agent.

  1. protectionScopes/compute  (ProtectionScopes.Compute.User) -> which activities need evaluation + ETag
  2. processContent            (Content.Process.User)          -> policyActions for uploadText / downloadText

Docs: https://learn.microsoft.com/en-us/purview/developer/use-the-api
The URL targets an authorized Entra user object ID. Delegated wiring can use the token's
user oid; app-only callers must supply a target user separately, never the token's SP oid.
"""
import datetime, json, logging, uuid
import httpx

logger = logging.getLogger(__name__)
GRAPH_BASE = "https://graph.microsoft.com/v1.0"
_ACTIVITIES = "uploadText,downloadText"


class PurviewDLP:
    def __init__(self, app_location_id: str, app_name: str = "Agent365Agent",
                 app_version: str = "1.0", fail_mode: str = "open"):
        self.app_location_id = app_location_id     # protected Entra appId matching the Purview policy location
        self.app_name, self.app_version = app_name, app_version
        self.fail_mode = (fail_mode or "open").strip().lower()
        if not app_location_id or not app_location_id.strip():
            raise ValueError("PURVIEW_APP_LOCATION_ID is required when DLP is enabled")
        if self.fail_mode not in ("open", "closed"):
            raise ValueError("PURVIEW_FAIL_MODE must be open or closed")
        self._etag_by_user: dict[str, str] = {}

    @property
    def _fail_blocked(self) -> bool:
        return self.fail_mode == "closed"

    def failure(self, error) -> dict:
        return {"blocked": self._fail_blocked, "actions": [], "error": str(error)}

    async def compute_scopes(self, client: httpx.AsyncClient, user_id: str) -> list:
        url = f"{GRAPH_BASE}/users/{user_id}/dataSecurityAndGovernance/protectionScopes/compute"
        body = {"activities": _ACTIVITIES,
                "locations": [{"@odata.type": "microsoft.graph.policyLocationApplication",
                               "value": self.app_location_id}]}
        r = await client.post(url, json=body)
        if r.status_code == 200:
            etag = r.headers.get("ETag") or r.headers.get("etag")
            if etag: self._etag_by_user[user_id] = etag
            value = r.json().get("value", [])
            logger.info("Purview protectionScopes/compute -> 200: %d scope(s) for app %s", len(value), self.app_location_id)
            return value
        logger.warning("Purview protectionScopes/compute -> %s: %s", r.status_code, r.text[:300])
        raise RuntimeError(f"protectionScopes/compute returned HTTP {r.status_code}")

    async def process_content(self, client: httpx.AsyncClient, user_id: str, activity: str,
                              text: str, correlation_id: str, sequence_number: int = 0) -> dict:
        url = f"{GRAPH_BASE}/users/{user_id}/dataSecurityAndGovernance/processContent"
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
        body = {"contentToProcess": {
            "contentEntries": [{
                "@odata.type": "microsoft.graph.processConversationMetadata",
                "identifier": str(uuid.uuid4()),
                "content": {"@odata.type": "microsoft.graph.textContent", "data": text},
                "name": f"{self.app_name} {activity}",
                "correlationId": correlation_id, "sequenceNumber": sequence_number,
                "isTruncated": False, "createdDateTime": now, "modifiedDateTime": now}],
            "activityMetadata": {"activity": activity},
            "deviceMetadata": {"deviceType": "Unmanaged", "ipAddress": "127.0.0.1"},
            "protectedAppMetadata": {"name": self.app_name, "version": self.app_version,
                "applicationLocation": {"@odata.type": "microsoft.graph.policyLocationApplication",
                                        "value": self.app_location_id}},
            "integratedAppMetadata": {"name": self.app_name, "version": self.app_version}}}
        headers = {}
        if (etag := self._etag_by_user.get(user_id)):
            headers["If-None-Match"] = etag
        r = await client.post(url, json=body, headers=headers)
        if r.status_code in (202, 204):
            return {"blocked": False, "actions": []}
        if r.status_code != 200:
            logger.warning("Purview processContent -> %s: %s", r.status_code, r.text[:300])
            return self.failure(f"processContent returned HTTP {r.status_code}")
        data = r.json()
        if data.get("protectionScopeState") == "modified":
            self._etag_by_user.pop(user_id, None)          # policies changed; recompute next turn
        actions = data.get("policyActions", []) or []
        blocked = any(a.get("action") == "restrictAccess" and a.get("restrictionAction") == "block" for a in actions)
        if data.get("processingErrors"):
            return {"blocked": blocked or self._fail_blocked, "actions": actions, "error": "processingErrors"}
        logger.info("Purview processContent (%s) -> state=%s, %d action(s)", activity, data.get("protectionScopeState"), len(actions))
        return {"blocked": blocked, "actions": actions, "state": data.get("protectionScopeState")}

    async def evaluate(self, graph_token: str, user_id: str, activity: str, text: str,
                       correlation_id: str, sequence_number: int = 0) -> dict:
        if not text or not text.strip():
            return {"blocked": False, "actions": []}
        try:
            if not graph_token or not user_id:
                return self.failure("Graph token and authorized user object id are required")
            async with httpx.AsyncClient(timeout=20.0, headers={"Authorization": f"Bearer {graph_token}",
                                                                "Content-Type": "application/json"}) as client:
                if user_id not in self._etag_by_user:
                    await self.compute_scopes(client, user_id)
                return await self.process_content(client, user_id, activity, text, correlation_id, sequence_number)
        except Exception as e:                       # governance must never crash the turn
            logger.warning("Purview evaluate(%s) error: %s", activity, e)
            return self.failure(e)


def token_object_id(jwt_token: str) -> str | None:
    """Unverified user-oid hint for delegated Graph tokens only; not an app-only user resolver."""
    import base64
    try:
        seg = jwt_token.split(".")[1]
        seg += "=" * (-len(seg) % 4)
        claims = json.loads(base64.urlsafe_b64decode(seg.encode("ascii")))
        oid = claims.get("oid")
        return oid if isinstance(oid, str) and oid else None
    except Exception:
        return None
```

Add `httpx>=0.27.0` to `requirements.txt` and install.

## Wiring into the turn

In the host's `_run_turn` (from `add-messaging-endpoint`) or the agent's `process_user_message`:

```python
import logging
import os
from purview_dlp import PurviewDLP, token_object_id

_PURVIEW = None
if os.getenv("ENABLE_PURVIEW_DLP", "false").strip().lower() == "true":
    _PURVIEW = PurviewDLP(os.getenv("PURVIEW_APP_LOCATION_ID", ""), app_name=AGENT_NAME,
                          fail_mode=os.getenv("PURVIEW_FAIL_MODE", "open"))

PURVIEW_SCOPES = ["https://graph.microsoft.com/Content.Process.User",
                  "https://graph.microsoft.com/ProtectionScopes.Compute.User"]


async def purview_evaluate(auth, context, auth_handler_name, activity, text, correlation_id, seq):
    if _PURVIEW is None:
        return {"blocked": False}
    try:
        kwargs = {"auth_handler_id": auth_handler_name} if auth_handler_name else {}
        token = await auth.exchange_token(context, scopes=PURVIEW_SCOPES, **kwargs)
        graph_token = getattr(token, "token", None) or getattr(token, "access_token", None)
        if not graph_token:
            return _PURVIEW.failure("Token exchange returned no Graph token")
        user_id = token_object_id(graph_token)            # the identity the token represents
        if not user_id:
            return _PURVIEW.failure("Graph token has no user object id")
        return await _PURVIEW.evaluate(graph_token, user_id, activity, text, correlation_id, seq)
    except Exception as e:
        logging.getLogger(__name__).warning("Purview evaluate(%s) error: %s", activity, e)
        return _PURVIEW.failure(e)
```

Then around the model call:

```python
import uuid

correlation_id = str(uuid.uuid4())  # one stateless prompt/reply pair
up = await purview_evaluate(self._authorization, context, AUTH_HANDLER_NAME, "uploadText", text, correlation_id, 0)
if up.get("blocked"):
    await context.send_activity("This request was blocked by your organisation's data policy.")
    return
reply = await self._agent.process_user_message(...)
dn = await purview_evaluate(self._authorization, context, AUTH_HANDLER_NAME, "downloadText", reply, correlation_id, 1)
if dn.get("blocked"):
    reply = "The response was withheld by your organisation's data policy."
await context.send_activity(reply)
```

`auth.exchange_token(context, scopes=..., auth_handler_id=...)` is the `Authorization` API on `microsoft-agents-hosting-core` 1.6.x; the AI Teammate sample calls it the same way.

For a stateful conversation, use its stable ID instead and allocate increasing sequence
numbers from conversation state; do not reuse 0/1 on every turn under the same ID. Token
decoding here is only a routing hint for an already-acquired delegated Graph token, not JWT
validation; `sub` is not an Entra object ID. App-only tokens need a separate user-targeting
and permission strategy. HTTP 202/204 are documented empty successes; HTTP/token failures
and `processingErrors` follow `PURVIEW_FAIL_MODE`, including before the REST calls.
Invalid enabled-DLP configuration fails startup instead of silently disabling the hooks.
