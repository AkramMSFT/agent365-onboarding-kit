# Lab tools -- Node.js / TypeScript (OpenAI Agents SDK for JS)

A port of the verified Python reference. The Graph-free tools are pure Node built-ins; only the web fetch uses the platform `fetch`. **Transcription, not yet run on a tenant** -- verify the `tool()` import path against your `@openai/agents` version.

## `src/labTools.ts`

```typescript
import { tool } from '@openai/agents';
import { z } from 'zod';
import { createHash } from 'node:crypto';

const MAX_FETCH_BYTES = 200_000;
const FETCH_TIMEOUT_MS = 15_000;

// -- web --------------------------------------------------------------------
export const fetchUrl = tool({
  name: 'fetch_url',
  description: 'Fetch an http/https URL and return its text (up to ~200 KB).',
  parameters: z.object({ url: z.string() }),
  async execute({ url }) {
    if (!/^https?:\/\//i.test(url.trim())) return 'Refused: only http/https URLs are supported.';
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);
    try {
      const r = await fetch(url.trim(), { redirect: 'follow', signal: ac.signal,
        headers: { 'User-Agent': 'NorthwindAgent/1.0' } });
      const body = (await r.text()).slice(0, MAX_FETCH_BYTES);
      return `HTTP ${r.status} ${r.headers.get('content-type') ?? ''}\nfinal_url: ${r.url}\n\n${body}`;
    } catch (e) { return `Fetch failed: ${e instanceof Error ? e.message : String(e)}`; }
    finally { clearTimeout(t); }
  },
});

export const summarizeUrlContent = tool({
  name: 'summarize_url_content',
  description: 'Fetch a URL and return its text with HTML stripped, ready to summarise.',
  parameters: z.object({ url: z.string() }),
  async execute({ url }) {
    const raw = await (fetchUrl as any).execute({ url });
    if (raw.startsWith('Refused') || raw.startsWith('Fetch failed')) return raw;
    const body = raw.split('\n\n').slice(1).join('\n\n');
    const text = body.replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, ' ')
      .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    return text.slice(0, MAX_FETCH_BYTES) || 'No readable text found.';
  },
});

// -- encoding ---------------------------------------------------------------
export const encodeText = tool({
  name: 'encode_text',
  description: 'Encode text. scheme = base64 | base64url | hex | url | rot13.',
  parameters: z.object({ text: z.string(), scheme: z.string() }),
  async execute({ text, scheme }) {
    const s = scheme.trim().toLowerCase(); const b = Buffer.from(text, 'utf8');
    switch (s) {
      case 'base64': return b.toString('base64');
      case 'base64url': return b.toString('base64url');
      case 'hex': return b.toString('hex');
      case 'url': return encodeURIComponent(text);
      case 'rot13': return text.replace(/[a-z]/gi, c =>
        String.fromCharCode((c <= 'Z' ? 90 : 122) >= (c.charCodeAt(0) + 13) ? c.charCodeAt(0) + 13 : c.charCodeAt(0) - 13));
      default: return `Unknown scheme '${scheme}'.`;
    }
  },
});

export const decodeText = tool({
  name: 'decode_text',
  description: 'Decode text. scheme = base64 | base64url | hex | url | rot13.',
  parameters: z.object({ text: z.string(), scheme: z.string() }),
  async execute({ text, scheme }) {
    const s = scheme.trim().toLowerCase();
    try {
      switch (s) {
        case 'base64': case 'base64url': return Buffer.from(text, s as BufferEncoding).toString('utf8');
        case 'hex': return Buffer.from(text.trim(), 'hex').toString('utf8');
        case 'url': return decodeURIComponent(text);
        case 'rot13': return (encodeText as any).execute({ text, scheme: 'rot13' });
        default: return `Unknown scheme '${scheme}'.`;
      }
    } catch (e) { return `Decode failed: ${e instanceof Error ? e.message : String(e)}`; }
  },
});

export const hashText = tool({
  name: 'hash_text',
  description: 'Hash text. algo = md5 | sha1 | sha256 | sha512.',
  parameters: z.object({ text: z.string(), algo: z.string().default('sha256') }),
  async execute({ text, algo }) {
    const a = algo.trim().toLowerCase();
    if (!['md5', 'sha1', 'sha256', 'sha512'].includes(a)) return `Unknown algorithm '${algo}'.`;
    return createHash(a).update(text, 'utf8').digest('hex');
  },
});

// -- text -------------------------------------------------------------------
export const transformText = tool({
  name: 'transform_text',
  description: 'Transform text. operation = upper | lower | reverse | strip | collapse-space.',
  parameters: z.object({ text: z.string(), operation: z.string() }),
  async execute({ text, operation }) {
    switch (operation.trim().toLowerCase()) {
      case 'upper': return text.toUpperCase();
      case 'lower': return text.toLowerCase();
      case 'reverse': return [...text].reverse().join('');
      case 'strip': return text.trim();
      case 'collapse-space': return text.replace(/\s+/g, ' ').trim();
      default: return `Unknown operation '${operation}'.`;
    }
  },
});

export const countText = tool({
  name: 'count_text',
  description: 'Count characters, words and lines in text.',
  parameters: z.object({ text: z.string() }),
  async execute({ text }) {
    return `characters: ${text.length}  words: ${text.trim() ? text.trim().split(/\s+/).length : 0}  lines: ${text.split(/\r?\n/).length}`;
  },
});

export const LAB_TOOLS = [
  fetchUrl, summarizeUrlContent, encodeText, decodeText, hashText, transformText, countText,
];
```

## Wiring

```typescript
import { LAB_TOOLS } from './labTools';
// when building the Agent, append -- never replace:
const agent = new Agent({
  name: '...',
  instructions: '... You also have local utility tools: fetch_url, summarize_url_content, '
    + 'encode_text, decode_text, hash_text, transform_text, count_text. Use them when asked '
    + 'to open a link, decode a value, or manipulate text. ...',
  tools: [...existingTools, ...LAB_TOOLS],
});
```

No extra packages: `fetch`, `Buffer` and `node:crypto` are built in. Verify with `npm run build` and check the agent still starts.
