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
const emptyLogMatch = source.match(/function emptyLogState[\s\S]*?\n}\n\nfunction emptySubscriptionState/);
const emptySubscriptionMatch = source.match(/function emptySubscriptionState[\s\S]*?\n}\n\nfunction tempConfigPath/);
const tempConfigMatch = source.match(/function tempConfigPath[\s\S]*?\n}\n\nasync function removeTempFile/);
const removeTempMatch = source.match(/async function removeTempFile[\s\S]*?\n}\n\nfunction assignConfigState/);
const assignConfigMatch = source.match(/function assignConfigState[\s\S]*?\n}\n\nfunction assignServiceState/);
const assignServiceMatch = source.match(/function assignServiceState[\s\S]*?\n}\n\nasync function readBackendJson/);
const readBackendJsonMatch = source.match(/async function readBackendJson[\s\S]*?\n}\n\nfunction assignSubscriptionState/);
const assignSubscriptionMatch = source.match(/function assignSubscriptionState[\s\S]*?\n}\n\nfunction assignStatusState/);
const assignStatusMatch = source.match(/function assignStatusState[\s\S]*?\n}\n\nfunction assignLogState/);
const assignLogMatch = source.match(/function assignLogState[\s\S]*?\n}\n\nasync function readConfig/);
const readConfigMatch = source.match(/async function readConfig[\s\S]*?\n}\n\nreturn baseclass\.extend/);
const exportMatch = source.match(/return baseclass\.extend\(\{[\s\S]*?\n\}\);/);

if (!emptyConfigMatch)
	throw new Error('emptyConfigState() not found');
if (!emptyStatusMatch)
	throw new Error('emptyStatusState() not found');
if (!emptyLogMatch)
	throw new Error('emptyLogState() not found');
if (!emptySubscriptionMatch)
	throw new Error('emptySubscriptionState() not found');
if (!tempConfigMatch)
	throw new Error('tempConfigPath() not found');
if (!removeTempMatch)
	throw new Error('removeTempFile() not found');
if (!assignConfigMatch)
	throw new Error('assignConfigState() not found');
if (!assignServiceMatch)
	throw new Error('assignServiceState() not found');
if (!readBackendJsonMatch)
	throw new Error('readBackendJson() not found');
if (!assignSubscriptionMatch)
	throw new Error('assignSubscriptionState() not found');
if (!assignStatusMatch)
	throw new Error('assignStatusState() not found');
if (!assignLogMatch)
	throw new Error('assignLogState() not found');
if (!readConfigMatch)
	throw new Error('readConfig() not found');
if (!exportMatch)
	throw new Error('backend export object not found');

