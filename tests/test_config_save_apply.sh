#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const vm = require('vm');
const harness = require('./tests/js_luci_harness');

const source = harness.readSource('rootfs/www/luci-static/resources/view/mihowrt/config.js');
const controlsMatch = source.match(/function controlsBusy[\s\S]*?\n}\n\nfunction updateControlDisabledState/);
const updateMatch = source.match(/function updateControlDisabledState[\s\S]*?\n}\n\nasync function withServiceActionLock/);
const restartMatch = source.match(/async function restartRunningService[\s\S]*?\n}\n\nfunction subscriptionUrlInputValue/);
const persistedMatch = source.match(/async function readPersistedConfigContent[\s\S]*?\n}\n\nfunction confirmSubscriptionOverwrite/);
const saveStart = source.indexOf('const saveAndApply = async function() {');
const saveEnd = source.indexOf('\n\n\t\tconst pageChildren = [', saveStart);

if (!controlsMatch)
	throw new Error('controlsBusy() not found');
if (!updateMatch)
	throw new Error('updateControlDisabledState() not found');
if (!restartMatch)
	throw new Error('restartRunningService() not found');
if (!persistedMatch)
	throw new Error('readPersistedConfigContent() not found');
if (saveStart === -1 || saveEnd === -1)
	throw new Error('saveAndApply() not found');

const controlsFnSource = controlsMatch[0].replace(/\n\nfunction updateControlDisabledState$/, '');
const updateFnSource = updateMatch[0].replace(/\n\nasync function withServiceActionLock$/, '');
const restartFnSource = restartMatch[0].replace(/\n\nfunction subscriptionUrlInputValue$/, '');
const persistedFnSource = persistedMatch[0].replace(/\n\nfunction confirmSubscriptionOverwrite$/, '');
const saveFnSource = source
	.slice(saveStart, saveEnd)
	.trim()
	.replace(/^const saveAndApply = /, '')
	.replace(/;$/, '');
const { module: configHelper } = harness.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/config.js');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function createContext(overrides = {}) {
	const context = {
		SERVICE_NAME: 'mihowrt',
		SERVICE_SCRIPT: '/etc/init.d/mihowrt',
		CLASH_CONFIG: '/opt/clash/config.yaml',
		startStopButton: { disabled: false },
		enableDisableButton: { disabled: false },
		dashboardButton: { disabled: false },
		saveApplyButton: { disabled: false },
		subscriptionUrlInput: { disabled: false },
		subscriptionOverrideInput: { disabled: false },
		subscriptionIntervalInput: { disabled: false },
		subscriptionSaveButton: { disabled: false },
		subscriptionFetchButton: { disabled: false },
		editorValue: 'mode: direct\n',
		editorSetCalls: [],
		editor: {
			getValue: () => context.editorValue,
			setValue: (value, cursor) => {
				context.editorValue = value;
				context.editorSetCalls.push({ value, cursor });
			}
		},
		writeCalls: [],
		readCalls: [],
		execCalls: [],
		notifications: [],
		appliedStates: [],
		pendingPersistCalls: [],
		refreshCalls: 0,
		serviceStatusCalls: 0,
		restartValidatedCalls: 0,
		disabledDuringApply: false,
		fs: {
			write: async(path, value) => {
				context.writeCalls.push({ path, value });
			},
			read: async(path) => {
				context.readCalls.push(path);
				if (context.readError)
					throw new Error(context.readError);
				return context.persistedConfigContent ?? context.editorValue;
			},
			exec: async(cmd, args) => {
				context.execCalls.push({ cmd, args });
				return { code: 0, stdout: '', stderr: '' };
			}
		},
		backendHelper: {
			applyConfig: async(path) => {
				context.disabledDuringApply = context.saveApplyButton.disabled;
				context.applyConfigPath = path;
				return context.applyResult || { restartRequired: false, hotReloaded: true, policyReloaded: false };
			},
			restartValidatedService: async() => {
				context.restartValidatedCalls += 1;
			}
		},
		mihowrtUi: {
			getServiceStatus: async() => {
				context.serviceStatusCalls += 1;
				return true;
			},
			execErrorDetail: result => String(result?.stderr || result?.stdout || '').trim() || 'unknown error',
			notify: (message, level) => context.notifications.push({ message, level })
		},
		pollServiceState: async(predicate) => {
			const settled = { running: true, enabled: true, ready: true };
			context.pollPredicateResult = predicate(settled);
			return settled;
		},
		refreshServiceState: async() => {
			context.refreshCalls += 1;
			return { running: true, enabled: true, ready: true };
		},
		applyServiceState: (running, enabled) => context.appliedStates.push({ running, enabled }),
		configHelper,
		Date: { now: () => 1700000000000 },
		Math
	};

	Object.assign(context, overrides);
	vm.createContext(context);
	vm.runInContext(`
function _(value) { return value; }
if (!String.prototype.format) {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return this.replace(/%[ds]/g, () => String(args[i++]));
	};
}
let startStopButton = globalThis.startStopButton;
let enableDisableButton = globalThis.enableDisableButton;
let dashboardButton = globalThis.dashboardButton;
let saveApplyButton = globalThis.saveApplyButton;
let subscriptionUrlInput = globalThis.subscriptionUrlInput;
let subscriptionOverrideInput = globalThis.subscriptionOverrideInput;
let subscriptionIntervalInput = globalThis.subscriptionIntervalInput;
let subscriptionSaveButton = globalThis.subscriptionSaveButton;
let subscriptionFetchButton = globalThis.subscriptionFetchButton;
let editor = globalThis.editor;
let serviceActionInFlight = false;
let saveInFlight = false;
let subscriptionInFlight = false;
let savedConfigContent = 'mode: old\\n';
${controlsFnSource}
${updateFnSource}
${restartFnSource}
${persistedFnSource}
async function persistPendingSubscriptionSettings(configContent) {
	globalThis.pendingPersistCalls.push(configContent);
	if (globalThis.pendingPersistError)
		throw new Error(globalThis.pendingPersistError);
	return !!globalThis.pendingPersistResult;
}
const saveAndApply = ${saveFnSource};
globalThis.saveAndApply = saveAndApply;
globalThis.getSavedConfigContent = () => savedConfigContent;
globalThis.getSaveInFlight = () => saveInFlight;
`, context);

	return context;
}

