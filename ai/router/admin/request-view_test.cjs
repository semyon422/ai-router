const {test} = require('node:test');
const assert = require('node:assert/strict');
const {parse} = require('./request-view.js');
const text = view => view.cards.flatMap(card => [card.title, ...card.parts.flatMap(part => [part.title, part.text])]).join('\n');
const frame = value => 'data: ' + (typeof value === 'string' ? value : JSON.stringify(value)) + '\n\n';
const response = (raw, options = {}) => parse(raw, {side: 'response', protocol: 'chat_completions', ...options});

test('requests show role messages, system instructions, settings, schemas and decoded tool results', () => {
  const raw = JSON.stringify({model: 'local/test', stream: true, chat_template_kwargs: {enable_thinking: false}, messages: [
    {role: 'system', content: 'Be helpful.\nKeep formatting.'}, {role: 'user', content: 'Compute.'},
    {role: 'assistant', content: null, tool_calls: [{id: 'c1', function: {name: 'browser_javascript', arguments: '{"code":"return 2+2;"}'}}]},
    {role: 'tool', tool_call_id: 'c1', content: '{"result":4,"logs":["done"]}'},
  ], tools: [{type: 'function', function: {name: 'browser_javascript', description: 'Calculate safely.', parameters: {required: ['code'], properties: {code: {type: 'string', description: 'A script'}}}}}]});
  const view = parse(raw, {side: 'request'});
  const readable = text(view);
  for (const value of ['System', 'Be helpful.\nKeep formatting.', 'User', 'Compute.', 'Tool call', 'return 2+2;', 'Tool result', 'Result · result\n4', 'done', 'Available tool', 'required', 'enable_thinking\nfalse']) assert.ok(readable.includes(value), value);
  assert.equal(view.partial, false);
  assert.equal(view.recognized, true);
  assert.equal(view.cards.flatMap(card => card.parts).find(part => part.title === 'Argument · code').code, true);
  assert.equal(JSON.parse(raw).messages[2].tool_calls[0].function.arguments, '{"code":"return 2+2;"}');
});

test('Responses input supports instructions, string input, messages and function exchanges', () => {
  let view = parse(JSON.stringify({instructions: 'System instructions', input: 'User prompt'}), {side: 'request'});
  assert.match(text(view), /Instructions\nText\nSystem instructions/);
  assert.match(text(view), /User\nText\nUser prompt/);
  view = parse(JSON.stringify({input: [
    {role: 'developer', content: [{type: 'input_text', text: 'Developer note'}]},
    {type: 'function_call', call_id: 'c1', name: 'calc', arguments: '{"x":7}'},
    {type: 'function_call_output', call_id: 'c1', output: [{type: 'input_text', text: 'Seven'}]},
  ]}), {side: 'request'});
  assert.match(text(view), /Developer note/); assert.match(text(view), /Argument · x\n7/); assert.match(text(view), /Result\nSeven/);
});

test('Chat JSON separates text, reasoning, refusals, tool arguments and multiple choices', () => {
  const view = response(JSON.stringify({choices: [
    {index: 0, message: {role: 'assistant', content: 'The answer\nhas lines.', reasoning_content: 'Think first.'}, finish_reason: 'stop'},
    {index: 1, message: {role: 'assistant', refusal: 'Cannot help.'}, finish_reason: 'content_filter'},
  ]}));
  assert.match(text(view), /choice 0/); assert.match(text(view), /The answer\nhas lines\./);
  assert.match(text(view), /Reasoning\nThink first\./); assert.match(text(view), /Refusal\nCannot help\./);
  assert.equal(view.partial, true); assert.match(view.notices.join(' '), /content_filter/);
});

test('Chat SSE joins indexed parallel choices and fragmented tools, accepting stop with structured calls', () => {
  const raw = [
    {choices: [{index: 1, delta: {content: 'Other'}}, {index: 0, delta: {reasoning_content: 'Think ', content: 'Hel', tool_calls: [{index: 2, id: 'c2', function: {name: 'cal', arguments: '{"co'}}]}}]},
    {choices: [{index: 0, delta: {reasoning_content: 'first.', content: 'lo', tool_calls: [{index: 2, function: {name: 'c', arguments: 'de":"return 4;"}'}}]}, finish_reason: 'stop'}, {index: 1, delta: {content: ' choice'}, finish_reason: 'stop'}]},
    {choices: [], usage: {prompt_tokens: 10}},
  ].map(frame).join('') + frame('[DONE]');
  const view = response(raw);
  assert.equal(view.partial, false); assert.equal(view.streaming, true);
  assert.match(text(view), /Hello/); assert.match(text(view), /Other choice/); assert.match(text(view), /Think first\./);
  assert.match(text(view), /Tool call · choice 0 · calc/); assert.match(text(view), /return 4;/);
  assert.equal(view.cards.filter(card => card.title.startsWith('Tool call')).length, 1);
});

