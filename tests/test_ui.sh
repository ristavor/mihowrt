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

page = overview.render([ Object.assign({}, base, { subscription_configured: true, running: true }), {},
	[ { name: 'FB', now: 'a', all: [ 'a', 'b' ], auto: true }, { name: 'Sel', now: 'a', all: [ 'a' ], auto: false } ] ]);
const selects = collect(page).filter((n) => n.tag === 'select');
h.assertEq(selects.map((n) => n.attrs.disabled === undefined || n.attrs.disabled === null ? 'on' : 'off').join(','), 'off,on', 'automatic groups are read-only');
h.assert(texts(page).includes('Chosen automatically by Mihomo'), 'automatic groups explained');
console.log('ok - automatic proxy groups');

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

// Device picker: themes with custom dropdowns (footstrap fs-select) re-send
// "change" with the same value after the picker resets the select.
function EL(tag, attrs, children) {
	const n = E(tag, attrs, children);
	n.listeners = {};
	n.addEventListener = (type, fn) => { n.listeners[type] = fn; };
	n.appendChild = (c) => { n.children.push(c); };
	return n;
}
const traffic = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
	E: EL, api, view: { extend: (v) => v }, form: {}, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }, Event
}).module;
const area = { value: '# devices\n192.168.1.5\n', dispatchEvent() {} };
const widget = { querySelector: (q) => q === 'textarea' ? area : null };
const picked = traffic.addLeasePicker(widget, { dhcp_leases: [ { hostname: 'pc', ipaddr: '192.168.1.151' }, { ipaddr: '192.168.1.5' } ] });
h.assert(picked.children[0] === widget, 'picker wraps the LuCI widget (survives form re-render)');
const select = picked.children[1].children[0];
for (let i = 0; i < 2; i++) {
	select.value = '192.168.1.151';
	select.listeners.change();
}
select.value = '192.168.1.5';
select.listeners.change();
h.assertEq(area.value, '# devices\n192.168.1.5\n192.168.1.151\n', 'device added once, existing device not repeated');
h.assertEq(select.value, '', 'picker resets to the prompt even for a repeated device');
console.log('ok - traffic device picker');

const hours = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, style: {} };
const hoursWidget = { querySelector: (q) => q === 'input' ? hours : null };
const refreshBtn = { tag: 'button' };
const intervalRow = traffic.intervalField(hoursWidget, refreshBtn);
h.assertEq(JSON.stringify(hours.attrs), '{"type":"number","min":"0","max":"8760"}', 'list interval is a number field like the subscription one');
h.assert(intervalRow.children[0] === hoursWidget && intervalRow.children[1] === refreshBtn, 'refresh button sits next to the interval');
console.log('ok - traffic interval field');

// Saving: a rejected list keeps the form (no map.save) and shows the error.
(async () => {
	const calls = [];
	const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
		E: EL, view: { extend: (v) => v }, form: {}, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }, Event,
		api: Object.assign({}, api, {
			upload: async (prefix, c) => { calls.push('upload'); return '/tmp/x'; },
			write: async () => { calls.push('apply'); throw new Error('Invalid dst entries: abc'); },
			notify: (msg, level) => calls.push('notify:' + level + ':' + msg)
		})
	}).module;
	tv.lists = { dst: '', src: '', direct: '' };
	tv.titles = { dst: 'Addresses via proxy' };
	tv.map = { parse: async () => { tv.edited.dst = 'abc'; calls.push('parse'); }, save: async () => calls.push('save') };
	let failed = false;
	await tv.handleSave().catch(() => { failed = true; });
	h.assert(failed, 'save rejects when a list is invalid');
	h.assertEq(calls.join(','), 'parse,upload,upload,upload,apply,notify:danger:"Addresses via proxy" has invalid lines: abc', 'lists applied before map.save; error shown');
	console.log('ok - traffic save order');
})();

// Dashboard link: the setup route makes zashboard use the given secret even
// when the browser stores an older backend for the same host and port.
let opened = '';
const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', {
	E: EL, view: { extend: (v) => v }, location: {}, window: { open: (url) => { opened = url; } },
	api: Object.assign({}, api, { busy: (b, fn) => fn(), write: async () => ({ host: '192.168.1.1', port: 9090, secret: 'a b', running: true }) })
}).module;
const dash = collect(ov.render([ Object.assign({}, base, { subscription_configured: true, running: true }), {}, [] ]))
	.find((n) => n.tag === 'button' && texts(n).includes('Open dashboard'));
Promise.resolve(dash.listeners.click()).then(() => {
	h.assertEq(opened, 'http://192.168.1.1:9090/ui/#/setup?hostname=192.168.1.1&port=9090&secret=a%20b', 'dashboard opens the setup route');
	console.log('ok - dashboard link');
});
NODE
