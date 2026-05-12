#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/mihowrt/backend.js'), 'utf8');
const emptyConfigMatch = source.match(/function emptyConfigState[\s\S]*?\n}\n\nfunction emptyStatusState/);
const emptyStatusMatch = source.match(/function emptyStatusState[\s\S]*?\n}\n\nfunction emptyLogState/);
const emptySubscriptionMatch = source.match(/function emptySubscriptionState[\s\S]*?\n}\n\nfunction tempConfigPath/);
const tempConfigMatch = source.match(/function tempConfigPath[\s\S]*?\n}\n\nasync function removeTempFile/);
const removeTempMatch = source.match(/async function removeTempFile[\s\S]*?\n}\n\nfunction commandResultState/);
const commandStateMatch = source.match(/function commandResultState[\s\S]*?\n}\n\nfunction assignConfigState/);
const exportMatch = source.match(/return baseclass\.extend\(\{[\s\S]*?\n\}\);/);

if (!emptyConfigMatch)
	throw new Error('emptyConfigState() not found');
if (!emptyStatusMatch)
	throw new Error('emptyStatusState() not found');
if (!emptySubscriptionMatch)
	throw new Error('emptySubscriptionState() not found');
if (!tempConfigMatch)
	throw new Error('tempConfigPath() not found');
if (!removeTempMatch)
	throw new Error('removeTempFile() not found');
if (!commandStateMatch)
	throw new Error('commandResultState() not found');
if (!exportMatch)
	throw new Error('backend export object not found');

const emptyConfigFnSource = emptyConfigMatch[0].replace(/\n\nfunction emptyStatusState$/, '');
const emptyStatusFnSource = emptyStatusMatch[0].replace(/\n\nfunction emptyLogState$/, '');
const emptySubscriptionFnSource = emptySubscriptionMatch[0].replace(/\n\nfunction tempConfigPath$/, '');
const tempConfigFnSource = tempConfigMatch[0].replace(/\n\nasync function removeTempFile$/, '');
const removeTempFnSource = removeTempMatch[0].replace(/\n\nfunction commandResultState$/, '');
const commandStateFnSource = commandStateMatch[0].replace(/\n\nfunction assignConfigState$/, '');
const exportObjectSource = exportMatch[0].replace(/^return baseclass\.extend\(/, '').replace(/\);$/, '');
const context = {
	Date: { now: () => 1700000000000 },
	Math: Object.create(Math),
	BACKEND: '/usr/bin/mihowrt',
	SERVICE_SCRIPT: '/etc/init.d/mihowrt',
	writeCalls: [],
	removeCalls: [],
	execCalls: [],
	fs: {
		write: async(path, value) => {
			context.writeCalls.push({ path, value });
		},
		remove: async(path) => {
			context.removeCalls.push(path);
			if (context.removeNotFound) {
				const error = new Error('not found');
				error.name = 'NotFoundError';
				throw error;
			}
		},
		exec: async(cmd, args) => {
			context.execCalls.push({ cmd, args });
			const key = `${cmd} ${args.join(' ')}`;
			return context.execResults[key] || { code: 0, stdout: '', stderr: '' };
		}
	},
	execHelper: {
		errorDetail: result => String(result?.stderr || result?.stdout || '').trim() || 'unknown error'
	},
	baseclass: {
		extend: value => value
	},
	execResults: {},
	removeNotFound: false
};
context.Math.random = () => 0.5;
vm.createContext(context);
vm.runInContext(`if (!String.prototype.format) { String.prototype.format = function() { let i = 0; const args = arguments; return this.replace(/%s/g, () => String(args[i++])); }; }\nfunction _(value) { return value; }\n${emptyConfigFnSource}\n${emptyStatusFnSource}\nfunction emptyLogState() { return { available: false, limit: 200, lines: [], errors: [] }; }\n${emptySubscriptionFnSource}\n${tempConfigFnSource}\n${removeTempFnSource}\n${commandStateFnSource}\nfunction assignConfigState(state) { return state; }\nasync function readConfig() { return emptyConfigState(); }\nconst backend = ${exportObjectSource};\nglobalThis.emptyStatusState = emptyStatusState;\nglobalThis.backend = backend;`, context);

const state = context.emptyStatusState();

if (state.available !== false)
	throw new Error('emptyStatusState should default available to false');
if (state.serviceReady !== false)
	throw new Error('emptyStatusState should default serviceReady to false');
if (state.runtimeSnapshotValid !== false)
	throw new Error('emptyStatusState should default runtimeSnapshotValid to false');
if (state.runtimeSafeReloadReady !== false)
	throw new Error('emptyStatusState should default runtimeSafeReloadReady to false');
if (state.runtimeMatchesDesired !== false)
	throw new Error('emptyStatusState should default runtimeMatchesDesired to false');
