using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol.Protocol;
using System.Text.Json;

internal sealed class WorkIqTool(AIFunction inner, string server, ILogger<WorkIqTool>? logger = null) : DelegatingAIFunction(inner)
{
    private readonly ILogger<WorkIqTool> log = logger ?? NullLogger<WorkIqTool>.Instance;
    public override string Name { get; } = MakeName(server, inner.Name);
    public override string Description => $"Work IQ server {server}. {InnerFunction.Description}";

    protected override async ValueTask<object?> InvokeCoreAsync(AIFunctionArguments arguments, CancellationToken cancellationToken)
    {
        log.LogInformation("Work IQ tool {Tool}: invoked.", Name);
        try
        {
            var result = await base.InvokeCoreAsync(arguments, cancellationToken);
            var error = result is CallToolResponse { IsError: true } ||
                (result is JsonElement { ValueKind: JsonValueKind.Object } json &&
                 json.TryGetProperty("isError", out var isError) && isError.ValueKind == JsonValueKind.True);
            if (error) log.LogWarning("Work IQ tool {Tool}: returned an MCP error. Arguments and results are not logged.", Name);
            else log.LogInformation("Work IQ tool {Tool}: completed. Arguments and results are not logged.", Name);
            return result;
        }
        catch (Exception error)
        {
            log.LogWarning("Work IQ tool {Tool}: failed with {ErrorType}. Arguments and results are not logged.", Name, error.GetType().Name);
            throw;
        }
    }

    internal static string MakeName(string server, string tool)
    {
        var raw = $"{(server.StartsWith("mcp_", StringComparison.Ordinal) ? server[4..] : server)}_{tool}";
        var safe = Regex.Replace(raw, "[^A-Za-z0-9_-]", "_");
        if (safe.Length <= 64 && safe == raw) return safe;
        var suffix = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(raw)))[..12].ToLowerInvariant();
        return safe[..Math.Min(51, safe.Length)] + "_" + suffix;
    }
}
