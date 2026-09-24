extern alias AzureIdentitySdk;

using System.Text.Json;
using Azure.Core;
using IdentitySdk = AzureIdentitySdk::Azure.Identity;

internal sealed class Agent365Tokens
{
    private readonly Dictionary<string, string> tokens;
    private readonly TokenCredential? renewalCredential;
    public string TenantId { get; }
    public string UserId { get; }
    public string UserPrincipalName { get; }

    public Agent365Tokens(string path, string tenantId, string userId, string userPrincipalName, string operatorClientAppId)
        : this(JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))
            ?? throw new InvalidOperationException("The local token file must contain an audience/token map."),
            tenantId, userId, userPrincipalName)
    {
        if (!Guid.TryParse(operatorClientAppId, out _)) throw new InvalidOperationException("Configure a verified OperatorClientAppId before using local cached tokens.");
        // Reuses the Agent 365 CLI's encrypted Azure Identity cache. Other developer credentials
        // would pick a different client, cache or account.
#pragma warning disable CS0618
        renewalCredential = new IdentitySdk.SharedTokenCacheCredential(new IdentitySdk.SharedTokenCacheCredentialOptions
        {
            ClientId = operatorClientAppId,
            TenantId = tenantId,
            Username = userPrincipalName,
            TokenCachePersistenceOptions = new IdentitySdk.TokenCachePersistenceOptions { Name = "Microsoft.Agents.A365.DevTools.Cli" }
        });
#pragma warning restore CS0618
    }

    internal Agent365Tokens(Dictionary<string, string> tokens, string tenantId, string userId, string userPrincipalName,
        TokenCredential? renewalCredential = null)
    {
        TenantId = tenantId;
        UserId = userId;
        UserPrincipalName = userPrincipalName;
        this.tokens = new(tokens, StringComparer.OrdinalIgnoreCase);
        this.renewalCredential = renewalCredential;
    }

    public async Task<string> GetAsync(string audience, string scope, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (tokens.TryGetValue(audience, out var existing) && !string.IsNullOrWhiteSpace(existing))
        {
            Validate(existing, audience, scope, TenantId, UserId, UserPrincipalName, allowExpired: true);
            using var claims = ParseClaims(existing);
            if (claims.RootElement.GetProperty("exp").GetInt64() > DateTimeOffset.UtcNow.AddMinutes(2).ToUnixTimeSeconds())
                return existing;
        }
        if (renewalCredential is null) return Get(audience, scope);
        Console.WriteLine($"Renewing local development token for resource {audience} from the encrypted cache.");
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(45));
            var refreshed = await renewalCredential.GetTokenAsync(new TokenRequestContext([$"{audience}/{scope}"]), timeout.Token);
            Validate(refreshed.Token, audience, scope, TenantId, UserId, UserPrincipalName);
            tokens[audience] = refreshed.Token;
            return refreshed.Token;
        }
        catch (IdentitySdk.AuthenticationFailedException)
        {
            throw new InvalidOperationException($"Silent token renewal failed for {audience}. Run Refresh-Agent365Tokens.ps1 using the configured account.");
        }
    }

    public string Get(string audience, string scope)
    {
        if (!tokens.TryGetValue(audience, out var token) || string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException($"Missing token for {audience}. Run Refresh-Agent365Tokens.ps1.");
        try { Validate(token, audience, scope, TenantId, UserId, UserPrincipalName); }
        catch (InvalidOperationException error)
        {
            throw new InvalidOperationException($"Token for resource {audience}: {error.Message}");
        }
        return token;
    }

    // Local consistency checks only. Microsoft services validate signatures and authorization.
    internal static void Validate(string token, string audience, string scope, string tenantId,
        string userId, string userPrincipalName, string? clientAppId = null, bool allowExpired = false)
    {
        try
        {
            using var document = ParseClaims(token);
            var claims = document.RootElement;
            string? Claim(string name) => claims.TryGetProperty(name, out var value) ? value.GetString() : null;
            var tokenAudience = Claim("aud")?.Replace("api://", "", StringComparison.Ordinal).TrimEnd('/');
            if (tokenAudience == "https://graph.microsoft.com") tokenAudience = "00000003-0000-0000-c000-000000000000";
            var upn = Claim("preferred_username") ?? Claim("upn") ?? Claim("unique_name");
            if (!string.Equals(tokenAudience, audience, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Claim("tid"), tenantId, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Claim("oid"), userId, StringComparison.OrdinalIgnoreCase) ||
                (upn is not null && !string.Equals(upn, userPrincipalName, StringComparison.OrdinalIgnoreCase)) ||
                (clientAppId is not null && !string.Equals(Claim("azp") ?? Claim("appid"), clientAppId, StringComparison.OrdinalIgnoreCase)) ||
                !(Claim("scp") ?? "").Split(' ').Contains(scope, StringComparer.Ordinal) ||
                !claims.TryGetProperty("exp", out var expiration) ||
                (!allowExpired && expiration.GetInt64() <= DateTimeOffset.UtcNow.AddMinutes(2).ToUnixTimeSeconds()))
                throw new InvalidOperationException("Token identity, audience, scope or expiry does not match this workspace. Run Refresh-Agent365Tokens.ps1 using the configured account.");
        }
        catch (Exception error) when (error is FormatException or JsonException or KeyNotFoundException)
        {
            throw new InvalidOperationException("Malformed local Agent 365 token. Run Refresh-Agent365Tokens.ps1.");
        }
    }

    internal static JsonDocument ParseClaims(string token)
    {
        var parts = token.Split('.');
        if (parts.Length != 3) throw new FormatException();
        var payload = parts[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
        return JsonDocument.Parse(Convert.FromBase64String(payload));
    }
}
