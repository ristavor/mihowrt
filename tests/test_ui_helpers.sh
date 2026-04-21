#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/mihowrt/ui.js'), 'utf8');
const probeMatch = source.match(/async function probeServiceStatus[\s\S]*?\n}\n\nasync function getServiceStatus/);
const statusMatch = source.match(/async function getServiceStatus[\s\S]*?\n}\n\nfunction execErrorDetail/);
const execMatch = source.match(/function execErrorDetail[\s\S]*?\n}\n\nfunction notify/);

if (!probeMatch)
	throw new Error('probeServiceStatus() not found');
if (!statusMatch)
	throw new Error('getServiceStatus() not found');
if (!execMatch)
	throw new Error('execErrorDetail() not found');

const probeFnSource = probeMatch[0].replace(/\n\nasync function getServiceStatus$/, '');
const statusFnSource = statusMatch[0].replace(/\n\nfunction execErrorDetail$/, '');
const execFnSource = execMatch[0].replace(/\n\nfunction notify$/, '');

const context = {
	fs: {
		exec: async() => ({ code: 1, stderr: '' })
	},
	callServiceList: async() => ({ mihowrt: { instances: { main: { running: true } } } })
};

vm.createContext(context);
vm.runInContext(`
function _(value) { return value; }
${probeFnSource}
${statusFnSource}
${execFnSource}
globalThis.getServiceStatus = getServiceStatus;
`, context);

(async () => {
	const runningByRpc = await context.getServiceStatus('mihowrt', '/etc/init.d/mihowrt');
	if (runningByRpc !== true)
		throw new Error('getServiceStatus() should return running=true from rpc data');

	context.callServiceList = async() => ({ mihowrt: { instances: { main: { running: false } } } });
	context.fs.exec = async() => ({ code: 0, stderr: '' });
	const runningByInit = await context.getServiceStatus('mihowrt', '/etc/init.d/mihowrt');
	if (runningByInit !== true)
		throw new Error('getServiceStatus() should fall back to init script when rpc says stopped');

	context.callServiceList = async() => {
		throw new Error('rpc down');
	};
	context.fs.exec = async() => ({ code: 1, stderr: '' });
	const stoppedByInit = await context.getServiceStatus('mihowrt', '/etc/init.d/mihowrt');
	if (stoppedByInit !== false)
		throw new Error('getServiceStatus() should report stopped when init script says not running');

	context.callServiceList = async() => {
		throw new Error('rpc down');
	};
	context.fs.exec = async() => ({ code: 2, stderr: 'probe failed' });
	let threw = false;
	try {
		await context.getServiceStatus('mihowrt', '/etc/init.d/mihowrt');
	}
	catch (e) {
		threw = true;
		if (!String(e.message).includes('rpc down') || !String(e.message).includes('probe failed'))
			throw new Error('getServiceStatus() should preserve rpc and init probe errors');
	}

	if (!threw)
		throw new Error('getServiceStatus() should throw when all service probes fail');
})().catch(err => {
	throw err;
});
EOF

pass "ui helpers"
