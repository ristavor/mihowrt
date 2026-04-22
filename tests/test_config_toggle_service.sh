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
const lockMatch = source.match(/async function withServiceActionLock[\s\S]*?\n}\n\nasync function runServiceAction/);
const toggleMatch = source.match(/async function toggleService[\s\S]*?\n}\n\nasync function toggleServiceEnabled/);

if (!controlsMatch)
	throw new Error('controlsBusy() not found');
if (!updateMatch)
	throw new Error('updateControlDisabledState() not found');
if (!lockMatch)
	throw new Error('withServiceActionLock() not found');
if (!toggleMatch)
	throw new Error('toggleService() not found');

const controlsFnSource = controlsMatch[0].replace(/\n\nfunction updateControlDisabledState$/, '');
const updateFnSource = updateMatch[0].replace(/\n\nasync function withServiceActionLock$/, '');
const lockFnSource = lockMatch[0].replace(/\n\nasync function runServiceAction$/, '');
const toggleFnSource = toggleMatch[0].replace(/\n\nasync function toggleServiceEnabled$/, '');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function assertDisabledState(context, expected, message) {
	const actual = [
		context.startStopButton.disabled,
		context.enableDisableButton.disabled,
		context.dashboardButton.disabled,
		context.saveApplyButton.disabled
	];

	if (actual.some(value => value !== expected))
		throw new Error(`${message}: expected all buttons disabled=${expected}, got ${actual.join(',')}`);
}

async function flushMicrotasks() {
	await Promise.resolve();
	await Promise.resolve();
}

async function waitFor(predicate, message) {
	for (let i = 0; i < 20; i++) {
		if (predicate())
			return;
		await new Promise(resolve => setTimeout(resolve, 0));
	}

	throw new Error(message);
}

function createContext(initialState) {
	const context = {
		startStopButton: { disabled: false },
		enableDisableButton: { disabled: false },
		dashboardButton: { disabled: false },
		saveApplyButton: { disabled: false },
		stopServiceCalls: 0,
		startServiceCalls: 0,
		notifications: [],
		appliedStates: [],
		resolvePoll: null,
		readServiceState: async() => Object.assign({}, initialState),
		stopService: async() => {
			context.stopServiceCalls += 1;
			return true;
		},
		startService: async() => {
			context.startServiceCalls += 1;
			return true;
		},
		pollServiceState: async() => new Promise(resolve => {
			context.resolvePoll = resolve;
		}),
		refreshServiceState: async() => Object.assign({}, initialState),
		applyServiceState: (running, enabled) => {
			context.appliedStates.push({ running, enabled });
		},
		mihowrtUi: {
			notify: (message, level) => context.notifications.push({ message, level })
		}
	};

	vm.createContext(context);
	vm.runInContext(`
function _(value) { return value; }
if (!String.prototype.format) {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return this.replace(/%s/g, () => String(args[i++]));
	};
}
let startStopButton = globalThis.startStopButton;
let enableDisableButton = globalThis.enableDisableButton;
let dashboardButton = globalThis.dashboardButton;
let saveApplyButton = globalThis.saveApplyButton;
let serviceActionInFlight = false;
let saveInFlight = false;
${controlsFnSource}
${updateFnSource}
${lockFnSource}
${toggleFnSource}
globalThis.toggleService = toggleService;
globalThis.controlsBusy = controlsBusy;
globalThis.getServiceActionInFlight = () => serviceActionInFlight;
`, context);

	return context;
}

(async () => {
	const stopContext = createContext({ running: true, enabled: true, ready: true });
	const stopPending = stopContext.toggleService();

	assert(stopContext.getServiceActionInFlight() === true, 'toggleService should mark service action busy immediately for stop');
	assertDisabledState(stopContext, true, 'toggleService should lock controls during stop transition');
	await flushMicrotasks();
	assert(stopContext.stopServiceCalls === 1, 'toggleService should invoke stopService for running service');
	assertDisabledState(stopContext, true, 'toggleService should keep controls locked while stop confirmation is pending');
	await waitFor(() => typeof stopContext.resolvePoll === 'function', 'toggleService should wait for stop state confirmation');

	stopContext.resolvePoll({ running: false, enabled: true, ready: false });
	await stopPending;

	assert(stopContext.getServiceActionInFlight() === false, 'toggleService should clear busy state after stop settles');
	assertDisabledState(stopContext, false, 'toggleService should unlock controls after stop settles');
	assert(stopContext.appliedStates.length === 1 && stopContext.appliedStates[0].running === false, 'toggleService should apply settled stopped state');

	const startContext = createContext({ running: false, enabled: true, ready: false });
	const startPending = startContext.toggleService();

	assert(startContext.getServiceActionInFlight() === true, 'toggleService should mark service action busy immediately for start');
	assertDisabledState(startContext, true, 'toggleService should lock controls during start transition');
	await flushMicrotasks();
	assert(startContext.startServiceCalls === 1, 'toggleService should invoke startService for stopped service');
	assertDisabledState(startContext, true, 'toggleService should keep controls locked while start confirmation is pending');
	await waitFor(() => typeof startContext.resolvePoll === 'function', 'toggleService should wait for start readiness confirmation');

	startContext.resolvePoll({ running: true, enabled: true, ready: true });
	await startPending;

	assert(startContext.getServiceActionInFlight() === false, 'toggleService should clear busy state after start settles');
	assertDisabledState(startContext, false, 'toggleService should unlock controls after start settles');
	assert(startContext.appliedStates.length === 1 && startContext.appliedStates[0].running === true, 'toggleService should apply settled started state');
})().catch(err => {
	throw err;
});
EOF

pass "config toggle service flow"
