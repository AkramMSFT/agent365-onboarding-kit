'use strict';

const fs = require('node:fs');

function countWords(text) {
  const value = text.trim();
  return value ? value.split(/\s+/u).length : 0;
}

async function createAgent(model = 'gpt-4.1-mini') {
  const { Agent, tool, setTracingDisabled } = await import('@openai/agents');
  const { z } = await import('zod');
  setTracingDisabled(true);
  return new Agent({
    name: 'Word and time helper',
    instructions: 'Help with short text and UTC time. Use count_words for exact word counts. Words are separated by whitespace. Use current_utc_time for the current time. Do not invent tool results.',
    model,
    tools: [
      tool({
        name: 'count_words',
        description: 'Count whitespace-separated words in text.',
        parameters: z.object({ text: z.string().max(4000) }),
        execute: async ({ text }) => JSON.stringify({ words: countWords(text) }),
      }),
      tool({
        name: 'current_utc_time',
        description: 'Return the current UTC date and time.',
        parameters: z.object({}),
        execute: async () => new Date().toISOString(),
      }),
    ],
  });
}

async function main(args = process.argv.slice(2)) {
  if (args.includes('--help')) {
    console.log('node agent.js [--mock|--live] [prompt]\nDefault: --mock (no model, credentials or tenant calls).');
    return 0;
  }
  const mode = args[0]?.startsWith('--') ? args.shift() : '--mock';
  if (!['--mock', '--live'].includes(mode)) throw new Error('Use --mock or --live.');
  const prompt = args.join(' ') || 'How many words are in "Hello from Agent 365", and what is the UTC time?';
  if (prompt.length > 4000) throw new Error('Keep the prompt within 4000 characters.');
  if (mode === '--mock') {
    console.log(JSON.stringify({
      mode: 'mock',
      aiInference: false,
      input: prompt,
      words: countWords(prompt),
      utc: new Date().toISOString(),
      note: 'Deterministic tool demonstration, not an AI response or Agent 365 integration test.',
    }, null, 2));
    return 0;
  }
  if (fs.existsSync('.env')) process.loadEnvFile('.env');
  if (!process.env.OPENAI_API_KEY?.trim()) throw new Error('Set OPENAI_API_KEY in your environment or .env before using --live.');
  const { run } = await import('@openai/agents');
  const agent = await createAgent(process.env.OPENAI_MODEL || 'gpt-4.1-mini');
  const result = await run(agent, prompt, { maxTurns: 5, signal: AbortSignal.timeout(60000) });
  console.log(result.finalOutput);
  return 0;
}

module.exports = { countWords, createAgent, main };

if (require.main === module) {
  main().then(code => { process.exitCode = code; }).catch(error => {
    console.error(error.message?.startsWith('Set OPENAI_API_KEY') ? error.message
      : 'The sample could not complete. Check the mode, prompt, dependencies, model access and network.');
    process.exitCode = 1;
  });
}
