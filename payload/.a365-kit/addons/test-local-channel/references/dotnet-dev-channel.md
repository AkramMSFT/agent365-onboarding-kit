# .NET — local dev channel

A faithful port of the Python module, which is the version that was run. **Not yet executed**
— check it against the four behaviours in the skill's Phase 3 before relying on it.

Uses only ASP.NET Core, already present in an Agent 365 .NET host.

## The module

Write this as `DevChannel.cs` beside `Program.cs`.

```csharp
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Agent365.DevChannel;

/// <summary>
/// Local dev channel: lets the agent be chatted with on this machine, with no tenant,
/// tunnel or Bot Framework token, without weakening the real /api/messages endpoint.
/// </summary>
public static class DevChannel
{
    // devtunnel host runs on the developer's own machine and forwards to a local port, so a
    // request from the public internet still arrives with a remote address of 127.0.0.1. A
    // loopback check alone would pass tunnelled traffic. These headers are the only reliable
    // signal, and they are used to deny, never to grant.
    private static readonly string[] ForwardingHeaders =
    {
        "X-Forwarded-For",
        "X-Forwarded-Host",
        "X-Forwarded-Proto",
        "Forwarded",
    };

    private const int DefaultDevPort = 3999;

    public static bool Enabled =>
        string.Equals(
            Environment.GetEnvironmentVariable("A365_DEV_CHANNEL")?.Trim(),
            "true",
            StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Starts the dev channel if enabled; returns null when it is not.
    /// <paramref name="answer"/> must be the same delegate the production handler calls.
    /// </summary>
    public static IHost? Start(Func<string, Task<string>> answer, int? port = null)
    {
        if (!Enabled)
        {
            return null;
        }

        var listenPort = port
            ?? (int.TryParse(Environment.GetEnvironmentVariable("A365_DEV_CHANNEL_PORT"), out var p)
                ? p
                : DefaultDevPort);

        var builder = WebApplication.CreateBuilder();
        // 127.0.0.1, never 0.0.0.0: nothing off this machine can reach it directly.
        builder.WebHost.UseUrls($"http://127.0.0.1:{listenPort}");

        var app = builder.Build();
        var logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("DevChannel");

        app.MapGet("/dev/health", () => Results.Json(new { status = "ok", channel = "dev" }));

        app.MapPost("/dev/chat", async (HttpContext ctx) =>
        {
            if (ForwardingHeaders.Any(h => ctx.Request.Headers.ContainsKey(h)))
            {
                logger.LogWarning(
                    "Dev channel refused a proxied request from {Remote}",
                    ctx.Connection.RemoteIpAddress);
                return Results.Json(
                    new { error = "dev channel is local only and refuses proxied requests" },
                    statusCode: 403);
            }

            DevChatRequest? body;
            try
            {
                body = await ctx.Request.ReadFromJsonAsync<DevChatRequest>();
            }
            catch
            {
                return Results.Json(new { error = "body must be JSON" }, statusCode: 400);
            }

            var text = body?.Text?.Trim();
            if (string.IsNullOrEmpty(text))
            {
                return Results.Json(new { error = "field 'text' is required" }, statusCode: 400);
            }

            return Results.Json(new { text = await answer(text) });
        });

        logger.LogWarning(
            "DEV CHANNEL ENABLED on http://127.0.0.1:{Port}/dev/chat -- authentication is " +
            "bypassed on this port. Never set A365_DEV_CHANNEL=true outside local " +
            "development, and never point a tunnel at this port.",
            listenPort);

        app.Start();
        return app;
    }

    private sealed record DevChatRequest(string? Text);
}
```

## Starting it

Call it once from `Program.cs`, after the production host is built:

```csharp
using Agent365.DevChannel;

var devChannel = DevChannel.Start(text => Task.FromResult(agent.Ask(text)));
```

`agent.Ask` must be the same method the production handler calls.

`Start` runs its own lightweight host on a separate port. It returns `null` when the flag is
absent, so the call is safe to leave in permanently.

## Checking it

```bash
A365_DEV_CHANNEL=true dotnet run
```

Then run the four checks from Phase 3 of the skill. The `X-Forwarded-For` request returning
403 is the one that matters — the loopback bind alone does not protect the endpoint.
