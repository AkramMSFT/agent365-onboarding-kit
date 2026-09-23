using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Agents.A365.Observability.Runtime.Tracing.Contracts;
using Microsoft.Agents.A365.Observability.Runtime.Tracing.Scopes;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;

internal static class Agent365Checks
{
    public static async Task RunAsync(AIFunction function)
    {
        var tenant = "offline-tenant";
        var user = "offline-user";
        var upn = "offline@example.invalid";
        var audience = "offline-audience";
        var claims = new Dictionary<string, object>
        {
            ["tid"] = tenant, ["oid"] = user, ["upn"] = upn,
            ["aud"] = audience, ["scp"] = "Tools.ListInvoke.All",
            ["exp"] = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()
        };
        string Token() => "e30." + Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(claims)))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_') + ".offline";
        void Validate() => Agent365Tokens.Validate(Token(), audience, "Tools.ListInvoke.All", tenant, user, upn);
        Validate();
        foreach (var field in new[] { "tid", "oid", "upn", "aud", "scp", "exp" })
        {
            var original = claims[field];
            claims[field] = field == "exp" ? 0L : "wrong";
            ExpectFailure(Validate);
            claims[field] = original;
        }
        ExpectFailure(() => Agent365Tokens.Validate("malformed", audience, "Tools.ListInvoke.All", tenant, user, upn));
        claims["azp"] = "offline-cli";
        ExpectFailure(() => Agent365Tokens.Validate(Token(), audience, "Tools.ListInvoke.All", tenant, user, upn, "offline-agent"));
        claims["azp"] = "offline-agent";
        Agent365Tokens.Validate(Token(), audience, "Tools.ListInvoke.All", tenant, user, upn, "offline-agent");
        claims.Remove("upn");
        Agent365Tokens.Validate(Token(), audience, "Tools.ListInvoke.All", tenant, user, upn, "offline-agent");
        await VerifyOboAsync(false);
        await VerifyOboAsync(true);
        await VerifyOboAsync(false, graph: true);
        ExpectFailure(() => new Agent365OboTokenProvider(
            new Agent365Tokens(new Dictionary<string, string>(), tenant, user, upn),
            OfflineOboHandler.Blueprint, OfflineOboHandler.Blueprint, "offline-secret"));
        var named = new WorkIqTool(function, "mcp_MailTools");
        var differentlyNamed = new WorkIqTool(function, "mcp_TeamsServer");
        if (named.Name == differentlyNamed.Name || named.Name != $"MailTools_{function.Name}" ||
            named.JsonSchema.ToString() != function.JsonSchema.ToString())
            throw new InvalidOperationException("Work IQ namespace/schema preservation failed.");
        var namedResult = await named.InvokeAsync(new AIFunctionArguments { ["text"] = "Hello Agent 365" });
        if (namedResult?.ToString() != "3") throw new InvalidOperationException("Namespaced Work IQ dispatch failed.");
        var longName = WorkIqTool.MakeName("mcp_Example", new string('a', 100));
        if (longName.Length != 64 || longName != WorkIqTool.MakeName("mcp_Example", new string('a', 100)) ||
            longName == WorkIqTool.MakeName("mcp_Example", new string('a', 99) + "b") ||
            WorkIqTool.MakeName("mcp_Example", "a.b") == WorkIqTool.MakeName("mcp_Example", "a_b"))
            throw new InvalidOperationException("Bounded unique Work IQ naming failed.");

        using var status = new ExporterStatus();
        var logger = status.CreateLogger("Microsoft.Agents.A365.Observability.Runtime.Tracing.Exporters.Agent365ExporterCore");
        logger.LogDebug("HTTP {StatusCode}", 200);
        status.Verify();
        logger.LogDebug("HTTP {StatusCode}", 403);
        ExpectFailure(status.Verify);
        foreach (var receipt in new[]
        {
            "{\"results\":[{\"status\":\"rejected\"}]}",
            "{\"results\":[{\"status\":\"not_routed\"}]}",
            "{\"partialSuccess\":{\"rejectedSpans\":\"1\"}}"
        })
        {
            using var rejected = new ExporterStatus();
            rejected.CreateLogger("Microsoft.Agents.A365.Observability.Runtime.Tracing.Exporters.Agent365ExporterCore")
                .LogDebug("HTTP {StatusCode}", 200);
            rejected.RecordReceipt(receipt);
            ExpectFailure(rejected.Verify);
        }
        using var accepted = new ExporterStatus();
        accepted.CreateLogger("Microsoft.Agents.A365.Observability.Runtime.Tracing.Exporters.Agent365ExporterCore")
            .LogDebug("HTTP {StatusCode}", 200);
        accepted.RecordReceipt("{\"results\":[{\"status\":\"sent\"}],\"partialSuccess\":{\"rejectedSpans\":0}}");
        accepted.Verify();
        if (!accepted.Summary.Contains("1 destination receipt(s) reported sent"))
            throw new InvalidOperationException("Ingestion receipt was not recognized.");

        var operations = new List<string>();
        using var listener = new ActivityListener
        {
            ShouldListenTo = _ => true,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
            ActivityStopped = activity =>
            {
                if (activity.GetTagItem("gen_ai.operation.name") is string operation) operations.Add(operation);
            }
        };
        ActivitySource.AddActivityListener(listener);
        var details = new AgentDetails(agentId: "offline-agent", agentName: "offline-agent", tenantId: tenant);
        var scopes = new Agent365Scopes(details, new UserDetails(userId: user, userEmail: upn));
        using (var turn = InvokeAgentScope.Start(request: new Request(content: "[content omitted]"),
            scopeDetails: new InvokeAgentScopeDetails(new Uri("urn:agent365:offline-test")), agentDetails: details))
        {
            var model = new OfflineChatClient(function.Name);
            using var client = scopes.WrapClient(model, "offline-model", "InMemory").AsBuilder().UseFunctionInvocation().Build();
            var agent = new ChatClientAgent(client, new ChatClientAgentOptions
            {
                ChatOptions = new ChatOptions { Tools = [scopes.WrapTool(function)] }
            });
            var response = await agent.RunAsync("Count the words in Hello Agent 365.");
            if (response.ToString() != "Word count: 3" || model.RequestCount != 2)
                throw new InvalidOperationException("Instrumented offline agent/tool loop failed.");
        }
        if (!operations.Contains("invoke_agent") || !operations.Contains("execute_tool") ||
            !operations.Any(name => name.Equals("chat", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("Missing manual agent, inference or tool span: " + string.Join(", ", operations));
        Console.WriteLine("Agent 365 token guards, exporter failure reporting and manual tracing checks passed offline.");
    }

    private static async Task VerifyOboAsync(bool wrongClient, bool graph = false)
    {
        using var handler = new OfflineOboHandler { ReturnWrongClient = wrongClient, GraphResource = graph };
        var tokens = new Agent365Tokens(new Dictionary<string, string> { [OfflineOboHandler.Blueprint] = handler.UserToken },
            OfflineOboHandler.Tenant, OfflineOboHandler.User, OfflineOboHandler.Upn);
        var provider = new Agent365OboTokenProvider(tokens, OfflineOboHandler.Blueprint, OfflineOboHandler.Agent,
            "offline-secret", handler);
        if (wrongClient)
        {
            try { await provider.GetAsync(); }
            catch (InvalidOperationException error) when (handler.TokenRequests == 2 &&
                error.Message.StartsWith("Token identity", StringComparison.Ordinal)) { return; }
            throw new InvalidOperationException("The exporter accepted a token for the wrong client.");
        }
        if (graph) { await provider.GetGraphAsync(); await provider.GetGraphAsync(); }
        else { await provider.GetAsync(); await provider.GetAsync(); }
        if (handler.TokenRequests != 2)
            throw new InvalidOperationException("The OBO provider did not cache its validated token.");
    }

    private static void ExpectFailure(Action action)
    {
        try { action(); }
        catch (InvalidOperationException) { return; }
        throw new InvalidOperationException("Expected a validation failure.");
    }
}