test('multiline SSE data, CRLF, comments and event-name fallback are parsed', () => {
  const raw = ': comment\r\nid: ignored\r\nevent: response.output_text.delta\r\ndata: {"output_index":0,\r\ndata: "content_index":0,"delta":"Hello"}\r\n\r\nevent: response.completed\r\ndata: {"response":{"status":"completed"}}\r\n\r\n';
  const view = response(raw, {protocol: 'responses'});
  assert.equal(view.partial, false); assert.match(text(view), /Hello/);
});

test('native terminal snapshots and done events replace deltas instead of duplicating text', () => {
  const item = {id: 'm1', type: 'message', role: 'assistant', content: [{type: 'output_text', text: 'Hello'}]};
  const raw = [
    {type: 'response.output_item.added', output_index: 0, item: {...item, content: []}},
    {type: 'response.output_text.delta', item_id: 'm1', content_index: 0, delta: 'Hel'},
    {type: 'response.output_text.delta', output_index: 0, content_index: 0, delta: 'lo'},
    {type: 'response.output_text.done', output_index: 0, content_index: 0, text: 'Hello'},
    {type: 'response.output_item.done', output_index: 0, item},
    {type: 'response.completed', response: {status: 'completed', output: [item]}},
  ].map(frame).join('');
  const view = response(raw, {protocol: 'responses'});
  assert.equal(view.partial, false);
  assert.equal(view.cards.length, 1);
  assert.equal(view.cards[0].parts[0].text, 'Hello');
});

test('native partial snapshots assemble parallel arguments, reasoning and content parts by index', () => {
  const raw = [
    {type: 'response.output_item.added', output_index: 2, item: {id: 'c2', type: 'function_call', call_id: 'call2', name: 'second', arguments: ''}},
    {type: 'response.output_item.added', output_index: 1, item: {id: 'c1', type: 'function_call', call_id: 'call1', name: 'first', arguments: ''}},
    {type: 'response.function_call_arguments.delta', item_id: 'c2', delta: '{"code":"2'},
    {type: 'response.function_call_arguments.delta', item_id: 'c1', delta: '{"code":"1"}'},
    {type: 'response.function_call_arguments.delta', output_index: 2, delta: '+2"}'},
    {type: 'response.function_call_arguments.done', output_index: 1, arguments: '{"code":"1+1"}'},
    {type: 'response.reasoning_summary_text.delta', output_index: 3, summary_index: 0, delta: 'Think '},
    {type: 'response.reasoning_summary_text.done', output_index: 3, summary_index: 0, text: 'Think carefully.'},
    {type: 'response.output_text.delta', output_index: 0, content_index: 1, delta: 'Second part'},
    {type: 'response.output_text.delta', output_index: 0, content_index: 0, delta: 'First part'},
    {type: 'response.completed', response: {status: 'completed'}},
  ].map(frame).join('');
  const view = response(raw, {protocol: 'responses'});
  assert.equal(view.partial, false);
  assert.deepEqual(view.cards[0].parts.map(p => p.text), ['First part', 'Second part']);
  assert.match(view.cards[1].title, /first/); assert.match(text(view), /1\+1/);
  assert.match(view.cards[2].title, /second/); assert.match(text(view), /2\+2/);
  assert.match(text(view), /Think carefully\./);
  assert.doesNotMatch(text(view), /Think Think/);
});

test('minimal native deltas are grouped provisionally, never claimed as a guaranteed full answer', () => {
  const raw = [
    {type: 'response.output_text.delta', delta: 'Hel'}, {type: 'response.output_text.delta', delta: 'lo'},
    {type: 'response.completed', response: {status: 'completed'}},
  ].map(frame).join('');
  const view = response(raw, {protocol: 'responses'});
  assert.equal(view.cards.length, 1);
  assert.match(text(view), /Hello/);
  assert.equal(view.partial, true);
  assert.match(view.notices.join(' '), /omit item identity/);
});

