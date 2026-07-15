#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(process.cwd(), 'rootfs/www/luci-static/resources/view/mihowrt/overview.js'), 'utf8');
const safeUrlMatch = source.match(/function safeExternalUrl[\s\S]*?\n}\n\nfunction externalButton/);
const numericMatch = source.match(/function numericHeader[\s\S]*?\n}\n\nfunction formatBytes/);
const bytesMatch = source.match(/function formatBytes[\s\S]*?\n}\n\nfunction subscriptionTraffic/);
const trafficMatch = source.match(/function subscriptionTraffic[\s\S]*?\n}\n\nfunction formatEpoch/);
const intervalMatch = source.match(/function intervalText[\s\S]*?\n}\n\nfunction serviceStateError/);

for (const [name, match] of Object.entries({ safeUrlMatch, numericMatch, bytesMatch, trafficMatch, intervalMatch })) {
	if (!match)
		throw new Error(`${name} not found`);
}

const context = { URL, Number, Math };
vm.createContext(context);
vm.runInContext(`
function _(value) { return value; }
if (!String.prototype.format) {
	String.prototype.format = function() { let i = 0; const args = arguments; return this.replace(/%s/g, () => String(args[i++])); };
}
${safeUrlMatch[0].replace(/\n\nfunction externalButton$/, '')}
${numericMatch[0].replace(/\n\nfunction formatBytes$/, '')}
${bytesMatch[0].replace(/\n\nfunction subscriptionTraffic$/, '')}
${trafficMatch[0].replace(/\n\nfunction formatEpoch$/, '')}
${intervalMatch[0].replace(/\n\nfunction serviceStateError$/, '')}
globalThis.safeExternalUrl = safeExternalUrl;
globalThis.subscriptionTraffic = subscriptionTraffic;
globalThis.intervalText = intervalText;
`, context);

function assertEq(actual, expected, message) {
	if (actual !== expected)
		throw new Error(`${message}: expected ${expected}, got ${actual}`);
}

assertEq(context.safeExternalUrl('https://t.me/happ_chat'), 'https://t.me/happ_chat', 'support links should keep HTTPS URLs');
assertEq(context.safeExternalUrl('javascript:alert(1)'), '', 'overview should reject unsafe support links');
const traffic = context.subscriptionTraffic({ upload: '10', download: '20', total: '0' });
assertEq(traffic.used, '30 B', 'overview should sum upload and download traffic');
assertEq(traffic.total, 'Unlimited', 'overview should treat total=0 as unlimited traffic');
assertEq(traffic.remaining, 'Unlimited', 'overview should keep unlimited traffic remaining');
assertEq(context.intervalText({ subscriptionUrl: '', subscriptionEffectiveInterval: '24' }), 'Disabled: no subscription URL', 'overview should disable auto-update without a URL');
assertEq(context.intervalText({ subscriptionUrl: 'https://example.com/sub', subscriptionEffectiveInterval: '12', subscriptionIntervalOverride: true }), '12 hours (manual)', 'overview should distinguish a manual interval override');

if (!source.includes("subscription.profileTitle || _('Subscription')"))
	throw new Error('overview should fall back to Subscription title');
if (!source.includes('subscription.announce'))
	throw new Error('overview should render provider announcements when present');
EOF

pass "overview subscription helpers"
