using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Agents.A365.Observability.Runtime.Tracing.Contracts;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;

internal static class LabToolsChecks
{
    public static async Task RunAsync(AIFunction original)
    {
        var extra = AIFunctionFactory.Create(() => "preserved", "ExistingWorkIqFixture");
        var tools = Program.CreateToolList(original, [extra]);
        Check(tools.Count == 10 && ReferenceEquals(tools[0], original) && ReferenceEquals(tools[^1], extra),
            "Original and extra tools must be preserved.");
        Check(LabTools.CreateTools().Select(tool => tool.Name).SequenceEqual(new[]
        {
            "FetchUrl", "SummarizeUrlContent", "EncodeText", "DecodeText", "HashText",
            "TransformText", "CountText", "RegexExtract"
        }), "All eight lab tools must be registered.");
        foreach (var scheme in new[] { "base64", "base64url", "hex", "url", "rot13" })
        {
            const string text = "Hello \u4e16\u754c \U0001F600 +/";
            Check(LabTools.DecodeText(LabTools.EncodeText(text, scheme), scheme) == text, "Encoding round trip: " + scheme);
        }
        Check(LabTools.DecodeText("%%%", "base64").StartsWith("Decode failed:"), "Malformed encoding must report failure.");
        Check(LabTools.EncodeText("x", "unknown").StartsWith("Unknown scheme"), "Unknown encoding must report failure.");
        Check(LabTools.HashText("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA256 must match its known vector.");
        Check(LabTools.HashText("abc", "md5") == "900150983cd24fb0d6963f7d28e17f72" &&
            LabTools.HashText("abc", "sha1") == "a9993e364706816aba3e25717850c26c9cd0d89d" &&
            LabTools.HashText("abc", "sha512").Length == 128, "Hash algorithms must be available.");
        Check(LabTools.TransformText("A\U0001F600B", "reverse") == "B\U0001F600A", "Reverse must preserve Unicode code points.");
        Check(LabTools.TransformText(" a \n b ", "collapse-space") == "a b", "Whitespace transform failed.");
        Check(LabTools.CountText("") == "characters: 0  words: 0  lines: 1", "Empty text counts changed.");
        Check(LabTools.RegexExtract("a1 b2", @"([a-z])(\d)") == "a1\nb2", "Regex capture handling failed.");
        Check(LabTools.RegexExtract(new string('a', 150), "a").Split('\n').Length == 100, "Regex result cap failed.");
        Check(LabTools.RegexExtract("x", "(") == "Invalid regex.", "Invalid regex must report failure.");
        Check(LabTools.RegexExtract(new string('a', 100_000) + "!", "^(a+)+$") == "Regex timed out.", "Regex timeout failed.");

        using (var handler = new LabLoopClient())
        using (var client = handler.AsBuilder().UseFunctionInvocation().Build())
        {
            var agent = new ChatClientAgent(client, new ChatClientAgentOptions { ChatOptions = new ChatOptions { Tools = tools } });
            Check((await agent.RunAsync("Encode Hello using base64.")).ToString() == "SGVsbG8=" && handler.RequestCount == 2,
                "Real SDK must complete a lab-tool model/tool/model turn.");
        }

        var spans = 0;
        using (var listener = new ActivityListener
        {
            ShouldListenTo = _ => true,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
            ActivityStopped = activity => { if (activity.GetTagItem("gen_ai.operation.name")?.ToString() == "execute_tool") spans++; }
        })
        {
            ActivitySource.AddActivityListener(listener);
            var scopes = new Agent365Scopes(new AgentDetails("offline-agent", "offline-agent", tenantId: "offline-tenant"),
                new UserDetails("offline-user"));
            var scopedTools = Program.CreateToolList(original, [extra], scopes);
            var encode = (AIFunction)scopedTools.Single(tool => tool.Name == "EncodeText");
            var result = await encode.InvokeAsync(new AIFunctionArguments { ["text"] = "Hello", ["scheme"] = "base64" });
            Check(result?.ToString() == "SGVsbG8=" && spans == 1, "Lab tools must retain Agent 365 tool instrumentation.");
        }
        await VerifyFetchAsync();
        Console.WriteLine("Eight lab tools verified offline: SDK invocation, composition, telemetry, fetch bounds, encodings and text utilities.");
    }

    private static async Task VerifyFetchAsync()
    {
        using var handler = new FakeHttpHandler((request, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("local test")
        }));
        using var http = new HttpClient(handler);
        Check((await LabTools.FetchUrlCore("file:///secret", http, LabTools.FetchTimeout)).StartsWith("Refused:") &&
            handler.Requests == 0, "Unsupported schemes must not be requested.");
        Check((await LabTools.FetchUrlCore("http://127.0.0.1/lab", http, LabTools.FetchTimeout)).Contains("local test"),
            "Private addresses must remain allowed for the selected lab mode.");

        var oversized = new CountingStream(Encoding.UTF8.GetBytes(new string('x', LabTools.MaxFetchBytes + 20)));
        handler.Respond = (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(oversized) });
        var fetched = await LabTools.FetchUrlCore("https://example.invalid/large", http, LabTools.FetchTimeout);
        Check(oversized.BytesRead == LabTools.MaxFetchBytes + 1 &&
            fetched.Contains(new string('x', LabTools.MaxFetchBytes) + "\n[truncated to 200000 bytes]"),
            "Fetch must read only limit+1 bytes and return an explicit truncation marker.");

