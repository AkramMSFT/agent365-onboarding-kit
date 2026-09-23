import assert from 'node:assert/strict';
import { test } from 'node:test';
import starter from './agent.js';

const { countWords, createAgent } = starter;

test('word counter handles empty, Unicode and repeated whitespace', () => {
  assert.equal(countWords(''), 0);
  assert.equal(countWords('Hello  世界\nAgent 365'), 4);
});

test('real SDK constructs the agent and invokes its local tool without a model request', async () => {
  const { RunContext } = await import('@openai/agents');
  const agent = await createAgent();
  const tool = agent.tools.find(item => item.name === 'count_words');
  assert.ok(tool);
  assert.equal(await tool.invoke(new RunContext(), '{"text":"Hello Agent 365"}'), '{"words":3}');
  const clock = agent.tools.find(item => item.name === 'current_utc_time');
  assert.ok(Number.isFinite(Date.parse(await clock.invoke(new RunContext(), '{}'))));
});

test('real SDK completes a model-tool-model turn using an in-memory model', async () => {
  const { run, Usage } = await import('@openai/agents');
  let calls = 0;
  const model = {
    async getResponse(request) {
      calls++;
      assert.ok(request.tools.some(item => item.name === 'count_words'));
      if (calls === 1) return {
        usage: new Usage(),
        output: [{ type: 'function_call', callId: 'offline-count', name: 'count_words',
          arguments: '{"text":"Hello Agent 365"}' }],
      };
      assert.equal(calls, 2);
      const result = request.input.find(item => item.type === 'function_call_result');
      assert.equal(result.callId, 'offline-count');
      assert.equal(typeof result.output === 'string' ? result.output : result.output.text, '{"words":3}');
      return {
        usage: new Usage(),
        output: [{ type: 'message', role: 'assistant', status: 'completed',
          content: [{ type: 'output_text', text: 'Word count: 3' }] }],
      };
    },
    async *getStreamedResponse() { throw new Error('This offline check is non-streaming.'); },
  };
  const result = await run(await createAgent(model), 'Count the words in Hello Agent 365.', { maxTurns: 3 });
  assert.equal(result.finalOutput, 'Word count: 3');
  assert.equal(calls, 2);
});
