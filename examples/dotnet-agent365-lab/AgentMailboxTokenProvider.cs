using Microsoft.Agents.Authentication;
using Microsoft.Agents.Authentication.Msal;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Identity.Client;

internal sealed class AgentMailboxTokenProvider : IDisposable
{
    private readonly ServiceProvider? services;
    private readonly IAgenticTokenProvider authentication;
    private readonly string tenant;
    private readonly string instance;
    private readonly string user;
    public string Mailbox { get; }

    public AgentMailboxTokenProvider(IConfiguration configuration)
    {
        tenant = TeamsAuthentication.RequiredGuid(configuration, "Agent365Observability:TenantId");
        instance = TeamsAuthentication.RequiredGuid(configuration, "Agent365Local:AgentMailbox:AgentIdentityId");
        user = TeamsAuthentication.RequiredGuid(configuration, "Agent365Local:AgentMailbox:UserId");
        Mailbox = configuration["Agent365Local:AgentMailbox:UserPrincipalName"]
            ?? throw new InvalidOperationException("Agent mailbox UPN is missing.");
        var blueprint = TeamsAuthentication.RequiredGuid(configuration, "Agent365Observability:AgentBlueprintId");
        if (instance == blueprint) throw new InvalidOperationException("Agent mailbox authentication requires its child identity.");
        var secret = configuration["Agent365Observability:ClientSecret"];
        if (string.IsNullOrWhiteSpace(secret)) throw new InvalidOperationException("Local blueprint credential is missing.");
        var authConfig = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["MailAuth:AuthType"] = "ClientSecret",
            ["MailAuth:ClientId"] = blueprint,
            ["MailAuth:AuthorityEndpoint"] = $"https://login.microsoftonline.com/{tenant}",
            ["MailAuth:ClientSecret"] = secret,
            ["MSALConfiguration:MSALEnabledLogPII"] = "false"
        }).Build();
        var collection = new ServiceCollection();
        collection.AddLogging(builder => builder.SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Warning));
        collection.AddHttpClient();
        collection.AddDefaultMsalAuth(authConfig);
        services = collection.BuildServiceProvider();
        authentication = new MsalAuth(services, authConfig.GetSection("MailAuth"));
    }

    internal AgentMailboxTokenProvider(IAgenticTokenProvider authentication, string tenant, string instance, string user, string mailbox)
    {
        this.authentication = authentication;
        this.tenant = tenant;
        this.instance = instance;
        this.user = user;
        Mailbox = mailbox;
    }

    public async Task<string> GetAsync(string audience, string scope)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        try
        {
            var token = await authentication.GetAgenticUserTokenAsync(tenant, instance, user,
                [$"{audience}/{scope}"], timeout.Token);
            Agent365Tokens.Validate(token, audience, scope, tenant, user, Mailbox, instance);
            return token;
        }
        catch (MsalException error)
        {
            throw new InvalidOperationException($"Agent mailbox token acquisition failed ({error.ErrorCode}); no fallback to the human mailbox was attempted.");
        }
    }

    public void Dispose() => services?.Dispose();
}
