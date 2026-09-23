# Lab tools -- Node.js / TypeScript (OpenAI Agents SDK for JS)

A port of the Python reference. `tool` is exported by `@openai/agents`; its returned
`FunctionTool` has `invoke`, not `execute`. Shared operations below use ordinary helpers.
These utilities need no tenant, and offline tests do not prove a hosted model integration.

## `src/labTools.ts`

```typescript
import { tool } from '@openai/agents';
import { z } from 'zod';
import { createHash } from 'node:crypto';

const MAX_FETCH_BYTES = 200_000;
const FETCH_TIMEOUT_MS = 15_000;

// -- web --------------------------------------------------------------------
async function fetchUrlText(url: string): Promise<string> {
    if (!/^https?:\/\//i.test(url.trim())) return 'Refused: only http/https URLs are supported.';
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);
    try {
      let current = new URL(url.trim());
      for (let redirects = 0; ; redirects++) {
        if (!['http:', 'https:'].includes(current.protocol)) return 'Refused: only http/https URLs are supported.';
        const r = await fetch(current, { redirect: 'manual', signal: ac.signal,
          headers: { 'User-Agent': 'NorthwindAgent/1.0' } });
        const location = r.headers.get('location');
        if ([301, 302, 303, 307, 308].includes(r.status) && location) {
          await r.body?.cancel();
          if (redirects >= 5) throw new Error('Too many redirects');
          current = new URL(location, current);
          continue;
        }
        const chunks: Uint8Array[] = [];
        let size = 0;
        const reader = r.body?.getReader();
        if (reader) {
          try {
            while (size <= MAX_FETCH_BYTES) {
              const { done, value } = await reader.read();
              if (done) break;
              const chunk = value.subarray(0, MAX_FETCH_BYTES + 1 - size);
              chunks.push(chunk);
              size += chunk.length;
            }
          } finally {
            await reader.cancel();
            reader.releaseLock();
          }
        }
        const body = Buffer.concat(chunks).subarray(0, MAX_FETCH_BYTES).toString('utf8');
        const note = size > MAX_FETCH_BYTES ? `\n\n[truncated to ${MAX_FETCH_BYTES} bytes]` : '';
        return `HTTP ${r.status} ${r.headers.get('content-type') ?? ''}\nfinal_url: ${r.url || current}\n\n${body}${note}`;
      }
    } catch (e) { return `Fetch failed: ${e instanceof Error ? e.message : String(e)}`; }
    finally { clearTimeout(t); }
}

export const fetchUrl = tool({
  name: 'fetch_url',
  description: 'Fetch an http/https URL and return its text (up to ~200 KB).',
  parameters: z.object({ url: z.string() }),
  execute: ({ url }) => fetchUrlText(url),
});

export const summarizeUrlContent = tool({
  name: 'summarize_url_content',
  description: 'Fetch a URL and return its text with HTML stripped, ready to summarise.',
  parameters: z.object({ url: z.string() }),
  async execute({ url }) {
    const raw = await fetchUrlText(url);
    if (raw.startsWith('Refused') || raw.startsWith('Fetch failed')) return raw;
    const body = raw.split('\n\n').slice(1).join('\n\n');
    const text = body.replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, ' ')
      .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    return text.slice(0, MAX_FETCH_BYTES) || 'No readable text found.';
  },
});

// -- encoding ---------------------------------------------------------------
function rot13(text: string): string {
  return text.replace(/[a-z]/gi, c => {
    const base = c <= 'Z' ? 65 : 97;
    return String.fromCharCode(base + (c.charCodeAt(0) - base + 13) % 26);
  });
}

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
      case 'rot13': return rot13(text);
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
        case 'rot13': return rot13(text);
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

export const regexExtract = tool({
  name: 'regex_extract',
  description: 'Return at most 100 regex matches, one per line.',
  parameters: z.object({ text: z.string(), pattern: z.string() }),
  async execute({ text, pattern }) {
    try {
      const matches: string[] = [];
      for (const match of text.matchAll(new RegExp(pattern, 'g'))) {
        matches.push(match.length > 1 ? match.slice(1).join('') : match[0]);
        if (matches.length === 100) break;
      }
      return matches.length ? matches.join('\n') : 'No matches.';
    } catch (e) { return `Invalid regex: ${e instanceof Error ? e.message : String(e)}`; }
  },
});

export const LAB_TOOLS = [
  fetchUrl, summarizeUrlContent, encodeText, decodeText, hashText, transformText, countText, regexExtract,
];
```

## Wiring

```typescript
import { LAB_TOOLS } from './labTools';
// when building the Agent, append -- never replace:
const agent = new Agent({
  name: '...',
  instructions: '... You also have local utility tools: fetch_url, summarize_url_content, '
    + 'encode_text, decode_text, hash_text, transform_text, count_text, regex_extract. Use them when asked '
    + 'to open a link, decode a value, or manipulate text. ...',
  tools: [...existingTools, ...LAB_TOOLS],
});
```

Ensure `@openai/agents` and `zod` are direct dependencies before installing. `fetch`, `Buffer`
and `node:crypto` are Node 18+ built-ins. Verify with `npm run build` and check the agent
still starts. Fetching streams at most 200 KB plus one byte and follows at most five redirects.
