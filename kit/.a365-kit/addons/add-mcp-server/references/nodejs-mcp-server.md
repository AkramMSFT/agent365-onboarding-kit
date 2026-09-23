# External MCP servers -- Node.js / TypeScript (OpenAI Agents SDK for JS)

Port of the Python reference. `MCPServerStdio` / `MCPServerStreamableHttp` are exported by
`@openai/agents`. Construction is lazy: connect before running, and close at host shutdown
or after partial startup failure. No tenant call is needed to check these lifecycle rules.

## `src/mcpServers.ts`

```typescript
import { MCPServerStdio, MCPServerStreamableHttp, type MCPServer } from '@openai/agents';

/** Direct MCP connections: no Agent 365 registration/approval/gateway routing is added here. */
export function buildExternalMcpServers() {
  const servers: MCPServer[] = [];

  const fsRoot = process.env.AGENT_FS_ROOT;
  if (fsRoot) {
    servers.push(new MCPServerStdio({
      name: 'filesystem',
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-filesystem', fsRoot],
      cacheToolsList: true,
      timeout: 30_000,
    }));
  }

  if (process.env.AGENT_ENABLE_FETCH_MCP === 'true') {
    servers.push(new MCPServerStdio({
      name: 'fetch', command: 'uvx', args: ['mcp-server-fetch'], cacheToolsList: true, timeout: 30_000,
    }));
  }

  if (process.env.GITHUB_PERSONAL_ACCESS_TOKEN) {
    servers.push(new MCPServerStdio({
      name: 'github', command: 'npx', args: ['-y', '@modelcontextprotocol/server-github'],
      env: { GITHUB_PERSONAL_ACCESS_TOKEN: process.env.GITHUB_PERSONAL_ACCESS_TOKEN },
      cacheToolsList: true,
      timeout: 30_000,
    }));
  }

  const httpUrl = process.env.AGENT_MCP_HTTP_URL;
  if (httpUrl) {
    servers.push(new MCPServerStreamableHttp({ name: 'remote', url: httpUrl, cacheToolsList: true, timeout: 30_000 }));
  }

  return servers;
}

export async function connectExternalMcpServers(servers = buildExternalMcpServers()) {
  const close = async () => {
    const results = await Promise.allSettled(servers.map(server => server.close()));
    for (const result of results) {
      if (result.status === 'rejected') console.warn('External MCP cleanup failed:', result.reason);
    }
  };
  try {
    for (const server of servers) await server.connect();
    return { servers, close };
  } catch (error) {
    await close();
    throw error;
  }
}
```

## Wiring

```typescript
import { connectExternalMcpServers } from './mcpServers';

const external = await connectExternalMcpServers();
try {
  const agent = new Agent({
    name: '...',
    instructions: '... You also have external MCP tools: <describe>. Use them when relevant. ...',
    tools: [...existingTools],
    mcpServers: [...existingMcpServers, ...external.servers],
  });
  await runAgentSession(agent); // existing host/session; resolves only on shutdown
} finally {
  await external.close();
}
```

`npx` ships with Node; `uvx` needs `uv`. Verify with `npm run build`, start the agent, confirm the server's tools list. Same governance as the Python reference: scope tightly, secrets from env, treat output as untrusted, pair with `add-purview-dlp`.
The session call and existing collections are adapter placeholders. Keep the `try/finally`
around the real host lifetime, not just construction of `Agent`. Preserve any framework
tool-name prefixing, and use fresh per-turn collections when attaching user-specific Work IQ
tools rather than modifying the shared base agent.