        var redirects = 0;
        handler.Respond = (request, _) => Task.FromResult(redirects++ < 5 ? Redirect("/next")
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("redirect success") });
        Check((await LabTools.FetchUrlCore("https://example.invalid/start", http, LabTools.FetchTimeout)).Contains("redirect success") &&
            redirects == 6, "Exactly five relative redirects must be permitted.");
        redirects = 0;
        handler.Respond = (_, _) => { redirects++; return Task.FromResult(Redirect("/loop")); };
        Check((await LabTools.FetchUrlCore("https://example.invalid/loop", http, LabTools.FetchTimeout)).Contains("too many redirects") &&
            redirects == 6, "A sixth redirect must be refused.");
        handler.Respond = (_, _) => Task.FromResult(Redirect("file:///secret"));
        var before = handler.Requests;
        Check((await LabTools.FetchUrlCore("https://example.invalid/start", http, LabTools.FetchTimeout)).StartsWith("Refused:") &&
            handler.Requests == before + 1, "Redirects must revalidate the scheme.");

        handler.Respond = async (_, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            throw new InvalidOperationException("Timeout cancellation was ignored.");
        };
        Check((await LabTools.FetchUrlCore("https://example.invalid/slow", http, TimeSpan.FromMilliseconds(30))).Contains("timed out"),
            "Timeout must include response headers.");
        handler.Respond = (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new SlowStream()) });
        Check((await LabTools.FetchUrlCore("https://example.invalid/slow-body", http, TimeSpan.FromMilliseconds(30))).Contains("timed out"),
            "Timeout must include response body reads.");
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        Check(await LabTools.FetchUrlCore("https://example.invalid/canceled", http, LabTools.FetchTimeout, canceled.Token) == "Fetch canceled.",
            "Caller cancellation must be honored.");

        var readable = LabTools.ReadableContent("HTTP 404 text/html\nfinal_url: https://example.invalid/\n\n<head>hidden</head><script>alert(1)</script><style>css</style><p>Hello &amp; world</p>");
        Check(readable == "HTTP 404 text/html\nfinal_url: https://example.invalid/\n\nHello & world",
            "Readable extraction must strip scripts, decode entities and preserve HTTP failure metadata.");
    }

    private static HttpResponseMessage Redirect(string location)
    {
        var response = new HttpResponseMessage(HttpStatusCode.Found);
        response.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
        return response;
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class FakeHttpHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        public Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } = respond;
        public int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Check(request.Headers.Authorization is null && !request.Headers.Contains("Cookie"),
                "Lab fetch must not attach agent credentials or cookies.");
            Requests++;
            return Respond(request, cancellationToken);
        }
    }

    private sealed class CountingStream(byte[] bytes) : MemoryStream(bytes)
    {
        public int BytesRead { get; private set; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var read = await base.ReadAsync(buffer, cancellationToken);
            BytesRead += read;
            return read;
        }
    }

    private sealed class SlowStream : MemoryStream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }
    }

    private sealed class LabLoopClient : IChatClient
    {
        public int RequestCount { get; private set; }
        public Task<ChatResponse> GetResponseAsync(IEnumerable<ChatMessage> messages, ChatOptions? options = null,
            CancellationToken cancellationToken = default)
        {
            RequestCount++;
            Check(options?.Tools?.Count == 10 && options.Tools.Any(tool => tool.Name == "EncodeText"),
                "Agent did not receive the complete composed tool list.");
            if (RequestCount == 1) return Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant,
            [
                new FunctionCallContent("offline-encode", "EncodeText", new Dictionary<string, object?> { ["text"] = "Hello", ["scheme"] = "base64" })
            ])));
            var result = messages.SelectMany(message => message.Contents).OfType<FunctionResultContent>().Single();
            Check(RequestCount == 2 && result.CallId == "offline-encode" && result.Result?.ToString() == "SGVsbG8=", "Incorrect lab tool result.");
            return Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, "SGVsbG8=")));
        }
        public IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(IEnumerable<ChatMessage> messages, ChatOptions? options = null,
            CancellationToken cancellationToken = default) => throw new NotSupportedException("Offline non-streaming fixture.");
        public object? GetService(Type serviceType, object? serviceKey = null) => serviceKey is null && serviceType.IsInstanceOfType(this) ? this : null;
        public void Dispose() { }
    }
}
