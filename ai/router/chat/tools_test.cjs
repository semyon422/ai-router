const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {runInNewContext} = require('node:vm');
const {setImmediate: settle} = require('node:timers/promises');
const source = readFileSync(join(__dirname, 'tools.js'), 'utf8');

function start({failAppend = false} = {}) {
	const frames = [], timers = new Map(), listeners = new Set();
	let nextTimer = 1;
	const window = {
		addEventListener: (name, fn) => listeners.add(fn),
		removeEventListener: (name, fn) => listeners.delete(fn),
	};
	const document = {
		createElement: tag => {
			assert.equal(tag, 'iframe');
			const frame = {attributes: {}, sent: [],
				setAttribute: (name, value) => { frame.attributes[name] = value; },
				contentWindow: {postMessage: (data, origin) => { frame.sent.push({data, origin}); }},
				remove: () => { const i = frames.indexOf(frame); if (i >= 0) frames.splice(i, 1); },
			};
			return frame;
		},
		body: {appendChild: frame => { if (failAppend) throw new Error('blocked'); frames.push(frame); }},
	};
	runInNewContext(source, {window, document, DOMException,
		setTimeout: (fn, delay) => { assert.equal(delay, 5000); const id = nextTimer++; timers.set(id, fn); return id; },
		clearTimeout: id => timers.delete(id),
	});
	return {run: window.routerChatTools.runJavaScript, frames, timers, listeners,
		dispatch: (source, data) => { for (const fn of [...listeners]) fn({source, data}); }};
}

test('sandbox is opaque-origin, denies network and never embeds model code into HTML', async () => {
	const view = start();
	const code = 'return "</script><img src=x onerror=alert(1)>";';
	const result = view.run(code);
	const frame = view.frames[0];
	assert.equal(frame.attributes.sandbox, 'allow-scripts');
	assert.equal(frame.referrerPolicy, 'no-referrer');
	assert.match(frame.srcdoc, /default-src 'none'/);
	assert.match(frame.srcdoc, /connect-src 'none'/);
	assert.match(frame.srcdoc, /worker-src blob:/);
	assert.equal(frame.srcdoc.includes(code), false);
	view.dispatch({}, {type: 'ready'});
	view.dispatch({}, {type: 'result', ok: true, output: 'forged'});
	assert.equal(frame.sent.length, 0);
	view.dispatch(frame.contentWindow, {type: 'result', ok: true, output: 'too early'});
	view.dispatch(frame.contentWindow, {type: 'ready'});
	view.dispatch(frame.contentWindow, {type: 'ready'});
	assert.equal(frame.sent.length, 1);
	assert.equal(frame.sent[0].data.code, code);
	view.dispatch(frame.contentWindow, {type: 'result', ok: true, output: 'x'.repeat(17000)});
	assert.equal((await result).output.length, 16000);
	assert.equal(view.frames.length, 0); assert.equal(view.timers.size, 0); assert.equal(view.listeners.size, 0);
	assert.equal(frame.sent.at(-1).data.type, 'cancel');
});

test('deadline and AbortSignal remove the frame, listener and timer', async () => {
	const view = start();
	const timed = view.run('while (true) {}');
	[...view.timers.values()][0]();
	assert.match((await timed).output, /timed out/);
	assert.equal(view.frames.length, 0); assert.equal(view.listeners.size, 0); assert.equal(view.timers.size, 0);
	const controller = new AbortController();
	const cancelled = view.run('await new Promise(() => {})', {signal: controller.signal});
	controller.abort();
	await assert.rejects(cancelled, {name: 'AbortError'});
	assert.equal(view.frames.length, 0); assert.equal(view.listeners.size, 0); assert.equal(view.timers.size, 0);
	await assert.rejects(view.run('return 1', {signal: controller.signal}), {name: 'AbortError'});
	assert.equal(view.frames.length, 0);
});

test('oversized code and blocked iframe creation fail without leaking resources', async () => {
	const view = start();
	assert.equal((await view.run('x'.repeat(20001))).ok, false);
	assert.equal(view.frames.length, 0); assert.equal(view.timers.size, 0);
	const blocked = start({failAppend: true});
	assert.equal((await blocked.run('return 1')).ok, false);
	assert.equal(blocked.listeners.size, 0); assert.equal(blocked.timers.size, 0);
});

async function runWorker(code) {
	// Evaluate the actual trusted frame/worker boot code with fake browser
	// transports. Browser CSP is asserted above, not claimed to be enforced by VM.
	const view = start();
	const pending = view.run(code);
	const frame = view.frames[0];
	let listener, worker, revoked = 0;
	const parent = {postMessage: data => view.dispatch(frame.contentWindow, data)};
	let blobSource;
	class Worker {
		constructor(url) {
			assert.equal(url, 'blob:opaque'); worker = this;
			this.self = {postMessage: data => this.onmessage({data})};
			runInNewContext(blobSource, {self: this.self});
		}
		postMessage(code) { this.self.onmessage({data: code}); }
		terminate() { this.terminated = true; }
	}
	runInNewContext(frame.srcdoc.match(/<script>([\s\S]*)<\/script>/)[1], {
		parent, Worker,
		addEventListener: (name, fn) => { listener = fn; },
		Blob: class { constructor(parts) { blobSource = parts.join(''); } },
		URL: {createObjectURL: () => 'blob:opaque', revokeObjectURL: () => revoked++},
	});
	const message = frame.sent.find(item => item.data.type === 'run');
	listener({source: parent, data: message.data});
	await settle();
	assert.equal(worker.terminated, true); assert.equal(revoked, 1);
	return pending;
}

test('actual worker handles async returns, bounded console output and errors', async () => {
	let result = await runWorker('console.log("hello"); return await Promise.resolve(1 + 2);');
	assert.equal(result.ok, true); assert.equal(result.output, 'hello\n3');
	result = await runWorker('return [typeof document, typeof parent, typeof localStorage, typeof window];');
	assert.equal(result.output, '["undefined","undefined","undefined","undefined"]');
	result = await runWorker('for (let i = 0; i < 200; i++) console.log("x".repeat(10000));');
	assert.equal(result.output.length, 16000);
	result = await runWorker('throw new Error("test failure")');
	assert.equal(result.ok, false); assert.match(result.output, /test failure/);
});
