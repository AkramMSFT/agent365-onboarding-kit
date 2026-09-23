using System.ClientModel.Primitives;
using System.Text;
using System.Text.Json;
using Microsoft.Agents.Authentication;
using Microsoft.Extensions.AI;

internal static class AgentMailboxChecks
{
    public static async Task RunAsync()
    {
        var fake = new AgentUserAuthentication();
        using var provider = new AgentMailboxTokenProvider(fake, "tenant", "instance", "agent-user", "agent@example.invalid");
        await provider.GetAsync("mail-audience", "Tools.ListInvoke.All");
        if (fake.Calls != 1) throw new InvalidOperationException("Agent mailbox token did not use the agent-user SDK API.");
        fake.WrongUser = true;
        try
        {
            await provider.GetAsync("mail-audience", "Tools.ListInvoke.All");
            throw new Exception("A human-user token was accepted for the agent mailbox.");
        }
        catch (InvalidOperationException error) when (error.Message.StartsWith("Token identity", StringComparison.Ordinal)) { }

        var invoked = 0;
        var tool = AIFunctionFactory.Create((string text) => { invoked++; return 3; }, "CountWords");
        using var handler = new OfflineMistralHandler(tool.Name);
        using var http = new HttpClient(handler);
        using var client = Program.CreateMistralClient("offline-mistral-key", "ministral-3b-2512",
            new HttpClientPipelineTransport(http), invokeTools: false);
        var response = await client.GetResponseAsync([new ChatMessage(ChatRole.User, "Synthetic routing check")],
            new ChatOptions { Tools = [tool] });
        if (invoked != 0 || handler.RequestCount != 1 ||
            !response.Messages.SelectMany(message => message.Contents).OfType<FunctionCallContent>().Any())
            throw new InvalidOperationException("Routing-only diagnostics executed a tool or lost the proposed call.");
        Console.WriteLine("Agent mailbox identity and no-execution mail diagnostics verified offline.");
    }

    private sealed class AgentUserAuthentication : IAgenticTokenProvider
    {
        public int Calls { get; private set; }
        public bool WrongUser { get; set; }
        public Task<string> GetAgenticApplicationTokenAsync(string tenantId, string agentAppInstanceId, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException("The wrapper must use GetAgenticUserTokenAsync.");
        public Task<string> GetAgenticInstanceTokenAsync(string tenantId, string agentAppInstanceId, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException("The wrapper must use GetAgenticUserTokenAsync.");
        public Task<string> GetAgenticUserTokenAsync(string tenantId, string agentAppInstanceId, string user, IList<string> scopes,
            CancellationToken cancellationToken = default)
        {
            if (tenantId != "tenant" || agentAppInstanceId != "instance" || user != "agent-user" ||
                scopes.Count != 1 || scopes[0] != "mail-audience/Tools.ListInvoke.All")
                throw new InvalidOperationException("Incorrect agent-user token request.");
            Calls++;
            var payload = JsonSerializer.Serialize(new
            {
                aud = "mail-audience", tid = "tenant", azp = "instance",
                oid = WrongUser ? "human-user" : "agent-user", upn = "agent@example.invalid",
                scp = "Tools.ListInvoke.All", exp = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()
            });
            return Task.FromResult("e30." + Convert.ToBase64String(Encoding.UTF8.GetBytes(payload))
                .TrimEnd('=').Replace('+', '-').Replace('/', '_') + ".offline");
        }
    }
}
