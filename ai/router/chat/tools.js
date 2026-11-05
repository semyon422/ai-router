(() => {
	// Only trusted boot code runs in the opaque-origin iframe. Model code runs
	// in its dedicated worker, inheriting the iframe's network-denying CSP.
	function workerMain() {
		const reply = self.postMessage.bind(self);
		const format = value => {
			try { return (typeof value === "string" ? value : JSON.stringify(value)) ?? String(value); }
			catch (_) { return "[unserializable value]"; }
		};
		self.onmessage = async event => {
			const lines = [];
			const log = (...values) => {
				if (lines.length < 100) lines.push(values.map(value => format(value).slice(0, 2000)).join(" ").slice(0, 2000));
			};
			try {
				const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
				const value = await new AsyncFunction("console", '"use strict";\n' + event.data)(
					Object.freeze({log, info: log, warn: log, error: log, debug: log}));
				if (value !== undefined) log(value);
				reply({ok: true, output: (lines.join("\n") || "undefined").slice(0, 16000)});
			} catch (error) {
				reply({ok: false, output: (lines.join("\n") + "\n" + String(error && error.message || "JavaScript failed.")).trim().slice(0, 16000)});
			}
		};
	}
	function frameMain(source) {
		let worker = null;
		let started = false;
		addEventListener("message", event => {
			if (event.source !== parent || !event.data) return;
			if (event.data.type === "cancel") { if (worker) worker.terminate(); return; }
			if (event.data.type !== "run" || started) return;
			started = true;
			try {
				const url = URL.createObjectURL(new Blob([source], {type: "text/javascript"}));
				worker = new Worker(url);
				URL.revokeObjectURL(url);
				worker.onmessage = message => {
					worker.terminate();
					const value = message.data;
					parent.postMessage({type: "result", ok: value && value.ok === true,
						output: value && typeof value.output === "string" ? value.output.slice(0, 16000) : "Invalid tool output."}, "*");
				};
				worker.onerror = () => {
					worker.terminate();
					parent.postMessage({type: "result", ok: false, output: "JavaScript worker failed."}, "*");
				};
				worker.postMessage(event.data.code);
			} catch (_) {
				parent.postMessage({type: "result", ok: false, output: "Sandbox could not start."}, "*");
			}
		});
		parent.postMessage({type: "ready"}, "*");
	}
	const workerSource = "(" + workerMain.toString() + ")()";
	const frameSource = "(" + frameMain.toString() + ")(" + JSON.stringify(workerSource) + ")";
	const policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'";
	window.routerChatTools = {
		runJavaScript(code, {signal} = {}) {
			return new Promise((resolve, reject) => {
				if (signal && signal.aborted) { reject(new DOMException("Aborted", "AbortError")); return; }
				if (typeof code !== "string" || code.length > 20000) {
					resolve({ok: false, output: "JavaScript code exceeds the 20,000 character limit."}); return;
				}
				const frame = document.createElement("iframe");
				frame.hidden = true;
				frame.setAttribute("sandbox", "allow-scripts");
				frame.setAttribute("aria-hidden", "true");
				frame.referrerPolicy = "no-referrer";
				frame.srcdoc = '<meta http-equiv="Content-Security-Policy" content="' + policy + '"><scr' + 'ipt>' + frameSource + '</scr' + 'ipt>';
				let settled = false;
				let started = false;
				const finish = (value, aborted = false) => {
					if (settled) return;
					settled = true;
					clearTimeout(timer);
					window.removeEventListener("message", receive);
					if (signal) signal.removeEventListener("abort", abort);
					if (frame.contentWindow) frame.contentWindow.postMessage({type: "cancel"}, "*");
					frame.remove(); // destroying the owner document also terminates its worker
					if (aborted) reject(new DOMException("Aborted", "AbortError"));
					else resolve(value);
				};
				const abort = () => finish(null, true);
				const receive = event => {
					if (event.source !== frame.contentWindow || !event.data) return;
					if (event.data.type === "ready" && !started) {
						started = true;
						frame.contentWindow.postMessage({type: "run", code}, "*");
					} else if (event.data.type === "result" && started) {
						finish({ok: event.data.ok === true, output: typeof event.data.output === "string"
							? event.data.output.slice(0, 16000) : "Invalid tool output."});
					}
				};
				const timer = setTimeout(() => finish({ok: false, output: "JavaScript timed out after 5 seconds."}), 5000);
				window.addEventListener("message", receive);
				if (signal) signal.addEventListener("abort", abort, {once: true});
				try { document.body.appendChild(frame); }
				catch (_) { finish({ok: false, output: "Sandbox could not start."}); }
			});
		},
	};
})();
