#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/config.js'), 'utf8');
const editorMatch = source.match(/function editorContentForSave[\s\S]*?\n}\n\nasync function restartRunningService/);
const loadMatch = source.match(/async function loadSubscriptionIntoEditor[\s\S]*?\n}\n\nreturn view\.extend/);

if (!editorMatch)
	throw new Error('editorContentForSave() not found');
if (!loadMatch)
	throw new Error('loadSubscriptionIntoEditor() not found');

const editorFnSource = editorMatch[0].replace(/\n\nasync function restartRunningService$/, '');
const loadFnSource = loadMatch[0].replace(/\n\nreturn view\.extend$/, '');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

(async() => {
	const context = {
		setValues: [],
		editor: {
			setValue: (value, cursor) => context.setValues.push({ value, cursor })
		},
		backendHelper: {
			fetchSubscription: async(url) => {
				context.fetchUrl = url;
				return 'mode: rule\n';
			}
		}
	};

	vm.createContext(context);
	vm.runInContext(`
function _(value) { return value; }
let editor = globalThis.editor;
${editorFnSource}
${loadFnSource}
globalThis.loadSubscriptionIntoEditor = loadSubscriptionIntoEditor;
`, context);

	const result = await context.loadSubscriptionIntoEditor('https://example.com/sub.yaml');
	assert(result === 'mode: rule\n', 'loadSubscriptionIntoEditor should return fetched contents');
	assert(context.fetchUrl === 'https://example.com/sub.yaml', 'loadSubscriptionIntoEditor should pass URL to backend fetch');
	assert(context.setValues.length === 1, 'loadSubscriptionIntoEditor should update editor');
	assert(context.setValues[0].value === 'mode: rule\n', 'loadSubscriptionIntoEditor should preserve fetched contents');
	assert(context.setValues[0].cursor === -1, 'loadSubscriptionIntoEditor should reset editor cursor');

	const missingEditorContext = {
		editor: null,
		backendHelper: {
			fetchSubscription: async() => {
				throw new Error('should not fetch without editor');
			}
		}
	};

	vm.createContext(missingEditorContext);
	vm.runInContext(`
function _(value) { return value; }
let editor = globalThis.editor;
${editorFnSource}
${loadFnSource}
globalThis.loadSubscriptionIntoEditor = loadSubscriptionIntoEditor;
`, missingEditorContext);

	let failed = false;
	try {
		await missingEditorContext.loadSubscriptionIntoEditor('https://example.com/sub.yaml');
	}
	catch (e) {
		failed = String(e.message).includes('Editor is still loading');
	}
	assert(failed, 'loadSubscriptionIntoEditor should reject fetch while editor is unavailable');
})().catch(err => {
	throw err;
});
EOF

pass "config subscription flow"
