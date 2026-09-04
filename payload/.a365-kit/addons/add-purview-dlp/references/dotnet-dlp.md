# Purview runtime DLP -- .NET

A port of the Python reference: the same two Graph calls over `HttpClient`. **The Graph contract is verified; this C# is a faithful transcription, not yet run against a tenant** -- the token-exchange call is the one line to check against your `Microsoft.Agents.*` version.

## `Governance/PurviewDlp.cs`

```csharp
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace YourNamespace.Governance;

public sealed record DlpResult(bool Blocked, IReadOnlyList<JsonElement> Actions, string? State = null, string? Error = null);

public sealed class PurviewDlp
{
    private const string GraphBase = "https://graph.microsoft.com/v1.0";
    private const string Activities = "uploadText,downloadText";
    private readonly Dictionary<string, string> _etagByUser = new();
    private readonly IHttpClientFactory _http;
    private readonly ILogger<PurviewDlp> _log;
    private readonly string _appLocationId, _appName, _appVersion;
    private readonly bool _failBlocked;

    public PurviewDlp(IHttpClientFactory http, ILogger<PurviewDlp> log, string appLocationId,
                      string appName = "Agent365Agent", string appVersion = "1.0", string failMode = "open")
    {
        _http = http; _log = log; _appLocationId = appLocationId;   // agent identity appId; PURVIEW_APP_LOCATION_ID
        _appName = appName; _appVersion = appVersion;
        _failBlocked = string.Equals(failMode, "closed", StringComparison.OrdinalIgnoreCase);
    }

    private HttpClient Client(string token)
    {
        var c = _http.CreateClient(); c.Timeout = TimeSpan.FromSeconds(20);
        c.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return c;
    }

    private async Task<int> ComputeScopesAsync(HttpClient c, string userId)
    {
        var body = new { activities = Activities,
            locations = new[] { new Dictionary<string, string> { ["@odata.type"] = "microsoft.graph.policyLocationApplication", ["value"] = _appLocationId } } };
        var r = await c.PostAsJsonAsync($"{GraphBase}/users/{userId}/dataSecurityAndGovernance/protectionScopes/compute", body);
        if ((int)r.StatusCode != 200) { _log.LogWarning("Purview protectionScopes/compute -> {S}", (int)r.StatusCode); return 0; }
        if (r.Headers.ETag is { } etag) _etagByUser[userId] = etag.ToString();
        var n = (await r.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("value").GetArrayLength();
        _log.LogInformation("Purview protectionScopes/compute -> 200: {N} scope(s) for app {App}", n, _appLocationId);
        return n;
    }

    private async Task<DlpResult> ProcessContentAsync(HttpClient c, string userId, string activity, string text, string correlationId, int seq)
    {
        var now = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss");
        var body = new { contentToProcess = new {
            contentEntries = new[] { new Dictionary<string, object> {
                ["@odata.type"] = "microsoft.graph.processConversationMetadata",
                ["identifier"] = Guid.NewGuid().ToString(),
                ["content"] = new Dictionary<string, string> { ["@odata.type"] = "microsoft.graph.textContent", ["data"] = text },
                ["name"] = $"{_appName} {activity}", ["correlationId"] = correlationId, ["sequenceNumber"] = seq,
                ["isTruncated"] = false, ["createdDateTime"] = now, ["modifiedDateTime"] = now } },
            activityMetadata = new { activity },
            deviceMetadata = new { deviceType = "Unmanaged", ipAddress = "127.0.0.1" },
            protectedAppMetadata = new { name = _appName, version = _appVersion,
                applicationLocation = new Dictionary<string, string> { ["@odata.type"] = "microsoft.graph.policyLocationApplication", ["value"] = _appLocationId } },
            integratedAppMetadata = new { name = _appName, version = _appVersion } } };
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{GraphBase}/users/{userId}/dataSecurityAndGovernance/processContent")
            { Content = JsonContent.Create(body) };
        if (_etagByUser.TryGetValue(userId, out var etag)) req.Headers.TryAddWithoutValidation("If-None-Match", etag);
        var r = await c.SendAsync(req);
        if ((int)r.StatusCode == 304) return new(false, Array.Empty<JsonElement>());
        if ((int)r.StatusCode != 200) { _log.LogWarning("Purview processContent -> {S}", (int)r.StatusCode); return new(_failBlocked, Array.Empty<JsonElement>(), Error: ((int)r.StatusCode).ToString()); }
        var data = await r.Content.ReadFromJsonAsync<JsonElement>();
        var state = data.TryGetProperty("protectionScopeState", out var s) ? s.GetString() : null;
        if (state == "modified") _etagByUser.Remove(userId);
        var actions = data.TryGetProperty("policyActions", out var pa) ? pa.EnumerateArray().ToList() : new List<JsonElement>();
        var blocked = actions.Any(a => a.TryGetProperty("action", out var ac) && ac.GetString() == "restrictAccess"
                                    && a.TryGetProperty("restrictionAction", out var ra) && ra.GetString() == "block");
        _log.LogInformation("Purview processContent ({A}) -> state={S}, {N} action(s)", activity, state, actions.Count);
        return new(blocked, actions, state);
    }

    public async Task<DlpResult> EvaluateAsync(string graphToken, string userId, string activity, string text, string correlationId, int seq = 0)
    {
        if (string.IsNullOrWhiteSpace(text)) return new(false, Array.Empty<JsonElement>());
        try
        {
            using var c = Client(graphToken);
            if (!_etagByUser.ContainsKey(userId)) await ComputeScopesAsync(c, userId);
            return await ProcessContentAsync(c, userId, activity, text, correlationId, seq);
        }
        catch (Exception e) { _log.LogWarning(e, "Purview evaluate({A}) error", activity); return new(_failBlocked, Array.Empty<JsonElement>(), Error: e.Message); }
    }

    /// 'oid' claim of an access token, unverified. Purview's users/{id} must be the token subject.
    public static string? TokenObjectId(string jwt)
    {
        try
        {
            var seg = jwt.Split('.')[1].Replace('-', '+').Replace('_', '/');
            seg = seg.PadRight(seg.Length + (4 - seg.Length % 4) % 4, '=');
            var claims = JsonSerializer.Deserialize<JsonElement>(Convert.FromBase64String(seg));
            return claims.TryGetProperty("oid", out var oid) ? oid.GetString() : claims.TryGetProperty("sub", out var sub) ? sub.GetString() : null;
        }
        catch { return null; }
    }
}
```

