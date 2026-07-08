#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/config.js'), 'utf8');

const controlsMatch = source.match(/function controlsBusy[\s\S]*?\n}\n\nfunction updateControlDisabledState/);
const updateMatch = source.match(/function updateControlDisabledState[\s\S]*?\n}\n\nasync function withServiceActionLock/);
const runActionMatch = source.match(/async function runServiceAction[\s\S]*?\n}\n\nasync function handleServiceAction/);
const updateKernelMatch = source.match(/async function updateKernel[\s\S]*?\n}\n\nasync function initializeAceEditor/);

if (!controlsMatch)
	throw new Error('controlsBusy() not found');
if (!updateMatch)
	throw new Error('updateControlDisabledState() not found');
if (!runActionMatch)
	throw new Error('runServiceAction() not found');
if (!updateKernelMatch)
	throw new Error('updateKernel() not found');

const controlsFnSource = controlsMatch[0].replace(/\n\nfunction updateControlDisabledState$/, '');
const updateFnSource = updateMatch[0].replace(/\n\nasync function withServiceActionLock$/, '');
const runActionFnSource = runActionMatch[0].replace(/\n\nasync function handleServiceAction$/, '');
const updateKernelFnSource = updateKernelMatch[0].replace(/\n\nasync function initializeAceEditor$/, '');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function createContext(overrides = {}) {
	const context = {
		SERVICE_SCRIPT: '/etc/init.d/mihowrt',
		startStopButton: { disabled: false },
		enableDisableButton: { disabled: false },
		dashboardButton: { disabled: false },
		updateKernelButton: { disabled: false },
		saveApplyButton: { disabled: false },
		subscriptionUrlInput: { disabled: false },
		subscriptionOverrideInput: { disabled: false, checked: false },
		subscriptionIntervalInput: { disabled: false },
		subscriptionSaveButton: { disabled: false },
		subscriptionFetchButton: { disabled: false },
		execCalls: [],
		restartValidatedCalls: 0,
		notifications: [],
		appliedStates: [],
		refreshCalls: 0,
		updateDisabledDuringCall: false,
		backendHelper: {
			updateKernel: async() => {
				context.updateDisabledDuringCall = context.updateKernelButton.disabled;
				return context.updateResult || {
					updated: true,
					restartRequired: true,
					latestVersion: 'v1.19.26'
				};
			},
			restartValidatedService: async() => {
				context.restartValidatedCalls += 1;
				if (context.restartResult && context.restartResult.code !== 0)
					throw new Error(String(context.restartResult.stderr || context.restartResult.stdout || '').trim() || 'restart failed');
			}
		},
		fs: {
			exec: async(cmd, args) => {
				context.execCalls.push({ cmd, args });
				return context.restartResult || { code: 0, stdout: '', stderr: '' };
			}
		},
		mihowrtUi: {
			execErrorDetail: result => String(result?.stderr || result?.stdout || '').trim() || 'unknown error',
			notify: (message, level) => context.notifications.push({ message, level })
		},
		pollServiceState: async(predicate) => {
			const settled = context.pollResult === undefined
				? { running: true, enabled: true, ready: true }
				: context.pollResult;
			if (settled)
				context.pollPredicateResult = predicate(settled);
			return settled;
		},
		refreshServiceState: async() => {
			context.refreshCalls += 1;
			return { running: false, enabled: true, ready: false };
		},
		applyServiceState: (running, enabled) => context.appliedStates.push({ running, enabled })
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
let updateKernelButton = globalThis.updateKernelButton;
let saveApplyButton = globalThis.saveApplyButton;
let subscriptionUrlInput = globalThis.subscriptionUrlInput;
let subscriptionOverrideInput = globalThis.subscriptionOverrideInput;
let subscriptionIntervalInput = globalThis.subscriptionIntervalInput;
let subscriptionSaveButton = globalThis.subscriptionSaveButton;
let subscriptionFetchButton = globalThis.subscriptionFetchButton;
let serviceActionInFlight = false;
let kernelUpdateInFlight = false;
let saveInFlight = false;
let subscriptionInFlight = false;
${controlsFnSource}
${updateFnSource}
${runActionFnSource}
${updateKernelFnSource}
globalThis.updateKernel = updateKernel;
globalThis.getKernelUpdateInFlight = () => kernelUpdateInFlight;
`, context);

	return context;
}

(async() => {
	const success = createContext();
	await success.updateKernel();
	assert(success.updateDisabledDuringCall === true, 'updateKernel should lock controls during backend call');
	assert(success.restartValidatedCalls === 1, 'updateKernel should restart service after updating a running kernel');
	assert(success.pollPredicateResult === true, 'updateKernel should wait for service readiness after restart');
	assert(success.appliedStates.length === 1 && success.appliedStates[0].running === true, 'updateKernel should apply settled restarted state');
	assert(success.getKernelUpdateInFlight() === false, 'updateKernel should clear busy flag after success');
	assert(success.updateKernelButton.disabled === false, 'updateKernel should unlock controls after success');
	assert(success.notifications.some(item => item.level === 'info' && String(item.message).includes('service restarted')), 'updateKernel should report restart success');

	const stopped = createContext({
		updateResult: {
			updated: true,
			restartRequired: false,
			latestVersion: 'v1.19.26'
		}
	});
	await stopped.updateKernel();
	assert(stopped.restartValidatedCalls === 0, 'updateKernel should not start stopped service after kernel update');
	assert(stopped.notifications.some(item => item.level === 'info' && String(item.message).includes('updated to v1.19.26')), 'updateKernel should report update without restart');

	const current = createContext({
		updateResult: {
			action: 'up_to_date',
			updated: false,
			restartRequired: false,
			currentVersion: 'v1.19.26',
			latestVersion: 'v1.19.26'
		}
	});
	await current.updateKernel();
	assert(current.restartValidatedCalls === 0, 'updateKernel should not restart when kernel is current');
	assert(current.notifications.some(item => item.level === 'info' && String(item.message).includes('up to date')), 'updateKernel should report current kernel');

	const restartFail = createContext({
		restartResult: { code: 1, stderr: 'restart failed' }
	});
	await restartFail.updateKernel();
	assert(restartFail.refreshCalls === 1, 'updateKernel should refresh state after restart failure');
	assert(restartFail.notifications.some(item => item.level === 'error' && String(item.message).includes('restart failed')), 'updateKernel should surface restart failure');
})().catch(err => {
	throw err;
});
EOF

pass "config kernel update flow"
