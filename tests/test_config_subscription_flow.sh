#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const vm = require('vm');
const harness = require('./tests/js_luci_harness');

const source = harness.readSource('rootfs/www/luci-static/resources/view/mihowrt/config.js');
const persistMatch = source.match(/async function persistSubscriptionUrlIfChanged[\s\S]*?\n}\n\nfunction editorHasUnsavedChanges/);
const unsavedMatch = source.match(/function editorHasUnsavedChanges[\s\S]*?\n}\n\nfunction confirmSubscriptionOverwrite/);
const confirmMatch = source.match(/function confirmSubscriptionOverwrite[\s\S]*?\n}\n\nasync function withSubscriptionLock/);
const loadMatch = source.match(/async function loadSubscriptionIntoEditor[\s\S]*?\n}\n\nreturn view\.extend/);
const fetchStart = source.indexOf('const fetchSubscription = async function() {');
const fetchEnd = source.indexOf('\n\n\t\tconst saveAndApply = async function() {', fetchStart);

if (!persistMatch)
	throw new Error('persistSubscriptionUrlIfChanged() not found');
if (!unsavedMatch)
	throw new Error('editorHasUnsavedChanges() not found');
if (!confirmMatch)
	throw new Error('confirmSubscriptionOverwrite() not found');
if (!loadMatch)
	throw new Error('loadSubscriptionIntoEditor() not found');
if (fetchStart === -1 || fetchEnd === -1)
	throw new Error('fetchSubscription() not found');

const persistFnSource = persistMatch[0].replace(/\n\nfunction editorHasUnsavedChanges$/, '');
const unsavedFnSource = unsavedMatch[0].replace(/\n\nfunction confirmSubscriptionOverwrite$/, '');
const confirmFnSource = confirmMatch[0].replace(/\n\nasync function withSubscriptionLock$/, '');
const loadFnSource = loadMatch[0].replace(/\n\nreturn view\.extend$/, '');
const { module: configHelper } = harness.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/config.js');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

