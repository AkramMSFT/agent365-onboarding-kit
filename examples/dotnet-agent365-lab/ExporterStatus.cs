using Microsoft.Extensions.Logging;
using System.Text.Json;

internal sealed class ExporterStatus : ILoggerProvider
{
    private int failed;
    private int succeeded;
    private int status;
    private int sent;
    private int rejected;

    public string Summary => Volatile.Read(ref sent) > 0
        ? $"Agent 365 telemetry: HTTP {Volatile.Read(ref status)}, {Volatile.Read(ref sent)} destination receipt(s) reported sent."
        : $"Agent 365 telemetry: HTTP {Volatile.Read(ref status)}. No per-destination sent receipt was supplied; verify portal visibility separately.";

    internal void RecordReceipt(string body)
    {
        if (string.IsNullOrWhiteSpace(body)) return;
        using var document = JsonDocument.Parse(body);
        Inspect(document.RootElement);
    }

    private void Inspect(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in element.EnumerateArray()) Inspect(child);
        }
        else if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Name == "status" && property.Value.ValueKind == JsonValueKind.String)
                {
                    var value = property.Value.GetString();
                    if (value == "sent") Interlocked.Increment(ref sent);
                    if (value is "rejected" or "not_routed") Interlocked.Increment(ref rejected);
                }
                else if (property.Name == "rejectedSpans" &&
                    long.TryParse(property.Value.ToString(), out var count) && count > 0)
                    Interlocked.Increment(ref rejected);
                Inspect(property.Value);
            }
        }
    }

    public ILogger CreateLogger(string categoryName) => new StatusLogger(this,
        categoryName.StartsWith("Microsoft.Agents.A365.Observability.Runtime.Tracing.Exporters.", StringComparison.Ordinal));
    public void Dispose() { }

    public void Verify()
    {
        if (Volatile.Read(ref rejected) > 0)
            throw new InvalidOperationException("Agent 365 returned a successful HTTP status but rejected or did not route telemetry. Verify tenant eligibility and span attributes.");
        if (Volatile.Read(ref failed) != 0)
            throw new InvalidOperationException($"Agent 365 telemetry export failed (last HTTP status: {Volatile.Read(ref status)}). Work IQ discovery does not prove telemetry delivery.");
        if (Volatile.Read(ref succeeded) == 0)
            throw new InvalidOperationException("No successful Agent 365 telemetry HTTP response was observed.");
    }

    private sealed class StatusLogger(ExporterStatus owner, bool exporter) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => exporter && logLevel >= LogLevel.Debug;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state,
            Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!exporter) return;
            if (logLevel >= LogLevel.Warning) Interlocked.Exchange(ref owner.failed, 1);
            if (state is not IEnumerable<KeyValuePair<string, object?>> fields) return;
            foreach (var field in fields)
            {
                if (field.Key != "StatusCode" || field.Value is not int code) continue;
                Interlocked.Exchange(ref owner.status, code);
                if (code is >= 200 and < 300) Interlocked.Increment(ref owner.succeeded);
                else Interlocked.Exchange(ref owner.failed, 1);
            }
        }
    }
}
