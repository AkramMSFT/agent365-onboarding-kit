using System.Security.Claims;
using System.Text.Json;

internal static class TeamsOwnerGuard
{
    internal const string MessagingBotAppId = "5a807f24-c9de-44ee-a3a7-329e88a00ffc";

    private static bool IsMicrosoftDelivery(ClaimsPrincipal principal, string tenantId)
    {
        var issuer = principal.FindFirst("iss")?.Value;
        var clientId = principal.FindFirst("azp")?.Value ?? principal.FindFirst("appid")?.Value;
        return TeamsAuthentication.MicrosoftDeliveryIssuers.Contains(issuer, StringComparer.Ordinal) ||
            (principal.FindFirst("tid")?.Value == tenantId &&
             clientId == MessagingBotAppId &&
             (issuer == $"https://login.microsoftonline.com/{tenantId}/v2.0" || issuer == $"https://sts.windows.net/{tenantId}/"));
    }

    internal static bool IsLifecycle(ClaimsPrincipal principal, JsonElement activity, string tenantId) =>
        principal.Identity?.IsAuthenticated == true && IsMicrosoftDelivery(principal, tenantId) &&
        Read(activity, "type") is "conversationUpdate" or "installationUpdate" &&
        MatchesRoute(activity, tenantId);

    internal static string Describe(ClaimsPrincipal principal, JsonElement activity) => JsonSerializer.Serialize(new
    {
        issuer = principal.FindFirst("iss")?.Value,
        clientId = principal.FindFirst("azp")?.Value ?? principal.FindFirst("appid")?.Value,
        tokenTenant = principal.FindFirst("tid")?.Value,
        tokenObjectId = principal.FindFirst("oid")?.Value,
        type = Read(activity, "type"),
        channel = Read(activity, "channelId"),
        senderAadId = Read(activity, "from", "aadObjectId"),
        senderId = Read(activity, "from", "id"),
        senderKeys = Keys(activity, "from"),
        conversationTenant = Read(activity, "conversation", "tenantId"),
        channelTenant = Read(activity, "channelData", "tenant", "id"),
        channelDataKeys = Keys(activity, "channelData"),
        serviceHost = Uri.TryCreate(Read(activity, "serviceUrl"), UriKind.Absolute, out var uri) ? uri.Host : null
    });

    private static string[] Keys(JsonElement value, string property) =>
        value.TryGetProperty(property, out var child) && child.ValueKind == JsonValueKind.Object
            ? child.EnumerateObject().Select(item => item.Name).ToArray() : [];

    public static bool IsAllowed(ClaimsPrincipal principal, JsonElement activity, string tenantId, string userId)
    {
        if (principal.Identity?.IsAuthenticated != true) return false;
        var microsoftDelivery = IsMicrosoftDelivery(principal, tenantId);
        if (!microsoftDelivery &&
            (principal.FindFirst("tid")?.Value != tenantId || principal.FindFirst("oid")?.Value != userId))
            return false;
        var sender = Read(activity, "from", "aadObjectId");
        return string.Equals(sender, userId, StringComparison.OrdinalIgnoreCase) && MatchesRoute(activity, tenantId);
    }

    private static bool MatchesRoute(JsonElement activity, string tenantId)
    {
        var tenant = Read(activity, "conversation", "tenantId") ?? Read(activity, "channelData", "tenant", "id");
        var channel = Read(activity, "channelId");
        if (!Uri.TryCreate(Read(activity, "serviceUrl"), UriKind.Absolute, out var serviceUrl) ||
            serviceUrl.Scheme != "https" || !serviceUrl.IsDefaultPort ||
            serviceUrl.Host is not ("smba.trafficmanager.net" or "smba.infra.teams.microsoft.com" or "agent365.svc.cloud.microsoft"))
            return false;
        return string.Equals(tenant, tenantId, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(channel, "msteams", StringComparison.Ordinal);
    }

    private static string? Read(JsonElement value, params string[] path)
    {
        foreach (var part in path)
        {
            if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(part, out value)) return null;
        }
        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }
}