test('reasoning aliases do not duplicate the same reported reasoning', () => {
  const raw = frame({choices: [{index: 0, delta: {content: 'OK', reasoning_content: 'Think.', reasoning: 'Think.'}, finish_reason: 'stop'}]}) + frame('[DONE]');
  const view = response(raw);
  assert.equal(text(view).match(/Think\./g).length, 1);
});

test('native JSON shows output, summary, opaque reasoning notices and failure details', () => {
  const view = response(JSON.stringify({object: 'response', status: 'incomplete', incomplete_details: {reason: 'max_output_tokens'}, output: [
    {type: 'reasoning', summary: [{type: 'summary_text', text: 'Reasoning summary'}], encrypted_content: 'opaque'},
    {type: 'message', role: 'assistant', content: [{type: 'output_text', text: 'Partial answer'}]},
    {type: 'function_call', name: 'calc', call_id: 'c1', arguments: '{"x":2}'},
  ]}), {protocol: 'responses'});
  assert.match(text(view), /Reasoning summary/); assert.match(text(view), /cannot be displayed/);
  assert.doesNotMatch(text(view), /\nopaque/); assert.match(text(view), /Partial answer/);
  assert.equal(view.partial, true); assert.match(view.notices.join(' '), /max_output_tokens/);
});

test('missing terminators, malformed frames, transport failures and truncation never claim completeness', () => {
  const prefix = frame({choices: [{index: 0, delta: {content: 'Useful partial'}, finish_reason: 'stop'}]});
  for (const [raw, options] of [
    [prefix, {}], [prefix + 'data: [DONE]\n', {}],
    [prefix + 'data: {invalid}\n\n' + frame('[DONE]'), {}],
    [prefix + frame('[DONE]'), {transportComplete: false}],
    [prefix + frame('[DONE]'), {truncated: true}], [prefix + frame('[DONE]'), {captureFailed: true}],
  ]) {
    const view = response(raw, options);
    assert.equal(view.partial, true); assert.match(text(view), /Useful partial/); assert.ok(view.notices.length > 0);
  }
  const view = response(frame({type: 'response.output_text.delta', output_index: 0, delta: 'Partial native'}), {protocol: 'responses'});
  assert.equal(view.partial, true); assert.match(text(view), /Partial native/);
});

test('failed native streams and error events show partial content without losing the error', () => {
  const view = response(frame({type: 'response.output_text.delta', output_index: 0, delta: 'Before error'}) + frame({type: 'response.failed', response: {status: 'failed', error: {message: 'Quota exceeded', code: 'quota'}}}), {protocol: 'responses'});
  assert.equal(view.partial, true); assert.match(text(view), /Before error/); assert.match(text(view), /Quota exceeded/);
  const chat = response(frame({error: {message: 'Bad request'}}) + frame('[DONE]'));
  assert.equal(chat.partial, true); assert.match(text(chat), /Bad request/);
});

test('unloaded previews and unread requests are not mistaken for complete empty conversations', () => {
  let view = parse('{"messages":', {side: 'request', bodyComplete: false});
  assert.equal(view.recognized, false); assert.equal(view.cards.length, 0); assert.match(view.notices.join(' '), /Load the full/);
  view = parse('', {side: 'request', requestState: 'not_read'});
  assert.equal(view.partial, true); assert.match(view.notices.join(' '), /did not read/);
});

test('attachments and untrusted identifiers remain text and prototype keys cannot mutate state', () => {
  const raw = '{"messages":[{"role":"__proto__","content":"</pre><script>alert(1)</script>"},{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.invalid/image"}},{"type":"input_audio","input_audio":{"data":"BASE64"}}]},{"role":"assistant","tool_calls":[{"function":{"name":"__proto__","arguments":"{\\"__proto__\\":{\\"polluted\\":true}}"}}]}]}';
  const view = parse(raw, {side: 'request'});
  assert.match(text(view), /Message · __proto__/); assert.match(text(view), /<script>alert\(1\)<\/script>/);
  assert.match(text(view), /https:\/\/example.invalid\/image/); assert.match(text(view), /not loaded or played/);
  assert.equal({}.polluted, undefined);
});

test('readable item limits are explicit and unsupported payloads retain a raw fallback', () => {
  const view = parse(JSON.stringify({messages: Array.from({length: 350}, () => ({role: 'user', content: 'text'}))}), {side: 'request'});
  assert.equal(view.partial, true); assert.ok(view.cards.length <= 300); assert.match(view.notices.join(' '), /limit reached/);
  assert.equal(response('{bad JSON').recognized, false);
});
