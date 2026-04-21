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

if (!hostMatch)
	throw new Error('normalizeHostPortFromAddr() not found');
if (!editorMatch)
	throw new Error('editorContentForSave() not found');

const hostFnSource = hostMatch[0].replace(/\n\nfunction computeUiPath$/, '');
const editorFnSource = editorMatch[0].replace(/\n\nfunction makeTempConfigPath$/, '');
const context = {};
vm.createContext(context);
vm.runInContext(`${hostFnSource}\n${editorFnSource}\nglobalThis.normalizeHostPortFromAddr = normalizeHostPortFromAddr;\nglobalThis.editorContentForSave = editorContentForSave;`, context);

const normalize = context.normalizeHostPortFromAddr;
const editorContentForSave = context.editorContentForSave;
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
EOF

pass "config view helpers"
