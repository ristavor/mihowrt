#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/config.js'), 'utf8');
const match = source.match(/function normalizeHostPortFromAddr[\s\S]*?\n}\n\nfunction computeUiPath/);

if (!match)
	throw new Error('normalizeHostPortFromAddr() not found');

const fnSource = match[0].replace(/\n\nfunction computeUiPath$/, '');
const context = {};
vm.createContext(context);
vm.runInContext(`${fnSource}\nglobalThis.normalizeHostPortFromAddr = normalizeHostPortFromAddr;`, context);

const normalize = context.normalizeHostPortFromAddr;
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
EOF

pass "config view helpers"
