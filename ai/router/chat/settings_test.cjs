const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {runInNewContext} = require('node:vm');
const source = readFileSync(join(__dirname, 'settings.js'), 'utf8');

function setup(narrow = false, supported = true) {
	function node() {
		return {children: [], hidden: false, open: false, attributes: {}, listeners: {},
			appendChild(child) {
				if (child.parentElement) child.parentElement.children.splice(child.parentElement.children.indexOf(child), 1);
				this.children.push(child); child.parentElement = this;
			},
			setAttribute(name, value) { this.attributes[name] = value; },
			addEventListener(name, callback) { this.listeners[name] = callback; },
			focus() { this.focused = true; },
			showModal() { this.open = true; },
			close() { this.open = false; if (this.listeners.close) this.listeners.close(); },
		};
	}
	const host = node(), panel = node(), dialog = node(), trigger = node(), close = node();
	panel.value = 'preserved settings'; panel.disabled = true; host.appendChild(panel);
	const media = {matches: narrow, addEventListener(name, callback) { this.change = callback; }};
	const elements = {'chat-settings': panel, 'chat-settings-dialog': dialog, 'chat-settings-open': trigger, 'chat-settings-close': close};
	if (!supported) dialog.showModal = undefined;
	runInNewContext(source, {document: {getElementById: id => elements[id]}, window: {matchMedia: query => {
		assert.equal(query, '(max-width: 1050px)'); return media;
	}}});
	return {host, panel, dialog, trigger, close, resize(matches) { media.matches = matches; media.change(); }};
}

test('wide layout keeps a single settings panel beside the conversation', () => {
	const s = setup();
	assert.equal(s.panel.parentElement, s.host);
	assert.equal(s.trigger.hidden, true);
	assert.equal(s.close.hidden, true);
	assert.equal(s.dialog.children.length, 0);
});

test('narrow layout moves controls into a native modal and close restores focus', () => {
	const s = setup(true);
	assert.equal(s.panel.parentElement, s.dialog);
	assert.equal(s.trigger.hidden, false);
	assert.equal(s.close.hidden, false);
	assert.equal(s.trigger.attributes['aria-expanded'], 'false');
	s.trigger.listeners.click();
	assert.equal(s.dialog.open, true);
	assert.equal(s.trigger.attributes['aria-expanded'], 'true');
	s.close.listeners.click();
	assert.equal(s.trigger.attributes['aria-expanded'], 'false');
	assert.equal(s.trigger.focused, true);
});

test('native Escape close updates accessibility state and restores focus', () => {
	const s = setup(true); s.trigger.listeners.click(); s.dialog.close();
	assert.equal(s.trigger.attributes['aria-expanded'], 'false');
	assert.equal(s.trigger.focused, true);
});

test('resizing an open modal preserves controls and locked inference settings', () => {
	const s = setup(true); s.trigger.listeners.click(); s.resize(false);
	assert.equal(s.dialog.open, false);
	assert.equal(s.panel.parentElement, s.host);
	assert.equal(s.panel.value, 'preserved settings');
	assert.equal(s.panel.disabled, true);
	for (let i = 0; i < 4; i++) { s.resize(true); s.resize(false); }
	assert.deepEqual(s.host.children, [s.panel]);
	assert.equal(s.dialog.children.length, 0);
});

test('unsupported modal leaves the original panel and controls accessible', () => {
	const s = setup(true, false);
	assert.equal(s.panel.parentElement, s.host);
	assert.equal(s.panel.value, 'preserved settings');
	assert.equal(s.trigger.listeners.click, undefined);
});
