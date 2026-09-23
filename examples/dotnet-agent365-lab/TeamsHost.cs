using System.Text.Json;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

internal static class TeamsHost
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (File.Exists(".env")) DotNetEnv.Env.NoClobber().Load();
        _ = ModelProviderSettings.FromEnvironment();
        var builder = WebApplication.CreateBuilder(args);
        using var settingsStream = File.OpenRead("appsettings.json");
        using var localStream = File.OpenRead(".a365-runtime.local.json");
        builder.Configuration.AddJsonStream(settingsStream).AddJsonStream(localStream).AddEnvironmentVariables();
        var tenant = TeamsAuthentication.RequiredGuid(builder.Configuration, "Agent365Observability:TenantId");
        var owner = TeamsAuthentication.RequiredGuid(builder.Configuration, "Agent365Local:UserId");
        var port = builder.Configuration["PORT"] is { } configuredPort
            ? int.Parse(configuredPort, System.Globalization.CultureInfo.InvariantCulture) : 5000;
        if (port is < 1 or > 65535) throw new InvalidOperationException("PORT must be between 1 and 65535.");
        builder.WebHost.UseUrls($"http://127.0.0.1:{port}");
        builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 1_048_576);
        builder.Configuration["TokenValidation:Enabled"] = "true";
        builder.Configuration["AgentApplication:UserAuthorization:AutoSignin"] = "false";
        builder.Configuration["AgentApplication:RemoveRecipientMention"] = "true";
        builder.Services.AddHttpClient();
        builder.Services.AddHttpContextAccessor();
        builder.Services.AddControllers();
        builder.Services.AddAgentAspNetAuthentication(builder.Configuration);
        builder.Services.AddSingleton<IStorage, MemoryStorage>();
        builder.Services.AddSingleton(sp => PurviewDlp.FromConfiguration(builder.Configuration,
            sp.GetRequiredService<ILogger<PurviewDlp>>()));
        builder.AddAgentApplicationOptions();
        builder.AddAgent<TeamsChatAgent>();

        var app = builder.Build();
        app.UseAuthentication();
        app.UseAuthorization();
        if (app.Services.GetRequiredService<IAgent>() is AgentApplication agent)
        {
            agent.OnTurnError(async (context, state, error, cancellationToken) =>
            {
                app.Logger.LogError("Teams turn failed: {ErrorType}. Review local token expiry, model access and SDK configuration.", error.GetType().Name);
                await context.SendActivityAsync("I could not complete this request. The host operator should check local token expiry and service access.",
                    cancellationToken: cancellationToken);
            });
        }
        app.MapGet("/api/health", () => Results.Ok(new { status = "healthy", mode = "single-user-teams-test" })).AllowAnonymous();
        app.MapPost("/api/messages", async (HttpContext context, IAgentHttpAdapter adapter, IAgent agent) =>
        {
            context.Request.EnableBuffering();
            try
            {
                using var document = await JsonDocument.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted);
                if (TeamsOwnerGuard.IsLifecycle(context.User, document.RootElement, tenant))
                {
                    context.Response.StatusCode = StatusCodes.Status202Accepted;
                    return;
                }
                if (!TeamsOwnerGuard.IsAllowed(context.User, document.RootElement, tenant, owner))
                {
                    app.Logger.LogWarning("Teams owner guard rejected delivery metadata: {Metadata}",
                        TeamsOwnerGuard.Describe(context.User, document.RootElement));
                    context.Response.StatusCode = StatusCodes.Status403Forbidden;
                    await context.Response.WriteAsJsonAsync(new { error = "This local test host is restricted to its configured Teams user and tenant." });
                    return;
                }
            }
            catch (JsonException)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }
            context.Request.Body.Position = 0;
            try { await adapter.ProcessAsync(context.Request, context.Response, agent, context.RequestAborted); }
            catch (Exception error)
            {
                app.Logger.LogError("Teams adapter failed: {ErrorType}.", error.GetType().Name);
                if (!context.Response.HasStarted)
                {
                    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                    await context.Response.WriteAsJsonAsync(new { error = "Message processing failed." });
                }
            }
        }).RequireAuthorization();
        Console.WriteLine($"Teams test host: http://127.0.0.1:{port}; messaging requires JWT authentication and configured owner identity.");
        await app.RunAsync();
        return 0;
    }
}
