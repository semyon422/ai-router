const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {runInNewContext} = require('node:vm');
const {setImmediate: settle} = require('node:timers/promises');
const source = readFileSync(join(__dirname, 'request.js'), 'utf8');

const reader = require('./request-view.js');

function start(raw = '{"content":"<script>not executed</script>"}', complete = true, options = {}) {
  const requests = [], timers = new Map(), events = {};
  let nextTimer = 0;
  function element(text = '') {
    const value = {_text: text, children: [], hidden: false, disabled: false, addEventListener(name, fn) { this[name] = fn; },
      append(...nodes) { this.children.push(...nodes); }, replaceChildren(...nodes) { this._text = ''; this.children = nodes; }};
    Object.defineProperty(value, 'textContent', {get() { return this._text + this.children.map(child => child.textContent).join(''); }, set(text) { this._text = String(text); this.children = []; }});
    Object.defineProperty(value, 'innerHTML', {set() { throw new Error('unsafe HTML sink'); }});
    return value;
  }
  const pre = element(raw), status = element(), format = element(), load = complete ? null : element();
  const readable = options.readable ? element() : null, original = options.readable ? element() : null;
  if (original) original.open = true;
  const nodes = {'[data-body]': pre, '[data-status]': status, '[data-format]': format, '[data-load]': load, '[data-readable]': readable, '[data-raw]': original};
  const section = {dataset: {url: '/requests/42/response', complete: String(complete), side: options.side || 'response', protocol: options.protocol || 'chat_completions', truncated: String(options.truncated || false), transportComplete: String(options.transportComplete !== false), requestState: options.requestState || 'complete'}, querySelector: s => nodes[s]};
  runInNewContext(source, {
    document: {querySelectorAll: () => [section], createElement: tag => { const node = element(); node.tagName = tag; return node; }},
    window: {RouterRequestView: options.reader || reader, addEventListener: (name, callback) => { events[name] = callback; }},
    AbortController,
    setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id),
    fetch: (url, options) => new Promise((resolve, reject) => requests.push({url, options, resolve, reject})),
  });
  return {pre, status, format, load, readable, original, requests, timers, events};
}

function reply(req, body, status = 200, type = 'text/plain; charset=utf-8') {
  req.resolve(new Response(body, {status, headers: {'Content-Type': type}}));
}

test('formats JSON as inert text and always returns to the original raw value', () => {
  const raw = '{"content":"</pre><script>not executed</script>"}';
  const view = start(raw);
  assert.equal(view.requests.length, 0);
  view.format.click();
  assert.equal(view.pre.textContent, JSON.stringify(JSON.parse(raw), null, 2));
  assert.equal(view.format.textContent, 'Show raw');
  view.format.click();
  assert.equal(view.pre.textContent, raw);
});

test('formats typed SSE without removing events, DONE, or tool/reasoning data', () => {
  const raw = 'event: response.output_text.delta\ndata: {"delta":"hello","reasoning":"x","tool_calls":[]}\n\ndata: [DONE]\n\n';
  const view = start(raw);
  view.format.click();
  assert.match(view.pre.textContent, /event: response.output_text.delta/);
  assert.match(view.pre.textContent, /"reasoning": "x"/);
  assert.match(view.pre.textContent, /"tool_calls": \[\]/);
  assert.match(view.pre.textContent, /data: \[DONE\]/);
  view.format.click();
  assert.equal(view.pre.textContent, raw);
});

test('loads large bodies only on demand, using cookies, with no overlapping calls', async () => {
  const view = start('preview', false);
  assert.equal(view.format.disabled, true);
  assert.equal(view.requests.length, 0);
  const pending = view.load.click();
  view.load.click();
  assert.equal(view.requests.length, 1);
  const req = view.requests[0];
  assert.equal(req.url, '/requests/42/response');
  assert.equal(req.options.credentials, 'same-origin');
  assert.equal(req.options.cache, 'no-store');
  assert.equal(req.options.redirect, 'error');
  assert.equal(req.options.headers, undefined);
  const raw = '{"content":"<script>still inert</script>"}';
  reply(req, raw);
  await pending;
  assert.equal(view.pre.textContent, raw);
  assert.equal(view.load.hidden, true);
  assert.equal(view.format.disabled, false);
  assert.equal(view.timers.size, 0);
  view.format.click();
  view.format.click();
  assert.equal(view.pre.textContent, raw);
});

