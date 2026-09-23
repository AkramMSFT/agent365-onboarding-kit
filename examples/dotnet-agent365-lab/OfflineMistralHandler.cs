using System.Net;
using System.Text;
using System.Text.Json;

internal sealed class OfflineMistralHandler(string toolName) : HttpMessageHandler
{
    public int RequestCount { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        RequestCount++;
        if (request.Method != HttpMethod.Post ||
            request.RequestUri?.AbsoluteUri != "https://api.mistral.ai/v1/chat/completions" ||
            request.Headers.Authorization?.Scheme != "Bearer" ||
            request.Headers.Authorization?.Parameter != "offline-mistral-key")
            throw new InvalidOperationException("Unexpected Mistral endpoint or authentication.");

        using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
        var root = body.RootElement;
        if (root.GetProperty("model").GetString() != "ministral-3b-2512" ||
            !root.GetProperty("tools").EnumerateArray().Any(tool =>
                tool.GetProperty("function").GetProperty("name").GetString() == toolName))
            throw new InvalidOperationException("Mistral request lost its model or tool definition.");

        object message;
        if (RequestCount == 1)
        {
            message = new
            {
                role = "assistant",
                content = (string?)null,
                tool_calls = new[]
                {
                    new
                    {
                        id = "call00001", type = "function",
                        function = new { name = toolName, arguments = "{\"text\":\"Hello Agent 365\"}" }
                    }
                }
            };
        }
        else
        {
            var result = root.GetProperty("messages").EnumerateArray()
                .Single(item => item.GetProperty("role").GetString() == "tool");
            if (RequestCount != 2 ||
                result.GetProperty("tool_call_id").GetString() != "call00001" ||
                result.GetProperty("content").GetString() != "3")
                throw new InvalidOperationException("Mistral request lost the tool result.");
            message = new { role = "assistant", content = "Word count: 3" };
        }

        var response = JsonSerializer.Serialize(new
        {
            id = "offline-response", @object = "chat.completion", created = 0,
            model = "ministral-3b-2512",
            choices = new[] { new { index = 0, message, finish_reason = RequestCount == 1 ? "tool_calls" : "stop" } },
            usage = new { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 }
        });
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(response, Encoding.UTF8, "application/json")
        };
    }
}
