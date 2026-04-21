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

if (!emptyConfigMatch)
	throw new Error('emptyConfigState() not found');
if (!emptyStatusMatch)
	throw new Error('emptyStatusState() not found');

const emptyConfigFnSource = emptyConfigMatch[0].replace(/\n\nfunction emptyStatusState$/, '');
const emptyStatusFnSource = emptyStatusMatch[0].replace(/\n\nfunction emptyLogState$/, '');
const context = {};
vm.createContext(context);
vm.runInContext(`${emptyConfigFnSource}\n${emptyStatusFnSource}\nglobalThis.emptyStatusState = emptyStatusState;`, context);

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
EOF

pass "backend helpers"
