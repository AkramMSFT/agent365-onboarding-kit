# Node.js hosting layer for a blueprint-based Agent 365 agent

Reuse the structure of upstream's Node.js AI Teammate hosting layer, but apply the deltas
below. The blueprint's real `/api/messages` endpoint must remain authenticated even during
local development.

**Read** `.a365-kit/skills/make-ai-teammate/references/nodejs-ai-teammate.md`, section **"src/index.ts -- Hosting Layer"**, and create `src/index.ts` from it. Then apply the deltas below.

## Deltas for a non-AI-Teammate agent

1. **`agentApplication`** must come from your existing agent module. If the onboarding skills did not create an `AgentApplication` for you (they do only on the AI Teammate path), wrap your agent in one -- section **"src/agent.ts -- Agent Class > Core structure"** of the same reference shows the shape. Keep the wrapper in a new file; do not edit the module `instrument-observability` / `add-workiq-tools` wrote.
2. **Auth config.** `loadAuthConfigFromEnv()` reads the `CONNECTIONS__*` / `CONNECTIONSMAP__*` values stamped into `.env`. Replace the reference's conditional `isProduction ? loadAuthConfigFromEnv() : {}` with the unconditional load below. Do not use `NODE_ENV` as an authentication switch.
3. **Port.** `PORT` in `.env` wins; default 3978. If taken, pick another and use it for the tunnel.
4. **Health before auth.** `/api/health` is registered before `authorizeJWT` in the reference; keep that order.
5. **`adapter.onTurnError`** must be set (the reference does) or a turn error becomes an unhandled rejection and kills the process.

```typescript
const authConfig = loadAuthConfigFromEnv();
if (!authConfig.clientId) {
  throw new Error('A configured clientId is required for the authenticated messaging endpoint');
}
```

Use `import 'dotenv/config'` before modules that consume environment variables. Calling
`configDotenv()` between static imports is not sufficient in an ES-module build because
imports are evaluated before module-body statements. Preserve the route-level `try/catch`
around the awaited `adapter.process`, and keep health before `authorizeJWT`.
Continue using the project's production environment settings for tunneled/hosted Work IQ
discovery (commonly `NODE_ENV=production`); that setting must not disable JWT validation
when it is absent.

## Packages

```
@microsoft/agents-hosting
express
dotenv
```

Run the install; the onboarding skills edit `package.json` without installing.

## Verify

```bash
npm start                                     # or: npx tsx src/index.ts
curl -s http://localhost:3978/api/health      # 200
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3978/api/messages -H "Content-Type: application/json" -d '{"type":"message","text":"hi"}'   # 401 in every environment
```

Log signal for a real turn: `[A365] Activity received: message` (or the `[/api/messages]` line the reference logs).
For anonymous local chat, add `test-local-channel` on its separate loopback port; never
empty the production endpoint's auth configuration to make a playground connect.
