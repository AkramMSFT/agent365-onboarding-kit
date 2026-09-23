using System.ComponentModel;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using OpenAI;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args.Contains("--help"))
        {
            Console.WriteLine("dotnet run -- [--mock|--live|--self-test] [prompt]\nDefault: --mock (no model, credentials or tenant calls).");
            return 0;
        }
        var mode = args.FirstOrDefault()?.StartsWith("--") == true ? args[0] : "--mock";
        var prompt = string.Join(" ", mode == args.FirstOrDefault() ? args.Skip(1) : args);
        if (string.IsNullOrWhiteSpace(prompt)) prompt = "Count the words in Hello from Agent 365.";
        if (prompt.Length > 4000 || mode is not ("--mock" or "--live" or "--self-test"))
        {
            Console.Error.WriteLine("Use --mock, --live or --self-test and a prompt of at most 4000 characters.");
            return 1;
        }
        var function = AIFunctionFactory.Create(CountWords);
        if (mode == "--self-test")
        {
            var result = await function.InvokeAsync(new AIFunctionArguments { ["text"] = "Hello Agent 365" });
            if (result is not JsonElement value || value.GetInt32() != 3 ||
                CountWords("") != 0 || CountWords("Hello  世界\nAgent 365") != 4)
                throw new InvalidOperationException("SDK tool invocation failed.");
            var model = new OfflineChatClient(function.Name);
            using var client = model.AsBuilder().UseFunctionInvocation().Build();
            var reply = await CreateAgent(client, function).RunAsync("Count the words in Hello Agent 365.");
            if (model.RequestCount != 2 || reply.ToString() != "Word count: 3")
                throw new InvalidOperationException("SDK agent/tool loop failed.");
            Console.WriteLine("SDK local tool and model-tool-model checks passed. The model was mocked; no external service was called.");
            return 0;
        }
        if (mode == "--mock")
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                mode = "mock", aiInference = false, input = prompt,
                words = CountWords(prompt), utc = DateTimeOffset.UtcNow.ToString("O"),
                note = "Deterministic tool demonstration, not an AI response or Agent 365 integration test."
            }));
            return 0;
        }
        if (File.Exists(".env")) DotNetEnv.Env.NoClobber().Load();
        var key = Environment.GetEnvironmentVariable("OPENAI_API_KEY");
        if (string.IsNullOrWhiteSpace(key))
        {
            Console.Error.WriteLine("Set OPENAI_API_KEY in your environment or .env before using --live.");
            return 1;
        }
        try
        {
            var model = Environment.GetEnvironmentVariable("OPENAI_MODEL") ?? "gpt-4.1-mini";
            using var client = new OpenAIClient(key).GetChatClient(model).AsIChatClient()
                .AsBuilder().UseFunctionInvocation().Build();
            var agent = CreateAgent(client, function);
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            var response = await agent.RunAsync(prompt, cancellationToken: cancellation.Token);
            Console.WriteLine(response);
            return 0;
        }
        catch (Exception)
        {
            Console.Error.WriteLine("Live request failed. Check dependencies, credentials, model access and network settings.");
            return 1;
        }
    }

    private static ChatClientAgent CreateAgent(IChatClient client, AIFunction function) =>
        new(client, new ChatClientAgentOptions
        {
            ChatOptions = new ChatOptions
            {
                Instructions = "Help with short text. Use CountWords for exact whitespace-separated word counts. Do not invent tool results.",
                Tools = [function]
            }
        });

    [Description("Count whitespace-separated words in text.")]
    private static int CountWords([Description("Text to count.")] string text) =>
        Regex.Matches(text, @"\S+").Count;
}
