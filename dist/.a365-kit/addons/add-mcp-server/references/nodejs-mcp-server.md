# External MCP servers -- Node.js / TypeScript (OpenAI Agents SDK for JS)

Port of the Python reference. **Transcription, not yet run on a tenant** -- verify the class names against your `@openai/agents` version (`MCPServerStdio` / `MCPServerStreamableHttp` live in the package's `mcp` surface).

## `src/mcpServers.ts`

```typescript
import { MCPServerStdio, MCPServerStreamableHttp } from '@openai/agents';

/** External (non-Work-IQ) MCP servers. NOT registered in Agent 365, NOT Entra-gated. */
export function buildExternalMcpServers() {
  const servers: any[] = [];

  const fsRoot = process.env.AGENT_FS_ROOT;
  if (fsRoot) {
    servers.push(new MCPServerStdio({
      name: 'filesystem',
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-filesystem', fsRoot],
      cacheToolsList: true,
    }));
  }

  if (process.env.AGENT_ENABLE_FETCH_MCP === 'true') {
    servers.push(new MCPServerStdio({
      name: 'fetch', command: 'uvx', args: ['mcp-server-fetch'], cacheToolsList: true,
    }));
  }

  if (process.env.GITHUB_PERSONAL_ACCESS_TOKEN) {
    servers.push(new MCPServerStdio({
      name: 'github', command: 'npx', args: ['-y', '@modelcontextprotocol/server-github'],
      env: { GITHUB_PERSONAL_ACCESS_TOKEN: process.env.GITHUB_PERSONAL_ACCESS_TOKEN },
      cacheToolsList: true,
    }));
  }

  const httpUrl = process.env.AGENT_MCP_HTTP_URL;
  if (httpUrl) {
    servers.push(new MCPServerStreamableHttp({ name: 'remote', url: httpUrl, cacheToolsList: true }));
  }

  return servers;
}
```

## Wiring

```typescript
import { buildExternalMcpServers } from './mcpServers';

const externalMcp = buildExternalMcpServers();
// The SDK requires servers be connected before the run; connect all:
await Promise.all(externalMcp.map(s => s.connect()));

const agent = new Agent({
  name: '...',
  instructions: '... You also have external MCP tools: <describe>. Use them when relevant. ...',
  tools: [...existingTools],
  mcpServers: [...externalMcp],   // + Work IQ servers if attached
});
```

`npx` ships with Node; `uvx` needs `uv`. Verify with `npm run build`, start the agent, confirm the server's tools list. Same governance as the Python reference: scope tightly, secrets from env, treat output as untrusted, pair with `add-purview-dlp`.
