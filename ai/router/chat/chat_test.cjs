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

function start(saved, {userId = 1, storage = {}} = {}) {
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
	};
	const document = {
		hidden: false,
		getElementById: id => elements[id],
		createElement: tag => element(tag),
	};
	const window = {
		routerChat: {csrfToken: 'csrf-123', userId, model: 'zai-1/glm-5.3'},
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
		}),
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
	assert.equal(JSON.parse(req.options.body).stream_options, undefined);
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
	assert.equal(body.children[0].textContent, 'Let me think…');
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

test('a 401 session bounce redirects to the chat page', async () => {
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
		assert.equal(outgoing.length, 100);
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
