#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(process.cwd(), 'rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js'), 'utf8');

if (!/const refreshSummary = async function\(\) \{\s*renderStatus\(statusFromServiceState\(await backendHelper\.readServiceState\(\)\)\);\s*detailsLoaded = false;\s*\};/.test(source))
	throw new Error('diagnostics refreshSummary should invalidate loaded runtime details after summary-only refresh');

if (!/catch \(e\) \{\s*detailsLoaded = false;\s*setChildren\(runtimeNode, \[ E\('div', \{ class: 'mihowrt-status-error' \}, _\('Failed to load details: %s'\)\.format\(e\.message\)\) \]\);/.test(source))
	throw new Error('diagnostics loadDetails should allow retry after detail load failure');
EOF

pass "diagnostics view helpers"
