using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

internal sealed record DlpDecision(bool Blocked, bool Checked, string? Error = null, bool PolicyBlocked = false);

internal sealed class PurviewDlp : IDisposable
{
    private sealed record ScopeCache(string ETag, DateTimeOffset Expires, JsonElement[] Scopes);
    private readonly ConcurrentDictionary<string, ScopeCache> cache = new(StringComparer.Ordinal);
    private readonly HttpClient http;
    private readonly ILogger<PurviewDlp> logger;
    private readonly Func<CancellationToken, Task<string>> getToken;
    private readonly string appId;
    private readonly bool failClosed;
    public bool Enabled { get; }

    public PurviewDlp(HttpClient http, ILogger<PurviewDlp> logger, Func<CancellationToken, Task<string>> getToken,
        string appId, string failMode, bool enabled = true)
    {
        if (enabled && !Guid.TryParse(appId, out _)) throw new ArgumentException("PURVIEW_APP_LOCATION_ID must be the confirmed Entra application appId.");
        if (failMode is not ("open" or "closed")) throw new ArgumentException("PURVIEW_FAIL_MODE must be open or closed.");
        this.http = http;
        this.logger = logger;
        this.getToken = getToken;
        this.appId = appId;
        failClosed = failMode == "closed";
        Enabled = enabled;
    }

    public static PurviewDlp FromConfiguration(IConfiguration configuration, ILogger<PurviewDlp> logger)
    {
        var raw = configuration["ENABLE_PURVIEW_DLP"] ?? "false";
        if (!bool.TryParse(raw, out var enabled)) throw new ArgumentException("ENABLE_PURVIEW_DLP must be true or false.");
        var gate = new object();
        Agent365OboTokenProvider? provider = null;
        Task<string> GraphToken(CancellationToken cancellationToken)
        {
            lock (gate)
            {
                provider ??= new Agent365OboTokenProvider(
                    new Agent365Tokens(".a365-tokens.local.json", Required("Agent365Observability:TenantId"),
                        Required("Agent365Local:UserId"), Required("Agent365Local:UserPrincipalName"),
                        Required("Agent365Local:OperatorClientAppId")),
                    Required("Agent365Observability:AgentBlueprintId"), Required("Agent365Observability:AgentId"),
                    Required("Agent365Observability:ClientSecret"));
            }
            return provider.GetGraphAsync(cancellationToken);
        }
        string Required(string key) => !string.IsNullOrWhiteSpace(configuration[key]) ? configuration[key]!
            : throw new InvalidOperationException($"DLP token configuration is missing {key}.");
        return new PurviewDlp(new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
        {
            Timeout = TimeSpan.FromSeconds(20)
        }, logger, GraphToken, configuration["PURVIEW_APP_LOCATION_ID"] ?? "",
            (configuration["PURVIEW_FAIL_MODE"] ?? "open").Trim().ToLowerInvariant(), enabled);
    }

