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
const serviceLabelMatch = source.match(/function serviceToggleLabel[\s\S]*?\n}\n\nfunction serviceBadgeText/);
const serviceTextMatch = source.match(/function serviceBadgeText[\s\S]*?\n}\n\nfunction serviceBadgeColor/);
const serviceColorMatch = source.match(/function serviceBadgeColor[\s\S]*?\n}\n\nfunction applyServiceState/);

if (!hostMatch)
	throw new Error('normalizeHostPortFromAddr() not found');
if (!editorMatch)
	throw new Error('editorContentForSave() not found');
if (!busyMatch)
	throw new Error('controlsBusy() not found');
if (!serviceLabelMatch)
	throw new Error('serviceToggleLabel() not found');
if (!serviceTextMatch)
	throw new Error('serviceBadgeText() not found');
if (!serviceColorMatch)
	throw new Error('serviceBadgeColor() not found');
if (source.includes('window.location.reload()'))
	throw new Error('config.js should not do full page reloads after local actions');

const hostFnSource = hostMatch[0].replace(/\n\nfunction computeUiPath$/, '');
const editorFnSource = editorMatch[0].replace(/\n\nfunction makeTempConfigPath$/, '');
const busyFnSource = busyMatch[0].replace(/\n\nfunction updateControlDisabledState$/, '');
const serviceLabelFnSource = serviceLabelMatch[0].replace(/\n\nfunction serviceBadgeText$/, '');
const serviceTextFnSource = serviceTextMatch[0].replace(/\n\nfunction serviceBadgeColor$/, '');
const serviceColorFnSource = serviceColorMatch[0].replace(/\n\nfunction applyServiceState$/, '');
const context = {};
vm.createContext(context);
vm.runInContext(`function _(value) { return value; }\nlet serviceActionInFlight = false; let saveInFlight = false;\n${hostFnSource}\n${editorFnSource}\n${busyFnSource}\n${serviceLabelFnSource}\n${serviceTextFnSource}\n${serviceColorFnSource}\nglobalThis.normalizeHostPortFromAddr = normalizeHostPortFromAddr;\nglobalThis.editorContentForSave = editorContentForSave;\nglobalThis.controlsBusy = controlsBusy;\nglobalThis.serviceToggleLabel = serviceToggleLabel;\nglobalThis.serviceBadgeText = serviceBadgeText;\nglobalThis.serviceBadgeColor = serviceBadgeColor;\nglobalThis.setBusyFlags = (serviceBusy, saveBusy) => { serviceActionInFlight = serviceBusy; saveInFlight = saveBusy; };`, context);

const normalize = context.normalizeHostPortFromAddr;
const editorContentForSave = context.editorContentForSave;
const controlsBusy = context.controlsBusy;
const serviceToggleLabel = context.serviceToggleLabel;
const serviceBadgeText = context.serviceBadgeText;
const serviceBadgeColor = context.serviceBadgeColor;
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
assertEq(serviceToggleLabel(true), 'Stop Service', 'serviceToggleLabel should render running action');
assertEq(serviceToggleLabel(false), 'Start Service', 'serviceToggleLabel should render stopped action');
assertEq(serviceBadgeText(true), 'MihoWRT is running', 'serviceBadgeText should render running badge');
assertEq(serviceBadgeText(false), 'MihoWRT stopped', 'serviceBadgeText should render stopped badge');
assertEq(serviceBadgeColor(true), '#5cb85c', 'serviceBadgeColor should use running color');
assertEq(serviceBadgeColor(false), '#d9534f', 'serviceBadgeColor should use stopped color');
context.setBusyFlags(false, false);
assertEq(String(controlsBusy()), 'false', 'controlsBusy should be false when no action is running');
context.setBusyFlags(true, false);
assertEq(String(controlsBusy()), 'true', 'controlsBusy should be true when service action is running');
context.setBusyFlags(false, true);
assertEq(String(controlsBusy()), 'true', 'controlsBusy should be true when save is running');
EOF

pass "config view helpers"
