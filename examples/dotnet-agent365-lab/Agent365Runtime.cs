using System.Text.Json;
using Microsoft.Agents.A365.Observability.Runtime.Common;
using Microsoft.Agents.A365.Observability.Runtime.Tracing.Contracts;
using Microsoft.Agents.A365.Observability.Runtime.Tracing.Scopes;
using Microsoft.Agents.A365.Tooling.Services;
using Microsoft.Agents.A365.Tooling.Extensions.AgentFramework.Services;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.OpenTelemetry;
using OpenTelemetry.Trace;

internal sealed class Agent365Runtime : IAsyncDisposable
{
    private readonly IHost host;
    private readonly SafeMcpServerService mcp;
    private readonly Agent365Tokens tokens;
    private readonly AgentDetails agentDetails;
    private readonly CallerDetails callerDetails;
    private readonly int expectedServers;
    private readonly ExporterStatus exporterStatus;
    public string AgentId { get; }
    public string MailSender { get; }
    public Agent365Scopes Scopes { get; }

    private Agent365Runtime(IHost host, Agent365Tokens tokens, int expectedServers, ExporterStatus exporterStatus)
    {
        this.host = host;
        this.tokens = tokens;
        this.expectedServers = expectedServers;
        this.exporterStatus = exporterStatus;
        mcp = host.Services.GetRequiredService<SafeMcpServerService>();
        var config = host.Services.GetRequiredService<IConfiguration>();
        MailSender = config.GetValue<bool>("Agent365Local:UseAgentMailboxForMail")
            ? Required(config, "Agent365Local:AgentMailbox:UserPrincipalName") : tokens.UserPrincipalName;
        AgentId = Required(config, "Agent365Observability:AgentId");
        agentDetails = new AgentDetails(
            agentId: AgentId,
            agentName: Required(config, "Agent365Observability:AgentName"),
            agentBlueprintId: Required(config, "Agent365Observability:AgentBlueprintId"),
            tenantId: tokens.TenantId);
        var user = new UserDetails(userId: tokens.UserId, userEmail: tokens.UserPrincipalName);
        callerDetails = new CallerDetails(userDetails: user);
        Scopes = new Agent365Scopes(agentDetails, user);
    }

    public static async Task<Agent365Runtime> StartAsync()
    {
        var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
        {
            EnvironmentName = Environments.Development,
            ContentRootPath = Directory.GetCurrentDirectory()
        });
        builder.Logging.ClearProviders();
        builder.Logging.AddSimpleConsole(options => options.SingleLine = true);
        builder.Logging.SetMinimumLevel(LogLevel.Warning);
        builder.Logging.AddFilter(typeof(WorkIqTool).FullName, LogLevel.Information);
        var exporterStatus = new ExporterStatus();
        builder.Logging.AddProvider(exporterStatus);
        builder.Logging.AddFilter<ExporterStatus>("Microsoft.Agents.A365.Observability.Runtime.Tracing.Exporters", LogLevel.Debug);
        using var settingsStream = File.OpenRead("appsettings.json");
        using var localStream = File.OpenRead(".a365-runtime.local.json");
        builder.Configuration.AddJsonStream(settingsStream).AddJsonStream(localStream).AddEnvironmentVariables();
        var config = builder.Configuration;
        var tokens = new Agent365Tokens(".a365-tokens.local.json",
            Required(config, "Agent365Observability:TenantId"),
            Required(config, "Agent365Local:UserId"),
            Required(config, "Agent365Local:UserPrincipalName"),
            Required(config, "Agent365Local:OperatorClientAppId"));
        var telemetryTokens = new Agent365OboTokenProvider(tokens,
            Required(config, "Agent365Observability:AgentBlueprintId"),
            Required(config, "Agent365Observability:AgentId"),
            Required(config, "Agent365Observability:ClientSecret"));
        await telemetryTokens.GetAsync();

        using var manifest = JsonDocument.Parse(File.Exists("ToolingManifest.json")
            ? File.ReadAllText("ToolingManifest.json") : "{\"mcpServers\":[]}");
        var configured = manifest.RootElement.GetProperty("mcpServers").EnumerateArray().ToArray();
        var disabled = (config.GetSection("Agent365Local:DisabledWorkIqServers").Get<string[]>() ?? []).ToHashSet(StringComparer.Ordinal);
        var configuredNames = configured.Select(server => server.GetProperty("mcpServerName").GetString()).ToHashSet(StringComparer.Ordinal);
        if (disabled.Any(name => !configuredNames.Contains(name)))
            throw new InvalidOperationException("A locally disabled Work IQ server is not in ToolingManifest.json.");
        foreach (var name in disabled) Console.Error.WriteLine($"Work IQ explicitly disabled in local configuration: {name}");
        var servers = configured.Where(server => !disabled.Contains(server.GetProperty("mcpServerName").GetString()!)).ToArray();
        if (servers.Length == 0) Console.WriteLine("Work IQ is not configured/enabled for this workspace; no remote tools will be loaded.");
        using var agentMailbox = config.GetValue<bool>("Agent365Local:UseAgentMailboxForMail") ? new AgentMailboxTokenProvider(config) : null;
        foreach (var server in servers)
        {
            var name = server.GetProperty("mcpServerName").GetString()
                ?? throw new InvalidOperationException("Missing MCP server name.");
            var audience = server.GetProperty("audience").GetString()
                ?? throw new InvalidOperationException("Missing MCP audience.");
            var scope = server.GetProperty("scope").GetString()
                ?? throw new InvalidOperationException("Missing MCP scope.");
            config[$"BEARER_TOKEN_{name.ToUpperInvariant().Replace('-', '_')}"] = name == "mcp_MailTools" && agentMailbox is not null
                ? await agentMailbox.GetAsync(audience, scope) : await tokens.GetAsync(audience, scope);
        }
        if (agentMailbox is not null) Console.WriteLine($"Mail tool identity: {agentMailbox.Mailbox} (agent user).");
        config["ASPNETCORE_ENVIRONMENT"] = "Development";
        config["SKIP_TOOLING_ON_ERRORS"] = "false";
        builder.Services.AddHttpClient();
        builder.Services.AddSingleton<HttpClient>(_ => new HttpClient(new TelemetryReceiptHandler(exporterStatus)
        {
            InnerHandler = new HttpClientHandler { AllowAutoRedirect = false }
        }));
        builder.Services.AddSingleton<SafeMcpServerService>();
        builder.Services.AddSingleton<IMcpToolServerConfigurationService>(sp => sp.GetRequiredService<SafeMcpServerService>());
        builder.Services.AddSingleton<IMcpToolRegistrationService, McpToolRegistrationService>();