if (state.policyMode !== 'direct-first')
	throw new Error('emptyStatusState should default policyMode to direct-first');
if (state.directDstCount !== 0)
	throw new Error('emptyStatusState should default directDstCount to zero');
if (state.directDstRemoteUrlCount !== 0)
	throw new Error('emptyStatusState should default directDstRemoteUrlCount to zero');

(async() => {
	await context.backend.applyConfig('mode: rule\n');
	if (context.writeCalls.length !== 1)
		throw new Error('applyConfig should stage config contents in a temp file');
	if (!context.writeCalls[0].path.startsWith('/tmp/mihowrt-config.'))
		throw new Error(`applyConfig should use mihowrt temp prefix, got '${context.writeCalls[0].path}'`);
	if (context.writeCalls[0].value !== 'mode: rule\n')
		throw new Error('applyConfig should write raw config contents to temp file');
	const applyExec = context.execCalls.find(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'apply-config');
	if (!applyExec)
		throw new Error('applyConfig should call backend apply-config with temp path');
	if (applyExec.args[1] !== context.writeCalls[0].path)
		throw new Error('applyConfig should pass staged temp path to backend');
	if (!context.removeCalls.includes(context.writeCalls[0].path))
		throw new Error('applyConfig should remove temp file after backend call');

	context.writeCalls.length = 0;
	context.removeCalls.length = 0;
	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt apply-config /tmp/mihowrt-config.1700000000000-80000000'] = {
		code: 1,
		stderr: 'bad config'
	};
	let applyFailed = false;
	try {
		await context.backend.applyConfig('bad\n');
	}
	catch (e) {
		applyFailed = e.message === 'bad config';
	}
	if (!applyFailed)
		throw new Error('applyConfig should surface backend validation failures');
	if (!context.removeCalls.includes('/tmp/mihowrt-config.1700000000000-80000000'))
		throw new Error('applyConfig should remove temp file after backend failure');
	context.execResults = {};

	await context.backend.restartValidatedService();
	if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'restart-validated-service'))
		throw new Error('restartValidatedService should dispatch through backend command');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt subscription-json'] = {
		code: 0,
		stdout: '{"subscription_url":"https://example.com/sub.yaml"}'
	};
	const subscriptionState = await context.backend.readSubscriptionUrl();
	if (subscriptionState.subscriptionUrl !== 'https://example.com/sub.yaml' || subscriptionState.errors.length)
		throw new Error('readSubscriptionUrl should parse saved subscription URL');
	if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'subscription-json'))
		throw new Error('readSubscriptionUrl should dispatch through backend command');

	context.execCalls.length = 0;
	await context.backend.saveSubscriptionUrl('https://example.com/sub.yaml');
	const saveSubscriptionExec = context.execCalls.find(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'set-subscription-url');
	if (!saveSubscriptionExec || saveSubscriptionExec.args[1] !== 'https://example.com/sub.yaml')
		throw new Error('saveSubscriptionUrl should pass URL to backend command');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt fetch-subscription https://example.com/sub.yaml'] = {
		code: 0,
		stdout: 'mode: rule\n'
	};
	const fetchedSubscription = await context.backend.fetchSubscription('https://example.com/sub.yaml');
	if (fetchedSubscription !== 'mode: rule\n')
		throw new Error('fetchSubscription should return backend stdout');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt fetch-subscription https://example.com/bad.yaml'] = {
		code: 1,
		stderr: 'download failed'
	};
	let fetchFailed = false;
	try {
		await context.backend.fetchSubscription('https://example.com/bad.yaml');
	}
	catch (e) {
		fetchFailed = e.message === 'download failed';
	}
	if (!fetchFailed)
		throw new Error('fetchSubscription should surface backend fetch failures');

	context.execCalls.length = 0;
	context.execResults['/etc/init.d/mihowrt enabled'] = { code: 0, stdout: '', stderr: '' };
	context.execResults['/usr/bin/mihowrt service-running'] = { code: 0, stdout: '', stderr: '' };
	context.execResults['/usr/bin/mihowrt service-ready'] = { code: 1, stdout: '', stderr: '' };
	const serviceState = await context.backend.readServiceState();
	if (!serviceState.available || !serviceState.serviceEnabled || !serviceState.serviceRunning || serviceState.serviceReady)
		throw new Error('readServiceState should map lightweight command statuses');
	if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'service-ready'))
		throw new Error('readServiceState should probe service-ready only when service is running');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt service-running'] = { code: 1, stdout: '', stderr: '' };
	const stoppedState = await context.backend.readServiceState();
	if (!stoppedState.available || stoppedState.serviceRunning || stoppedState.serviceReady)
		throw new Error('readServiceState should report stopped service without ready probe');
	if (context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'service-ready'))
		throw new Error('readServiceState should skip service-ready probe when service is stopped');
})().catch(err => {
	throw err;
});
EOF

pass "backend helpers"
