#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/config.js'), 'utf8');
const errorMatch = source.match(/function serviceStateErrorDetail[\s\S]*?\n}\n\nasync function pollServiceState/);
const readStateMatch = source.match(/async function readServiceState[\s\S]*?\n}\n\nasync function refreshServiceState/);

if (!errorMatch)
	throw new Error('serviceStateErrorDetail() not found');
if (!readStateMatch)
	throw new Error('readServiceState() not found');

const errorFnSource = errorMatch[0].replace(/\n\nasync function pollServiceState$/, '');
const readStateFnSource = readStateMatch[0].replace(/\n\nasync function refreshServiceState$/, '');

const context = {
	backendHelper: {
		readServiceState: async() => ({ available: false, errors: ['backend down'] })
	}
};

vm.createContext(context);
vm.runInContext(`
function _(value) { return value; }
let lastServiceState = { running: true, enabled: false, ready: true };
${errorFnSource}
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
