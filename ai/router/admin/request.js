(function () {
  "use strict";
  const active = new Set();
  function formatPayload(raw) {
    try { return JSON.stringify(JSON.parse(raw), null, 2); } catch (_) { /* SSE or invalid JSON */ }
    if (!/^(?:event:|data:)/m.test(raw)) throw new Error("Not JSON/SSE");
    return raw.split(/\r?\n\r?\n/).map(block => block.split(/\r?\n/).map(line => {
      if (!line.startsWith("data:")) return line;
      const data = line.slice(5).trimStart();
      try { return "data: " + JSON.stringify(JSON.parse(data), null, 2); } catch (_) { return line; }
    }).join("\n")).join("\n\n");
  }
  document.querySelectorAll("[data-payload]").forEach(section => {
    const pre = section.querySelector("[data-body]");
    const status = section.querySelector("[data-status]");
    const format = section.querySelector("[data-format]");
    const load = section.querySelector("[data-load]");
    let raw = pre.textContent;
    let complete = section.dataset.complete === "true";
    let formatted = false;
    let loading = false;
    const readable = section.querySelector("[data-readable]");
    const original = section.querySelector("[data-raw]");
    function renderReadable() {
      if (!readable || !window.RouterRequestView) return;
      let view;
      try {
        view = window.RouterRequestView.parse(raw, {
          side: section.dataset.side, protocol: section.dataset.protocol, bodyComplete: complete,
          truncated: section.dataset.truncated === "true", transportComplete: section.dataset.transportComplete !== "false",
          requestState: section.dataset.requestState, captureFailed: section.dataset.captureFailed === "true",
        });
      } catch (_) {
        view = {cards: [], notices: ["Readable view could not be built. The original payload remains available."], partial: true, recognized: false, streaming: false};
      }
      const children = [];
      function node(tag, text, className) {
        const element = document.createElement(tag);
        if (text !== undefined) element.textContent = text;
        if (className) element.className = className;
        return element;
      }
      const title = !complete ? "Readable view · full body not loaded" : section.dataset.side === "request" ? "Readable request" : view.streaming ? "Assembled streaming response" : "Readable response";
      children.push(node("h3", title + (complete && view.partial ? " · partial" : view.streaming ? " · complete" : "")));
      for (const notice of view.notices) children.push(node("p", notice, "muted"));
      for (const card of view.cards) {
        const article = node("article", undefined, "request-message");
        article.append(node("h3", card.title));
        if (card.parts.length === 0) article.append(node("p", "No text content.", "muted"));
        for (const part of card.parts) {
          const text = node("pre", part.text, part.code ? "request-message-code" : "request-message-text");
          if (part.title === "Reasoning" || part.title === "Summary") {
            const disclosure = node("details");
            disclosure.append(node("summary", part.title), text);
            article.append(disclosure);
          } else article.append(node("h4", part.title), text);
        }
        children.push(article);
      }
      if (view.recognized && view.cards.length === 0) children.push(node("p", "No readable messages or text were returned. Other data remains in the original payload.", "muted"));
      readable.replaceChildren(...children);
      readable.hidden = false;
      if (original) original.open = !view.recognized || !complete;
    }
    renderReadable();
    function resetFormat() {
      formatted = false;
      format.textContent = "Format JSON/SSE";
      format.disabled = !complete;
    }
    format.hidden = false;
    resetFormat();
    format.addEventListener("click", () => {
      if (!complete || loading) return;
      try {
        pre.textContent = formatted ? raw : formatPayload(raw);
        formatted = !formatted;
        format.textContent = formatted ? "Show raw" : "Format JSON/SSE";
        status.textContent = formatted ? "Formatted view. Downloads retain the original saved bytes." : "Raw saved body.";
      } catch (_) {
        status.textContent = "Cannot format this body. It may be incomplete or not JSON/SSE. Raw bytes are unchanged.";
      }
    });
    if (!load || typeof fetch !== "function" || typeof AbortController !== "function") return;
    load.hidden = false;
    load.addEventListener("click", async () => {
      if (loading) return;
      loading = true;
      load.disabled = true;
      format.disabled = true;
      status.textContent = "Loading saved body…";
      const controller = new AbortController();
      active.add(controller);
      const timer = setTimeout(() => controller.abort(), 30000);
      try {
        const response = await fetch(section.dataset.url, {credentials: "same-origin", cache: "no-store", redirect: "error", signal: controller.signal});
        if (!response.ok) {
          status.textContent = response.status === 401 ? "Session expired. Sign in again." : "Payload unavailable. It may have been replaced by a newer request.";
          return;
        }
        if (!(response.headers.get("Content-Type") || "").startsWith("text/plain")) throw new Error("Unexpected payload type");
        const text = await response.text();
        if (controller.signal.aborted) {
          status.textContent = "Load was cancelled. Retry or use the download link.";
          return;
        }
        raw = text;
        pre.textContent = raw;
        complete = true;
        renderReadable();
        load.hidden = true;
        status.textContent = "Full saved body loaded. A storage-limit truncation warning still applies, if shown.";
      } catch (_) {
        status.textContent = "Could not load the body. Retry or use the download link.";
      } finally {
        clearTimeout(timer);
        active.delete(controller);
        loading = false;
        load.disabled = false;
        resetFormat();
      }
    });
  });
  window.addEventListener("pagehide", () => { for (const controller of active) controller.abort(); });
})();
