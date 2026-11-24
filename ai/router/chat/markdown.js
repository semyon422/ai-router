(() => {
	const tags = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "li",
		"strong", "em", "s", "a", "table", "thead", "tbody", "tr", "th", "td"]);
	const append = (parent, tag, text) => {
		const node = document.createElement(tag);
		if (text !== undefined) node.textContent = text;
		parent.appendChild(node);
		return node;
	};
	const safeUrl = href => {
		if (!/^(https?:\/\/|mailto:)/i.test(href)) return null;
		try { return new URL(href).href; } catch (_) { return null; }
	};
	const walk = (tokens, root) => {
		const stack = [root];
		for (const token of tokens) {
			if (token.hidden) continue;
			const parent = stack[stack.length - 1];
			if (token.type === "inline") walk(token.children, parent);
			else if (token.type === "text" || token.type === "image") {
				// Keep image alt text without making model-supplied network requests.
				parent.appendChild(document.createTextNode(token.content));
			} else if (token.type === "softbreak" || token.type === "hardbreak") append(parent, "br");
			else if (token.type === "hr") append(parent, "hr");
			else if (token.type === "code_inline") append(parent, "code", token.content);
			else if (token.type === "code_block" || token.type === "fence") append(append(parent, "pre"), "code", token.content);
			else if (tags.has(token.tag)) {
				if (token.nesting === -1) { stack.pop(); continue; }
				if (token.nesting !== 1) continue;
				if (token.tag === "a") {
					const href = safeUrl(token.attrGet("href"));
					if (!href) { stack.push(parent); continue; }
					const link = append(parent, "a");
					link.href = href;
					link.target = "_blank";
					link.rel = "noopener noreferrer";
					stack.push(link);
					continue;
				}
				let container = parent;
				if (token.tag === "table") {
					container = append(parent, "div");
					container.className = "markdown-table";
				}
				const node = append(container, token.tag);
				if (token.tag === "ol" && token.attrGet("start") !== null) node.start = Number(token.attrGet("start"));
				if (token.tag === "th" || token.tag === "td") {
					const align = /^text-align:(left|center|right)$/.exec(token.attrGet("style"));
					if (align) node.style.textAlign = align[1];
				}
				stack.push(node);
			}
		}
	};
	const install = () => {
		if (typeof window.markdownit !== "function") return false;
		const parser = window.markdownit({html: false});
		window.routerChatMarkdown = (node, text) => {
			// The parser's HTML renderer is never used; only allowlisted DOM nodes are created.
			const fragment = document.createDocumentFragment();
			walk(parser.parse(text, {}), fragment);
			if (!fragment.hasChildNodes()) return false;
			node.replaceChildren(fragment);
			return true;
		};
		return true;
	};
	const script = document.createElement("script");
	script.src = "https://cdn.jsdelivr.net/npm/markdown-it@15.0.3/dist/browser/markdown-it.umd.min.js";
	script.integrity = "sha384-ARStLecQmtLYjBgfD3+w+irhiSoLTnFk/ne6c0gRWQKQtC9791ZLMQ9D3OaBISt3";
	script.crossOrigin = "anonymous";
	script.referrerPolicy = "no-referrer";
	script.async = true;
	script.addEventListener("load", () => {
		if (install()) window.dispatchEvent(new Event("router-chat-markdown-ready"));
	}, {once: true});
	document.head.appendChild(script);
})();
