using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Identity.Client;

internal sealed class OfflineOboHandler : HttpMessageHandler, IMsalHttpClientFactory
{
    internal const string Tenant = "11111111-1111-1111-1111-111111111111";
    internal const string Blueprint = "22222222-2222-2222-2222-222222222222";
    internal const string Agent = "33333333-3333-3333-3333-333333333333";
    internal const string User = "44444444-4444-4444-4444-444444444444";
    internal const string Upn = "offline@example.invalid";
    private readonly HttpClient client;
    private readonly string parentToken = Token("api://AzureADTokenExchange", "", Blueprint);
    public string UserToken { get; } = Token(Blueprint, "access_agent_as_user", "offline-cli");
    public bool ReturnWrongClient { get; init; }
    public bool GraphResource { get; init; }
    public int TokenRequests { get; private set; }

    public OfflineOboHandler() => client = new HttpClient(this, disposeHandler: false);
    public HttpClient GetHttpClient() => client;

    internal static string Token(string audience, string scope, string clientId) =>
        "eyJhbGciOiJub25lIn0." + Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            aud = audience, scp = scope, azp = clientId, tid = Tenant, oid = User, upn = Upn,
            exp = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()
        }))).TrimEnd('=').Replace('+', '-').Replace('/', '_') + ".offline";

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Method != HttpMethod.Post ||
            request.RequestUri?.AbsoluteUri != $"https://login.microsoftonline.com/{Tenant}/oauth2/v2.0/token")
            throw new InvalidOperationException("Unexpected MSAL request; offline test permits only the configured token endpoint.");
        var form = (await request.Content!.ReadAsStringAsync(cancellationToken)).Split('&')
            .Select(field => field.Split('=', 2))
            .ToDictionary(field => Uri.UnescapeDataString(field[0]),
                field => Uri.UnescapeDataString(field[1].Replace('+', ' ')));
        TokenRequests++;
        string token;
        if (TokenRequests == 1)
        {
            if (form["grant_type"] != "client_credentials" || form["client_id"] != Blueprint ||
                form["client_secret"] != "offline-secret" || form["fmi_path"] != Agent ||
                !form["scope"].Split(' ').Contains("api://AzureADTokenExchange/.default"))
                throw new InvalidOperationException("Incorrect blueprint FMI token request.");
            token = parentToken;
        }
        else
        {
            if (TokenRequests != 2 || form["grant_type"] != "urn:ietf:params:oauth:grant-type:jwt-bearer" ||
                form["client_id"] != Agent || form["client_assertion"] != parentToken ||
                form["assertion"] != UserToken || form["requested_token_use"] != "on_behalf_of" ||
                !form["scope"].Split(' ').Contains(GraphResource ? "https://graph.microsoft.com/.default" : $"api://{Agent365OboTokenProvider.Audience}/.default"))
                throw new InvalidOperationException("Incorrect agent-identity OBO request.");
            token = Token(GraphResource ? "https://graph.microsoft.com" : Agent365OboTokenProvider.Audience,
                GraphResource ? "ProtectionScopes.Compute.User Content.Process.User" : "Agent365.Observability.OtelWrite",
                ReturnWrongClient ? "offline-cli" : Agent);
        }
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(JsonSerializer.Serialize(new
            {
                token_type = "Bearer", access_token = token, expires_in = 3600, scope = form["scope"]
            }), Encoding.UTF8, "application/json")
        };
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) client.Dispose();
        base.Dispose(disposing);
    }
}
