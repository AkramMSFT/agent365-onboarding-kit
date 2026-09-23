using System.Text;
using System.Text.Json;
using Azure.Core;

internal static class TokenRenewalChecks
{
    public static async Task RunAsync()
    {
        const string audience = "offline-audience";
        const string scope = "offline-scope";
        const string tenant = "offline-tenant";
        const string user = "offline-user";
        const string upn = "offline@example.invalid";
        string Token(long expires, string tokenUser = user) =>
            "e30." + Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
            {
                aud = audience, scp = scope, tid = tenant, oid = tokenUser, upn, exp = expires
            }))).TrimEnd('=').Replace('+', '-').Replace('/', '_') + ".offline";
        var future = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();
        var expired = new Dictionary<string, string> { [audience] = Token(0) };
        var credential = new RenewalCredential(Token(future), audience + "/" + scope);
        var tokens = new Agent365Tokens(expired, tenant, user, upn, credential);
        await tokens.GetAsync(audience, scope);
        await tokens.GetAsync(audience, scope);
        if (credential.Calls != 1) throw new InvalidOperationException("Renewed token was not cached in memory.");

        var wrongCredential = new RenewalCredential(Token(future, "wrong-user"), audience + "/" + scope);
        var rejected = new Agent365Tokens(expired, tenant, user, upn, wrongCredential);
        try
        {
            await rejected.GetAsync(audience, scope);
            throw new Exception("A token for a different user was accepted.");
        }
        catch (InvalidOperationException error) when (error.Message.StartsWith("Token identity", StringComparison.Ordinal)) { }

        var mismatched = new Agent365Tokens(new Dictionary<string, string> { [audience] = Token(0, "wrong-user") },
            tenant, user, upn, credential);
        try
        {
            await mismatched.GetAsync(audience, scope);
            throw new Exception("A mismatched stored token triggered a silent replacement.");
        }
        catch (InvalidOperationException error) when (error.Message.StartsWith("Token identity", StringComparison.Ordinal)) { }
        if (credential.Calls != 1) throw new InvalidOperationException("Mismatched identity reached the renewal credential.");
        Console.WriteLine("Silent renewal scope, caching and immutable-user checks passed offline.");
    }

    private sealed class RenewalCredential(string token, string scope) : TokenCredential
    {
        public int Calls { get; private set; }
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new NotSupportedException("Use async token acquisition.");
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (requestContext.Scopes.Length != 1 || requestContext.Scopes[0] != scope)
                throw new InvalidOperationException("Renewal requested an unexpected scope.");
            Calls++;
            return ValueTask.FromResult(new AccessToken(token, DateTimeOffset.UtcNow.AddHours(1)));
        }
    }
}
