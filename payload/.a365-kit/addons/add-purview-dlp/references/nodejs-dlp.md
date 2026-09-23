# Purview runtime DLP -- Node.js / TypeScript

A port of the Python reference: the same two Graph calls over `fetch`. **The Graph contract is verified; this TypeScript is a faithful transcription, not yet run against a tenant** -- treat the token-exchange call as the one line to check against your `@microsoft/agents-hosting` version.

## `src/purview-dlp.ts`

```typescript
import { randomUUID } from 'node:crypto';

const GRAPH_BASE = 'https://graph.microsoft.com/v1.0';
const ACTIVITIES = 'uploadText,downloadText';

export type DlpResult = { blocked: boolean; actions: unknown[]; state?: string; error?: string | number };

export class PurviewDlp {
  private etagByUser = new Map<string, string>();
  constructor(
    private appLocationId: string,          // protected Entra appId matching the Purview policy location
    private appName = 'Agent365Agent',
    private appVersion = '1.0',
    private failMode: 'open' | 'closed' = 'open',
  ) {
    if (!appLocationId?.trim()) throw new Error('PURVIEW_APP_LOCATION_ID is required when DLP is enabled');
    if (!['open', 'closed'].includes(failMode)) throw new Error('PURVIEW_FAIL_MODE must be open or closed');
  }

  private get failBlocked() { return this.failMode === 'closed'; }

  failure(error: unknown): DlpResult {
    return { blocked: this.failBlocked, actions: [], error: String(error) };
  }

  private async computeScopes(token: string, userId: string): Promise<unknown[]> {
    const r = await fetch(`${GRAPH_BASE}/users/${userId}/dataSecurityAndGovernance/protectionScopes/compute`, {
      method: 'POST',
      signal: AbortSignal.timeout(20_000),
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        activities: ACTIVITIES,
        locations: [{ '@odata.type': 'microsoft.graph.policyLocationApplication', value: this.appLocationId }],
      }),
    });
    if (r.status !== 200) throw new Error(`protectionScopes/compute returned HTTP ${r.status}`);
    const etag = r.headers.get('etag'); if (etag) this.etagByUser.set(userId, etag);
    const value = ((await r.json()) as { value?: unknown[] }).value ?? [];
    console.info(`Purview protectionScopes/compute -> 200: ${value.length} scope(s) for app ${this.appLocationId}`);
    return value;
  }

  private async processContent(token: string, userId: string, activity: 'uploadText' | 'downloadText',
                               text: string, correlationId: string, sequenceNumber: number): Promise<DlpResult> {
    const now = new Date().toISOString();
    const body = { contentToProcess: {
      contentEntries: [{
        '@odata.type': 'microsoft.graph.processConversationMetadata',
        identifier: randomUUID(),
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
                          { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
    if (r.status === 202 || r.status === 204) return { blocked: false, actions: [] };
    if (r.status !== 200) { console.warn(`Purview processContent -> ${r.status}`); return { blocked: this.failBlocked, actions: [], error: r.status }; }
    const data = (await r.json()) as { protectionScopeState?: string; policyActions?: Array<{ action?: string; restrictionAction?: string }>; processingErrors?: unknown[] };
    if (data.protectionScopeState === 'modified') this.etagByUser.delete(userId);
    const actions = data.policyActions ?? [];
    const blocked = actions.some(a => a.action === 'restrictAccess' && a.restrictionAction === 'block');
    if (data.processingErrors?.length) return { blocked: blocked || this.failBlocked, actions, error: 'processingErrors' };
    console.info(`Purview processContent (${activity}) -> state=${data.protectionScopeState}, ${actions.length} action(s)`);
    return { blocked, actions, state: data.protectionScopeState };
  }

  async evaluate(token: string, userId: string, activity: 'uploadText' | 'downloadText',
                 text: string, correlationId: string, sequenceNumber = 0): Promise<DlpResult> {
    if (!text?.trim()) return { blocked: false, actions: [] };
    try {
      if (!token || !userId) return this.failure('Graph token and authorized user object id are required');
      if (!this.etagByUser.has(userId)) await this.computeScopes(token, userId);
      return await this.processContent(token, userId, activity, text, correlationId, sequenceNumber);
    } catch (e) {                                    // governance must never crash the turn
      console.warn(`Purview evaluate(${activity}) error:`, e);
      return this.failure(e);
    }
  }
}

/** Unverified user-oid hint for delegated Graph tokens only; not an app-only user resolver. */
export function tokenObjectId(jwt: string): string | undefined {
  try {
    const seg = jwt.split('.')[1];
    const claims = JSON.parse(Buffer.from(seg, 'base64url').toString('utf8'));
    return typeof claims.oid === 'string' && claims.oid ? claims.oid : undefined;
  } catch { return undefined; }
}
```

## Wiring into the turn (`src/agent.ts`, inside the message handler)

```typescript
import { randomUUID } from 'node:crypto';
import type { TurnContext } from '@microsoft/agents-hosting';
import { PurviewDlp, tokenObjectId } from './purview-dlp';

const purview = process.env.ENABLE_PURVIEW_DLP?.trim().toLowerCase() === 'true'
  ? new PurviewDlp(process.env.PURVIEW_APP_LOCATION_ID ?? '', AGENT_NAME, '1.0',
                   (process.env.PURVIEW_FAIL_MODE?.trim().toLowerCase() as 'open' | 'closed') ?? 'open')
  : undefined;

const PURVIEW_SCOPES = ['https://graph.microsoft.com/Content.Process.User',
                        'https://graph.microsoft.com/ProtectionScopes.Compute.User'];

async function purviewEvaluate(context: TurnContext, activity: 'uploadText' | 'downloadText', text: string, correlationId: string, seq: number) {
  if (!purview) return { blocked: false };
  try {
    // Authorization.exchangeToken(context, scopes, authHandlerId) returns TokenResponse.
    const token = await agentApplication.authorization.exchangeToken(context, PURVIEW_SCOPES, AUTH_HANDLER_NAME);
    const accessToken = token?.token;
    if (!accessToken) return purview.failure('Token exchange returned no Graph token');
    const userId = tokenObjectId(accessToken);      // the identity the token represents
    if (!userId) return purview.failure('Graph token has no user object id');
    return await purview.evaluate(accessToken, userId, activity, text, correlationId, seq);
  } catch (e) { console.warn(`Purview evaluate(${activity}) error:`, e); return purview.failure(e); }
}

// in the message handler:
const correlationId = randomUUID(); // one stateless prompt/reply pair
const up = await purviewEvaluate(context, 'uploadText', text, correlationId, 0);
if (up.blocked) { await context.sendActivity("This request was blocked by your organisation's data policy."); return; }
let reply = await runModel(text);
const dn = await purviewEvaluate(context, 'downloadText', reply, correlationId, 1);
if (dn.blocked) reply = "The response was withheld by your organisation's data policy.";
await context.sendActivity(reply);
```

No extra packages: `fetch`, `node:crypto` and `Buffer` are Node 18+ built-ins. For a stateful
conversation, keep its ID and allocate increasing sequence numbers from conversation
state rather than resetting them to 0/1. Only an `oid` from a delegated Graph token is a
user-routing hint; `sub` is not an Entra object ID. This helper does not validate JWTs or
implement app-only user targeting. Token/HTTP failures and `processingErrors` honor the
configured fail mode; 202/204 are documented empty successes.
Invalid enabled-DLP configuration fails startup instead of silently disabling the hooks.
