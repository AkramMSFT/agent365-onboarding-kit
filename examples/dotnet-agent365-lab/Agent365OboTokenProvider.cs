using Microsoft.Identity.Client;

internal sealed class Agent365OboTokenProvider
{
    internal const string Audience = "9b975845-388f-4429-889e-eab1ef63949c";
    private readonly Agent365Tokens userTokens;
    private readonly string blueprintId;
    private readonly string agentId;
    private readonly string clientSecret;
    private readonly IConfidentialClientApplication blueprint;
    private readonly IMsalHttpClientFactory? httpClientFactory;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, AuthenticationResult> cached = new(StringComparer.Ordinal);

    public Agent365OboTokenProvider(Agent365Tokens userTokens, string blueprintId, string agentId,
        string clientSecret, IMsalHttpClientFactory? httpClientFactory = null)
    {
        if (string.Equals(blueprintId, agentId, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Agent OBO requires the child agent identity, not the blueprint ID. Verify the runtime identity override after CLI endpoint or publish operations.");
        this.userTokens = userTokens;
        this.blueprintId = blueprintId;
        this.agentId = agentId;
        this.clientSecret = clientSecret;
        this.httpClientFactory = httpClientFactory;
        blueprint = Configure(ConfidentialClientApplicationBuilder.Create(blueprintId)
            .WithClientSecret(clientSecret)).Build();
    }

    private ConfidentialClientApplicationBuilder Configure(ConfidentialClientApplicationBuilder builder)
    {
        builder.WithAuthority($"https://login.microsoftonline.com/{userTokens.TenantId}")
            .WithInstanceDiscovery(false);
        if (httpClientFactory is not null) builder.WithHttpClientFactory(httpClientFactory);
        return builder;
    }

    public Task<string> GetAsync() => AcquireAsync(Audience, $"api://{Audience}",
        ["Agent365.Observability.OtelWrite"], CancellationToken.None);

    public Task<string> GetGraphAsync(CancellationToken cancellationToken = default) =>
        AcquireAsync("00000003-0000-0000-c000-000000000000", "https://graph.microsoft.com",
            ["ProtectionScopes.Compute.User", "Content.Process.User"], cancellationToken);

    private async Task<string> AcquireAsync(string audience, string resource, string[] requiredScopes,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(60));
        await gate.WaitAsync(timeout.Token);
        try
        {
            if (cached.TryGetValue(audience, out var previous) && previous.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(2))
                return previous.AccessToken;

            var assertion = await userTokens.GetAsync(blueprintId, "access_agent_as_user", timeout.Token);
            var parent = await blueprint.AcquireTokenForClient(["api://AzureADTokenExchange/.default"])
                .WithFmiPath(agentId).ExecuteAsync(timeout.Token);
            var agent = Configure(ConfidentialClientApplicationBuilder.Create(agentId)
                .WithClientAssertion((AssertionRequestOptions _) => Task.FromResult(parent.AccessToken))).Build();
            var result = await agent.AcquireTokenOnBehalfOf([$"{resource}/.default"],
                new UserAssertion(assertion)).ExecuteAsync(timeout.Token);
            foreach (var scope in requiredScopes)
                Agent365Tokens.Validate(result.AccessToken, audience, scope,
                    userTokens.TenantId, userTokens.UserId, userTokens.UserPrincipalName, agentId);
            cached[audience] = result;
            return result.AccessToken;
        }
        catch (MsalException error)
        {
            var message = System.Text.RegularExpressions.Regex.Replace(error.Message,
                @"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "[token redacted]")
                .Replace(clientSecret, "[secret redacted]", StringComparison.Ordinal);
            throw new InvalidOperationException($"Agent OBO token exchange failed ({error.ErrorCode}): {message}");
        }
        finally { gate.Release(); }
    }
}