const emptyConfigFnSource = emptyConfigMatch[0].replace(/\n\nfunction emptyStatusState$/, '');
const emptyStatusFnSource = emptyStatusMatch[0].replace(/\n\nfunction emptyLogState$/, '');
const emptyLogFnSource = emptyLogMatch[0].replace(/\n\nfunction emptySubscriptionState$/, '');
const emptySubscriptionFnSource = emptySubscriptionMatch[0].replace(/\n\nfunction tempConfigPath$/, '');
const tempConfigFnSource = tempConfigMatch[0].replace(/\n\nasync function removeTempFile$/, '');
const removeTempFnSource = removeTempMatch[0].replace(/\n\nfunction assignConfigState$/, '');
const assignConfigFnSource = assignConfigMatch[0].replace(/\n\nfunction assignServiceState$/, '');
const assignServiceFnSource = assignServiceMatch[0].replace(/\n\nasync function readBackendJson$/, '');
const readBackendJsonFnSource = readBackendJsonMatch[0].replace(/\n\nfunction assignSubscriptionState$/, '');
const assignSubscriptionFnSource = assignSubscriptionMatch[0].replace(/\n\nfunction assignStatusState$/, '');
const assignStatusFnSource = assignStatusMatch[0].replace(/\n\nfunction assignLogState$/, '');
const assignLogFnSource = assignLogMatch[0].replace(/\n\nasync function readConfig$/, '');
const readConfigFnSource = readConfigMatch[0].replace(/\n\nreturn baseclass\.extend$/, '');
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
vm.runInContext(`if (!String.prototype.format) { String.prototype.format = function() { let i = 0; const args = arguments; return this.replace(/%s/g, () => String(args[i++])); }; }\nfunction _(value) { return value; }\n${emptyConfigFnSource}\n${emptyStatusFnSource}\n${emptyLogFnSource}\n${emptySubscriptionFnSource}\n${tempConfigFnSource}\n${removeTempFnSource}\n${assignConfigFnSource}\n${assignServiceFnSource}\n${readBackendJsonFnSource}\n${assignSubscriptionFnSource}\n${assignStatusFnSource}\n${assignLogFnSource}\n${readConfigFnSource}\nconst backend = ${exportObjectSource};\nglobalThis.emptyStatusState = emptyStatusState;\nglobalThis.backend = backend;`, context);

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
	context.execResults['/usr/bin/mihowrt read-config /tmp/config.yaml'] = {
		code: 0,
		stdout: '{"config_path":"/tmp/config.yaml","dns_port":5353,"catch_fakeip":true,"errors":["parse warning"]}'
	};
	const configState = await context.backend.readConfig('/tmp/config.yaml');
	if (configState.configPath !== '/tmp/config.yaml' || configState.dnsPort !== '5353' || !configState.catchFakeip)
		throw new Error('readConfig should map backend JSON payload into config state');
	if (configState.errors[0] !== 'parse warning')
		throw new Error('readConfig should preserve backend config parse errors');
	if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args.join(' ') === 'read-config /tmp/config.yaml'))
		throw new Error('readConfig should pass optional config path to backend command');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt read-config'] = {
		code: 1,
		stderr: 'read failed'
	};
	const failedConfigState = await context.backend.readConfig();
	if (failedConfigState.errors[0] !== 'read failed')
		throw new Error('readConfig should surface backend command failures');

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
	context.execResults['/usr/bin/mihowrt status-json'] = {
		code: 0,
		stdout: JSON.stringify({
			service_enabled: true,
			service_running: true,
			service_ready: true,
			route_table_id: 302,
			route_rule_priority: 120,
			source_network_interfaces: ['lan', 7],
			always_proxy_dst_count: 2,
			active: {
				present: true,
				enabled: true,
				policy_mode: 'proxy-first',
				source_network_interfaces: ['wan']
			},
			config: {
				dns_port: 1053
			}
		})
	};
	const statusState = await context.backend.readStatus();
	if (!statusState.available || !statusState.serviceEnabled || !statusState.serviceRunning || !statusState.serviceReady)
		throw new Error('readStatus should map service flags from backend JSON');
	if (statusState.routeTableId !== '302' || statusState.routeRulePriority !== '120')
		throw new Error('readStatus should stringify route settings');
	if (statusState.sourceNetworkInterfaces.join(',') !== 'lan,7')
		throw new Error('readStatus should stringify configured source interfaces');
	if (!statusState.active.present || statusState.active.policyMode !== 'proxy-first')
		throw new Error('readStatus should map active runtime state');
	if (statusState.config.dnsPort !== '1053')
		throw new Error('readStatus should map nested parsed config state');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt logs-json 10'] = {
		code: 0,
		stdout: '{"available":true,"limit":10,"lines":["one",2]}'
	};
	const logState = await context.backend.readLogs(10);
	if (!logState.available || logState.limit !== 10 || logState.lines.join('|') !== 'one|2')
		throw new Error('readLogs should map backend log payload');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt logs-json 3'] = {
		code: 1,
		stderr: 'logs failed'
	};
	const failedLogState = await context.backend.readLogs(3);
	if (failedLogState.errors[0] !== 'logs failed')
		throw new Error('readLogs should surface backend command failures');

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
	context.execResults['/usr/bin/mihowrt update-policy-lists'] = {
		code: 0,
		stdout: 'updated=1\n'
	};
	const policyListsChanged = await context.backend.updatePolicyLists();
	if (!policyListsChanged)
		throw new Error('updatePolicyLists should report changed lists from backend stdout');
	if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'update-policy-lists'))
		throw new Error('updatePolicyLists should dispatch through backend command');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt update-policy-lists'] = {
		code: 0,
		stdout: 'updated=0\n'
	};
	const policyListsUnchanged = await context.backend.updatePolicyLists();
	if (policyListsUnchanged)
		throw new Error('updatePolicyLists should report unchanged lists from backend stdout');

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
	context.execResults['/usr/bin/mihowrt service-state-json'] = {
		code: 0,
		stdout: '{"service_enabled":true,"service_running":true,"service_ready":false}'
	};
	const serviceState = await context.backend.readServiceState();
	if (!serviceState.available || !serviceState.serviceEnabled || !serviceState.serviceRunning || serviceState.serviceReady)
		throw new Error('readServiceState should map backend service-state-json payload');
	if (context.execCalls.length !== 1 || context.execCalls[0].args[0] !== 'service-state-json')
		throw new Error('readServiceState should use one backend state command');

	context.execCalls.length = 0;
	context.execResults['/usr/bin/mihowrt service-state-json'] = {
		code: 0,
		stdout: '{"service_enabled":false,"service_running":false,"service_ready":false}'
	};
	const stoppedState = await context.backend.readServiceState();
	if (!stoppedState.available || stoppedState.serviceRunning || stoppedState.serviceReady)
		throw new Error('readServiceState should report stopped service from one state payload');
})().catch(err => {
	throw err;
});
EOF

pass "backend helpers"
