# Node.js word and time agent

A console agent built on the OpenAI Agents SDK, with two in-process tools: `count_words` and `current_utc_time`. Requires Node.js 24 or newer.

## Offline first

From the prepared workspace:

```powershell
npm ci
npm test
npm start
```

`npm test` runs the SDK's agent and tool loop against an in-memory model. `npm start` is mock mode: it counts the words in a sample prompt and reports `aiInference: false`. Neither makes a model, credential or tenant call.

## Opt-in live inference

Copy `.env.example` to `.env` and set `OPENAI_API_KEY`, or set it in your shell. `OPENAI_MODEL` defaults to `gpt-4.1-mini`.

```powershell
npm run live -- "How many words are in this sentence?"
```

Live mode sends your prompt to OpenAI and may incur charges.

## Onboarding it to Agent 365

This is a console agent with no HTTP host. Start your CLI in this folder and say *Onboard this agent to Agent 365.* The kit registers it, then the `add-messaging-endpoint` add-on adds the `/api/messages` host that Teams needs.