(async() => {
	const success = createContext();
	await success.saveAndApply();

	assert(success.serviceStatusCalls === 1, 'saveAndApply should read service state before apply');
	assert(success.writeCalls.length === 0, 'saveAndApply should not write temp config from frontend');
	assert(success.applyConfigPath === 'mode: direct\n', 'saveAndApply should pass raw editor contents to backend apply');
	assert(success.restartValidatedCalls === 0, 'saveAndApply should not restart after backend hot reload');
	assert(!success.execCalls.some(call => call.cmd === '/etc/init.d/mihowrt' && call.args[0] === 'restart'), 'saveAndApply should avoid duplicate init restart validation after backend apply');
	assert(!success.execCalls.some(call => call.cmd === '/bin/sh'), 'saveAndApply should not shell out for temp config cleanup');
	assert(success.pollPredicateResult === undefined, 'saveAndApply should skip restart polling after hot reload');
	assert(success.appliedStates.length === 0, 'saveAndApply should not apply restart-settled state after hot reload');
	assert(success.refreshCalls === 1, 'saveAndApply should refresh state after hot reload');
	assert(success.pendingPersistCalls.length === 1 && success.pendingPersistCalls[0] === 'mode: direct\n', 'saveAndApply should persist staged subscription settings after hot reload apply');
	assert(success.readCalls.includes('/opt/clash/config.yaml'), 'saveAndApply should refresh editor contents from persisted config');
	assert(success.editorSetCalls.length === 0, 'saveAndApply should not rewrite editor when backend left config unchanged');
	assert(success.disabledDuringApply === true, 'saveAndApply should lock controls while save is in flight');
	assert(success.getSavedConfigContent() === 'mode: direct\n', 'saveAndApply should update saved content after success');
	assert(success.getSaveInFlight() === false, 'saveAndApply should clear save lock after success');
	assert(success.saveApplyButton.disabled === false, 'saveAndApply should re-enable controls after success');
	assert(success.notifications.some(item => item.level === 'info' && String(item.message).includes('Configuration saved successfully.')), 'saveAndApply should report config save success');
	assert(success.notifications.some(item => item.level === 'info' && String(item.message).includes('Configuration hot-reloaded.')), 'saveAndApply should report hot reload success');

	const patchedConfig = createContext({
		persistedConfigContent: '# ===== MihoWRT autogenerated API defaults BEGIN =====\nexternal-controller: 192.168.1.1:9090\n# ===== MihoWRT autogenerated API defaults END =====\n\nmode: direct\n'
	});
	await patchedConfig.saveAndApply();
	assert(patchedConfig.editorSetCalls.length === 1, 'saveAndApply should update editor when backend patched config contents');
	assert(patchedConfig.getSavedConfigContent() === patchedConfig.persistedConfigContent, 'saveAndApply should track patched persisted config as saved baseline');
	assert(patchedConfig.pendingPersistCalls.length === 1 && patchedConfig.pendingPersistCalls[0] === 'mode: direct\n', 'saveAndApply should persist subscription settings against original applied subscription content');

	const restartFallback = createContext({
		applyResult: { restartRequired: true }
	});
	await restartFallback.saveAndApply();
	assert(restartFallback.restartValidatedCalls === 1, 'saveAndApply should restart running service when backend requires restart');
	assert(restartFallback.pollPredicateResult === true, 'saveAndApply should wait for ready service state after restart fallback');
	assert(restartFallback.pendingPersistCalls.length === 1 && restartFallback.pendingPersistCalls[0] === 'mode: direct\n', 'saveAndApply should persist staged subscription settings after restart fallback settles');
	assert(restartFallback.appliedStates.length === 1 && restartFallback.appliedStates[0].running === true && restartFallback.appliedStates[0].enabled === true, 'saveAndApply should apply settled running state after restart fallback');
	assert(restartFallback.refreshCalls === 0, 'saveAndApply should not force refresh on successful restart fallback');
	assert(restartFallback.notifications.some(item => item.level === 'info' && String(item.message).includes('Service restarted successfully.')), 'saveAndApply should report service restart fallback success');

	const failure = createContext();
	failure.backendHelper.applyConfig = async() => {
		throw new Error('apply broke');
	};
	await failure.saveAndApply();

	assert(failure.writeCalls.length === 0, 'saveAndApply should not write temp config before backend failure');
	assert(failure.pendingPersistCalls.length === 0, 'saveAndApply should not persist staged subscription settings after backend failure');
	assert(!failure.execCalls.some(call => call.cmd === '/bin/sh'), 'saveAndApply should not attempt temp config cleanup after backend failure');
	assert(failure.restartValidatedCalls === 0, 'saveAndApply should not restart service when backend apply fails');
	assert(failure.getSaveInFlight() === false, 'saveAndApply should clear save lock after backend failure');
	assert(failure.saveApplyButton.disabled === false, 'saveAndApply should re-enable controls after backend failure');
	assert(failure.notifications.some(item => item.level === 'error' && String(item.message).includes('Unable to save contents: apply broke')), 'saveAndApply should surface backend apply failure');

	const pendingFailure = createContext({ pendingPersistError: 'subscription save broke' });
	await pendingFailure.saveAndApply();
	assert(pendingFailure.notifications.some(item => item.level === 'warning' && String(item.message).includes('subscription save broke')), 'saveAndApply should warn when staged subscription settings fail to save');

	const unchangedPending = createContext({
		editor: {
			getValue: () => 'mode: old\n'
		},
		pendingPersistResult: true
	});
	await unchangedPending.saveAndApply();
	assert(unchangedPending.serviceStatusCalls === 0, 'saveAndApply should not read service state when unchanged config only saves staged subscription settings');
	assert(!unchangedPending.applyConfigPath, 'saveAndApply should not apply unchanged config when only subscription settings are pending');
	assert(unchangedPending.pendingPersistCalls.length === 1 && unchangedPending.pendingPersistCalls[0] === 'mode: old\n', 'saveAndApply should persist staged subscription settings even when config is unchanged');
	assert(unchangedPending.notifications.some(item => item.level === 'info' && String(item.message).includes('Subscription settings saved.')), 'saveAndApply should report saved staged subscription settings for unchanged config');
})().catch(err => {
	throw err;
});
EOF

pass "config save/apply flow"
