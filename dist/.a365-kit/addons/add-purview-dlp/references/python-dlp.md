# Purview runtime DLP -- Python

Adapted from the Agent 365 + Claude reference deployment (`purview_dlp.py`), which ran against a live tenant with Purview collection and Risky Agents policies. Transport is `httpx`; the caller supplies the Graph bearer token.

## `purview_dlp.py` (project root)

```python
"""Runtime Microsoft Purview data-security integration for an Agent 365 agent.

  1. protectionScopes/compute  (ProtectionScopes.Compute.User) -> which activities need evaluation + ETag
  2. processContent            (Content.Process.User)          -> policyActions for uploadText / downloadText

Docs: https://learn.microsoft.com/en-us/purview/developer/use-the-api
The user_id in the URL MUST match the token's 'oid' claim -- see token_object_id() below.
"""
import datetime, json, logging, uuid
import httpx

logger = logging.getLogger(__name__)
GRAPH_BASE = "https://graph.microsoft.com/v1.0"
_ACTIVITIES = "uploadText,downloadText"


class PurviewDLP:
    def __init__(self, app_location_id: str, app_name: str = "Agent365Agent",
                 app_version: str = "1.0", fail_mode: str = "open"):
        self.app_location_id = app_location_id     # the agent identity appId; PURVIEW_APP_LOCATION_ID
        self.app_name, self.app_version = app_name, app_version
        self.fail_mode = (fail_mode or "open").lower()
        self._etag_by_user: dict[str, str] = {}

    @property
    def _fail_blocked(self) -> bool:
        return self.fail_mode == "closed"

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
        return []

    async def process_content(self, client: httpx.AsyncClient, user_id: str, activity: str,
                              text: str, correlation_id: str, sequence_number: int = 0) -> dict:
        url = f"{GRAPH_BASE}/users/{user_id}/dataSecurityAndGovernance/processContent"
        now = datetime.datetime.utcnow().replace(microsecond=0).isoformat()
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
        if r.status_code not in (200, 304):
            logger.warning("Purview processContent -> %s: %s", r.status_code, r.text[:300])
            return {"blocked": self._fail_blocked, "actions": [], "error": r.status_code}
        if r.status_code == 304:
            return {"blocked": False, "actions": []}
        data = r.json()
        if data.get("protectionScopeState") == "modified":
            self._etag_by_user.pop(user_id, None)          # policies changed; recompute next turn
        actions = data.get("policyActions", []) or []
        blocked = any(a.get("action") == "restrictAccess" and a.get("restrictionAction") == "block" for a in actions)
        logger.info("Purview processContent (%s) -> state=%s, %d action(s)", activity, data.get("protectionScopeState"), len(actions))
        return {"blocked": blocked, "actions": actions, "state": data.get("protectionScopeState")}

    async def evaluate(self, graph_token: str, user_id: str, activity: str, text: str,
                       correlation_id: str, sequence_number: int = 0) -> dict:
        if not text or not text.strip():
            return {"blocked": False, "actions": []}
        try:
            async with httpx.AsyncClient(timeout=20.0, headers={"Authorization": f"Bearer {graph_token}",
                                                                "Content-Type": "application/json"}) as client:
                if user_id not in self._etag_by_user:
                    await self.compute_scopes(client, user_id)
                return await self.process_content(client, user_id, activity, text, correlation_id, sequence_number)
        except Exception as e:                       # governance must never crash the turn
            logger.warning("Purview evaluate(%s) error: %s", activity, e)
            return {"blocked": self._fail_blocked, "actions": [], "error": str(e)}


def token_object_id(jwt_token: str) -> str | None:
    """'oid' claim of an access token, unverified. Purview's users/{id} must be the token subject."""
    import base64
    try:
        seg = jwt_token.split(".")[1]
        seg += "=" * (-len(seg) % 4)
        claims = json.loads(base64.urlsafe_b64decode(seg.encode("ascii")))
        return claims.get("oid") or claims.get("sub")
    except Exception:
        return None
```

Add `httpx>=0.27.0` to `requirements.txt` and install.

## Wiring into the turn

In the host's `_run_turn` (from `add-messaging-endpoint`) or the agent's `process_user_message`:

```python
import os
from purview_dlp import PurviewDLP, token_object_id

_PURVIEW = None
if os.getenv("ENABLE_PURVIEW_DLP", "false").lower() == "true" and os.getenv("PURVIEW_APP_LOCATION_ID"):
    _PURVIEW = PurviewDLP(os.environ["PURVIEW_APP_LOCATION_ID"], app_name=AGENT_NAME,
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
            return {"blocked": False}
        user_id = token_object_id(graph_token)            # the identity the token represents
        return await _PURVIEW.evaluate(graph_token, user_id, activity, text, correlation_id, seq)
    except Exception as e:
        logging.getLogger(__name__).warning("Purview evaluate(%s) error: %s", activity, e)
        return {"blocked": False}
```

Then around the model call:

```python
up = await purview_evaluate(self._authorization, context, AUTH_HANDLER_NAME, "uploadText", text, conversation_id, 0)
if up.get("blocked"):
    await context.send_activity("This request was blocked by your organisation's data policy.")
    return
reply = await self._agent.process_user_message(...)
dn = await purview_evaluate(self._authorization, context, AUTH_HANDLER_NAME, "downloadText", reply, conversation_id, 1)
if dn.get("blocked"):
    reply = "The response was withheld by your organisation's data policy."
await context.send_activity(reply)
```

`auth.exchange_token(context, scopes=..., auth_handler_id=...)` is the `Authorization` API on `microsoft-agents-hosting-core` 1.6.x; the AI Teammate sample calls it the same way.
