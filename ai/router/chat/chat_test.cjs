const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {runInNewContext} = require('node:vm');
const {setImmediate: settle} = require('node:timers/promises');

const source = readFileSync(join(__dirname, 'chat.js'), 'utf8');

function element(tag = 'div') {
	const node = {
		tag,
		className: '',
		textContent: '',
		children: [],
		parentElement: null,
		listeners: {},
		addEventListener: (name, callback) => { node.listeners[name] = callback; },
		remove: () => { if (node.parentElement) node.parentElement.removeChild(node); },
		replaceChildren: (...children) => {
			for (const child of node.children) child.parentElement = null;
			node.children.length = 0;
			for (const child of children) node.appendChild(child);
		},
		appendChild: child => {
			child.parentElement = node;
			node.children.push(child);
			return child;
		},
		insertBefore: (child, ref) => {
			child.parentElement = node;
			const index = node.children.indexOf(ref);
			node.children.splice(index < 0 ? node.children.length : index, 0, child);
			return child;
		},
		removeChild: child => {
			node.children.splice(node.children.indexOf(child), 1);
			child.parentElement = null;
		},
	};
	return node;
}

function start(saved, {userId = 1, storage = {}, runJavaScript, modelInfo = {}} = {}) {
	if (saved) storage['ai-router-chat:' + userId] = saved;
	const elements = {
		'chat-model': {
			tag: 'select',
			value: 'zai-1/glm-5.3',
			options: [{value: 'zai-1/glm-5.3'}, {value: 'openai-1/gpt-6-luna'}],
			listeners: {},
			addEventListener: (name, callback) => { elements['chat-model'].listeners[name] = callback; },
		},
		'chat-messages': {
			...element('div'),
			scrollTop: 0,
			scrollHeight: 10,
		},
		'chat-input': {tag: 'textarea', value: '', disabled: false, listeners: {},
			addEventListener: (name, callback) => { elements['chat-input'].listeners[name] = callback; }},
		'chat-send': {tag: 'button', value: '', disabled: false, textContent: 'Send', listeners: {},
			addEventListener: (name, callback) => { elements['chat-send'].listeners[name] = callback; }},
		'chat-error': element('div'),
		'chat-reset': element('button'),
		'chat-system': {...element('textarea'), value: ''},
		'chat-reasoning': {...element('select'), value: 'default'},
		'chat-tools': {...element('input'), checked: false},
		'chat-status': element('p'),
		'chat-reasoning-hint': element('p'),
	};
	const document = {
		hidden: false,
		getElementById: id => elements[id],
		createElement: tag => element(tag),
	};
	const window = {
		routerChat: {csrfToken: 'csrf-123', userId, model: 'zai-1/glm-5.3', modelInfo},
		routerChatTools: {runJavaScript: runJavaScript || (async () => ({ok: true, output: '2'}))},
		location: {},
		addEventListener: () => {},
	};
	const requests = [];
	runInNewContext(source, {
		document,
		window,
		localStorage: {
			getItem: key => (key in storage ? storage[key] : null),
			setItem: (key, value) => { storage[key] = value; },
		},
		fetch: (url, options) => new Promise((resolve, reject) => {
			requests.push({url, options, resolve, reject});
			if (options.signal && options.signal.aborted) reject(new DOMException('Aborted', 'AbortError'));
			else if (options.signal) options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), {once: true});
		}),
		performance: {now: (() => { let time = 0; return () => time += 100; })()},
		TextDecoder,
		AbortController,
	});
	return {
		elements,
		requests,
		storage,
		contextWindow: window,
		send: () => {
			if (!elements['chat-send'].disabled) elements['chat-send'].listeners.click();
		},
		key: (key, shiftKey = false) => elements['chat-input'].listeners.keydown(
			{key, shiftKey, preventDefault: () => {}}),
		modelChange: () => elements['chat-model'].listeners.change(),
	};
}

function sse(chunks, request) {
	const payload = chunks.map(chunk => 'data: ' + chunk + '\n\n').join('');
	let offset = 0;
	return {
		ok: true,
		status: 200,
		body: {
			getReader: () => ({
				read: () => new Promise((resolve, reject) => {
					if (request && request.options.signal && request.options.signal.aborted) {
						reject(new DOMException('Aborted', 'AbortError'));
						return;
					}
					if (offset >= payload.length) {
						resolve({done: true});
						return;
					}
					const index = payload.indexOf('\n\n', offset);
					const next = index < 0 ? payload.length : index + 2;
					resolve({done: false, value: new TextEncoder().encode(payload.slice(offset, next))});
					offset = next;
				}),
			}),
		},
	};
}

