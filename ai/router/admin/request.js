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
