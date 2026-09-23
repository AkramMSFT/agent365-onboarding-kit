# .NET hosting layer for a blueprint-based Agent 365 agent

Reuse the ASP.NET Core startup and endpoint structure from upstream's AI Teammate reference,
but keep the consuming agent's model/tool services and apply the deltas below.

**Read** `.a365-kit/skills/make-ai-teammate/references/dotnet-ai-teammate.md`, sections **"Program.cs -- Startup / Service Registration"** and **"appsettings.json"**, and apply them. Then the deltas below.

## Deltas for a non-AI-Teammate agent

1. **Your agent class** must derive from `AgentApplication` and be registered with `builder.AddAgent<YourAgent>()`. If the onboarding skills did not create one (they do only on the AI Teammate path), add a thin subclass in a new file that forwards `OnMessage` to your existing logic -- section **"Agent/MyAgent.cs -- AgentApplication Subclass"** shows the shape. Do not edit the files `instrument-observability` / `add-workiq-tools` wrote.
2. **Authentication.** `builder.Services.AddAgentAspNetAuthentication(builder.Configuration)` reads the connection settings `a365 setup all` stamped into `appsettings.json` / environment. Keep it on -- an anonymous POST to `/api/messages` must return 401.
3. **Endpoints.** `app.MapAgentApplicationEndpoints()` maps `/api/messages`. Keep authentication required in every environment. Use the separate `test-local-channel` listener for anonymous local chat, not `requireAuth: false`.
4. **Health.** Add an unauthenticated `app.MapGet("/api/health", ...)` returning 200 so the tunnel and the platform's liveness probe can reach it.
5. **Port.** Wire the chosen `PORT` into the host before `builder.Build()` as below. ASP.NET
   Core does not automatically read `.env`, and `PORT` alone is not a Kestrel setting.
   Set it in the process environment or `appsettings.Development.json`; use that same port
   for the tunnel rather than an unrelated `launchSettings.json` URL.

```csharp
using Microsoft.AspNetCore.Hosting;
using Microsoft.Agents.Builder.App;

var port = int.TryParse(builder.Configuration["PORT"], out var configuredPort) ? configuredPort : 5000;
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
```

`Microsoft.Agents.Builder.App` contains `AgentApplication` / `AgentApplicationOptions`;
include that using in the thin agent subclass and any startup block that names those types.
The snippet above is a startup fragment; `builder` is the existing `WebApplicationBuilder`.

## Packages

The reference's **"Required NuGet Packages"** table. Run `dotnet restore` / `dotnet build` -- the onboarding skills edit the `.csproj` without building.

## Verify

```bash
dotnet run
curl -s http://localhost:5000/api/health      # 200
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:5000/api/messages -H "Content-Type: application/json" -d '{"type":"message","text":"hi"}'   # 401
```

Log signal for a real turn: `ActivityHandler: OnMessageActivityAsync called`.