function chunks(message) {
	return [
		JSON.stringify({choices: [{delta: {role: 'assistant'}}]}),
		JSON.stringify({choices: [{delta: {content: message}}]}),
		JSON.stringify({choices: [{delta: {}, finish_reason: 'stop'}]}),
		'[DONE]',
	];
}

function userMessage(request) {
	const body = JSON.parse(request.options.body);
	return body.messages[body.messages.length - 1];
}

test('raw reasoning remains under its original name through display, restore and follow-up', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Think'; view.send();
	view.requests[0].resolve(sse([
		JSON.stringify({choices: [{delta: {reasoning: '<script>inert</script>'}, finish_reason: 'length'}]}), '[DONE]',
	]));
	await settle(); await settle();
	const saved = JSON.parse(view.storage['ai-router-chat:1']).messages[1];
	assert.equal(saved.reasoning, '<script>inert</script>');
	assert.equal(Object.hasOwn(saved, 'reasoning_content'), false);
	const body = view.elements['chat-messages'].children[1].children[1];
	assert.equal(body.children[0].children[1].textContent, saved.reasoning);
	assert.equal(body.children[1].hidden, true);
	const stats = view.elements['chat-messages'].children[1].children[2].textContent;
	assert.equal(stats.includes('TTFT —'), false);
	const restored = start(null, {storage: view.storage});
	assert.equal(restored.elements['chat-messages'].children[1].children[1].children[0].children[1].textContent, saved.reasoning);
	restored.elements['chat-input'].value = 'Next'; restored.send();
	const sent = JSON.parse(restored.requests[0].options.body).messages[1];
	assert.deepEqual(sent, saved);
	restored.send(); await settle();
});

test('both reasoning fields stay independent; only identical displayed text is deduplicated', async () => {
	for (const [raw, legacy] of [['first', 'second'], ['same', 'same']]) {
		const view = start(); view.elements['chat-input'].value = 'Think'; view.send();
		view.requests[0].resolve(sse([
			JSON.stringify({choices: [{delta: {reasoning: raw.slice(0, 2), reasoning_content: legacy.slice(0, 1)}}]}),
			JSON.stringify({choices: [{delta: {reasoning: raw.slice(2), reasoning_content: legacy.slice(1), content: 'answer'}, finish_reason: 'stop'}]}), '[DONE]',
		]));
		await settle(); await settle();
		const saved = JSON.parse(view.storage['ai-router-chat:1']).messages[1];
		assert.equal(saved.reasoning, raw); assert.equal(saved.reasoning_content, legacy);
		const reasoning = view.elements['chat-messages'].children[1].children[1].children.filter(node => node.className === 'reasoning' && !node.hidden);
		assert.equal(reasoning.length, raw === legacy ? 1 : 2);
		if (raw !== legacy) {
			assert.deepEqual(reasoning.map(node => node.children[1].textContent), [legacy, raw]);
			assert.deepEqual(reasoning.map(node => node.children[0].textContent), ['Reasoning (reasoning_content)', 'Reasoning (reasoning)']);
		}
		const restored = start(null, {storage: view.storage});
		restored.elements['chat-input'].value = 'Next'; restored.send();
		assert.deepEqual(JSON.parse(restored.requests[0].options.body).messages[1], saved);
		restored.send(); await settle();
	}
});

test('null and empty reasoning are not renamed and reported reasoning counters distinguish missing from zero', async () => {
	for (const count of [undefined, 0, 3]) {
		const view = start(); view.elements['chat-input'].value = 'Hello'; view.send();
		view.requests[0].resolve(sse([
			JSON.stringify({choices: [{delta: {reasoning: null, reasoning_content: '', content: 'answer'}, finish_reason: 'stop'}]}),
			JSON.stringify({choices: [], usage: {prompt_tokens: 10, completion_tokens: 7, prompt_tokens_details: {cached_tokens: 0},
				completion_tokens_details: count === undefined ? undefined : {reasoning_tokens: count}}}), '[DONE]',
		]));
		await settle(); await settle();
		const saved = JSON.parse(view.storage['ai-router-chat:1']).messages[1];
		assert.equal(saved.reasoning, null); assert.equal(saved.reasoning_content, '');
		const stats = view.elements['chat-messages'].children[1].children[2].textContent;
		assert.ok(stats.includes('out 7'));
		assert.equal(stats.includes('reasoning '), count !== undefined);
		if (count !== undefined) assert.ok(stats.includes('reasoning ' + count));
	}
});

