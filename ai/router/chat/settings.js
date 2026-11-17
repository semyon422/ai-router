(() => {
	const get = id => document.getElementById(id);
	const panel = get("chat-settings"), dialog = get("chat-settings-dialog");
	const trigger = get("chat-settings-open"), close = get("chat-settings-close");
	if (!panel || !dialog || !trigger || !close || !window.matchMedia || !dialog.showModal) return;
	const host = panel.parentElement, narrow = window.matchMedia("(max-width: 1050px)");
	const expanded = () => trigger.setAttribute("aria-expanded", String(dialog.open));
	const layout = () => {
		if (dialog.open) dialog.close();
		if (narrow.matches) dialog.appendChild(panel);
		else host.appendChild(panel);
		trigger.hidden = !narrow.matches;
		close.hidden = !narrow.matches;
		expanded();
	};
	trigger.addEventListener("click", () => {
		if (!narrow.matches || dialog.open) return;
		dialog.showModal(); expanded();
	});
	close.addEventListener("click", () => dialog.close());
	dialog.addEventListener("close", () => {
		expanded();
		if (narrow.matches) trigger.focus();
	});
	narrow.addEventListener("change", layout);
	layout();
})();
