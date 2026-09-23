using Microsoft.Agents.A365.Observability.Runtime.Tracing.Contracts;
using Microsoft.Agents.A365.Observability.Runtime.Tracing.Scopes;
using Microsoft.Extensions.AI;

internal sealed class Agent365Scopes(AgentDetails details, UserDetails user)
{
    private readonly AgentDetails agentDetails = details;
    private readonly UserDetails userDetails = user;
    private Request NewRequest() => new(content: "[content omitted]", channel: new Channel("console"));

    public IChatClient WrapClient(IChatClient client, string model, string provider = "Mistral") => new ScopedClient(client, this, model, provider);
    public AIFunction WrapTool(AIFunction tool) => new ScopedTool(tool, this);

    private sealed class ScopedClient(IChatClient inner, Agent365Scopes owner, string model, string provider) : DelegatingChatClient(inner)
    {
        public override async Task<ChatResponse> GetResponseAsync(IEnumerable<ChatMessage> messages,
            ChatOptions? options = null, CancellationToken cancellationToken = default)
        {
            using var scope = InferenceScope.Start(request: owner.NewRequest(),
                details: new InferenceCallDetails(InferenceOperationType.Chat, model, provider),
                agentDetails: owner.agentDetails, userDetails: owner.userDetails);
            return await base.GetResponseAsync(messages, options, cancellationToken);
        }
    }

    private sealed class ScopedTool(AIFunction inner, Agent365Scopes owner) : DelegatingAIFunction(inner)
    {
        protected override async ValueTask<object?> InvokeCoreAsync(AIFunctionArguments arguments,
            CancellationToken cancellationToken)
        {
            using var scope = ExecuteToolScope.Start(request: owner.NewRequest(),
                details: new ToolCallDetails(toolName: Name, arguments: "[arguments omitted]"),
                agentDetails: owner.agentDetails, userDetails: owner.userDetails);
            return await base.InvokeCoreAsync(arguments, cancellationToken);
        }
    }
}
