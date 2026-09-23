using System.Net.Http.Headers;
using System.Collections.Concurrent;
using Microsoft.Agents.A365.Tooling.Models;
using Microsoft.Agents.A365.Tooling.Services;
using Microsoft.Agents.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.AI;
using ModelContextProtocol.Client;

// Keep SDK catalog/token resolution, but retain TLS validation and own per-turn clients.
internal sealed class SafeMcpServerService(
    ILogger<IMcpToolServerConfigurationService> logger,
    IConfiguration configuration,
    IServiceProvider services,
    IHttpClientFactory httpClientFactory) :
    McpToolServerConfigurationService(logger, configuration, services, httpClientFactory), IAsyncDisposable, IDisposable
{
    private readonly ILogger serviceLogger = logger;
    private readonly HashSet<string> disabledServers =
        (configuration.GetSection("Agent365Local:DisabledWorkIqServers").Get<string[]>() ?? []).ToHashSet(StringComparer.Ordinal);
    private readonly ConcurrentBag<IMcpClient> clients = [];
    private readonly ConcurrentBag<HttpClient> httpClients = [];
    private readonly ConcurrentDictionary<string, int> toolCounts = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<AITool, string> toolServers = new(ReferenceEqualityComparer.Instance);
    public IReadOnlyDictionary<string, int> ToolCounts => toolCounts;
    public string ServerFor(AITool tool) => toolServers.TryGetValue(tool, out var server) ? server
        : throw new InvalidOperationException("An MCP tool has no originating server.");
    private bool disposed;
    private int connectedServers;
    public int ConnectedServers => Volatile.Read(ref connectedServers);

    public override async Task<List<MCPServerConfig>> ListToolServersAsync(string agentInstanceId, string authToken, ToolOptions toolOptions)
    {
        var servers = await base.ListToolServersAsync(agentInstanceId, authToken, toolOptions);
        return servers.Where(server => !disabledServers.Contains(server.mcpServerName)).ToList();
    }

    public override async Task<IList<McpClientTool>> GetMcpClientToolsAsync(
        ITurnContext turnContext, MCPServerConfig server, string authToken, ToolOptions toolOptions)
    {
        var endpoint = new Uri(server.url);
        if (endpoint.Scheme != Uri.UriSchemeHttps ||
            endpoint.Host != "agent365.svc.cloud.microsoft" || !endpoint.IsDefaultPort ||
            !endpoint.AbsolutePath.StartsWith("/agents/servers/", StringComparison.Ordinal))
            throw new InvalidOperationException("Work IQ endpoint is outside the approved Microsoft catalog host.");
        if (server.Headers is null ||
            !server.Headers.TryGetValue("Authorization", out var authorization) ||
            !authorization.StartsWith("Bearer ", StringComparison.Ordinal))
            throw new InvalidOperationException($"Missing per-server authorization for {server.mcpServerName}.");

        var http = new HttpClient(new CatalogHostGuard(serviceLogger) { InnerHandler = new HttpClientHandler { AllowAutoRedirect = false } })
        {
            Timeout = TimeSpan.FromSeconds(30)
        };
        httpClients.Add(http);
        http.DefaultRequestHeaders.Authorization = AuthenticationHeaderValue.Parse(authorization);
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Agent365LocalTestAgent/1.0");
        var transport = new SseClientTransport(new SseClientTransportOptions
        {
            Endpoint = endpoint,
            TransportMode = HttpTransportMode.StreamableHttp
        }, http);
        IMcpClient client;
        try
        {
            client = await McpClientFactory.CreateAsync(transport, new McpClientOptions
            {
                InitializationTimeout = TimeSpan.FromSeconds(30)
            });
        }
        catch
        {
            await transport.DisposeAsync();
            throw;
        }
        clients.Add(client);
        var tools = await client.ListToolsAsync();
        if (tools.Count == 0)
            throw new InvalidOperationException($"No tools returned by {server.mcpServerName}.");
        toolCounts[server.mcpServerName] = tools.Count;
        foreach (var tool in tools) toolServers[tool] = server.mcpServerName;
        Interlocked.Increment(ref connectedServers);
        return tools;
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        List<Exception> errors = [];
        foreach (var client in clients)
        {
            try { await client.DisposeAsync(); }
            catch (Exception error) { errors.Add(error); }
        }
        foreach (var http in httpClients) http.Dispose();
        if (errors.Count != 0) throw new AggregateException("MCP session cleanup failed.", errors);
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    private sealed class CatalogHostGuard(ILogger logger) : DelegatingHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri is not { Scheme: "https", Host: "agent365.svc.cloud.microsoft", IsDefaultPort: true })
                throw new InvalidOperationException("MCP transport attempted to leave the approved catalog host.");
            var response = await base.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode && !(request.Method == HttpMethod.Get &&
                response.StatusCode == System.Net.HttpStatusCode.MethodNotAllowed))
                logger.LogWarning("MCP {Method} {Endpoint} returned HTTP {StatusCode}.",
                    request.Method, request.RequestUri.GetLeftPart(UriPartial.Path), (int)response.StatusCode);
            return response;
        }
    }
}
