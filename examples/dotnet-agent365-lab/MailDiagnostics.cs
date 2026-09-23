using Microsoft.Extensions.AI;

internal static class MailDiagnostics
{
    public static async Task<int> RunAsync(PurviewDlp dlp, ModelProviderSettings settings)
    {
        await using var runtime = await Agent365Runtime.StartAsync();
        using var turn = runtime.StartTurn();
        var workIq = await runtime.GetToolsAsync();
        var tools = Program.CreateToolList(Program.CreateWordCounter(), workIq);
        Console.WriteLine($"Mail tools use the configured mailbox: {runtime.MailSender}");
        foreach (var name in new[] { "MailTools_SendEmailWithAttachments", "MailTools_CreateDraftMessage",
            "MailTools_SendDraftMessage", "M365Copilot_copilot_chat" })
        {
            var tool = tools.OfType<AIFunction>().Single(item => item.Name == name);
            Console.WriteLine($"Tool: {tool.Name}\nDescription: {tool.Description}\nSchema: {tool.JsonSchema}");
        }
        using var client = Program.CreateProviderClient(settings, invokeTools: false);
        foreach (var prompt in new[]
        {
            "Can you send an email to recipient@example.com?",
            "Send an email to recipient@example.com with subject 'Synthetic diagnostic' and body 'This is a diagnostic request.'"
        })
        {
            var result = await DlpTurnGuard.RunAsync(dlp, new DlpConversation(), prompt, async cancellationToken =>
            {
                var response = await client.GetResponseAsync([new ChatMessage(ChatRole.User, prompt)],
                    new ChatOptions { Instructions = Program.InstructionsFor(runtime.MailSender), Tools = tools }, cancellationToken);
                var calls = response.Messages.SelectMany(message => message.Contents).OfType<FunctionCallContent>().ToArray();
                Console.WriteLine($"Routing-only probe: {calls.Length} proposed tool call(s).");
                foreach (var call in calls) Console.WriteLine($"Proposed tool: {call.Name}; argument keys: {string.Join(", ", call.Arguments?.Keys ?? [])}");
                return response.Text.Length > 0 ? response.Text : "(The model proposed tool calls; none were executed.)";
            });
            Console.WriteLine(result.Text);
        }
        Console.WriteLine("No Work IQ tools were invoked, drafts created, or emails sent. These probes do not establish the outcome of a real send.");
        return 0;
    }
}
