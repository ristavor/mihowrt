#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/config.js'), 'utf8');
const hostMatch = source.match(/function normalizeHostPortFromAddr[\s\S]*?\n}\n\nfunction computeUiPath/);
const editorMatch = source.match(/function editorContentForSave[\s\S]*?\n}\n\nfunction makeTempConfigPath/);
const busyMatch = source.match(/function controlsBusy[\s\S]*?\n}\n\nfunction updateControlDisabledState/);

if (!hostMatch)
	throw new Error('normalizeHostPortFromAddr() not found');
if (!editorMatch)
	throw new Error('editorContentForSave() not found');
if (!busyMatch)
	throw new Error('controlsBusy() not found');

const hostFnSource = hostMatch[0].replace(/\n\nfunction computeUiPath$/, '');
const editorFnSource = editorMatch[0].replace(/\n\nfunction makeTempConfigPath$/, '');
const busyFnSource = busyMatch[0].replace(/\n\nfunction updateControlDisabledState$/, '');
const context = {};
vm.createContext(context);
vm.runInContext(`let serviceActionInFlight = false; let saveInFlight = false;\n${hostFnSource}\n${editorFnSource}\n${busyFnSource}\nglobalThis.normalizeHostPortFromAddr = normalizeHostPortFromAddr;\nglobalThis.editorContentForSave = editorContentForSave;\nglobalThis.controlsBusy = controlsBusy;\nglobalThis.setBusyFlags = (serviceBusy, saveBusy) => { serviceActionInFlight = serviceBusy; saveInFlight = saveBusy; };`, context);

const normalize = context.normalizeHostPortFromAddr;
const editorContentForSave = context.editorContentForSave;
const controlsBusy = context.controlsBusy;
const fallbackHost = 'router.lan';
const fallbackPort = '9090';

function assertEq(actual, expected, message) {
	if (actual !== expected)
		throw new Error(`${message}: expected '${expected}', got '${actual}'`);
}

function assertHostPort(addr, expectedHost, expectedPort, message) {
	const actual = normalize(addr, fallbackHost, fallbackPort);
	assertEq(actual.host, expectedHost, `${message} host`);
	assertEq(actual.port, expectedPort, `${message} port`);
}

assertHostPort('127.0.0.1:9090', fallbackHost, '9090', 'IPv4 loopback should use LuCI host');
assertHostPort('127.2.3.4:9090', fallbackHost, '9090', 'Any 127/8 loopback should use LuCI host');
assertHostPort('[::1]:9090', fallbackHost, '9090', 'IPv6 loopback should use LuCI host');
assertHostPort('localhost:9090', fallbackHost, '9090', 'localhost should use LuCI host');
assertHostPort('0.0.0.0:9090', fallbackHost, '9090', 'Wildcard IPv4 should use LuCI host');
assertHostPort('[::]:9090', fallbackHost, '9090', 'Wildcard IPv6 should use LuCI host');
assertHostPort('192.168.1.10:9090', '192.168.1.10', '9090', 'Remote controller host should stay unchanged');
assertHostPort('', fallbackHost, fallbackPort, 'Empty controller should keep fallback host/port');
assertEq(editorContentForSave('line 1\n\n  tail  '), 'line 1\n\n  tail  ', 'editorContentForSave should preserve whitespace and blank lines');
assertEq(editorContentForSave('plain'), 'plain', 'editorContentForSave should not force trailing newline');
assertEq(editorContentForSave(null), '', 'editorContentForSave should map null to empty string');
context.setBusyFlags(false, false);
assertEq(String(controlsBusy()), 'false', 'controlsBusy should be false when no action is running');
context.setBusyFlags(true, false);
assertEq(String(controlsBusy()), 'true', 'controlsBusy should be true when service action is running');
context.setBusyFlags(false, true);
assertEq(String(controlsBusy()), 'true', 'controlsBusy should be true when save is running');
EOF

pass "config view helpers"
