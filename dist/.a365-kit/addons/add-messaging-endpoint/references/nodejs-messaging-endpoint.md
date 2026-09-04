# Node.js hosting layer for a blueprint-based Agent 365 agent

The Node.js hosting layer in upstream's AI Teammate reference is framework-neutral and works unchanged for a blueprint-based agent -- the identity model lives in `.env`, not in the host. Use it as-is:

**Read** `.a365-kit/skills/make-ai-teammate/references/nodejs-ai-teammate.md`, section **"src/index.ts -- Hosting Layer"**, and create `src/index.ts` from it. Then apply the deltas below.

## Deltas for a non-AI-Teammate agent

1. **`agentApplication`** must come from your existing agent module. If the onboarding skills did not create an `AgentApplication` for you (they do only on the AI Teammate path), wrap your agent in one -- section **"src/agent.ts -- Agent Class > Core structure"** of the same reference shows the shape. Keep the wrapper in a new file; do not edit the module `instrument-observability` / `add-workiq-tools` wrote.
2. **Auth config.** `loadAuthConfigFromEnv()` reads the `CONNECTIONS__*` / `CONNECTIONSMAP__*` values `a365 setup all` stamped into `.env`. The reference only loads it in production; for a dev tunnel set `NODE_ENV=production` so JWT validation is on -- Teams sends signed tokens and an anonymous POST must be rejected.
3. **Port.** `PORT` in `.env` wins; default 3978. If taken, pick another and use it for the tunnel.
4. **Health before auth.** `/api/health` is registered before `authorizeJWT` in the reference; keep that order.
5. **`adapter.onTurnError`** must be set (the reference does) or a turn error becomes an unhandled rejection and kills the process.

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
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3978/api/messages -H "Content-Type: application/json" -d '{"type":"message","text":"hi"}'   # 401 with NODE_ENV=production
```

Log signal for a real turn: `[A365] Activity received: message` (or the `[/api/messages]` line the reference logs).
