# .NET hosting layer for a blueprint-based Agent 365 agent

ASP.NET Core hosting in upstream's AI Teammate reference is the same for a blueprint-based agent; the identity model is configuration, not code. Use it as-is:

**Read** `.a365-kit/skills/make-ai-teammate/references/dotnet-ai-teammate.md`, sections **"Program.cs -- Startup / Service Registration"** and **"appsettings.json"**, and apply them. Then the deltas below.

## Deltas for a non-AI-Teammate agent

1. **Your agent class** must derive from `AgentApplication` and be registered with `builder.AddAgent<YourAgent>()`. If the onboarding skills did not create one (they do only on the AI Teammate path), add a thin subclass in a new file that forwards `OnMessage` to your existing logic -- section **"Agent/MyAgent.cs -- AgentApplication Subclass"** shows the shape. Do not edit the files `instrument-observability` / `add-workiq-tools` wrote.
2. **Authentication.** `builder.Services.AddAgentAspNetAuthentication(builder.Configuration)` reads the connection settings `a365 setup all` stamped into `appsettings.json` / environment. Keep it on -- an anonymous POST to `/api/messages` must return 401.
3. **Endpoints.** `app.MapAgentApplicationEndpoints()` maps `/api/messages`. Do **not** pass `requireAuth: false` except for a deliberate local playground session; never for a tunnel or cloud host.
4. **Health.** Add an unauthenticated `app.MapGet("/api/health", ...)` returning 200 so the tunnel and the platform's liveness probe can reach it.
5. **Port.** Default launch port 5000 (see `Properties/launchSettings.json`); use the same port for the tunnel.

## Packages

The reference's **"Required NuGet Packages"** table. Run `dotnet restore` / `dotnet build` -- the onboarding skills edit the `.csproj` without building.

## Verify

```bash
dotnet run
curl -s http://localhost:5000/api/health      # 200
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:5000/api/messages -H "Content-Type: application/json" -d '{"type":"message","text":"hi"}'   # 401
```

Log signal for a real turn: `ActivityHandler: OnMessageActivityAsync called`.
