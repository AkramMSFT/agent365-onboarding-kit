# External MCP servers -- .NET

Port of the Python reference using the official `ModelContextProtocol` C# SDK 1.x
(`McpClient.CreateAsync`, `HttpClientTransport`). The older preview
`McpClientFactory` / `SseClientTransport` names are not available in 1.x.

## Package

```
dotnet add package ModelContextProtocol --version 1.4.1
```

## `Tools/ExternalMcpServers.cs`

```csharp
using ModelContextProtocol.Client;
using Microsoft.Extensions.AI;

namespace YourNamespace.Tools;

/// Direct MCP connections: no Agent 365 registration/approval/gateway routing is added here.
public sealed class ExternalMcpServers : IAsyncDisposable
{
    private readonly List<McpClient> _clients = new();
    private readonly List<AITool> _tools = new();
    public IReadOnlyList<AITool> Tools => _tools;

    public static async Task<ExternalMcpServers> BuildAsync()
    {
        var result = new ExternalMcpServers();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {

        // Scope the filesystem server to one directory.
        var fsRoot = Environment.GetEnvironmentVariable("AGENT_FS_ROOT");
        if (!string.IsNullOrEmpty(fsRoot))
        {
            var client = await McpClient.CreateAsync(new StdioClientTransport(new()
            {
                Name = "filesystem",
                Command = "npx",
                Arguments = ["-y", "@modelcontextprotocol/server-filesystem", fsRoot],
            }), cancellationToken: timeout.Token);
            result._clients.Add(client);
            result._tools.AddRange((await client.ListToolsAsync(cancellationToken: timeout.Token))
                .Select(tool => tool.WithName($"filesystem_{tool.Name}")));
        }

        // Connect only to a remote server you trust.
        var httpUrl = Environment.GetEnvironmentVariable("AGENT_MCP_HTTP_URL");
        if (!string.IsNullOrEmpty(httpUrl))
        {
            var client = await McpClient.CreateAsync(
                new HttpClientTransport(new() {
                    Name = "remote", Endpoint = new Uri(httpUrl),
                    TransportMode = HttpTransportMode.StreamableHttp,
                }), cancellationToken: timeout.Token);
            result._clients.Add(client);
            result._tools.AddRange((await client.ListToolsAsync(cancellationToken: timeout.Token))
                .Select(tool => tool.WithName($"remote_{tool.Name}")));
        }

            return result;
        }
        catch
        {
            try { await result.DisposeAsync(); }
            catch (Exception cleanupError) { Console.Error.WriteLine($"External MCP cleanup failed: {cleanupError.Message}"); }
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        try { await Task.WhenAll(_clients.Select(client => client.DisposeAsync().AsTask())); }
        finally { _clients.Clear(); }
    }
}
```

## Wiring

`McpClientTool` implements `AITool`, so the results merge straight into the agent's tool collection -- **append**, do not replace the built-in or Work IQ tools:

```csharp
using YourNamespace.Tools;

await using var external = await ExternalMcpServers.BuildAsync();
// Append external.Tools to the existing ChatOptions.Tools / agent tool collection.
// Name them in the agent instructions so the model uses them.
await app.RunAsync(); // keep clients alive until the existing host stops
```

Prerequisites and governance match the Python reference: `npx`/`uvx` for stdio servers, secrets from the environment, scope every server tightly, treat output as untrusted, and pair with `purview-dlp-integration`. Build with `dotnet build` and confirm the agent still starts and lists the new tools.
Keep the disposable owner, not just the tool list. It closes all connected clients at
shutdown, including clients created before a startup/list-tools failure. The model-facing
names are prefixed per server; `WithName` preserves the original remote MCP tool name.