(async() => {
	const fetchFnSource = source.slice(fetchStart, fetchEnd);
	assert(fetchFnSource.includes('stageSubscriptionSettings(value, result)'), 'fetchSubscription should stage subscription settings after fetch');
	assert(!fetchFnSource.includes('persistSubscriptionSettings(value, result.profileUpdateInterval'), 'fetchSubscription should not persist settings before validate/apply');

	const context = {
		setValues: [],
		saveCalls: [],
		saveSettingsCalls: [],
		confirmCalls: 0,
		confirmResult: true,
		editor: {
			getValue: () => context.editorValue,
			setValue: (value, cursor) => context.setValues.push({ value, cursor })
		},
		subscriptionOverrideInput: { checked: false },
		subscriptionIntervalInput: { value: '' },
		editorValue: 'mode: old\n',
		backendHelper: {
			saveSubscriptionUrl: async(url) => context.saveCalls.push(url),
			saveSubscriptionSettings: async(url, override, interval, header, hotReloadSupported) => {
				context.saveSettingsCalls.push({ url, override, interval, header, hotReloadSupported });
			},
			fetchSubscription: async(url) => {
				context.fetchUrl = url;
				return 'mode: rule\n';
			}
		},
		window: {
			confirm: () => {
				context.confirmCalls += 1;
				return context.confirmResult;
			}
		},
		configHelper
	};

	vm.createContext(context);
	vm.runInContext(`
function _(value) { return value; }
let editor = globalThis.editor;
let subscriptionOverrideInput = globalThis.subscriptionOverrideInput;
let subscriptionIntervalInput = globalThis.subscriptionIntervalInput;
let savedConfigContent = 'mode: old\\n';
let savedSubscriptionUrl = 'https://example.com/same.yaml';
let pendingSubscriptionSettings = null;
${persistFnSource}
${unsavedFnSource}
${confirmFnSource}
${loadFnSource}
globalThis.persistSubscriptionUrlIfChanged = persistSubscriptionUrlIfChanged;
globalThis.stageSubscriptionSettings = stageSubscriptionSettings;
globalThis.persistPendingSubscriptionSettings = persistPendingSubscriptionSettings;
globalThis.editorHasUnsavedChanges = editorHasUnsavedChanges;
globalThis.confirmSubscriptionOverwrite = confirmSubscriptionOverwrite;
globalThis.getSavedSubscriptionUrl = () => savedSubscriptionUrl;
globalThis.setSavedSubscriptionUrl = value => { savedSubscriptionUrl = value; };
globalThis.getPendingSubscriptionSettings = () => pendingSubscriptionSettings;
globalThis.loadSubscriptionIntoEditor = loadSubscriptionIntoEditor;
`, context);

	assert(await context.persistSubscriptionUrlIfChanged('https://example.com/same.yaml') === false, 'persistSubscriptionUrlIfChanged should skip unchanged URL');
	assert(context.saveCalls.length === 0, 'persistSubscriptionUrlIfChanged should avoid redundant UCI writes');
	assert(await context.persistSubscriptionUrlIfChanged('https://example.com/new.yaml') === true, 'persistSubscriptionUrlIfChanged should save changed URL');
	assert(context.saveCalls.length === 1 && context.saveCalls[0] === 'https://example.com/new.yaml', 'persistSubscriptionUrlIfChanged should write changed URL once');
	assert(context.getSavedSubscriptionUrl() === 'https://example.com/new.yaml', 'persistSubscriptionUrlIfChanged should update saved URL after save');
	context.setSavedSubscriptionUrl(null);
	assert(await context.persistSubscriptionUrlIfChanged('https://example.com/new.yaml') === true, 'persistSubscriptionUrlIfChanged should save when initial URL state is unknown');
	assert(context.saveCalls.length === 2, 'persistSubscriptionUrlIfChanged should not skip save after failed initial URL read');

	context.editorValue = 'mode: old\n';
	context.confirmCalls = 0;
	assert(context.editorHasUnsavedChanges() === false, 'editorHasUnsavedChanges should ignore unchanged editor content');
	assert(context.confirmSubscriptionOverwrite() === true, 'confirmSubscriptionOverwrite should allow replacing unchanged editor content');
	assert(context.confirmCalls === 0, 'confirmSubscriptionOverwrite should not prompt for unchanged editor content');

	context.editorValue = 'mode: edited\n';
	context.confirmResult = false;
	assert(context.editorHasUnsavedChanges() === true, 'editorHasUnsavedChanges should detect unsaved editor content');
	assert(context.confirmSubscriptionOverwrite() === false, 'confirmSubscriptionOverwrite should honor cancelled overwrite prompt');
	assert(context.confirmCalls === 1, 'confirmSubscriptionOverwrite should prompt when editor has unsaved changes');

	context.editorValue = 'mode: old\n';
	const result = await context.loadSubscriptionIntoEditor('https://example.com/sub.yaml', 'mode: old\n');
	assert(result.content === 'mode: rule\n', 'loadSubscriptionIntoEditor should return fetched contents');
	assert(result.profileUpdateInterval === '', 'loadSubscriptionIntoEditor should tolerate legacy string fetch results');
	assert(context.fetchUrl === 'https://example.com/sub.yaml', 'loadSubscriptionIntoEditor should pass URL to backend fetch');
	assert(context.setValues.length === 1, 'loadSubscriptionIntoEditor should update editor');
	assert(context.setValues[0].value === 'mode: rule\n', 'loadSubscriptionIntoEditor should preserve fetched contents');
	assert(context.setValues[0].cursor === -1, 'loadSubscriptionIntoEditor should reset editor cursor');
	context.stageSubscriptionSettings('https://example.com/sub.yaml', { content: result.content, profileUpdateInterval: '24', hotReloadSupported: true });
	assert(context.saveSettingsCalls.length === 0, 'stageSubscriptionSettings should not persist settings before apply');
	assert(await context.persistPendingSubscriptionSettings('mode: edited\n') === false, 'persistPendingSubscriptionSettings should ignore changed editor content');
	assert(context.saveSettingsCalls.length === 0, 'persistPendingSubscriptionSettings should not save stale staged settings');
	assert(await context.persistPendingSubscriptionSettings('mode: rule\n') === true, 'persistPendingSubscriptionSettings should save matching staged settings after apply');
	assert(context.saveSettingsCalls.length === 1, 'persistPendingSubscriptionSettings should save exactly once');
	assert(context.saveSettingsCalls[0].url === 'https://example.com/sub.yaml', 'persistPendingSubscriptionSettings should save staged URL');
	assert(context.saveSettingsCalls[0].header === '24', 'persistPendingSubscriptionSettings should save staged header interval');
	assert(context.saveSettingsCalls[0].hotReloadSupported === true, 'persistPendingSubscriptionSettings should save staged hot reload flag');
	assert(context.getPendingSubscriptionSettings() === null, 'persistPendingSubscriptionSettings should clear staged settings after save');

	context.setValues.length = 0;
	context.editorValue = 'mode: old\n';
	context.backendHelper.fetchSubscription = async() => {
		context.editorValue = 'mode: changed during fetch\n';
		return 'mode: rule\n';
	};
	let changedDuringFetchFailed = false;
	try {
		await context.loadSubscriptionIntoEditor('https://example.com/sub.yaml', 'mode: old\n');
	}
	catch (e) {
		changedDuringFetchFailed = String(e.message).includes('Editor content changed during subscription download');
	}
	assert(changedDuringFetchFailed, 'loadSubscriptionIntoEditor should reject when editor changes during download');
	assert(context.setValues.length === 0, 'loadSubscriptionIntoEditor should not overwrite editor after concurrent edits');

	const missingEditorContext = {
		editor: null,
		configHelper,
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