test('both reasoning string fields obey the browser content bound', async () => {
	for (const field of ['reasoning', 'reasoning_content']) {
		const view = start(); view.elements['chat-input'].value = 'Think'; view.send();
		view.requests[0].resolve(sse([JSON.stringify({choices: [{delta: {[field]: 'x'.repeat(100001)}}]}), '[DONE]']));
		await settle(); await settle();
		assert.match(view.elements['chat-error'].textContent, /Reasoning exceeded/);
		assert.equal(JSON.parse(view.storage['ai-router-chat:1']).messages.length, 1);
	}
});

test('sends the conversation with the CSRF token and renders the streamed reply', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Hello';
	view.send();
	assert.equal(view.requests.length, 1);
	const req = view.requests[0];
	assert.equal(req.url, '/chat/completions');
	assert.equal(req.options.method, 'POST');
	assert.equal(req.options.credentials, 'same-origin');
	assert.equal(req.options.headers['X-CSRF-Token'], 'csrf-123');
	assert.ok(req.options.signal && typeof req.options.signal.aborted === 'boolean');
	assert.equal(userMessage(req).role, 'user');
	assert.equal(userMessage(req).content, 'Hello');
	assert.equal(JSON.parse(req.options.body).stream, true);
	assert.deepEqual(JSON.parse(req.options.body).stream_options, {include_usage: true});
	assert.equal(view.elements['chat-send'].textContent, 'Stop');
	assert.equal(view.elements['chat-input'].disabled, true);
	req.resolve(sse(chunks('Hi there')));
	await settle();
	await settle();
	assert.equal(view.elements['chat-messages'].children.length, 2);
	assert.equal(view.elements['chat-messages'].children[1].children[1].children[0].textContent, 'Hi there');
	assert.equal(view.elements['chat-send'].textContent, 'Send');
	assert.equal(view.elements['chat-input'].disabled, false);
	const saved = JSON.parse(view.storage['ai-router-chat:1']);
	assert.deepEqual(saved.messages, [
		{role: 'user', content: 'Hello'},
		{role: 'assistant', content: 'Hi there'},
	]);
	assert.equal(saved.model, 'zai-1/glm-5.3');
});

test('streams deltas incrementally and renders reasoning content', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Think';
	view.send();
	const req = view.requests[0];
	const response = sse([
		JSON.stringify({choices: [{delta: {role: 'assistant'}}]}),
		JSON.stringify({choices: [{delta: {reasoning_content: 'Let me '}}]}),
		JSON.stringify({choices: [{delta: {reasoning_content: 'think…'}}]}),
		JSON.stringify({choices: [{delta: {content: 'Answer '}}]}),
		JSON.stringify({choices: [{delta: {content: 'now.'}}]}),
		'[DONE]',
	]);
	req.resolve(response);
	await settle();
	await settle();
	const bubble = view.elements['chat-messages'].children[1];
	const body = bubble.children[1];
	assert.equal(body.children.length, 2);
	assert.equal(body.children[0].className, 'reasoning');
	assert.equal(body.children[0].children[0].textContent, 'Reasoning');
	assert.equal(body.children[0].children[1].textContent, 'Let me think…');
	assert.equal(body.children[1].className, 'content');
	assert.equal(body.children[1].textContent, 'Answer now.');
});

test('http errors surface the server message and keep the composer usable', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Flood';
	view.send();
	view.requests[0].resolve({
		ok: false,
		status: 429,
		text: () => Promise.resolve(JSON.stringify({error: {message: 'Too many requests for this user.'}})),
	});
	await settle();
	await settle();
	assert.equal(view.elements['chat-error'].textContent, 'Too many requests for this user.');
	assert.equal(view.elements['chat-send'].textContent, 'Send');
	assert.equal(view.elements['chat-input'].disabled, false);
	// The failed assistant bubble is dropped; the user message stays.
	assert.equal(view.elements['chat-messages'].children.length, 1);
	assert.equal(view.elements['chat-messages'].children[0].className, 'msg user');
});