        // A365 Observability - exchange the user's blueprint-scoped assertion for
        // an agent-identity OBO token; a CLI-client token cannot export for this agent.
        builder.UseMicrosoftOpenTelemetry(options =>
        {
            options.Exporters = ExportTarget.Agent365;
            options.Agent365.UseS2SEndpoint = false;
            options.Agent365.TokenResolver = (agentId, tenantId) =>
            {
                if (agentId != Required(config, "Agent365Observability:AgentId") || tenantId != tokens.TenantId)
                    throw new InvalidOperationException("Exporter identity does not match this workspace.");
                return ResolveTelemetryToken();
            };
        });
        async Task<string?> ResolveTelemetryToken() => await telemetryTokens.GetAsync();
        var host = builder.Build();
        try
        {
            await host.StartAsync();
            return new Agent365Runtime(host, tokens, servers.Length, exporterStatus);
        }
        catch
        {
            host.Dispose();
            throw;
        }
    }

    public async Task<IList<AITool>> GetToolsAsync()
    {
        if (expectedServers == 0) return [];
        // A365 WorkIQ - the SDK supports environment tokens outside an AgentApplication.
        // This console has no inbound HTTP turn; real hosted OBO requires UserAuthorization.
        // SDK 1.1.14-preview accepts null here but its public annotations still require hosted inputs.
#pragma warning disable CS8625
        var tools = await host.Services.GetRequiredService<IMcpToolRegistrationService>()
            .GetMcpToolsAsync(AgentId, null, null, null, "");
#pragma warning restore CS8625
        foreach (var entry in mcp.ToolCounts.OrderBy(entry => entry.Key, StringComparer.Ordinal))
            Console.WriteLine($"Work IQ {entry.Key}: {entry.Value} tools");
        if (mcp.ConnectedServers != expectedServers || tools.Count == 0)
            throw new InvalidOperationException("Work IQ did not connect to every configured server.");
        IList<AITool> namespaced = tools.Select(tool => tool is AIFunction function
            ? (AITool)new WorkIqTool(function, mcp.ServerFor(tool), host.Services.GetRequiredService<ILogger<WorkIqTool>>())
            : throw new InvalidOperationException("Work IQ returned a non-function tool.")).ToList();
        if (namespaced.Select(tool => tool.Name).Distinct(StringComparer.Ordinal).Count() != namespaced.Count)
            throw new InvalidOperationException("Work IQ returned duplicate names within a server.");
        return namespaced;
    }

    public IDisposable StartTurn()
    {
        var baggage = new BaggageBuilder().TenantId(tokens.TenantId).AgentId(AgentId)
            .UserId(tokens.UserId).UserEmail(tokens.UserPrincipalName).ChannelName("console").Build();
        var request = new Request(content: "[content omitted]", sessionId: Guid.NewGuid().ToString(),
            channel: new Channel("console"));
        try
        {
            var scope = InvokeAgentScope.Start(request: request,
                scopeDetails: new InvokeAgentScopeDetails(endpoint: new Uri("urn:agent365:local-console")),
                agentDetails: agentDetails, callerDetails: callerDetails);
            return new TurnScope(scope, baggage);
        }
        catch
        {
            baggage.Dispose();
            throw;
        }
    }

    private sealed class TurnScope(IDisposable scope, IDisposable baggage) : IDisposable
    {
        public void Dispose()
        {
            try { scope.Dispose(); }
            finally { baggage.Dispose(); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (host.Services.GetService<TracerProvider>() is { } provider && !provider.ForceFlush(15000))
                throw new InvalidOperationException("Timed out flushing Agent 365 telemetry.");
        }
        finally
        {
            try
            {
                await mcp.DisposeAsync();
                await host.StopAsync(TimeSpan.FromSeconds(15));
            }
            finally { host.Dispose(); }
        }
        exporterStatus.Verify();
        Console.WriteLine(exporterStatus.Summary);
    }

    private static string Required(IConfiguration configuration, string key) =>
        !string.IsNullOrWhiteSpace(configuration[key]) ? configuration[key]!
        : throw new InvalidOperationException($"Missing {key}. Complete Agent 365 setup first.");
}
