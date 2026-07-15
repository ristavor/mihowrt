#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(process.cwd(), 'rootfs/www/luci-static/resources/view/mihowrt/policy.js'), 'utf8');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

assert(source.includes("new form.Map('mihowrt', _('Traffic Settings')"), 'policy page should use a user-facing traffic settings title');
assert(source.includes("network.getDevices()"), 'policy page should discover active router interfaces');
assert(source.includes("device?.getName?.()"), 'policy page should add discovered device names to the interface selector');
assert(source.includes("form.DynamicList, 'source_network_interfaces'"), 'policy page should retain manual interface entry alongside discovered choices');
assert(source.includes("s.option(form.Button, '_update_remote_lists'"), 'policy page should provide manual remote list updates');
assert(source.includes("URL[;port] | update hours"), 'policy page should document per-URL update intervals');
assert(source.includes("backendHelper.syncPolicyRemoteAutoUpdate()"), 'saving changed lists should refresh their scheduled updates');
assert(!source.includes('route_table_id'), 'policy page should not expose a route table override');
assert(!source.includes('route_rule_priority'), 'policy page should not expose a route priority override');
assert(!source.includes('policy_remote_update_interval'), 'policy page should not expose the removed global list interval');
assert(!source.includes('const toolbar = E('), 'policy page should keep the manual update action near the lists');
EOF

pass "traffic settings view"
