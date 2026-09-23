using Microsoft.Extensions.AI;

internal sealed class OfflineChatClient(string toolName) : IChatClient
{
    public int RequestCount { get; private set; }

    public Task<ChatResponse> GetResponseAsync(IEnumerable<ChatMessage> messages,
        ChatOptions? options = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RequestCount++;
        if (options?.Tools?.Any(tool => tool.Name == toolName) != true)
            throw new InvalidOperationException("Agent did not send its tool definition.");
        if (RequestCount == 1)
        {
            return Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant,
            [
                new FunctionCallContent("offline-count", toolName,
                    new Dictionary<string, object?> { ["text"] = "Hello Agent 365" })
            ])));
        }
        var result = messages.SelectMany(message => message.Contents).OfType<FunctionResultContent>().Single();
        if (RequestCount != 2 || result.CallId != "offline-count" || result.Result?.ToString() != "3")
            throw new InvalidOperationException("Unexpected SDK tool result.");
        return Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, "Word count: 3")));
    }

    public IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(IEnumerable<ChatMessage> messages,
        ChatOptions? options = null, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("This offline check is non-streaming.");

    public object? GetService(Type serviceType, object? serviceKey = null) =>
        serviceKey is null && serviceType.IsInstanceOfType(this) ? this : null;

    public void Dispose() { }
}
