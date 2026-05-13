#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const vm = require('vm');
const harness = require('./tests/js_luci_harness');

const source = harness.readSource('rootfs/www/luci-static/resources/view/mihowrt/config.js');
const readStateMatch = source.match(/async function readServiceState[\s\S]*?\n}\n\nasync function refreshServiceState/);
if (!readStateMatch)
	throw new Error('readServiceState() not found');

const readStateFnSource = readStateMatch[0].replace(/\n\nasync function refreshServiceState$/, '');
const { module: configHelper } = harness.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/config.js');

const context = {
	configHelper,
	backendHelper: {
		readServiceState: async() => ({ available: false, errors: ['backend down'] })
	}
};

vm.createContext(context);
vm.runInContext(`
let lastServiceState = { running: true, enabled: false, ready: true };
${readStateFnSource}
globalThis.readServiceState = readServiceState;
globalThis.getLastServiceState = () => lastServiceState;
`, context);

(async () => {
	let threw = false;

	try {
		await context.readServiceState();
	}
	catch (e) {
		threw = true;
		if (!String(e.message).includes('backend down'))
			throw new Error('readServiceState() should expose backend error details');
	}

	if (!threw)
		throw new Error('readServiceState() should throw when backend returns errors');

	const preserved = context.getLastServiceState();
	if (preserved.running !== true || preserved.enabled !== false || preserved.ready !== true)
		throw new Error('readServiceState() should preserve last known state on backend errors');

	context.backendHelper.readServiceState = async() => ({
		available: true,
		errors: [],
		serviceRunning: false,
		serviceEnabled: true,
		serviceReady: false
	});

	const nextState = await context.readServiceState();
	if (nextState.running !== false || nextState.enabled !== true || nextState.ready !== false)
		throw new Error('readServiceState() should map running/enabled/ready fields from backend status');
})().catch(err => {
	throw err;
});
EOF

pass "config service state helpers"
