#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

command -v node >/dev/null 2>&1 || {
	printf 'skip - ui tests (node missing)\n'
	exit 0
}

node - "$ROOT_DIR" <<'NODE'
const path = require('path');
const h = require(path.join(process.argv[2], 'tests/js_luci_harness.js'));

// E() stub: records nodes. A plain string child would be parsed as HTML by
// LuCI, so the test fails on any non-array children.
function E(tag, attrs, children) {
	if (Array.isArray(attrs) || typeof attrs === 'string') {
		children = attrs;
		attrs = {};
	}
	if (typeof children === 'string')
		throw new Error(`E('${tag}') got a string child: ${children}`);
	return { tag, attrs: attrs || {}, children: children || [], addEventListener() {}, classList: { add() {}, remove() {} } };
}
const ui = { addNotification() {} };
const api = h.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/api.js', { E, ui, fs: {} }).module;

h.assertEq(api.trafficSummary({ upload: 1024, download: 1024 }), '2.0 KiB / Unlimited', 'missing total is unlimited');
h.assertEq(api.trafficSummary({ upload: 0, download: 512, total: 2048 }), '512 B / 2.0 KiB', 'usage and total');
h.assertEq(api.trafficSummary({}), 'Unlimited', 'no usage, no total');
h.assertEq(api.trafficSummary({ total: 1073741824 }), '1.0 GiB', 'total only');
h.assert(api.safeLink('javascript:alert(1)', 'x') === null, 'non-http links are dropped');
h.assertEq(api.safeLink('https://example.com', 'x').attrs.rel, 'noopener noreferrer', 'external links isolated');
console.log('ok - api helpers');

function collect(node, out = []) {
	if (node && typeof node === 'object') {
		out.push(node);
		(node.children || []).forEach((c) => collect(c, out));
	}
	return out;
}
function texts(node) {
	return collect(node).flatMap((n) => n.children.filter((c) => typeof c === 'string'));
}

const overview = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', {
	E, api, view: { extend: (v) => v }, location: {}, window: {}
}).module;
const base = { core_installed: true, subscription_configured: false, running: false, enabled: false, mode: 'direct-first', version: '0.8.0', core: 'v1.19.32' };

let page = overview.render([ base, {}, [] ]);
h.assert(texts(page).includes('Connect a subscription'), 'first-run card shown without subscription');

page = overview.render([ Object.assign({}, base, { core_installed: false }), {}, [] ]);
h.assert(texts(page).includes('Mihomo core is not installed'), 'core card shown when core is missing');

const evil = '<img src=x onerror=alert(1)>';
page = overview.render([ Object.assign({}, base, { subscription_configured: true, running: true }),
	{ profile_title: evil, announce: evil, effective_interval: 24 },
	[ { name: evil, now: 'a', all: [ 'a', evil ] } ] ]);
h.assert(!texts(page).includes('Connect a subscription'), 'first-run card hidden with subscription');
h.assert(texts(page).filter((t) => t === evil).length >= 3, 'provider text rendered as text nodes');
console.log('ok - overview render');

const diag = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', {
	E, api, view: { extend: (v) => v }, location: {}
}).module;
page = diag.render(Object.assign({}, base, { running: true, dns_ok: false, policy_active: true, config_valid: true,
	custom_dns_servers: [ '9.9.9.9' ], lists: { dst: 1, src: 0, direct: 0 }, route: {}, errors: [] }));
const all = texts(page);
h.assert(all.includes('Mihomo answers DNS queries'), 'DNS check listed');
h.assert(all.some((t) => t.includes('9.9.9.9')), 'custom dnsmasq server warning');
h.assert(all.includes('Problem:'), 'failures are announced in text, not only by symbol');
console.log('ok - diagnostics checklist');
NODE
