using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

internal static class TeamsHostChecks
{
    public static void Run()
    {
        const string tenant = "11111111-1111-1111-1111-111111111111";
        const string owner = "22222222-2222-2222-2222-222222222222";
        var activity = new Dictionary<string, object?>
        {
            ["type"] = "message", ["text"] = "synthetic",
            ["channelId"] = "msteams",
            ["serviceUrl"] = "https://smba.trafficmanager.net/emea/",
            ["from"] = new { aadObjectId = owner },
            ["conversation"] = new { tenantId = tenant }
        };
        var delivery = new ClaimsPrincipal(new ClaimsIdentity([new Claim("iss", "https://api.botframework.com")], "test"));
        bool Allowed(ClaimsPrincipal principal) => TeamsOwnerGuard.IsAllowed(principal, JsonSerializer.SerializeToElement(activity), tenant, owner);
        if (!Allowed(delivery)) throw new InvalidOperationException("Configured Teams owner was rejected.");
        if (Allowed(new ClaimsPrincipal(new ClaimsIdentity()))) throw new InvalidOperationException("Unauthenticated caller was accepted.");
        activity["from"] = new { aadObjectId = "other-user" };
        if (Allowed(delivery)) throw new InvalidOperationException("Another Teams user could use owner credentials.");
        activity["from"] = new { aadObjectId = owner };
        activity["conversation"] = new { tenantId = "other-tenant" };
        if (Allowed(delivery)) throw new InvalidOperationException("Another Teams tenant was accepted.");
        activity["conversation"] = new { tenantId = tenant };
        activity["serviceUrl"] = "https://example.invalid/steal-connector-token";
        if (Allowed(delivery)) throw new InvalidOperationException("An untrusted Connector reply URL was accepted.");
        activity["serviceUrl"] = "https://smba.trafficmanager.net/emea/";
        var otherUser = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim("iss", $"https://login.microsoftonline.com/{tenant}/v2.0"),
             new Claim("tid", tenant), new Claim("oid", "other-user")], "test"));
        if (Allowed(otherUser)) throw new InvalidOperationException("A direct user token could spoof the activity owner.");
        var messagingBot = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim("iss", $"https://login.microsoftonline.com/{tenant}/v2.0"),
             new Claim("tid", tenant), new Claim("oid", "messaging-service-principal"),
             new Claim("azp", TeamsOwnerGuard.MessagingBotAppId)], "test"));
        if (!Allowed(messagingBot)) throw new InvalidOperationException("Microsoft Messaging Bot delivery for the owner was rejected.");
        activity["from"] = new { aadObjectId = "other-user" };
        if (Allowed(messagingBot)) throw new InvalidOperationException("Messaging Bot delivery bypassed the owner restriction.");
        activity["from"] = new { id = "system-lifecycle" };
        activity["type"] = "conversationUpdate";
        if (!TeamsOwnerGuard.IsLifecycle(messagingBot, JsonSerializer.SerializeToElement(activity), tenant) ||
            TeamsOwnerGuard.IsLifecycle(otherUser, JsonSerializer.SerializeToElement(activity), tenant))
            throw new InvalidOperationException("Trusted lifecycle acknowledgements are incorrectly scoped.");
        activity["type"] = "message";
        if (TeamsOwnerGuard.IsLifecycle(messagingBot, JsonSerializer.SerializeToElement(activity), tenant))
            throw new InvalidOperationException("An ordinary message bypassed authorization as a lifecycle event.");
        activity["from"] = new { aadObjectId = owner };
        activity["channelId"] = "other-channel";
        if (Allowed(delivery)) throw new InvalidOperationException("Non-Teams channel was accepted.");

        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["TokenValidation:Enabled"] = "false",
            ["Agent365Observability:TenantId"] = tenant,
            ["Agent365Observability:AgentBlueprintId"] = "33333333-3333-3333-3333-333333333333",
            ["Agent365Observability:AgentId"] = "44444444-4444-4444-4444-444444444444"
        }).Build();
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddAgentAspNetAuthentication(configuration);
        using var provider = services.BuildServiceProvider();
        var monitor = provider.GetRequiredService<IOptionsMonitor<JwtBearerOptions>>();
        foreach (var scheme in new[] { "BotConnector", "Entra" })
        {
            var options = monitor.Get(scheme);
            var validation = options.TokenValidationParameters;
            if (!validation.ValidateIssuer || !validation.ValidateAudience || !validation.ValidateLifetime ||
                !validation.ValidateIssuerSigningKey || !validation.RequireSignedTokens || !validation.RequireExpirationTime ||
                validation.ValidAudiences.Count() != 2 || !options.RequireHttpsMetadata)
                throw new InvalidOperationException("Teams JWT validation was weakened.");
        }
        Console.WriteLine("Teams owner/tenant/reply-URL guards and mandatory JWT settings verified offline.");
    }
}
