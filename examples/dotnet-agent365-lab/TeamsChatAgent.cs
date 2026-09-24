using System.Text.Json;
using System.Collections.Concurrent;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Builder.State;
using Microsoft.Agents.Core.Models;
using Microsoft.Extensions.AI;

internal sealed class TeamsChatAgent : AgentApplication
{
    private readonly SemaphoreSlim turns = new(1, 1);
    private readonly PurviewDlp dlp;
    private readonly ConcurrentDictionary<string, DlpConversation> dlpConversations = new(StringComparer.Ordinal);

    public TeamsChatAgent(AgentApplicationOptions options, PurviewDlp dlp) : base(options)
    {
        this.dlp = dlp;
        OnActivity(ActivityTypes.Message, OnMessageAsync, isAgenticOnly: false);
        OnActivity(ActivityTypes.Message, OnMessageAsync, isAgenticOnly: true);
    }

    private async Task OnMessageAsync(ITurnContext context, ITurnState state, CancellationToken cancellationToken)
    {
        var prompt = context.Activity.Text ?? "";
        if (string.IsNullOrWhiteSpace(prompt) || prompt.Length > 4000)
        {
            await context.SendActivityAsync("Send a text message of 1 to 4000 characters.", cancellationToken: cancellationToken);
            return;
        }
        await turns.WaitAsync(cancellationToken);
        try
        {
            await context.SendActivityAsync(new Activity { Type = ActivityTypes.Typing }, cancellationToken);
            var conversationId = context.Activity.Conversation?.Id;
            if (string.IsNullOrWhiteSpace(conversationId)) throw new InvalidOperationException("Teams conversation identity is missing.");
            var conversation = dlpConversations.GetOrAdd(conversationId, _ => new DlpConversation());
            string? pendingSession = null;
            var result = await DlpTurnGuard.RunAsync(dlp, conversation, prompt, async token =>
            {
                // The HTTP guard restricts this local harness to the owner of these dev tokens.
                await using var runtime = await Agent365Runtime.StartAsync();
                using var turn = runtime.StartTurn();
                var function = runtime.Scopes.WrapTool(Program.CreateWordCounter());
                var tools = (await runtime.GetToolsAsync()).Select(tool => tool is AIFunction callable
                    ? (AITool)runtime.Scopes.WrapTool(callable) : tool).ToList();
                var model = ModelProviderSettings.FromEnvironment();
                using var client = Program.CreateProviderClient(model, scopes: runtime.Scopes);
                var agent = Program.CreateAgent(client, function, tools, runtime.AgentId, runtime.Scopes, runtime.MailSender);
                var saved = state.Conversation.GetValue<string?>("agentSession", () => null);
                var session = saved is null ? await agent.CreateSessionAsync(token)
                    : await agent.DeserializeSessionAsync(JsonSerializer.Deserialize<JsonElement>(saved), cancellationToken: token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(TimeSpan.FromSeconds(60));
                var response = await agent.RunAsync(prompt, session, cancellationToken: timeout.Token);
                var text = response.ToString();
                if (string.IsNullOrWhiteSpace(text)) throw new InvalidOperationException("The model returned an empty reply.");
                pendingSession = (await agent.SerializeSessionAsync(session, cancellationToken: token)).GetRawText();
                return text;
            }, cancellationToken);
            if (result.Unchecked && !result.Blocked)
                await context.SendActivityAsync("Warning: Purview could not complete a DLP check; this turn continued in fail-open mode.", cancellationToken: cancellationToken);
            await context.SendActivityAsync(result.Text, cancellationToken: cancellationToken);
            // Keep policy-blocked replies out of the saved conversation history.
            if (!result.Blocked && pendingSession is not null) state.Conversation.SetValue("agentSession", pendingSession);
        }
        finally { turns.Release(); }
    }
}