test('expired sessions, eviction, wrong content types and network errors preserve the preview', async () => {
  for (const mode of ['session', 'eviction', 'html', 'network']) {
    const view = start('original preview', false);
    const pending = view.load.click();
    if (mode === 'network') view.requests[0].reject(new Error('PRIVATE-NETWORK-ERROR'));
    else reply(view.requests[0], '<html>not a body</html>', mode === 'session' ? 401 : mode === 'eviction' ? 404 : 200, mode === 'html' ? 'text/html' : 'text/plain');
    await pending;
    assert.equal(view.pre.textContent, 'original preview');
    assert.equal(view.load.disabled, false);
    assert.equal(view.format.disabled, true);
    assert.equal(view.timers.size, 0);
    assert.doesNotMatch(view.status.textContent, /PRIVATE|<html>/);
  }
});

test('page exit and deadline abort pending reads and reject late body delivery', async () => {
  for (const abort of ['pagehide', 'deadline']) {
    const view = start('preview', false);
    const pending = view.load.click();
    const req = view.requests[0];
    if (abort === 'pagehide') view.events.pagehide();
    else [...view.timers.values()][0]();
    assert.equal(req.options.signal.aborted, true);
    reply(req, 'late secret body');
    await pending;
    assert.equal(view.pre.textContent, 'preview');
    assert.equal(view.load.disabled, false);
    assert.equal(view.timers.size, 0);
  }
});

test('readable messages are default, inert and leave original JSON independently accessible', () => {
  const raw = JSON.stringify({messages: [{role: 'system', content: 'Be helpful.'}, {role: 'user', content: '</pre><script>not executed</script>\nSecond line.'}]});
  const view = start(raw, true, {readable: true, side: 'request'});
  assert.equal(view.readable.hidden, false);
  assert.match(view.readable.textContent, /System/);
  assert.match(view.readable.textContent, /<script>not executed<\/script>\nSecond line\./);
  assert.equal(view.original.open, false);
  assert.equal(view.pre.textContent, raw);
  assert.equal(view.requests.length, 0);
  view.original.open = true;
  view.format.click();
  view.format.click();
  assert.equal(view.pre.textContent, raw);
  assert.equal(view.original.open, true);
});

test('the actual DOM renderer displays one assembled SSE answer and honest partial states', () => {
  const raw = ['Hel', 'lo world'].map(content => 'data: ' + JSON.stringify({choices: [{index: 0, delta: {content}}]}) + '\n\n').join('') + 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
  const view = start(raw, true, {readable: true});
  assert.match(view.readable.textContent, /Assembled streaming response · complete/);
  assert.equal(view.readable.textContent.match(/Hello world/g).length, 1);
  assert.equal(view.pre.textContent, raw);
  const partial = start(raw, true, {readable: true, truncated: true});
  assert.match(partial.readable.textContent, /Assembled streaming response · partial/);
  assert.doesNotMatch(partial.readable.textContent, /· complete/);
  assert.match(partial.readable.textContent, /Omitted content cannot be reconstructed/);
});

test('large readable views wait for explicit full loading and preserve source bytes', async () => {
  const view = start('prefix only', false, {readable: true});
  assert.match(view.readable.textContent, /full body not loaded/);
  assert.equal(view.original.open, true);
  assert.equal(view.requests.length, 0);
  const pending = view.load.click();
  const raw = JSON.stringify({choices: [{message: {role: 'assistant', content: 'Full answer'}, finish_reason: 'stop'}]});
  reply(view.requests[0], raw);
  await pending;
  assert.match(view.readable.textContent, /Full answer/);
  assert.equal(view.original.open, false);
  assert.equal(view.pre.textContent, raw);
});

test('reader failures cannot remove raw data or break its controls', () => {
  const raw = '{"choices":[]}';
  const view = start(raw, true, {readable: true, reader: {parse() { throw new Error('PRIVATE-PARSER-ERROR'); }}});
  assert.equal(view.original.open, true);
  assert.equal(view.pre.textContent, raw);
  assert.match(view.readable.textContent, /original payload remains available/);
  assert.doesNotMatch(view.readable.textContent, /PRIVATE-PARSER/);
  view.format.click();
  view.format.click();
  assert.equal(view.pre.textContent, raw);
  assert.equal(view.requests.length, 0);
});

test('unrecognized bodies keep their original view open', () => {
  const view = start('invalid JSON', true, {readable: true});
  assert.equal(view.original.open, true);
  assert.equal(view.pre.textContent, 'invalid JSON');
  assert.match(view.readable.textContent, /original payload is still available/);
});

test('invalid or truncated JSON is never evaluated or silently replaced', async () => {
  const view = start('{"incomplete":', true);
  view.format.click();
  assert.equal(view.pre.textContent, '{"incomplete":');
  assert.match(view.status.textContent, /Cannot format/);
  assert.equal(view.requests.length, 0);
  await settle();
});
