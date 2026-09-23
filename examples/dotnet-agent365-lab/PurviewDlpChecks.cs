using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;

internal static class PurviewDlpChecks
{
    private const string App = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    private const string User = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    private static readonly object[] Block = [new { action = "restrictAccess", restrictionAction = "block" }];
    private static string Token(bool appOnly = false) => "e30." +
        Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            oid = User, sub = "not-the-user-routing-id", aud = "00000003-0000-0000-c000-000000000000",
            scp = "ProtectionScopes.Compute.User Content.Process.User", idtyp = appOnly ? "app" : "user"
        }))).TrimEnd('=').Replace('+', '-').Replace('/', '_') + ".offline";

    public static async Task RunAsync()
    {
        using (var handler = new Handler())
        using (var dlp = Create(handler))
        {
            var conversation = new DlpConversation();
            var called = 0;
            Task<string> Model(CancellationToken _) { called++; return Task.FromResult("response"); }
            var first = await DlpTurnGuard.RunAsync(dlp, conversation, "prompt", Model);
            var second = await DlpTurnGuard.RunAsync(dlp, conversation, "prompt two", Model);
            Check(!first.Blocked && !second.Unchecked && called == 2, "Allowed turns did not complete.");
            Check(handler.Requests.Count == 5, "ETag cache should avoid redundant compute calls.");
            var entries = handler.Requests.Where(item => item.Path.EndsWith("processContent")).Select(item =>
                item.Body.GetProperty("contentToProcess").GetProperty("contentEntries")[0]).ToArray();
            Check(entries.Select(entry => entry.GetProperty("sequenceNumber").GetInt64()).SequenceEqual([0L, 1L, 2L, 3L]),
                "Stateful DLP sequences must increase.");
            Check(entries.All(entry => entry.GetProperty("correlationId").GetString() == conversation.CorrelationId),
                "Conversation correlation changed between turns.");
            Check(handler.Requests.Where(item => item.Path.EndsWith("processContent")).All(item => item.ETag == "\"v1\""),
                "processContent must send the computed ETag.");
        }
        using (var handler = new Handler { OnProcess = (body, _) => Json(new { protectionScopeState = "modified", policyActions = Array.Empty<object>() }) })
        using (var dlp = Create(handler))
        {
            await DlpTurnGuard.RunAsync(dlp, new DlpConversation(), "prompt", _ => Task.FromResult("reply"));
            Check(handler.Requests.Count == 4, "Modified protection state must invalidate the scope cache.");
        }
        foreach (var activity in new[] { "uploadText", "downloadText" })
        {
            using var handler = new Handler
            {
                OnProcess = (body, _) => Json(new
                {
                    policyActions = body.GetProperty("contentToProcess").GetProperty("activityMetadata").GetProperty("activity").GetString() == activity
                        ? Block : Array.Empty<object>()
                })
            };
            using var dlp = Create(handler);
            var called = false;
            var result = await DlpTurnGuard.RunAsync(dlp, new DlpConversation(), "prompt", _ =>
            {
                called = true;
                return Task.FromResult("private response must not be returned");
            });
            Check(result.Blocked && called == (activity == "downloadText") &&
                !result.Text.Contains("private response"), "A returned policy block was not enforced at its boundary.");
        }
        foreach (var failMode in new[] { "open", "closed" })
        {
            using var handler = new Handler { OnProcess = (_, _) => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) };
            using var dlp = Create(handler, failMode);
            var result = await DlpTurnGuard.RunAsync(dlp, new DlpConversation(), "prompt", _ => Task.FromResult("reply"));
            Check(result.Blocked == (failMode == "closed") && result.Unchecked, "HTTP errors did not follow the configured failure mode.");
            using var tokenHandler = new Handler();
            using var tokenDlp = Create(tokenHandler, failMode, _ => throw new InvalidOperationException("Token acquisition failed."));
            var tokenResult = await DlpTurnGuard.RunAsync(tokenDlp, new DlpConversation(), "prompt", _ => Task.FromResult("reply"));
            Check(tokenResult.Blocked == (failMode == "closed") && tokenResult.Unchecked && tokenHandler.Requests.Count == 0,
                "Token errors must follow the same fail mode without HTTP calls.");
        }
        using (var handler = new Handler { OnProcess = (_, _) => Json(new { policyActions = Block, processingErrors = new[] { new { code = "fixture" } } }) })
        using (var dlp = Create(handler, "open"))
        {
            var result = await DlpTurnGuard.RunAsync(dlp, new DlpConversation(), "prompt", _ => Task.FromResult("must not run"));
            Check(result.Blocked && !result.ModelInvoked && result.Text.Contains("organisation's data policy"),
                "Processing errors must not override a policy block in fail-open mode.");
        }
        foreach (var status in new[] { HttpStatusCode.Accepted, HttpStatusCode.NoContent })
        {
            using var handler = new Handler { OnProcess = (_, _) => new HttpResponseMessage(status) };
            using var dlp = Create(handler);
            var result = await dlp.EvaluateAsync("uploadText", "prompt", Guid.NewGuid().ToString(), 0);
            Check(result.Checked && !result.Blocked, "202/204 must succeed without parsing a body.");
        }
        using (var handler = new Handler())
        using (var dlp = Create(handler, "closed", _ => Task.FromResult(Token(appOnly: true))))
        {
            var result = await dlp.EvaluateAsync("uploadText", "prompt", Guid.NewGuid().ToString(), 0);
            Check(result.Blocked && handler.Requests.Count == 0, "An app-only oid must not be used as a delegated /users id.");
        }
        using (var handler = new Handler())
        using (var dlp = new PurviewDlp(new HttpClient(handler), NullLogger<PurviewDlp>.Instance,
            _ => throw new InvalidOperationException("Disabled DLP must not request tokens."), "", "closed", enabled: false))
        {
            var result = await DlpTurnGuard.RunAsync(dlp, new DlpConversation(), "prompt", _ => Task.FromResult("reply"));
            Check(!result.Blocked && handler.Requests.Count == 0, "Explicitly disabled DLP made a governance call.");
        }
        var shared = new DlpConversation();
        var sequences = Enumerable.Range(0, 100).AsParallel().Select(_ => shared.ReservePair()).Order().ToArray();
        Check(sequences.SequenceEqual(Enumerable.Range(0, 100).Select(index => (long)index * 2)), "Concurrent DLP sequence allocation collided.");
        Console.WriteLine("Purview contract, ETag, fail-mode, token, sequencing and prompt/reply block checks passed offline.");
    }

    private static PurviewDlp Create(Handler handler, string mode = "open", Func<CancellationToken, Task<string>>? token = null) =>
        new(new HttpClient(handler), NullLogger<PurviewDlp>.Instance, token ?? (_ => Task.FromResult(Token())), App, mode);
    private static HttpResponseMessage Json(object body) => new(HttpStatusCode.OK) { Content = JsonContent.Create(body) };
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed record RequestData(string Path, JsonElement Body, string? ETag);
    private sealed class Handler : HttpMessageHandler
    {
        public List<RequestData> Requests { get; } = [];
        public Func<JsonElement, int, HttpResponseMessage> OnProcess { get; init; } =
            (_, _) => Json(new { protectionScopeState = "notModified", policyActions = Array.Empty<object>() });
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Check(request.RequestUri?.Host == "graph.microsoft.com" &&
                request.RequestUri.AbsolutePath.StartsWith($"/v1.0/users/{User}/dataSecurityAndGovernance/", StringComparison.Ordinal),
                "Purview request used the wrong authority or user object ID.");
            Check(request.Headers.Authorization?.Scheme == "Bearer", "Missing delegated authentication.");
            var body = await request.Content!.ReadFromJsonAsync<JsonElement>(cancellationToken: cancellationToken);
            Requests.Add(new(request.RequestUri!.AbsolutePath, body, request.Headers.IfNoneMatch.FirstOrDefault()?.ToString()));
            if (request.RequestUri.AbsolutePath.EndsWith("protectionScopes/compute"))
            {
                Check(body.GetProperty("activities").GetString() == "uploadText,downloadText" &&
                    body.GetProperty("locations")[0].GetProperty("value").GetString() == App &&
                    body.GetProperty("locations")[0].GetProperty("@odata.type").GetString() == "microsoft.graph.policyLocationApplication",
                    "Incorrect compute contract or protected application location.");
                var response = Json(new { value = Array.Empty<object>() });
                response.Headers.ETag = new("\"v1\"");
                return response;
            }
            var content = body.GetProperty("contentToProcess");
            Check(content.GetProperty("protectedAppMetadata").GetProperty("applicationLocation").GetProperty("value").GetString() == App &&
                content.GetProperty("contentEntries")[0].GetProperty("@odata.type").GetString() == "microsoft.graph.processConversationMetadata" &&
                content.GetProperty("contentEntries")[0].GetProperty("content").GetProperty("@odata.type").GetString() == "microsoft.graph.textContent",
                "Incorrect processContent contract.");
            return OnProcess(body, Requests.Count);
        }
    }
}
