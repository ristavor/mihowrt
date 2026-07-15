#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const harness = require('./tests/js_luci_harness');
const configSource = harness.readSource('rootfs/www/luci-static/resources/view/mihowrt/config.js');
const overviewSource = harness.readSource('rootfs/www/luci-static/resources/view/mihowrt/overview.js');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

assert(!configSource.includes("const updateKernelButton"), 'subscription page should not keep a core update control');
assert(!configSource.includes("const dashboardButton"), 'subscription page should not keep a dashboard control');
assert(overviewSource.includes("const toggleButton = E('button'"), 'overview should render a service start/stop control');
assert(overviewSource.includes("const autostartButton = E('button'"), 'overview should render an autostart control');
assert(overviewSource.includes("const dashboardButton = E('button'"), 'overview should render a dashboard control');
assert(overviewSource.includes("const updateButton = E('button'"), 'overview should render a core update control');
assert(overviewSource.includes("runInitAction(start ? 'start' : 'stop')"), 'overview should start or stop the init service');
assert(overviewSource.includes("current.serviceEnabled ? 'disable' : 'enable'"), 'overview should toggle init autostart');
assert(overviewSource.includes('backendHelper.updateKernel()'), 'overview should delegate core updates to backend validation');
assert(overviewSource.includes('configHelper.openDashboard'), 'overview should use the safe dashboard URL helper');
EOF

pass "service controls live on overview"
