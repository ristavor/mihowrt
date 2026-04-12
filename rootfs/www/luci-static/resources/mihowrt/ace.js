'use strict';
'require baseclass';

const ACE_BASE = '/luci-static/resources/view/mihowrt/ace/';

let aceScriptPromise = null;

function loadScript(src) {
	return new Promise((resolve, reject) => {
		const script = document.createElement('script');
		script.src = src;
		script.onload = resolve;
		script.onerror = reject;
		document.head.appendChild(script);
	});
}

function loadAce() {
	if (!aceScriptPromise)
		aceScriptPromise = loadScript(ACE_BASE + 'ace.js');

	return aceScriptPromise;
}

async function createEditor(node, mode, options) {
	await loadAce();
	ace.config.set('basePath', ACE_BASE);

	const editor = ace.edit(node);
	editor.setTheme('ace/theme/tomorrow_night_bright');
	editor.session.setMode('ace/mode/' + mode);
	editor.setOptions(Object.assign({
		showPrintMargin: false,
		wrap: true
	}, options || {}));

	return editor;
}

return baseclass.extend({
	ACE_BASE: ACE_BASE,
	loadAce: loadAce,
	createEditor: createEditor
});