test('a 401 session bounce redirects to the shared login page', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Expired';
	view.send();
	view.requests[0].resolve({ok: false, status: 401, text: () => Promise.resolve('{}')});
	await settle();
	await settle();
	assert.equal(view.contextWindow.location.href, '/login');
});

test('clicking Stop aborts the stream without an error', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Long one';
	view.send();
	const req = view.requests[0];
	let release;
	let reads = 0;
	req.resolve({ok: true, status: 200, body: {getReader: () => ({
		read: () => {
			if (reads++ === 0) return Promise.resolve({done: false,
				value: new TextEncoder().encode('data: ' + JSON.stringify({choices: [{delta: {content: 'part'}}]}) + '\n\n')});
			return new Promise((resolve, reject) => {
				release = resolve;
				req.options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
			});
		},
	})}});
	await settle();
	assert.equal(view.elements['chat-send'].disabled, false);
	assert.equal(view.elements['chat-send'].textContent, 'Stop');
	view.send(); // active -> abort
	await settle();
	assert.equal(req.options.signal.aborted, true);
	release({done: true});
	assert.equal(view.elements['chat-error'].textContent, '');
	assert.equal(view.elements['chat-send'].textContent, 'Send');
	// The partial reply is kept.
	const saved = JSON.parse(view.storage['ai-router-chat:1']);
	assert.equal(saved.messages[1].content, 'part');
});

test('an empty reply without reasoning reports a generic failure', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Empty';
	view.send();
	view.requests[0].resolve(sse([
		JSON.stringify({choices: [{delta: {role: 'assistant'}}]}),
		'[DONE]',
	]));
	await settle();
	await settle();
	assert.equal(view.elements['chat-error'].textContent, 'No reply was received.');
});

test('restores model and history from localStorage and skips junk', async () => {
	const saved = JSON.stringify({
		model: 'gone-model',
		messages: [
			{role: 'user', content: 'one'},
			{role: 'system', content: 'injected'},
			{role: 'assistant', content: ''},
			'junk',
			{role: 'assistant', content: 'two'},
		],
	});
	const view = start(saved);
	assert.equal(view.elements['chat-model'].value, 'zai-1/glm-5.3');
	assert.equal(view.elements['chat-messages'].children.length, 2);
	assert.equal(view.elements['chat-messages'].children[0].children[0].textContent, 'You');
	assert.equal(view.elements['chat-messages'].children[0].children[1].children[0].textContent, 'one');
	assert.equal(view.elements['chat-messages'].children[1].children[1].children[0].textContent, 'two');
});

test('isolates account history and ignores unowned legacy history', async () => {
	const storage = {'ai-router-chat': JSON.stringify({messages: [{role: 'user', content: 'legacy secret'}]})};
	const alice = start(null, {userId: 1, storage});
	assert.equal(alice.elements['chat-messages'].children.length, 0);
	alice.elements['chat-input'].value = 'Alice secret';
	alice.send();
	alice.requests[0].resolve(sse(chunks('Alice reply')));
	await settle(); await settle();
	const bob = start(null, {userId: 2, storage});
	assert.equal(bob.elements['chat-messages'].children.length, 0);
	bob.elements['chat-input'].value = 'Bob prompt';
	bob.send();
	assert.equal(JSON.parse(bob.requests[0].options.body).messages.length, 1);
	assert.equal(bob.requests[0].options.body.includes('Alice secret'), false);
	const restored = start(null, {userId: 1, storage});
	assert.equal(restored.elements['chat-messages'].children.length, 2);
});

test('bounds outgoing and persisted history across successive exchanges', async () => {
	const view = start(JSON.stringify({messages: Array.from({length: 100}, (_, i) => ({
		role: i % 2 ? 'assistant' : 'user', content: 'old-' + i,
	}))}));
	for (let i = 0; i < 3; i++) {
		view.elements['chat-input'].value = 'x'.repeat(100001);
		view.send();
		const req = view.requests[i];
		const outgoing = JSON.parse(req.options.body).messages;
		assert.ok(outgoing.length <= 100);
		assert.equal(outgoing.at(-1).content.length, 100000);
		req.resolve(sse(chunks('reply')));
		await settle(); await settle();
		assert.equal(JSON.parse(view.storage['ai-router-chat:1']).messages.length, 100);
	}
});