    public async Task<DlpDecision> EvaluateAsync(string activity, string text, string correlationId, long sequence,
        CancellationToken cancellationToken = default)
    {
        if (!Enabled) return new(false, false);
        try
        {
            if (activity is not ("uploadText" or "downloadText") || !Guid.TryParse(correlationId, out _) || sequence < 0)
                throw new ArgumentException("Invalid DLP activity, correlation ID or sequence.");
            var token = await getToken(cancellationToken);
            var user = TokenObjectId(token);
            if (!cache.TryGetValue(user, out var scopes) || scopes.Expires <= DateTimeOffset.UtcNow)
                scopes = await ComputeAsync(token, user, cancellationToken);
            if (scopes.Scopes.Any(scope => ActivityMatches(scope, activity) && HasBlock(scope)))
            {
                logger.LogWarning("Purview {Activity}: blocked by protection scope.", activity);
                return new(true, true, PolicyBlocked: true);
            }
            using var request = Request(token, user, "processContent");
            var now = DateTimeOffset.UtcNow.ToString("O");
            request.Content = JsonContent.Create(new
            {
                contentToProcess = new
                {
                    contentEntries = new[]
                    {
                        new Dictionary<string, object>
                        {
                            ["@odata.type"] = "microsoft.graph.processConversationMetadata",
                            ["identifier"] = Guid.NewGuid().ToString(),
                            ["content"] = new Dictionary<string, string> { ["@odata.type"] = "microsoft.graph.textContent", ["data"] = text },
                            ["name"] = $"Agent365Agent {activity}", ["correlationId"] = correlationId,
                            ["sequenceNumber"] = sequence, ["isTruncated"] = false,
                            ["createdDateTime"] = now, ["modifiedDateTime"] = now
                        }
                    },
                    activityMetadata = new { activity },
                    deviceMetadata = new { deviceType = "Unmanaged", ipAddress = "127.0.0.1" },
                    protectedAppMetadata = new { name = "Agent365Agent", version = "1.0", applicationLocation = Location() },
                    integratedAppMetadata = new { name = "Agent365Agent", version = "1.0" }
                }
            });
            if (!string.IsNullOrEmpty(scopes.ETag)) request.Headers.TryAddWithoutValidation("If-None-Match", scopes.ETag);
            using var response = await http.SendAsync(request, cancellationToken);
            if (response.StatusCode is HttpStatusCode.Accepted or HttpStatusCode.NoContent)
            {
                logger.LogInformation("Purview processContent ({Activity}) -> HTTP {Status}; accepted without a policy body.", activity, (int)response.StatusCode);
                return new(false, true);
            }
            if (response.StatusCode != HttpStatusCode.OK) return Failure(activity, $"processContent HTTP {(int)response.StatusCode}");
            var data = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken: cancellationToken);
            var state = data.TryGetProperty("protectionScopeState", out var value) ? value.GetString() : null;
            if (state == "modified") cache.TryRemove(user, out _);
            var blocked = HasBlock(data);
            if (data.TryGetProperty("processingErrors", out var errors) && errors.ValueKind != JsonValueKind.Null &&
                (errors.ValueKind != JsonValueKind.Array || errors.GetArrayLength() > 0))
            {
                var failure = Failure(activity, "processingErrors");
                return failure with { Blocked = blocked || failure.Blocked, PolicyBlocked = blocked };
            }
            logger.LogInformation("Purview processContent ({Activity}) -> 200: state={State}, blocked={Blocked}.", activity, state, blocked);
            return new(blocked, true, PolicyBlocked: blocked);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return Failure(activity, "timeout");
        }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException or
            InvalidOperationException or ArgumentException or FormatException or KeyNotFoundException)
        {
            return Failure(activity, error is HttpRequestException { StatusCode: { } status }
                ? $"HTTP {(int)status}" : error.GetType().Name);
        }
    }

    private async Task<ScopeCache> ComputeAsync(string token, string user, CancellationToken cancellationToken)
    {
        using var request = Request(token, user, "protectionScopes/compute");
        request.Content = JsonContent.Create(new { activities = "uploadText,downloadText", locations = new[] { Location() } });
        using var response = await http.SendAsync(request, cancellationToken);
        if (response.StatusCode != HttpStatusCode.OK)
            throw new HttpRequestException($"protectionScopes/compute HTTP {(int)response.StatusCode}", null, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken: cancellationToken);
        var values = data.GetProperty("value").EnumerateArray().Select(item => item.Clone()).ToArray();
        var snapshot = new ScopeCache(response.Headers.ETag?.ToString() ?? "", DateTimeOffset.UtcNow.AddMinutes(5), values);
        if (snapshot.ETag.Length != 0) cache[user] = snapshot;
        logger.LogInformation("Purview protectionScopes/compute -> 200: {Count} scope(s) for app {App}.", values.Length, appId);
        logger.LogInformation("Purview scope evaluation modes: {Modes}.", string.Join(", ",
            values.Select(value => value.TryGetProperty("executionMode", out var mode) ? mode.GetString() : "unspecified")));
        return snapshot;
    }

    private Dictionary<string, string> Location() => new() { ["@odata.type"] = "microsoft.graph.policyLocationApplication", ["value"] = appId };

    private static HttpRequestMessage Request(string token, string user, string operation)
    {
        var request = new HttpRequestMessage(HttpMethod.Post,
            $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(user)}/dataSecurityAndGovernance/{operation}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Add("Client-Request-Id", Guid.NewGuid().ToString());
        return request;
    }

    private static string TokenObjectId(string token)
    {
        using var document = Agent365Tokens.ParseClaims(token);
        var claims = document.RootElement;
        var user = claims.GetProperty("oid").GetString();
        var audience = claims.GetProperty("aud").GetString()?.TrimEnd('/');
        var scopes = claims.GetProperty("scp").GetString()?.Split(' ') ?? [];
        if (!Guid.TryParse(user, out _) || audience is not ("00000003-0000-0000-c000-000000000000" or "https://graph.microsoft.com") ||
            !scopes.Contains("ProtectionScopes.Compute.User") || !scopes.Contains("Content.Process.User") ||
            (claims.TryGetProperty("idtyp", out var type) && type.GetString() == "app"))
            throw new InvalidOperationException("A delegated Graph token with both Purview scopes and a user oid is required.");
        return user!;
    }

    private static bool ActivityMatches(JsonElement scope, string activity) =>
        scope.TryGetProperty("activities", out var value) &&
        (value.GetString() ?? "").Split(',').Any(item => item.Trim() == activity);

    private static bool HasBlock(JsonElement data) =>
        data.TryGetProperty("policyActions", out var actions) &&
        actions.EnumerateArray().Any(action =>
            action.TryGetProperty("action", out var name) && name.GetString() == "restrictAccess" &&
            action.TryGetProperty("restrictionAction", out var restriction) && restriction.GetString() == "block");

    private DlpDecision Failure(string activity, string error)
    {
        logger.LogWarning("Purview {Activity} failed ({Error}); fail-{Mode}: {Action}.",
            activity, error, failClosed ? "closed" : "open", failClosed ? "turn blocked" : "continuing WITHOUT a completed DLP check");
        return new(failClosed, false, error);
    }

    public void Dispose() => http.Dispose();
}