Register in `Program.cs`: `builder.Services.AddHttpClient();` (already present in the reference) and `builder.Services.AddSingleton(sp => new PurviewDlp(sp.GetRequiredService<IHttpClientFactory>(), sp.GetRequiredService<ILogger<PurviewDlp>>(), builder.Configuration["PURVIEW_APP_LOCATION_ID"]!, agentName, "1.0", builder.Configuration["PURVIEW_FAIL_MODE"] ?? "open"));` guarded by `ENABLE_PURVIEW_DLP == "true"`.

## Wiring into the turn (your `AgentApplication` subclass, message handler)

```csharp
private static readonly string[] PurviewScopes = {
    "https://graph.microsoft.com/Content.Process.User",
    "https://graph.microsoft.com/ProtectionScopes.Compute.User" };

private async Task<DlpResult> PurviewEvaluateAsync(ITurnContext turnContext, string activity, string text, string correlationId, int seq)
{
    if (_purview is null) return new(false, Array.Empty<JsonElement>());
    try
    {
        // Verify against your Microsoft.Agents.Builder version: the AgentApplication exposes
        // token exchange through its Authorization member and the handler name from configuration.
        var token = await Authorization.ExchangeTokenAsync(turnContext, PurviewScopes, AuthHandlerName);
        var access = token?.Token;
        if (string.IsNullOrEmpty(access)) return new(false, Array.Empty<JsonElement>());
        var userId = PurviewDlp.TokenObjectId(access);      // the identity the token represents
        if (userId is null) return new(false, Array.Empty<JsonElement>());
        return await _purview.EvaluateAsync(access, userId, activity, text, correlationId, seq);
    }
    catch (Exception e) { _logger.LogWarning(e, "Purview evaluate({A}) error", activity); return new(false, Array.Empty<JsonElement>()); }
}

// in OnMessageAsync:
var conversationId = turnContext.Activity.Conversation?.Id ?? "conversation";
var up = await PurviewEvaluateAsync(turnContext, "uploadText", text, conversationId, 0);
if (up.Blocked) { await turnContext.SendActivityAsync("This request was blocked by your organisation's data policy."); return; }
var reply = await RunModelAsync(text);
var dn = await PurviewEvaluateAsync(turnContext, "downloadText", reply, conversationId, 1);
if (dn.Blocked) reply = "The response was withheld by your organisation's data policy.";
await turnContext.SendActivityAsync(reply);
```

No extra NuGet packages beyond what the hosting reference already requires.
