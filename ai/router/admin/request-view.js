/* Pure display-only decoding. Never executes tools, HTML, URLs or model code. */
(function (root) {
  "use strict";
  function parse(raw, options = {}) {
    const cards = [], notices = new Set();
    let parts = 0, limited = false, partial = false;
    const warn = text => notices.add(text);
    const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
    const label = value => typeof value === "string" ? value.slice(0, 300) : "";
    const scalar = value => value === null ? "null" : String(value);
    function card(title) {
      if (cards.length >= 300) { limited = true; return null; }
      const value = {title, parts: []}; cards.push(value); return value;
    }
    function part(target, title, text, code = false) {
      if (!target || typeof text !== "string" || text.length === 0) return;
      if (parts >= 1200) { limited = true; return; }
      target.parts.push({title, text, code}); parts++;
    }
    function fields(target, value, prefix = "", depth = 0) {
      if (value === null || typeof value !== "object") { part(target, prefix, scalar(value), typeof value === "string" && /(?:^| · )(?:code|script|expression)$/.test(prefix)); return; }
      if (depth > 6) { warn("Deeply nested fields remain available in the original payload."); return; }
      let count = 0;
      for (const key of Object.keys(value)) {
        if (++count > 100 || parts >= 1200) { limited = true; break; }
        const name = prefix ? prefix + (Array.isArray(value) ? "[" + key + "]" : " · " + key) : key;
        fields(target, value[key], name, depth + 1);
      }
    }
    function structured(target, value, title) {
      if (typeof value === "string") {
        try { const decoded = JSON.parse(value); if (decoded !== null && typeof decoded === "object") { if (Object.keys(decoded).length === 0) part(target, title, Array.isArray(decoded) ? "Empty list" : "No fields"); else fields(target, decoded, title); return; } } catch (_) { /* incomplete or plain text */ }
        part(target, title, value, true);
      } else if (value !== undefined) fields(target, value, title);
    }
    function content(target, value, title = "Text") {
      if (typeof value === "string") { part(target, title, value); return; }
      if (!Array.isArray(value)) { if (value != null) warn("Some structured content is available only in the original payload."); return; }
      for (const item of value.slice(0, 300)) {
        if (!object(item)) continue;
        if (typeof item.text === "string") part(target, title, item.text);
        else if (typeof item.refusal === "string") part(target, "Refusal", item.refusal);
        else if (["image_url", "input_image", "image"].includes(item.type)) {
          const url = typeof item.image_url === "string" ? item.image_url : item.image_url?.url || item.url;
          part(target, "Image attachment", typeof url === "string" && !url.startsWith("data:") ? url : "Inline image or file reference; see original payload. Images are not loaded.");
        } else if (["input_audio", "audio", "output_audio", "file", "input_file"].includes(item.type)) {
          part(target, "Attachment · " + item.type, label(item.filename || item.file?.filename || item.file_id) || "Binary/file data remains in the original payload. It is not loaded or played.");
        } else {
          part(target, "Structured content · " + label(item.type || "unknown"), "See original payload for this content type.");
        }
      }
      if (value.length > 300) limited = true;
    }
    function toolCall(value, prefix = "Tool call") {
      const fn = object(value.function) ? value.function : value;
      const target = card(prefix + " · " + (label(fn.name) || "unnamed"));
      part(target, "Call ID", label(value.call_id || (object(value.function) ? value.id : "")));
      if (value.type === "function_call") part(target, "Item ID", label(value.id));
      structured(target, fn.arguments, "Argument");
    }
    function message(value, suffix = "") {
      if (!object(value)) return;
      const role = typeof value.role === "string" ? value.role : "assistant";
      const title = role === "tool" ? "Tool result" : ["system", "developer", "user", "assistant"].includes(role) ? role[0].toUpperCase() + role.slice(1) : "Message · " + label(role);
      const target = card(title + suffix);
      if (role === "tool") {
        part(target, "Call ID", label(value.tool_call_id || value.call_id));
        if (Array.isArray(value.content)) content(target, value.content, "Result");
        else structured(target, value.content, "Result");
      } else content(target, value.content);
      const distinct = typeof value.reasoning_content === "string" && value.reasoning_content
        && typeof value.reasoning === "string" && value.reasoning && value.reasoning !== value.reasoning_content;
      for (const field of ["reasoning_content", "reasoning"]) {
        if (field === "reasoning" && typeof value[field] === "string" && value[field] === value.reasoning_content) continue;
        const title = distinct ? "Reasoning (" + field + ")" : "Reasoning";
        if (typeof value[field] === "string") part(target, title, value[field]);
        else if (Array.isArray(value[field])) content(target, value[field], title);
      }
      if (typeof value.refusal === "string") part(target, "Refusal", value.refusal);
      if (value.audio?.transcript) part(target, "Audio transcript", value.audio.transcript);
      if (Array.isArray(value.tool_calls)) {
        for (const call of value.tool_calls.slice(0, 300)) if (object(call)) toolCall(call, "Tool call" + suffix);
        if (value.tool_calls.length > 300) limited = true;
      }
      if (object(value.function_call)) toolCall(value.function_call, "Tool call" + suffix);
      return target;
    }
    function nativeItem(item) {
      if (!object(item)) return;
      if (item.type === "message" || item.role) message(item);
      else if (item.type === "function_call") toolCall(item);
      else if (item.type === "function_call_output") {
        const target = card("Tool result"); part(target, "Call ID", label(item.call_id));
        if (Array.isArray(item.output)) content(target, item.output, "Result");
        else structured(target, item.output, "Result");
      } else if (item.type === "reasoning") {
        const target = card("Assistant reasoning");
        content(target, item.summary, "Summary"); content(target, item.content, "Reasoning");
        if (item.encrypted_content) part(target, "Encrypted reasoning", "Encrypted content cannot be displayed as text; original data is retained.");
      } else if (["input_text", "text"].includes(item.type)) {
        const target = card("User"); part(target, "Text", item.text);
      } else if (["image_url", "input_image", "image", "input_audio", "audio", "output_audio", "file", "input_file"].includes(item.type)) {
        content(card("Attachment"), [item]);
      } else part(card("Item · " + label(item.type || "unknown")), "Structured item", "See original payload for this item type.");
    }
    function error(value) {
      if (!value) return;
      partial = true;
      const target = card("Error");
      if (typeof value === "string") part(target, "Message", value);
      else if (object(value)) {
        part(target, "Message", typeof value.message === "string" ? value.message : "See original error payload.");
        part(target, "Code", label(value.code)); part(target, "Type", label(value.type));
      }
    }
    function request(body) {
      const settings = card("Request settings");
      for (const key of Object.keys(body)) {
        if (!["messages", "input", "instructions", "tools"].includes(key)) fields(settings, body[key], key);
        if (parts >= 1200) break;
      }
      if (typeof body.instructions === "string") part(card("Instructions"), "Text", body.instructions);
      if (Array.isArray(body.messages)) {
        for (const value of body.messages.slice(0, 300)) message(value);
        if (body.messages.length > 300) limited = true;
      }
      if (typeof body.input === "string") part(card("User"), "Text", body.input);
      else if (Array.isArray(body.input)) {
        for (const value of body.input.slice(0, 300)) nativeItem(value);
        if (body.input.length > 300) limited = true;
      }
      if (Array.isArray(body.tools)) {
        for (const value of body.tools.slice(0, 100)) {
          if (!object(value)) continue;
          const fn = object(value.function) ? value.function : value;
          const target = card("Available tool · " + label(fn.name || value.type || "unknown"));
          part(target, "Description", fn.description);
          if (object(fn.parameters)) {
            const required = Array.isArray(fn.parameters.required) ? fn.parameters.required : [];
            let count = 0;
            for (const key of Object.keys(fn.parameters.properties || {})) {
              if (++count > 100) { limited = true; break; }
              const field = fn.parameters.properties[key];
              part(target, "Parameter · " + label(key), [object(field) ? label(field.type) : "", required.includes(key) ? "required" : "optional", object(field) ? label(field.description) : ""].filter(Boolean).join(" · "));
            }
          }
        }
        if (body.tools.length > 100) limited = true;
      }
    }
    function nativeResponse(body) {
      if (Array.isArray(body.output)) {
        for (const item of body.output.slice(0, 300)) nativeItem(item);
        if (body.output.length > 300) limited = true;
      }
      if ((!Array.isArray(body.output) || body.output.length === 0) && typeof body.output_text === "string") part(card("Assistant"), "Text", body.output_text);
      if (body.error) error(body.error);
      if (body.status === "failed" || body.status === "incomplete" || body.status === "cancelled") {
        partial = true; warn("Model response status: " + body.status + ".");
        if (body.incomplete_details?.reason) warn("Incomplete reason: " + label(body.incomplete_details.reason) + ".");
      }
    }
    function finish(reason) {
      if (reason && !["stop", "tool_calls", "function_call"].includes(reason)) {
        partial = true; warn("Model finish reason: " + label(reason) + ".");
      }
    }
    function chatResponse(body) {
      for (const [ordinal, choice] of body.choices.slice(0, 300).entries()) {
        if (!object(choice)) continue;
        const target = message(choice.message || choice.delta, body.choices.length > 1 ? " · choice " + (choice.index ?? ordinal) : "");
        part(target, "Finish reason", label(choice.finish_reason));
        finish(choice.finish_reason);
      }
      if (body.choices.length > 300) limited = true;
    }
    function stream(text, native) {
      const choices = new Map(), items = [], byIndex = new Map(), byId = new Map();
      let done = false, terminal = null, malformed = false, trailing = false;
      const index = n => Number.isSafeInteger(n) && n >= 0;
      function getItem(event, snapshot) {
        const id = event.item_id || snapshot?.id;
        const outputIndex = index(event.output_index) ? event.output_index : typeof id === "string" ? null : 0;
        if (!index(event.output_index) && typeof id !== "string") {
          partial = true; warn("Some native deltas omit item identity; output is grouped provisionally.");
        }
        let state = (index(outputIndex) && byIndex.get(outputIndex)) || (typeof id === "string" && byId.get(id));
        if (!state) {
          if (items.length >= 300) { limited = true; return null; }
          state = {order: items.length, index: index(outputIndex) ? outputIndex : items.length, value: {}, content: new Map(), summary: new Map(), args: []};
          items.push(state);
        }
        if (index(outputIndex)) { state.index = outputIndex; byIndex.set(outputIndex, state); }
        if (typeof id === "string") { byId.set(id, state); if (!state.value.id) state.value.id = id; }
        return state;
      }
      function setPart(map, i, value) {
        if (!map.has(i) && map.size >= 300) { limited = true; return; }
        map.set(i, {value, chunks: [typeof value.text === "string" ? value.text : typeof value.refusal === "string" ? value.refusal : ""]});
      }
      function snapshot(state, value, authoritative) {
        state.value = {...state.value, ...value};
        for (const key of ["content", "summary"]) if (Array.isArray(value[key]) && (authoritative || value[key].length)) {
          state[key].clear(); value[key].slice(0, 300).forEach((p, i) => { if (object(p)) setPart(state[key], i, p); });
          if (value[key].length > 300) limited = true;
        }
        if (typeof value.arguments === "string") state.args = [value.arguments];
      }
      function event(value, name) {
        if (!object(value)) { malformed = true; return; }
        if (value.error) error(value.error);
        if (!native) {
          if (done) { warn("Data after [DONE] remains available in the original payload."); return; }
          if (!Array.isArray(value.choices)) { if (!value.error) warn("Some stream events are available only in the original payload."); return; }
          for (const [ordinal, choice] of value.choices.entries()) {
            if (!object(choice)) continue;
            const i = index(choice.index) ? choice.index : ordinal;
            let state = choices.get(i);
            if (!state) {
              if (choices.size >= 300) { limited = true; break; }
              state = {text: [], reasoning: [], reasoning_content: [], refusal: [], tools: new Map()}; choices.set(i, state);
            }
            if (object(choice.message)) state.message = choice.message;
            if (choice.finish_reason != null) state.finish = choice.finish_reason;
            const delta = object(choice.delta) ? choice.delta : {};
            for (const [field, target] of [["content", "text"], ["reasoning_content", "reasoning_content"], ["reasoning", "reasoning"], ["refusal", "refusal"]]) {
              if (typeof delta[field] === "string") state[target].push(delta[field]);
              else if ((field === "reasoning" || field === "reasoning_content") && delta[field] != null) warn("Structured reasoning deltas remain available in the original payload.");
            }
            const calls = Array.isArray(delta.tool_calls) ? delta.tool_calls : object(delta.function_call) ? [{index: 0, function: delta.function_call}] : [];
            for (const [position, call] of calls.entries()) {
              if (!object(call)) continue;
              const k = index(call.index) ? call.index : position;
              let tool = state.tools.get(k);
              if (!tool) {
                if (state.tools.size >= 300) { limited = true; break; }
                tool = {id: [], name: [], args: []}; state.tools.set(k, tool);
              }
              if (typeof call.id === "string") tool.id.push(call.id);
              if (typeof call.function?.name === "string") tool.name.push(call.function.name);
              if (typeof call.function?.arguments === "string") tool.args.push(call.function.arguments);
            }
          }
          return;
        }
        if (terminal) { warn("Events after the terminal response remain available in the original payload."); return; }
        const type = value.type || name;
        if (["response.completed", "response.failed", "response.incomplete", "response.done"].includes(type)) {
          terminal = object(value.response) ? value.response : {};
          if (type !== "response.completed" && type !== "response.done") { partial = true; warn("Stream ended with " + type + "."); }
          return;
        }
        if (type === "error") { if (!value.error) error(value); return; }
        if (type === "response.output_item.added" || type === "response.output_item.done") {
          if (object(value.item)) { const state = getItem(value, value.item); if (state) snapshot(state, value.item, type.endsWith(".done")); }
          return;
        }
        const contentEvent = /^response\.(output_text|refusal|reasoning_text|reasoning_summary_text)\.(delta|done)$/.exec(type || "");
        const partEvent = /^response\.(content_part|reasoning_summary_part)\.(added|done)$/.exec(type || "");
        const argsEvent = /^response\.function_call_arguments\.(delta|done)$/.exec(type || "");
        if (contentEvent || partEvent || argsEvent) {
          const state = getItem(value); if (!state) return;
          if (argsEvent) {
            state.value.type = "function_call";
            if (argsEvent[1] === "done" && typeof value.arguments === "string") state.args = [value.arguments];
            else if (typeof value.delta === "string") state.args.push(value.delta);
            return;
          }
          const summary = contentEvent?.[1] === "reasoning_summary_text" || partEvent?.[1] === "reasoning_summary_part";
          const reasoning = summary || contentEvent?.[1] === "reasoning_text" || ["reasoning_text", "summary_text"].includes(value.part?.type);
          if (!state.value.type) state.value.type = reasoning ? "reasoning" : "message";
          const map = summary ? state.summary : state.content;
          const n = summary ? value.summary_index : value.content_index;
          const i = index(n) ? n : 0;
          if (partEvent) { if (object(value.part)) setPart(map, i, value.part); return; }
          const refusal = contentEvent[1] === "refusal";
          if (!map.has(i)) setPart(map, i, {type: refusal ? "refusal" : reasoning ? "reasoning_text" : "output_text"});
          const p = map.get(i); if (!p) return;
          const full = refusal ? value.refusal : value.text;
          if (contentEvent[2] === "done" && typeof full === "string") p.chunks = [full];
          else if (typeof value.delta === "string") p.chunks.push(value.delta);
          return;
        }
        if (!["response.created", "response.in_progress", "response.queued", "response.reasoning_summary_part.done"].includes(type)) warn("Some native events are available only in the original payload.");
      }
      let name = "", data = [];
      function dispatch(complete) {
        if (data.length) {
          const joined = data.join("\n");
          if (joined.trim() === "[DONE]" && !native) done = true;
          else { try { event(JSON.parse(joined), name); } catch (_) { malformed = true; } }
          if (!complete) trailing = true;
        }
        name = ""; data = [];
      }
      const lines = text.split(/\r\n|\r|\n/);
      for (let position = 0; position < lines.length; position++) {
        const line = lines[position];
        if (position === lines.length - 1 && line === "") break;
        if (line === "") dispatch(true);
        else if (line === "data" || line.startsWith("data:")) data.push(line === "data" ? "" : line.slice(5).replace(/^ /, ""));
        else if (line.startsWith("event:")) name = line.slice(6).replace(/^ /, "");
      }
      dispatch(false);
      if (malformed || trailing) { partial = true; warn("Malformed or unterminated SSE data: the assembled view may be incomplete."); }
      if (native) {
        if (!terminal) { partial = true; warn("No terminal Responses event was saved; showing collected partial output."); }
        if (terminal && Array.isArray(terminal.output) && terminal.output.length) nativeResponse(terminal);
        else {
          if (terminal && items.length) warn("Terminal output items were omitted; this view is assembled from saved deltas.");
          for (const state of items.sort((a, b) => a.index - b.index || a.order - b.order)) {
            const value = {...state.value};
            for (const key of ["content", "summary"]) if (state[key].size) value[key] = [...state[key]].sort((a, b) => a[0] - b[0]).map(([, p]) => ({...p.value, [p.value.type === "refusal" ? "refusal" : "text"]: p.chunks.join("")}));
            if (value.type === "function_call") value.arguments = state.args.join("");
            nativeItem(value);
          }
          if (terminal) nativeResponse({...terminal, output: []});
        }
      } else {
        if (!done) { partial = true; warn("No [DONE] marker was saved; showing collected partial output."); }
        for (const [i, state] of [...choices].sort((a, b) => a[0] - b[0])) {
          const value = state.message || {role: "assistant", content: state.text.join(""), reasoning: state.reasoning.join(""), reasoning_content: state.reasoning_content.join(""), refusal: state.refusal.join(""), tool_calls: [...state.tools].sort((a, b) => a[0] - b[0]).map(([, t]) => ({id: t.id.join(""), function: {name: t.name.join(""), arguments: t.args.join("")}}))};
          const target = message(value, choices.size > 1 ? " · choice " + i : "");
          part(target, "Finish reason", label(state.finish));
          if (state.finish == null) { partial = true; warn("A choice has no saved finish reason."); }
          finish(state.finish);
        }
      }
    }
    let recognized = false, streaming = false;
    if (options.bodyComplete === false) {
      partial = true; warn("Load the full saved body to build a readable view. The preview alone is not a complete request or answer.");
    } else {
      let body;
      try { body = JSON.parse(raw); } catch (_) { /* possibly SSE */ }
      if (object(body)) {
        if (options.side === "request") { request(body); recognized = true; }
        else if (Array.isArray(body.choices)) { chatResponse(body); recognized = true; }
        else if (Array.isArray(body.output) || body.object === "response" || typeof body.output_text === "string") { nativeResponse(body); recognized = true; }
        else if (body.error) { error(body.error); recognized = true; }
      } else if (options.side !== "request" && /^(?:data(?::|$)|event:)/m.test(raw)) {
        streaming = true; stream(raw, options.protocol === "responses"); recognized = true;
      }
      if (!recognized) warn("This body cannot be decoded into messages. The original payload is still available below.");
    }
    if (options.truncated) { partial = true; warn("The stored body was truncated. Omitted content cannot be reconstructed."); }
    if (options.captureFailed || (options.side === "response" && options.transportComplete === false)) {
      partial = true; warn("Capture or response transport was incomplete; this is not a guaranteed full answer.");
    }
    if (options.side === "request" && options.requestState && options.requestState !== "complete") {
      partial = true; warn(options.requestState === "not_read" ? "The router did not read this request body." : "Only part of the request body was received.");
    }
    if (limited) { partial = true; warn("Readable view limit reached. Remaining items are retained in the original payload."); }
    return {cards, notices: [...notices], partial, streaming, recognized};
  }
  const api = {parse};
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.RouterRequestView = api;
})(typeof window !== "undefined" ? window : globalThis);
