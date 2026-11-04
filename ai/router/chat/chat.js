(() => {
	const config = window.routerChat;
	const model = document.getElementById("chat-model");
	const messages = document.getElementById("chat-messages");
	const input = document.getElementById("chat-input");
	const send = document.getElementById("chat-send");
	const errorLine = document.getElementById("chat-error");
	if (!config || !model || !messages || !input || !send || !errorLine) return;

	const storageKey = "ai-router-chat:" + config.userId;
	const maxMessages = 100;
	const maxContent = 100000;
	// Options the current session may use; the server re-checks grants and
	// the protocol for every request, so a stale selection is harmless.
	const options = [...model.options].map(option => option.value).filter(value => value !== "");
	if (options.length === 0) return;

	let history = [];
	let active = null; // AbortController while a reply is streaming
	let assistant = null; // {node, body, content, text, reasoning, reasoningNode}

	const appendHistory = (role, content) => {
		history.push({role, content: content.slice(0, maxContent)});
		history = history.slice(-maxMessages);
	};

	const save = () => {
		try {
			localStorage.setItem(storageKey, JSON.stringify({
				model: model.value,
				messages: history.slice(-maxMessages),
			}));
		} catch (_) { /* Storage may be disabled; the chat still works for this page load. */ }
	};

	const addMessage = (role, text) => {
		const node = document.createElement("div");
		node.className = "msg " + role;
		const meta = document.createElement("div");
		meta.className = "meta";
		meta.textContent = role === "user" ? "You" : "Assistant";
		const body = document.createElement("div");
		body.className = "body";
		const content = document.createElement("div");
		content.className = "content";
		content.textContent = text;
		body.appendChild(content);
		node.appendChild(meta);
		node.appendChild(body);
		messages.appendChild(node);
		messages.scrollTop = messages.scrollHeight;
		return {node, body, content};
	};

	const restore = () => {
		let saved = null;
		try {
			const raw = localStorage.getItem(storageKey);
			if (raw) saved = JSON.parse(raw);
		} catch (_) { saved = null; }
		if (saved) {
			if (typeof saved.model === "string" && options.includes(saved.model)) {
				model.value = saved.model;
			}
			if (Array.isArray(saved.messages)) {
				for (const item of saved.messages) {
					if (!item || (item.role !== "user" && item.role !== "assistant")) continue;
					if (typeof item.content !== "string" || item.content === "") continue;
					history.push({role: item.role, content: item.content.slice(0, maxContent)});
				}
				history = history.slice(-maxMessages);
				for (const item of history) addMessage(item.role, item.content);
			}
		}
	};

	const setBusy = busy => {
		send.disabled = false;
		send.textContent = busy ? "Stop" : "Send";
		input.disabled = busy;
	};

	const fail = message => {
		errorLine.textContent = message;
	};

	const applyDelta = payload => {
		if (payload === "[DONE]" || !assistant) return;
		let parsed;
		try { parsed = JSON.parse(payload); } catch (_) { return; }
		if (parsed && parsed.error && typeof parsed.error.message === "string") {
			fail(parsed.error.message);
			return;
		}
		if (!parsed || !Array.isArray(parsed.choices)) return;
		const delta = parsed.choices[0] && parsed.choices[0].delta;
		if (!delta) return;
		if (typeof delta.reasoning_content === "string" && delta.reasoning_content !== "") {
			assistant.reasoning += delta.reasoning_content;
			if (!assistant.reasoningNode) {
				assistant.reasoningNode = document.createElement("div");
				assistant.reasoningNode.className = "reasoning";
				assistant.body.insertBefore(assistant.reasoningNode, assistant.content);
			}
			assistant.reasoningNode.textContent = assistant.reasoning;
		}
		if (typeof delta.content === "string" && delta.content !== "") {
			assistant.text += delta.content;
			assistant.content.textContent = assistant.text;
		}
		messages.scrollTop = messages.scrollHeight;
	};

	const finish = () => {
		setBusy(false);
		active = null;
		if (!assistant) return;
		const done = assistant;
		assistant = null;
		if (done.text === "") {
			if (done.node.parentElement) done.node.parentElement.removeChild(done.node);
			if (done.reasoning !== "") {
				// Reasoning-only reply: keep it, it is still useful output.
				appendHistory("assistant", done.reasoning);
				save();
			} else if (errorLine.textContent === "") {
				fail("No reply was received.");
			}
		} else {
			appendHistory("assistant", done.text);
			save();
		}
	};

	const run = async () => {
		const text = input.value.trim().slice(0, maxContent);
		const selected = model.value;
		if (!text || !selected || active) return;
		errorLine.textContent = "";
		appendHistory("user", text);
		addMessage("user", text);
		input.value = "";
		const bubble = addMessage("assistant", "");
		assistant = {
			node: bubble.node,
			body: bubble.body,
			content: bubble.content,
			text: "",
			reasoning: "",
			reasoningNode: null,
		};
		setBusy(true);
		const abort = new AbortController();
		active = abort;
		try {
			let response;
			try {
				response = await fetch("/chat/completions", {
					method: "POST",
					credentials: "same-origin",
					headers: {
						"Content-Type": "application/json",
						"X-CSRF-Token": config.csrfToken,
					},
					body: JSON.stringify({
						model: selected,
						messages: history.map(item => ({role: item.role, content: item.content})),
						stream: true,
					}),
					signal: abort.signal,
				});
			} catch (err) {
				if (!err || err.name !== "AbortError") fail("Network error — the request did not reach the router.");
				return;
			}
			if (response.status === 401) {
				window.location.href = "/chat";
				return;
			}
			if (!response.ok) {
				let message = "Request failed (HTTP " + response.status + ").";
				try {
					const parsed = JSON.parse(await response.text());
					if (parsed && parsed.error && typeof parsed.error.message === "string") {
						message = parsed.error.message;
					}
				} catch (_) {}
				fail(message);
				return;
			}
			let buffer = "";
			const decoder = new TextDecoder();
			try {
				const reader = response.body.getReader();
				for (;;) {
					const chunk = await reader.read();
					if (chunk.done) break;
					buffer += decoder.decode(chunk.value, {stream: true});
					for (;;) {
						const index = buffer.indexOf("\n\n");
						if (index < 0) break;
						const frame = buffer.slice(0, index);
						buffer = buffer.slice(index + 2);
						for (const line of frame.split("\n")) {
							if (line.startsWith("data: ")) applyDelta(line.slice(6));
						}
					}
				}
			} catch (err) {
				if (!err || err.name !== "AbortError") fail("The connection dropped while receiving the reply.");
			}
		} finally {
			// Every exit path (done, error, 401, abort) settles the UI state.
			finish();
		}
	};

	send.addEventListener("click", () => {
		if (active) active.abort();
		else run();
	});
	input.addEventListener("keydown", event => {
		if (event.key === "Enter" && !event.shiftKey) {
			event.preventDefault();
			run();
		}
	});
	model.addEventListener("change", save);
	restore();
})();
