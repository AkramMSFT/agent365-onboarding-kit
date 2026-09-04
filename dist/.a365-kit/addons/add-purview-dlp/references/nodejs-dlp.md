# Purview runtime DLP -- Node.js / TypeScript

A port of the Python reference: the same two Graph calls over `fetch`. **The Graph contract is verified; this TypeScript is a faithful transcription, not yet run against a tenant** -- treat the token-exchange call as the one line to check against your `@microsoft/agents-hosting` version.

## `src/purview-dlp.ts`

```typescript
const GRAPH_BASE = 'https://graph.microsoft.com/v1.0';
const ACTIVITIES = 'uploadText,downloadText';

export type DlpResult = { blocked: boolean; actions: unknown[]; state?: string; error?: string | number };

export class PurviewDlp {
  private etagByUser = new Map<string, string>();
  constructor(
    private appLocationId: string,          // agent identity appId; PURVIEW_APP_LOCATION_ID
    private appName = 'Agent365Agent',
    private appVersion = '1.0',
    private failMode: 'open' | 'closed' = 'open',
  ) {}

  private get failBlocked() { return this.failMode === 'closed'; }

  private async computeScopes(token: string, userId: string): Promise<unknown[]> {
    const r = await fetch(`${GRAPH_BASE}/users/${userId}/dataSecurityAndGovernance/protectionScopes/compute`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        activities: ACTIVITIES,
        locations: [{ '@odata.type': 'microsoft.graph.policyLocationApplication', value: this.appLocationId }],
      }),
    });
    if (r.status !== 200) { console.warn(`Purview protectionScopes/compute -> ${r.status}`); return []; }
    const etag = r.headers.get('etag'); if (etag) this.etagByUser.set(userId, etag);
    const value = ((await r.json()) as { value?: unknown[] }).value ?? [];
    console.info(`Purview protectionScopes/compute -> 200: ${value.length} scope(s) for app ${this.appLocationId}`);
    return value;
  }

  private async processContent(token: string, userId: string, activity: 'uploadText' | 'downloadText',
                               text: string, correlationId: string, sequenceNumber: number): Promise<DlpResult> {
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, '');
    const body = { contentToProcess: {
      contentEntries: [{
        '@odata.type': 'microsoft.graph.processConversationMetadata',
        identifier: crypto.randomUUID(),
        content: { '@odata.type': 'microsoft.graph.textContent', data: text },
        name: `${this.appName} ${activity}`, correlationId, sequenceNumber,
        isTruncated: false, createdDateTime: now, modifiedDateTime: now,
      }],
      activityMetadata: { activity },
      deviceMetadata: { deviceType: 'Unmanaged', ipAddress: '127.0.0.1' },
      protectedAppMetadata: { name: this.appName, version: this.appVersion,
        applicationLocation: { '@odata.type': 'microsoft.graph.policyLocationApplication', value: this.appLocationId } },
      integratedAppMetadata: { name: this.appName, version: this.appVersion },
    } };
    const headers: Record<string, string> = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
    const etag = this.etagByUser.get(userId); if (etag) headers['If-None-Match'] = etag;
    const r = await fetch(`${GRAPH_BASE}/users/${userId}/dataSecurityAndGovernance/processContent`,
                          { method: 'POST', headers, body: JSON.stringify(body) });
    if (r.status === 304) return { blocked: false, actions: [] };
    if (r.status !== 200) { console.warn(`Purview processContent -> ${r.status}`); return { blocked: this.failBlocked, actions: [], error: r.status }; }
    const data = (await r.json()) as { protectionScopeState?: string; policyActions?: Array<{ action?: string; restrictionAction?: string }> };
    if (data.protectionScopeState === 'modified') this.etagByUser.delete(userId);
    const actions = data.policyActions ?? [];
    const blocked = actions.some(a => a.action === 'restrictAccess' && a.restrictionAction === 'block');
    console.info(`Purview processContent (${activity}) -> state=${data.protectionScopeState}, ${actions.length} action(s)`);
    return { blocked, actions, state: data.protectionScopeState };
  }

  async evaluate(token: string, userId: string, activity: 'uploadText' | 'downloadText',
                 text: string, correlationId: string, sequenceNumber = 0): Promise<DlpResult> {
    if (!text?.trim()) return { blocked: false, actions: [] };
    try {
      if (!this.etagByUser.has(userId)) await this.computeScopes(token, userId);
      return await this.processContent(token, userId, activity, text, correlationId, sequenceNumber);
    } catch (e) {                                    // governance must never crash the turn
      console.warn(`Purview evaluate(${activity}) error:`, e);
      return { blocked: this.failBlocked, actions: [], error: String(e) };
    }
  }
}

/** 'oid' claim of an access token, unverified. Purview's users/{id} must be the token subject. */
export function tokenObjectId(jwt: string): string | undefined {
  try {
    const seg = jwt.split('.')[1];
    const claims = JSON.parse(Buffer.from(seg, 'base64url').toString('utf8'));
    return claims.oid ?? claims.sub;
  } catch { return undefined; }
}
```

## Wiring into the turn (`src/agent.ts`, inside the message handler)

```typescript
import { PurviewDlp, tokenObjectId } from './purview-dlp';

const purview = process.env.ENABLE_PURVIEW_DLP === 'true' && process.env.PURVIEW_APP_LOCATION_ID
  ? new PurviewDlp(process.env.PURVIEW_APP_LOCATION_ID, AGENT_NAME, '1.0',
                   (process.env.PURVIEW_FAIL_MODE as 'open' | 'closed') ?? 'open')
  : undefined;

const PURVIEW_SCOPES = ['https://graph.microsoft.com/Content.Process.User',
                        'https://graph.microsoft.com/ProtectionScopes.Compute.User'];

async function purviewEvaluate(context, activity: 'uploadText' | 'downloadText', text: string, correlationId: string, seq: number) {
  if (!purview) return { blocked: false };
  try {
    // Verify this call against your @microsoft/agents-hosting version: the AgentApplication
    // exposes token exchange through its authorization object and the handler name from .env.
    const token = await agentApplication.authorization.exchangeToken(context, PURVIEW_SCOPES, AUTH_HANDLER_NAME);
    const accessToken = token?.token ?? token?.accessToken;
    if (!accessToken) return { blocked: false };
    const userId = tokenObjectId(accessToken);      // the identity the token represents
    if (!userId) return { blocked: false };
    return await purview.evaluate(accessToken, userId, activity, text, correlationId, seq);
  } catch (e) { console.warn(`Purview evaluate(${activity}) error:`, e); return { blocked: false }; }
}

// in the message handler:
const conversationId = context.activity.conversation?.id ?? 'conversation';
const up = await purviewEvaluate(context, 'uploadText', text, conversationId, 0);
if (up.blocked) { await context.sendActivity("This request was blocked by your organisation's data policy."); return; }
let reply = await runModel(text);
const dn = await purviewEvaluate(context, 'downloadText', reply, conversationId, 1);
if (dn.blocked) reply = "The response was withheld by your organisation's data policy.";
await context.sendActivity(reply);
```

No extra packages: `fetch`, `crypto.randomUUID` and `Buffer` are Node 18+ built-ins.