test('Enter sends while Shift+Enter does not', () => {
	const view = start();
	view.key('Enter');
	assert.equal(view.requests.length, 0);
	view.elements['chat-input'].value = 'Go';
	view.key('Enter');
	assert.equal(view.requests.length, 1);
	view.key('Enter', true);
	assert.equal(view.requests.length, 1);
});

function toolChunks(code = 'return 1 + 1', {id = 'call-1', name = 'browser_javascript'} = {}) {
	const args = JSON.stringify({code});
	return [
		JSON.stringify({id: 'completion-tools', choices: [{delta: {tool_calls: [{index: 0, id, type: 'function', function: {name, arguments: args.slice(0, 8)}}]}}]}),
		JSON.stringify({choices: [{delta: {tool_calls: [{index: 0, function: {arguments: args.slice(8)}}]}}]}),
		JSON.stringify({choices: [{delta: {}, finish_reason: 'tool_calls'}]}),
		JSON.stringify({choices: [], usage: {prompt_tokens: 100, completion_tokens: 20, prompt_tokens_details: {cached_tokens: 50}}}),
		'[DONE]',
	];
}

const drain = async () => { await settle(); await settle(); };

test('hides leading blank lines across deltas without changing code indentation or wire history', async () => {
	const view = start();
	view.elements['chat-input'].value = 'Code'; view.send();
	view.requests[0].resolve(sse([
		JSON.stringify({choices: [{delta: {content: '\n'}}]}),
		JSON.stringify({choices: [{delta: {content: '\n    indented\n\nnext'}}]}), '[DONE]',
	]));
	await drain();
	assert.equal(view.elements['chat-messages'].children[1].children[1].children[0].textContent, '    indented\n\nnext');
	assert.equal(JSON.parse(view.storage['ai-router-chat:1']).messages[1].content, '\n\n    indented\n\nnext');
	const restored = start(null, {storage: view.storage});
	assert.equal(restored.elements['chat-messages'].children[1].children[1].children[0].textContent, '    indented\n\nnext');
});

test('streams UTF-8 and CRLF frames split at every byte', async () => {
	const view = start(); view.elements['chat-input'].value = 'Unicode'; view.send();
	const payload = new TextEncoder().encode(chunks('Привет 🌍').map(item => 'data: ' + item + '\r\n\r\n').join(''));
	let offset = 0;
	view.requests[0].resolve({ok: true, status: 200, body: {getReader: () => ({read: async () => offset < payload.length
		? {done: false, value: payload.slice(offset, ++offset)} : {done: true}})}});
	await drain();
	assert.equal(view.elements['chat-messages'].children[1].children[1].children[0].textContent, 'Привет 🌍');
	assert.equal(view.elements['chat-error'].textContent, '');
});

test('a whitespace-only reply is not kept as a permanently empty bubble', async () => {
	const view = start(); view.elements['chat-input'].value = 'Empty'; view.send();
	view.requests[0].resolve(sse(chunks('\n\n   '))); await drain();
	assert.equal(view.elements['chat-messages'].children.length, 1);
	assert.equal(view.elements['chat-error'].textContent, 'No reply was received.');
});

test('system prompt and reasoning settings are account-scoped and editable between requests', async () => {
	const view = start(null, {modelInfo: {'zai-1/glm-5.3': {kind: 'zai'}}});
	view.elements['chat-system'].value = 'Be precise';
	view.elements['chat-reasoning'].value = 'disabled';
	view.elements['chat-input'].value = 'Hi'; view.send();
	let body = JSON.parse(view.requests[0].options.body);
	assert.deepEqual(body.messages[0], {role: 'system', content: 'Be precise'});
	assert.deepEqual(body.thinking, {type: 'disabled'});
	assert.equal(body.chat_template_kwargs, undefined);
	assert.equal(view.elements['chat-system'].disabled, true);
	view.requests[0].resolve(sse(chunks('OK'))); await drain();
	view.elements['chat-system'].value = 'New instruction';
	view.elements['chat-input'].value = 'Next'; view.send();
	body = JSON.parse(view.requests[1].options.body);
	assert.equal(body.messages[0].content, 'New instruction');
	assert.equal(body.messages.filter(item => item.role === 'system').length, 1);
	view.requests[1].resolve(sse(chunks('Done'))); await drain();
	const restored = start(null, {storage: view.storage});
	assert.equal(restored.elements['chat-system'].value, 'New instruction');
	assert.equal(restored.elements['chat-reasoning'].value, 'disabled');
	assert.equal(start(null, {userId: 2, storage: view.storage}).elements['chat-system'].value, '');
});

