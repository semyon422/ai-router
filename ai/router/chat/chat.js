(() => {
	const config = window.routerChat;
	const get = id => document.getElementById(id);
	const model = get("chat-model"), messages = get("chat-messages"), input = get("chat-input");
	const send = get("chat-send"), errorLine = get("chat-error"), reset = get("chat-reset");
	const system = get("chat-system"), reasoning = get("chat-reasoning"), tools = get("chat-tools");
	const status = get("chat-status"), reasoningHint = get("chat-reasoning-hint");
	if (!config || !model || !messages || !input || !send || !errorLine || !reset || !system || !reasoning || !tools || !status) return;
	const storageKey = "ai-router-chat:" + config.userId;
	const maxMessages = 100, maxContent = 100000, maxSteps = 6, maxTools = 4;
	const options = [...model.options].map(option => option.value).filter(Boolean);
	const now = () => performance.now();
	const modes = ["default", "enabled", "disabled"];
	const reasoningFields = ["reasoning_content", "reasoning"];
	const hasReasoning = value => reasoningFields.some(field => typeof value[field] === "string" && value[field].length > 0);
	const toolSchema = {type: "function", function: {name: "browser_javascript",
		description: "Run JavaScript for calculations or data processing in an isolated browser worker. Use return for a result or console.log. No page DOM, network, credentials or storage. Each call has a 5-second deadline and 16000-character output limit.",
		parameters: {type: "object", properties: {code: {type: "string"}}, required: ["code"], additionalProperties: false}}};
	let history = [], active = null;
	tools.checked = false; // Never silently re-enable automatic execution after reload.

	// Remove only leading blank lines in presentation. Keep indentation and the
	// original protocol content (including whitespace) for subsequent requests.
	const visibleText = text => text.replace(/^(?:[\t ]*\r?\n)+/, "");
	const trimHistory = () => {
		history = history.slice(-maxMessages);
		while (history.length && history[0].role !== "user") history.shift();
	};
	const save = () => {
		try { localStorage.setItem(storageKey, JSON.stringify({version: 2, model: model.value,
			settings: {systemPrompt: system.value.slice(0, maxContent), reasoning: reasoning.value}, messages: history})); }
		catch (_) { /* The page still works without browser storage. */ }
	};
	const appendHistory = item => { history.push(item); trimHistory(); save(); };
	const scroll = () => { messages.scrollTop = messages.scrollHeight; };
	const element = (tag, className, text) => {
		const node = document.createElement(tag);
		node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	};
	const addMessage = (role, text = "") => {
		const node = element("div", "msg " + role);
		const meta = element("div", "meta", role === "user" ? "You" : role === "tool" ? "JavaScript result" : "Assistant");
		const body = element("div", "body"), content = element("div", "content", role === "assistant" ? visibleText(text) : text);
		body.appendChild(content); node.appendChild(meta); node.appendChild(body); messages.appendChild(node); scroll();
		return {node, body, content};
	};
	const addReasoning = (bubble, text) => {
		const details = element("details", "reasoning"), summary = element("summary", "", "Reasoning");
		const content = element("div", "reasoning-content", text);
		details.appendChild(summary); details.appendChild(content); bubble.body.insertBefore(details, bubble.content);
		return content;
	};
	const showReasoning = (bubble, values) => {
		bubble.reasoningNodes = bubble.reasoningNodes || {};
		const different = hasReasoning(values) && typeof values.reasoning === "string" && values.reasoning
			&& typeof values.reasoning_content === "string" && values.reasoning_content && values.reasoning !== values.reasoning_content;
		for (const field of reasoningFields) {
			const text = typeof values[field] === "string" ? values[field] : "";
			if (!text && !bubble.reasoningNodes[field]) continue;
			const node = bubble.reasoningNodes[field] || (bubble.reasoningNodes[field] = addReasoning(bubble, ""));
			node.textContent = text;
			node.parentElement.hidden = !text || (field === "reasoning" && text === values.reasoning_content);
			node.parentElement.children[0].textContent = different ? "Reasoning (" + field + ")" : "Reasoning";
		}
	};
	const showTools = (bubble, calls) => {
		if (!bubble.toolsNode) { bubble.toolsNode = element("div", "tool-calls"); bubble.body.appendChild(bubble.toolsNode); }
		bubble.toolsNode.replaceChildren();
		for (const call of calls) {
			const details = element("details", "tool-call");
			details.appendChild(element("summary", "", "Tool: " + (call.function.name || "pending")));
			let text = call.function.arguments;
			try { const args = JSON.parse(text); if (typeof args.code === "string") text = args.code; } catch (_) {}
			details.appendChild(element("pre", "tool-code", text)); bubble.toolsNode.appendChild(details);
		}
	};
	const seconds = ms => (ms / 1000).toFixed(3) + "s";
	const updateStats = (bubble, stats) => {
		if (!bubble.statsNode) { bubble.statsNode = element("div", "inference-stats"); bubble.node.appendChild(bubble.statsNode); }
		const usage = stats.usage, duration = stats.endedAt - stats.startedAt;
		const parts = [stats.model, "Chat Completions / SSE"];
		if (stats.kind) parts.push(stats.kind);
		if (stats.channel) parts.push(stats.channel + "/" + stats.upstreamModel);
		if (usage) {
			parts.push("in " + usage.input, "out " + usage.output);
			if (usage.reasoning !== null) parts.push("reasoning " + usage.reasoning);
			parts.push(usage.cached === null ? "cache —" : "cache " + usage.cached + (usage.input > 0 ? " (" + (usage.cached / usage.input * 100).toFixed(1) + "%)" : ""));
		} else parts.push("tokens — (not reported)");
		parts.push("TTFT " + (stats.firstAt === null ? "—" : seconds(stats.firstAt - stats.startedAt)), "total " + seconds(duration));
		parts.push(usage && stats.firstAt !== null && stats.endedAt > stats.firstAt && stats.state === "complete"
			? (usage.output * 1000 / (stats.endedAt - stats.firstAt)).toFixed(1) + " tok/s" : "speed —");
		parts.push(stats.state === "complete" ? stats.finishReason || "complete" : stats.state + (stats.finishReason ? " (" + stats.finishReason + ")" : ""));
		if (stats.id) parts.push("id " + stats.id);
		bubble.statsNode.textContent = parts.join(" · ");
	};
	const parseUsage = value => {
		const finite = n => typeof n === "number" && Number.isFinite(n) && n >= 0;
		if (!value || !finite(value.prompt_tokens) || !finite(value.completion_tokens)) return null;
		const cached = value.prompt_tokens_details && value.prompt_tokens_details.cached_tokens;
		const reportedReasoning = value.completion_tokens_details && value.completion_tokens_details.reasoning_tokens;
		return {input: value.prompt_tokens, output: value.completion_tokens, cached: finite(cached) ? cached : null,
			reasoning: finite(reportedReasoning) ? reportedReasoning : null};
	};
	const setBusy = busy => {
		send.disabled = !model.value; send.textContent = busy ? "Stop" : "Send";
		input.disabled = busy || !model.value;
		for (const control of [model, reset, system, reasoning, tools]) control.disabled = busy;
		model.disabled = busy || options.length === 0;
	};
	const hint = () => {
		if (!reasoningHint) return;
		const info = (config.modelInfo || {})[model.value];
		reasoningHint.textContent = info && info.kind === "zai"
			? "Reasoning mode uses Z.ai thinking.type. Only reasoning returned by the provider can be displayed."
			: "Reasoning mode uses chat_template_kwargs.enable_thinking. Compatible servers may ignore or reject it; Provider default sends no override.";
	};

	const restore = () => {
		let saved;
		try { saved = JSON.parse(localStorage.getItem(storageKey) || "null"); } catch (_) {}
		if (!saved || typeof saved !== "object") return;
		if (options.includes(saved.model)) model.value = saved.model;
		if (saved.settings && typeof saved.settings.systemPrompt === "string") system.value = saved.settings.systemPrompt.slice(0, maxContent);
		if (saved.settings && modes.includes(saved.settings.reasoning)) reasoning.value = saved.settings.reasoning;
		if (!Array.isArray(saved.messages)) return;
		let pending = [];
		for (const raw of saved.messages.slice(-maxMessages)) {
			if (!raw || typeof raw.content !== "string") continue;
			const item = {role: raw.role, content: raw.content.slice(0, maxContent)};
			if (item.role === "user") { if (pending.length) break; if (item.content) history.push(item); }
			else if (item.role === "assistant" && history.length && !pending.length) {
				for (const field of reasoningFields) {
					if (typeof raw[field] === "string") item[field] = raw[field].slice(0, maxContent);
					else if (raw[field] === null) item[field] = null;
				}
				if (Array.isArray(raw.tool_calls) && raw.tool_calls.length > 0 && raw.tool_calls.length <= maxTools) {
					const ids = new Set();
					const valid = raw.tool_calls.every(call => call && typeof call.id === "string" && call.id.length > 0 && call.id.length <= 200
						&& !ids.has(call.id) && ids.add(call.id) && call.type === "function" && call.function
						&& typeof call.function.name === "string" && call.function.name.length <= 100
						&& typeof call.function.arguments === "string" && call.function.arguments.length <= 24000);
					if (!valid) continue;
					item.tool_calls = raw.tool_calls.map(call => ({id: call.id, type: "function", function: {name: call.function.name, arguments: call.function.arguments}}));
					pending = item.tool_calls.map(call => call.id);
				}
				if (item.content.trim() || hasReasoning(item) || item.tool_calls) history.push(item);
			} else if (item.role === "tool" && pending.includes(raw.tool_call_id)) {
				item.tool_call_id = raw.tool_call_id; pending = pending.filter(id => id !== item.tool_call_id); history.push(item);
			}
		}
		// Drop an incomplete restored tool exchange rather than inventing results.
		if (pending.length) { while (history.length && !history[history.length - 1].tool_calls) history.pop(); history.pop(); }
		trimHistory();
		for (const item of history) {
			const bubble = addMessage(item.role, item.content);
			showReasoning(bubble, item);
			if (item.tool_calls) showTools(bubble, item.tool_calls);
			if (item.role === "assistant" && !item.content.trim() && (hasReasoning(item) || item.tool_calls)) bubble.content.hidden = true;
		}
	};

	const complete = async (turn, step) => {
		const bubble = addMessage("assistant"), info = (config.modelInfo || {})[turn.model] || {};
		const stats = {model: turn.model, kind: info.kind, channel: info.channel, upstreamModel: info.upstreamModel,
			startedAt: now(), endedAt: 0, firstAt: null, usage: null, finishReason: "", id: "", state: "receiving"};
		let text = "", done = false, failed = false;
		const thoughts = {};
		const calls = [];
		const fail = message => { failed = true; errorLine.textContent = message; };
		const output = () => { if (stats.firstAt === null) stats.firstAt = now(); };
		const apply = payload => {
			if (done || turn.controller.signal.aborted) return;
			if (payload === "[DONE]") { done = true; return; }
			let parsed;
			try { parsed = JSON.parse(payload); } catch (_) { throw new Error("Invalid stream data."); }
			if (parsed && parsed.error) { fail(typeof parsed.error.message === "string" ? parsed.error.message : "Inference failed."); return; }
			if (!parsed || !Array.isArray(parsed.choices)) return;
			if (typeof parsed.id === "string") stats.id = parsed.id.slice(0, 200);
			if (parsed.usage) stats.usage = parseUsage(parsed.usage);
			const choice = parsed.choices[0];
			if (!choice) return;
			if (typeof choice.finish_reason === "string") stats.finishReason = choice.finish_reason.slice(0, 80);
			const delta = choice.delta || {};
			if (typeof delta.content === "string" && delta.content) {
				output();
				if (text.length + delta.content.length > maxContent) throw new Error("Reply exceeded the browser content limit.");
				text += delta.content; bubble.content.textContent = visibleText(text);
			}
			for (const field of reasoningFields) {
				const value = delta[field];
				if (typeof value === "string") {
					if (value) output();
					const previous = typeof thoughts[field] === "string" ? thoughts[field] : "";
					if (previous.length + value.length > maxContent) throw new Error("Reasoning exceeded the browser content limit.");
					thoughts[field] = previous + value;
				} else if (value === null) thoughts[field] = null;
			}
			showReasoning(bubble, thoughts);
			if (Array.isArray(delta.tool_calls)) {
				for (const part of delta.tool_calls) {
					if (!Number.isInteger(part.index) || part.index < 0 || part.index >= maxTools) throw new Error("Too many or invalid tool calls.");
					const call = calls[part.index] || (calls[part.index] = {id: "", type: "function", function: {name: "", arguments: ""}});
					if (typeof part.id === "string") call.id += part.id;
					if (part.function && typeof part.function.name === "string" && part.function.name) { call.function.name += part.function.name; output(); }
					if (part.function && typeof part.function.arguments === "string" && part.function.arguments) { call.function.arguments += part.function.arguments; output(); }
					if (call.id.length > 200 || call.function.name.length > 100 || call.function.arguments.length > 24000) throw new Error("Tool call exceeds the browser limit.");
				}
				showTools(bubble, calls.filter(Boolean));
			}
			stats.endedAt = now(); updateStats(bubble, stats); scroll();
		};
		const body = {model: turn.model, messages: history.map(item => ({...item})), stream: true, stream_options: {include_usage: true}};
		if (turn.systemPrompt) body.messages.unshift({role: "system", content: turn.systemPrompt});
		if (turn.reasoning !== "default") {
			if (info.kind === "zai") body.thinking = {type: turn.reasoning};
			else body.chat_template_kwargs = {enable_thinking: turn.reasoning === "enabled"};
		}
		if (turn.tools) { body.tools = [toolSchema]; body.tool_choice = step === maxSteps - 1 ? "none" : "auto"; }
		status.textContent = "Inference " + (step + 1) + "/" + maxSteps + " · receiving";
		let reader;
		try {
			const response = await fetch("/chat/completions", {method: "POST", credentials: "same-origin",
				headers: {"Content-Type": "application/json", "X-CSRF-Token": config.csrfToken}, body: JSON.stringify(body), signal: turn.controller.signal});
			if (response.status === 401) { window.location.href = "/login"; failed = true; }
			else if (!response.ok) {
				let message = "Request failed (HTTP " + response.status + ").";
				try { const value = JSON.parse(await response.text()); if (value && value.error && typeof value.error.message === "string") message = value.error.message; } catch (_) {}
				fail(message);
			} else {
				reader = response.body.getReader();
				const decoder = new TextDecoder(); let buffer = "";
				for (;;) {
					const chunk = await reader.read();
					if (turn.controller.signal.aborted) break;
					buffer = (buffer + decoder.decode(chunk.value || new Uint8Array(), {stream: !chunk.done})).replace(/\r\n/g, "\n");
					if (buffer.length > 1024 * 1024) throw new Error("Stream frame exceeds the browser limit.");
					let index;
					while (!done && (index = buffer.indexOf("\n\n")) >= 0) {
						const frame = buffer.slice(0, index); buffer = buffer.slice(index + 2);
						const data = frame.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).replace(/^ /, ""));
						if (data.length) apply(data.join("\n"));
					}
					if (chunk.done) break;
				}
				if (!done && !turn.controller.signal.aborted) fail("The stream ended before completion.");
			}
		} catch (error) {
			if (!error || error.name !== "AbortError") fail(error && error.message || "Network error while receiving the reply.");
		} finally {
			if (reader && reader.cancel) { try { await reader.cancel(); } catch (_) {} }
			stats.endedAt = now(); stats.state = turn.controller.signal.aborted ? "stopped" : failed ? "failed" : "complete";
			updateStats(bubble, stats);
			if (!text.trim() && (hasReasoning(thoughts) || calls.length)) bubble.content.hidden = true;
		}
		const ids = new Set();
		const validCalls = calls.length && Array.from(calls).every(call => call && call.id && !ids.has(call.id) && ids.add(call.id) && call.function.name);
		const toolCalls = validCalls && done && !failed && !turn.controller.signal.aborted && (stats.finishReason === "tool_calls" || stats.finishReason === "stop") ? calls : [];
		if (calls.length && !toolCalls.length && !turn.controller.signal.aborted && !failed) {
			fail("Incomplete or invalid tool call; nothing was executed."); stats.state = "failed"; updateStats(bubble, stats);
		}
		if (!text.trim() && !hasReasoning(thoughts) && !calls.length) {
			bubble.node.remove();
			if (!failed && !turn.controller.signal.aborted) fail("No reply was received.");
		}
		const record = text.trim() || hasReasoning(thoughts) || toolCalls.length ? {role: "assistant", content: text} : null;
		if (record) for (const field of reasoningFields) if (Object.prototype.hasOwnProperty.call(thoughts, field)) record[field] = thoughts[field];
		if (record && toolCalls.length) record.tool_calls = toolCalls;
		return {record, calls: toolCalls, complete: done && !failed && !turn.controller.signal.aborted};
	};

	const run = async () => {
		const text = input.value.trim().slice(0, maxContent);
		if (!text || !model.value || active) return;
		const turn = {controller: new AbortController(), model: model.value, systemPrompt: system.value.slice(0, maxContent),
			reasoning: modes.includes(reasoning.value) ? reasoning.value : "default", tools: tools.checked};
		active = turn; errorLine.textContent = ""; input.value = "";
		appendHistory({role: "user", content: text}); addMessage("user", text); setBusy(true);
		let count = 0, toolCount = 0;
		try {
			for (let step = 0; step < maxSteps; step++) {
				if (turn.controller.signal.aborted) break;
				count++;
				const result = await complete(turn, step);
				if (result.record) appendHistory(result.record);
				if (!result.complete || !result.calls.length) break;
				for (const call of result.calls) {
					let value;
					if (turn.controller.signal.aborted) value = {ok: false, output: "Tool execution cancelled."};
					else if (!turn.tools) value = {ok: false, output: "Browser tools are disabled."};
					else if (step === maxSteps - 1) value = {ok: false, output: "Inference step limit reached; tool was not executed."};
					else {
						status.textContent = "Running JavaScript · call " + (toolCount + 1);
						try {
							const args = JSON.parse(call.function.arguments);
							if (call.function.name !== "browser_javascript" || !args || typeof args.code !== "string" || Object.keys(args).some(key => key !== "code")) throw new Error("Invalid JavaScript tool name or arguments.");
							if (!window.routerChatTools) throw new Error("JavaScript sandbox is unavailable.");
							toolCount++;
							value = await window.routerChatTools.runJavaScript(args.code, {signal: turn.controller.signal});
						} catch (error) { value = {ok: false, output: error && error.name === "AbortError" ? "Tool execution cancelled." : String(error && error.message || "Tool failed.").slice(0, 16000)}; }
					}
					const content = JSON.stringify(value).slice(0, maxContent);
					appendHistory({role: "tool", tool_call_id: call.id, content}); addMessage("tool", content);
				}
				if (!turn.tools || step === maxSteps - 1) { errorLine.textContent = !turn.tools ? "The model requested a tool, but tools are disabled." : "Stopped at the six-request tool loop limit."; break; }
			}
		} catch (_) { errorLine.textContent = "The chat could not finish this turn."; }
		finally {
			active = null; setBusy(false); save();
			status.textContent = (turn.controller.signal.aborted ? "Stopped" : errorLine.textContent ? "Failed" : "Completed")
				+ " · " + count + " inference request(s) · " + toolCount + " JavaScript call(s)";
		}
	};
	send.addEventListener("click", () => { if (active) active.controller.abort(); else run(); });
	input.addEventListener("keydown", event => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); run(); } });
	reset.addEventListener("click", () => {
		if (active) return;
		history = []; messages.replaceChildren(); input.value = ""; errorLine.textContent = ""; status.textContent = "New conversation. Settings kept."; save();
	});
	model.addEventListener("change", () => { hint(); save(); });
	system.addEventListener("input", save); reasoning.addEventListener("change", save);
	restore(); hint(); setBusy(false);
})();
