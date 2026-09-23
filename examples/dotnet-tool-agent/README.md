# .NET word-count agent

A console agent built on Microsoft Agent Framework, with one in-process tool: `CountWords`. Requires the .NET 8 SDK.

## Offline first

From the prepared workspace:

```powershell
dotnet restore --locked-mode
dotnet run -- --self-test
dotnet run -- --mock "Hello Agent 365"
```

`--self-test` runs the SDK's tool call and a model-tool-model turn against a mocked model. `--mock` is a deterministic tool demonstration and reports that no AI inference happened. Neither makes a model, credential or tenant call.

## Opt-in live inference

Copy `.env.example` to `.env` and set `OPENAI_API_KEY`, or set it in your shell; shell variables win. `OPENAI_MODEL` defaults to `gpt-4.1-mini`.

```powershell
dotnet run -- --live "How many words are in this sentence?"
```

Live mode sends your prompt to OpenAI and may incur charges.

## Onboarding it to Agent 365

This is a console agent with no HTTP host. Start your CLI in this folder and say *Onboard this agent to Agent 365.* The kit registers it, then the `add-messaging-endpoint` add-on adds the ASP.NET Core `/api/messages` host that Teams needs.
