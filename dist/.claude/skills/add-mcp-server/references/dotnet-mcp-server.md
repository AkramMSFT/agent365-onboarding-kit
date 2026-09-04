# External MCP servers -- .NET

Port of the Python reference using the official `ModelContextProtocol` C# SDK. **Transcription, not yet run on a tenant** -- verify the package version and the client factory against the SDK you install.

## Package

```
dotnet add package ModelContextProtocol --prerelease
```

## `Tools/ExternalMcpServers.cs`

```csharp
using ModelContextProtocol.Client;
using Microsoft.Extensions.AI;

namespace YourNamespace.Tools;

/// External (non-Work-IQ) MCP servers. NOT registered in Agent 365, NOT Entra-gated.
public static class ExternalMcpServers
{
    public static async Task<IList<AITool>> BuildAsync()
    {
        var tools = new List<AITool>();

        // stdio example: filesystem, scoped to one directory
        var fsRoot = Environment.GetEnvironmentVariable("AGENT_FS_ROOT");
        if (!string.IsNullOrEmpty(fsRoot))
        {
            var client = await McpClientFactory.CreateAsync(new StdioClientTransport(new()
            {
                Name = "filesystem",
                Command = "npx",
                Arguments = ["-y", "@modelcontextprotocol/server-filesystem", fsRoot],
            }));
            tools.AddRange(await client.ListToolsAsync());
        }

        // streamable-HTTP example: a remote server you trust
        var httpUrl = Environment.GetEnvironmentVariable("AGENT_MCP_HTTP_URL");
        if (!string.IsNullOrEmpty(httpUrl))
        {
            var client = await McpClientFactory.CreateAsync(
                new SseClientTransport(new() { Name = "remote", Endpoint = new Uri(httpUrl) }));
            tools.AddRange(await client.ListToolsAsync());
        }

        return tools;
    }
}
```

## Wiring

`McpClientTool` implements `AITool`, so the results merge straight into the agent's tool collection -- **append**, do not replace the built-in or Work IQ tools:

```csharp
var externalTools = await ExternalMcpServers.BuildAsync();
// add externalTools to the ChatOptions.Tools / agent tool list you already build,
// and name them in the agent instructions so the model uses them.
```

Prerequisites and governance match the Python reference: `npx`/`uvx` for stdio servers, secrets from the environment, scope every server tightly, treat output as untrusted, and pair with `add-purview-dlp`. Build with `dotnet build` and confirm the agent still starts and lists the new tools.