test('compatible thinking overrides use template kwargs and default sends no override', async () => {
	const view = start();
	view.elements['chat-reasoning'].value = 'enabled';
	view.elements['chat-input'].value = 'Think'; view.send();
	assert.deepEqual(JSON.parse(view.requests[0].options.body).chat_template_kwargs, {enable_thinking: true});
	view.requests[0].resolve(sse(chunks('Yes'))); await drain();
	view.elements['chat-reasoning'].value = 'default';
	view.elements['chat-input'].value = 'Default'; view.send();
	const body = JSON.parse(view.requests[1].options.body);
	assert.equal(body.thinking, undefined); assert.equal(body.chat_template_kwargs, undefined);
});

test('New chat clears messages and draft, keeps settings, and cannot race an active request', async () => {
	const view = start();
	view.elements['chat-system'].value = 'Keep this';
	view.elements['chat-input'].value = 'Old'; view.send();
	assert.equal(view.elements['chat-reset'].disabled, true);
	view.elements['chat-reset'].listeners.click();
	assert.equal(view.elements['chat-messages'].children.length, 2);
	view.requests[0].resolve(sse(chunks('Answer'))); await drain();
	view.elements['chat-input'].value = 'Draft'; view.elements['chat-reset'].listeners.click();
	assert.equal(view.elements['chat-messages'].children.length, 0);
	assert.equal(view.elements['chat-input'].value, '');
	const saved = JSON.parse(view.storage['ai-router-chat:1']);
	assert.deepEqual(saved.messages, []); assert.equal(saved.settings.systemPrompt, 'Keep this');
	view.elements['chat-input'].value = 'Fresh'; view.send();
	assert.deepEqual(JSON.parse(view.requests[1].options.body).messages, [{role: 'system', content: 'Keep this'}, {role: 'user', content: 'Fresh'}]);
});

test('reasoning-only responses stay visible and never become assistant answer text', async () => {
	const view = start(); view.elements['chat-input'].value = 'Think'; view.send();
	view.requests[0].resolve(sse([JSON.stringify({choices: [{delta: {reasoning_content: 'Thought only'}}]}), '[DONE]']));
	await drain();
	assert.equal(view.elements['chat-messages'].children.length, 2);
	const assistant = JSON.parse(view.storage['ai-router-chat:1']).messages[1];
	assert.equal(assistant.content, ''); assert.equal(assistant.reasoning_content, 'Thought only');
	const restored = start(null, {storage: view.storage});
	assert.equal(restored.elements['chat-messages'].children[1].children[1].children[0].children[1].textContent, 'Thought only');
});

test('shows provider usage, cache ratio, browser timing, speed, finish reason and identity', async () => {
	const view = start(null, {modelInfo: {'zai-1/glm-5.3': {kind: 'zai', channel: 'glm', upstreamModel: 'actual'}}});
	view.elements['chat-input'].value = 'Stats'; view.send();
	view.requests[0].resolve(sse([...chunks('Answer').slice(0, -1),
		JSON.stringify({id: 'request-123', choices: [], usage: {prompt_tokens: 100, completion_tokens: 20, prompt_tokens_details: {cached_tokens: 25}}}), '[DONE]']));
	await drain();
	const stats = view.elements['chat-messages'].children[1].children[2].textContent;
	for (const text of ['glm/actual', 'in 100', 'out 20', 'cache 25 (25.0%)', 'TTFT ', 'total ', 'tok/s', 'stop', 'id request-123']) assert.ok(stats.includes(text), text);
	assert.equal(stats.includes('NaN'), false);
});

