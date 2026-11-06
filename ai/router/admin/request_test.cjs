const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {runInNewContext} = require('node:vm');
const {setImmediate: settle} = require('node:timers/promises');
const source = readFileSync(join(__dirname, 'request.js'), 'utf8');

function start(raw = '{"content":"<script>not executed</script>"}', complete = true) {
  const requests = [], timers = new Map(), events = {};
  let nextTimer = 0;
  function element(text = '') {
    const value = {textContent: text, hidden: true, disabled: false, addEventListener(name, fn) { this[name] = fn; }};
    Object.defineProperty(value, 'innerHTML', {set() { throw new Error('unsafe HTML sink'); }});
    return value;
  }
  const pre = element(raw), status = element(), format = element(), load = complete ? null : element();
  const nodes = {'[data-body]': pre, '[data-status]': status, '[data-format]': format, '[data-load]': load};
  const section = {dataset: {url: '/requests/42/response', complete: String(complete)}, querySelector: s => nodes[s]};
  runInNewContext(source, {
    document: {querySelectorAll: () => [section]},
    window: {addEventListener: (name, callback) => { events[name] = callback; }},
    AbortController,
    setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id),
    fetch: (url, options) => new Promise((resolve, reject) => requests.push({url, options, resolve, reject})),
  });
  return {pre, status, format, load, requests, timers, events};
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

test('invalid or truncated JSON is never evaluated or silently replaced', async () => {
  const view = start('{"incomplete":', true);
  view.format.click();
  assert.equal(view.pre.textContent, '{"incomplete":');
  assert.match(view.status.textContent, /Cannot format/);
  assert.equal(view.requests.length, 0);
  await settle();
});
