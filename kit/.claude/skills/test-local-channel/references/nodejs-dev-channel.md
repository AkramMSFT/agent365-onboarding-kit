# Node.js — local dev channel

The module is covered by offline HTTP tests for the opt-in flag, loopback binding, valid and
invalid chat bodies, forwarding-header rejection and shutdown. Those tests do not verify
the consuming agent's production authentication or a live tenant.

Uses only `node:http`, so it adds no dependency.

## The module

Write this as `src/devChannel.ts` (or `.js`, dropping the types) beside the host.

```typescript
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

// The devtunnel host process runs on the developer's own machine and forwards to a local
// port, so a request from the public internet still arrives with a remote address of
// 127.0.0.1. A loopback check alone would pass tunnelled traffic. Header rejection is
// defense in depth: a proxy can omit the headers, so never expose this port through a tunnel.
const FORWARDING_HEADERS = [
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
  'forwarded',
];

const DEFAULT_DEV_PORT = 3999;
const MAX_BODY_BYTES = 64 * 1024;

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
    let size = 0;
    let tooLarge = false;
    req.on('data', (c: Buffer) => {
      if (tooLarge) return;
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        chunks.length = 0;
        send(res, 413, { error: 'body is too large' });
        return;
      }
      chunks.push(c);
    });
    req.on('error', () => {
      if (!res.headersSent) send(res, 400, { error: 'request interrupted' });
    });
    req.on('end', () => {
      if (tooLarge) return;
      void (async () => {
        let text: string;
        try {
          const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (!body || Array.isArray(body) || typeof body.text !== 'string') {
            send(res, 400, { error: "field 'text' must be a string" });
            return;
          }
          text = body.text.trim();
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

  // Bind to 127.0.0.1, never 0.0.0.0, so nothing off this machine can reach it directly.
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

const devChannel = startDevChannel((text) => agent.ask(text));
// Run this in the host's existing shutdown path, before disposing the model and tools.
if (devChannel) {
  await new Promise<void>((resolve, reject) =>
    devChannel.close(error => error ? reject(error) : resolve()));
}
```

`agent.ask` is an adapter placeholder, not an Agents SDK method. Use the same model/local-tool
call as production, without reusing per-user Work IQ clients or fabricating credentials.
The shutdown fragment belongs in the existing host's `finally`/shutdown handler, not
immediately after startup. Preserve its error handlers, and handle the returned server's
`error` event (for example, a busy dev port). This route does not verify auth-dependent DLP.

## Checking it

```bash
A365_DEV_CHANNEL=true npm start
```

Then run the four checks from Phase 3 of the skill. The one that matters most is the
`X-Forwarded-For` request returning 403. Forwarded-header checks supplement the loopback bind;
they cannot protect against proxies that omit headers. Never tunnel the dev port.
