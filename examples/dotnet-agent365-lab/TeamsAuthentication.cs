using System.IdentityModel.Tokens.Jwt;
using Microsoft.Agents.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;
using Microsoft.IdentityModel.Validators;

internal static class TeamsAuthentication
{
    internal static readonly string[] MicrosoftDeliveryIssuers =
    [
        "https://api.botframework.com",
        "https://sts.windows.net/d6d49420-f39b-4df7-a1dc-d59a935871db/",
        "https://login.microsoftonline.com/d6d49420-f39b-4df7-a1dc-d59a935871db/v2.0",
        "https://sts.windows.net/f8cdef31-a31e-4b4a-93e4-5f571e91255a/",
        "https://login.microsoftonline.com/f8cdef31-a31e-4b4a-93e4-5f571e91255a/v2.0",
        "https://sts.windows.net/69e9b82d-4842-4902-8d1e-abc5b98a55e8/",
        "https://login.microsoftonline.com/69e9b82d-4842-4902-8d1e-abc5b98a55e8/v2.0"
    ];

    public static void AddAgentAspNetAuthentication(this IServiceCollection services, IConfiguration configuration)
    {
        var tenant = RequiredGuid(configuration, "Agent365Observability:TenantId");
        var audiences = new[]
        {
            RequiredGuid(configuration, "Agent365Observability:AgentBlueprintId"),
            RequiredGuid(configuration, "Agent365Observability:AgentId")
        };
        services.AddAuthentication("AgentTransport")
            .AddPolicyScheme("AgentTransport", "Microsoft agent delivery", options =>
            {
                options.ForwardDefaultSelector = context =>
                {
                    var authorization = context.Request.Headers.Authorization.ToString();
                    if (authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
                    {
                        var encoded = authorization[7..].Trim();
                        var reader = new JwtSecurityTokenHandler();
                        try
                        {
                            // The unverified issuer only selects the validation scheme; it never grants access.
                            if (reader.CanReadToken(encoded) && reader.ReadJwtToken(encoded).Issuer == "https://api.botframework.com")
                                return "BotConnector";
                        }
                        catch (ArgumentException) { }
                    }
                    return "Entra";
                };
            })
            .AddJwtBearer("BotConnector", options =>
            {
                Configure(options, audiences, ["https://api.botframework.com"]);
                options.MetadataAddress = AuthenticationConstants.PublicAzureBotServiceOpenIdMetadataUrl;
            })
            .AddJwtBearer("Entra", options =>
            {
                Configure(options, audiences,
                    [.. MicrosoftDeliveryIssuers.Where(issuer => issuer != "https://api.botframework.com"),
                     $"https://sts.windows.net/{tenant}/", $"https://login.microsoftonline.com/{tenant}/v2.0"]);
                options.MetadataAddress = AuthenticationConstants.PublicOpenIdMetadataUrl;
            });
        services.AddAuthorization();
    }

    private static void Configure(JwtBearerOptions options, string[] audiences, string[] issuers)
    {
        options.MapInboundClaims = false;
        options.SaveToken = true;
        options.RequireHttpsMetadata = true;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuers = issuers,
            ValidateAudience = true,
            ValidAudiences = audiences,
            ValidateLifetime = true,
            RequireExpirationTime = true,
            RequireSignedTokens = true,
            ValidateIssuerSigningKey = true,
            ClockSkew = TimeSpan.FromMinutes(2)
        };
        options.TokenValidationParameters.EnableAadSigningKeyIssuerValidation();
    }

    internal static string RequiredGuid(IConfiguration configuration, string key) =>
        Guid.TryParse(configuration[key], out var value) ? value.ToString()
        : throw new InvalidOperationException($"Missing or invalid {key}.");
}
