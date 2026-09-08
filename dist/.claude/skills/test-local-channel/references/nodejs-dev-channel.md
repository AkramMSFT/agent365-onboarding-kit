# Node.js — local dev channel

A faithful port of the Python module, which is the version that was run. **Not yet executed**
— check it against the four behaviours in the skill's Phase 3 before relying on it.

Uses only `node:http`, so it adds no dependency.

## The module

Write this as `src/devChannel.ts` (or `.js`, dropping the types) beside the host.

```typescript
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

// devtunnel host runs on the developer's own machine and forwards to a local port, so a
// request from the public internet still arrives with a remote address of 127.0.0.1. A
// loopback check alone would pass tunnelled traffic. These headers are the only reliable
// signal, and they are used to deny, never to grant.
const FORWARDING_HEADERS = [
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
  'forwarded',
];

const DEFAULT_DEV_PORT = 3999;

export function devChannelEnabled(): boolean {
  return (process.env.A365_DEV_CHANNEL ?? '').trim().toLowerCase() === 'true';
}

function looksProxied(req: IncomingMessage): boolean {
  return FORWARDING_HEADERS.some((h) => req.headers[h] !== undefined);
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(payload);
}

/**
 * Starts the dev channel if enabled; returns null when it is not.
 * `answer` must be the same function the production handler calls.
 */
export function startDevChannel(
  answer: (text: string) => string | Promise<string>,
  port?: number,
): Server | null {
  if (!devChannelEnabled()) {
    return null;
  }

  const listenPort = port ?? Number(process.env.A365_DEV_CHANNEL_PORT ?? DEFAULT_DEV_PORT);

  const server = createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/dev/health') {
      send(res, 200, { status: 'ok', channel: 'dev' });
      return;
    }
    if (req.method !== 'POST' || req.url !== '/dev/chat') {
      send(res, 404, { error: 'not found' });
      return;
    }
    if (looksProxied(req)) {
      console.warn(`Dev channel refused a proxied request from ${req.socket.remoteAddress}`);
      send(res, 403, { error: 'dev channel is local only and refuses proxied requests' });
      return;
    }

    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => chunks.push(c));
    req.on('end', () => {
      void (async () => {
        let text: string;
        try {
          text = String(JSON.parse(Buffer.concat(chunks).toString('utf8')).text ?? '').trim();
        } catch {
          send(res, 400, { error: 'body must be JSON' });
          return;
        }
        if (!text) {
          send(res, 400, { error: "field 'text' is required" });
          return;
        }
        try {
          send(res, 200, { text: await answer(text) });
        } catch (err) {
          send(res, 500, { error: String(err) });
        }
      })();
    });
  });

  // 127.0.0.1, never 0.0.0.0: nothing off this machine can reach it directly.
  server.listen(listenPort, '127.0.0.1', () => {
    console.warn(
      `DEV CHANNEL ENABLED on http://127.0.0.1:${listenPort}/dev/chat -- authentication is ` +
        'bypassed on this port. Never set A365_DEV_CHANNEL=true outside local development, ' +
        'and never point a tunnel at this port.',
    );
  });

  return server;
}
```

## Starting it

Call it once from the host's startup, after the production listener is bound:

```typescript
import { startDevChannel } from './devChannel';

startDevChannel((text) => agent.ask(text));
```

`agent.ask` must be the same function the production handler calls.

## Checking it

```bash
A365_DEV_CHANNEL=true npm start
```

Then run the four checks from Phase 3 of the skill. The one that matters most is the
`X-Forwarded-For` request returning 403, because it is the check that actually protects the
endpoint — the loopback bind does not.