test('automatic tools assemble deltas and send results back in a bounded native tool exchange', async () => {
	const executed = [];
	const view = start(null, {runJavaScript: async code => { executed.push(code); return {ok: true, output: '2'}; }});
	view.elements['chat-tools'].checked = true;
	view.elements['chat-input'].value = 'Calculate'; view.send();
	assert.equal(JSON.parse(view.requests[0].options.body).tools[0].function.name, 'browser_javascript');
	view.requests[0].resolve(sse(toolChunks())); await drain();
	assert.deepEqual(executed, ['return 1 + 1']); assert.equal(view.requests.length, 2);
	const body = JSON.parse(view.requests[1].options.body);
	assert.equal(body.messages[1].role, 'assistant');
	assert.equal(body.messages[1].tool_calls[0].id, 'call-1');
	assert.equal(body.messages[2].role, 'tool'); assert.equal(body.messages[2].tool_call_id, 'call-1');
	assert.deepEqual(JSON.parse(body.messages[2].content), {ok: true, output: '2'});
	view.requests[1].resolve(sse(chunks('It is 2'))); await drain();
	assert.equal(JSON.parse(view.storage['ai-router-chat:1']).messages.length, 4);
	const restored = start(null, {storage: view.storage});
	assert.equal(restored.elements['chat-tools'].checked, false);
	assert.equal(restored.requests.length, 0); // Restored code is never executed.
	assert.equal(restored.elements['chat-messages'].children.length, 4);
});

test('compatible stop terminals may carry complete structured tool calls, but length terminals cannot execute', async () => {
	for (const finish of ['stop', 'length']) {
		let executed = 0;
		const view = start(null, {runJavaScript: async () => { executed++; return {ok: true, output: '2'}; }});
		view.elements['chat-tools'].checked = true; view.elements['chat-input'].value = 'Tool'; view.send();
		const frames = toolChunks().map(frame => frame.replace('"finish_reason":"tool_calls"', '"finish_reason":"' + finish + '"'));
		view.requests[0].resolve(sse(frames)); await drain();
		assert.equal(executed, finish === 'stop' ? 1 : 0);
		assert.equal(view.requests.length, finish === 'stop' ? 2 : 1);
	}
});

test('tools disabled or unrecognized names never execute model code', async () => {
	let executions = 0;
	for (const enabled of [false, true]) {
		const view = start(null, {runJavaScript: async () => { executions++; return {ok: true, output: 'unexpected'}; }});
		view.elements['chat-tools'].checked = enabled;
		view.elements['chat-input'].value = 'Tool'; view.send();
		view.requests[0].resolve(sse(toolChunks('return 2', {name: enabled ? 'unknown_tool' : 'browser_javascript'}))); await drain();
		assert.equal(executions, 0);
		if (!enabled) assert.equal(view.requests.length, 1);
		else {
			assert.equal(view.requests.length, 2);
			assert.equal(JSON.parse(JSON.parse(view.requests[1].options.body).messages[2].content).ok, false);
		}
	}
});

test('six inference requests are the hard tool-loop limit', async () => {
	let executed = 0;
	const view = start(null, {runJavaScript: async () => { executed++; return {ok: true, output: 'ok'}; }});
	view.elements['chat-tools'].checked = true; view.elements['chat-input'].value = 'Loop'; view.send();
	for (let i = 0; i < 6; i++) { assert.equal(view.requests.length, i + 1); view.requests[i].resolve(sse(toolChunks('return 1', {id: 'call-' + i}))); await drain(); }
	assert.equal(view.requests.length, 6); assert.equal(executed, 5);
	assert.match(view.elements['chat-error'].textContent, /limit/);
	assert.equal(view.elements['chat-send'].textContent, 'Send');
});

test('Stop cancels a running tool, persists a closed exchange and prevents follow-up inference', async () => {
	const view = start(null, {runJavaScript: (code, {signal}) => new Promise((resolve, reject) => {
		signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
	})});
	view.elements['chat-tools'].checked = true; view.elements['chat-input'].value = 'Wait'; view.send();
	view.requests[0].resolve(sse(toolChunks())); await drain(); view.send(); await drain();
	assert.equal(view.requests.length, 1); assert.equal(view.elements['chat-error'].textContent, '');
	const saved = JSON.parse(view.storage['ai-router-chat:1']).messages;
	assert.equal(saved[2].role, 'tool'); assert.match(saved[2].content, /cancelled/);
	assert.match(view.elements['chat-status'].textContent, /Stopped/);
});

test('incomplete streams and oversized tool calls never execute code', async () => {
	let executed = 0;
	for (const frames of [toolChunks().slice(0, -1), toolChunks('x'.repeat(25000))]) {
		const view = start(null, {runJavaScript: async () => { executed++; }});
		view.elements['chat-tools'].checked = true; view.elements['chat-input'].value = 'Unsafe'; view.send();
		view.requests[0].resolve(sse(frames)); await drain();
		assert.equal(executed, 0); assert.equal(view.requests.length, 1);
		assert.notEqual(view.elements['chat-error'].textContent, '');
	}
});
