using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Extensions.Configuration;

internal static class MailDeliveryDiagnostics
{
    public static async Task<int> RunAsync(IConfiguration configuration)
    {
        if (!configuration.GetValue<bool>("Agent365Local:UseAgentMailboxForMail"))
            throw new InvalidOperationException("Agent-mailbox mode must be enabled for this diagnostic.");
        using var tokenProvider = new AgentMailboxTokenProvider(configuration);
        const string graph = "00000003-0000-0000-c000-000000000000";
        var token = await tokenProvider.GetAsync(graph, "Mail.ReadWrite");
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
        {
            BaseAddress = new Uri("https://graph.microsoft.com/v1.0/"),
            Timeout = TimeSpan.FromSeconds(30)
        };
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var user = TeamsAuthentication.RequiredGuid(configuration, "Agent365Local:AgentMailbox:UserId");
        foreach (var folder in new[] { "sentitems", "outbox", "inbox" })
        {
            var filter = Uri.EscapeDataString(folder == "inbox"
                ? "contains(subject, 'Agent 365 mail diagnostic')" : "subject eq 'Agent 365 mail diagnostic'");
            using var response = await http.GetAsync($"users/{user}/mailFolders/{folder}/messages?$filter={filter}&$top=5&$select=id,subject,sentDateTime,from,sender,toRecipients,internetMessageId");
            if (!response.IsSuccessStatusCode)
            {
                Console.Error.WriteLine($"Mailbox metadata query ({folder}) failed: HTTP {(int)response.StatusCode}.");
                return 1;
            }
            using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            Console.WriteLine($"{folder}: {body.RootElement.GetProperty("value").GetArrayLength()} matching diagnostic message(s).");
            foreach (var message in body.RootElement.GetProperty("value").EnumerateArray())
                Console.WriteLine(message.GetRawText());
        }
        Console.WriteLine("Read-only diagnostic completed. No message bodies read and no mail sent.");
        return 0;
    }
}
