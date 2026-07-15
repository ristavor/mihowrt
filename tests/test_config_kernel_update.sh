#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(process.cwd(), 'rootfs/www/luci-static/resources/view/mihowrt/overview.js'), 'utf8');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

assert(source.includes('backendHelper.updateKernel()'), 'overview should invoke validated core updates through the backend');
assert(source.includes('backendHelper.readCoreVersion()'), 'overview should refresh the displayed core version after update');
assert(source.includes('result.updated && result.restartRequired && serviceState.serviceRunning'), 'overview should restart only a running service after a core update');
assert(source.includes('backendHelper.restartValidatedService()'), 'overview should use the validated restart path');
assert(source.includes("_('Mihomo core updated to %s.')"), 'overview should report successful core updates');
assert(source.includes("_('Mihomo core is up to date (%s).')"), 'overview should report an already-current core');
assert(source.includes("_('Unable to update Mihomo core: %s')"), 'overview should report update failures');
EOF

pass "overview core update flow"
