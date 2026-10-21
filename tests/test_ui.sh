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
	const n = { tag, attrs: attrs || {}, children: children || [], listeners: {}, classList: { add() {}, remove() {} } };
 n.addEventListener = (type, fn) => { n.listeners[type] = fn; };
 n.appendChild = c => n.children.push(c);
 n.removeChild = c => n.children.splice(n.children.indexOf(c), 1);
 Object.defineProperty(n, 'firstChild', { get: () => n.children[0] });
 return n;
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
	[ { name: 'FB', now: 'a', all: [ 'a', 'b' ], type: 'LoadBalance' }, { name: 'Sel', now: 'a', all: [ 'a' ], type: 'Selector' } ] ]);
const selects = collect(page).filter((n) => n.tag === 'select');
h.assertEq(selects.map((n) => n.attrs.disabled === undefined || n.attrs.disabled === null ? 'on' : 'off').join(','), 'off,on', 'automatic groups are read-only');
h.assert(texts(page).includes('Mihomo spreads connections across these servers'), 'automatic groups explained');
console.log('ok - automatic proxy groups');

const diag = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', {
	E, api, view: { extend: (v) => v }, location: {}
}).module;
page = diag.render([Object.assign({}, base, { running: true, dns_ok: false, policy_active: true, config_valid: true,
	custom_dns_servers: [ '9.9.9.9' ], lists: { dst: 1, src: 0, direct: 0 }, route: {}, errors: [] }), {}]);
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
	tv.lists = { dst: '', src: '', direct: '', direct_src: '' };
	tv.titles = { dst: 'Addresses via proxy' };
	tv.map = { parse: async () => { tv.edited.dst = 'abc'; calls.push('parse'); }, save: async () => calls.push('save') };
	let failed = false;
	await tv.handleSave().catch(() => { failed = true; });
	h.assert(failed, 'save rejects when a list is invalid');
	h.assertEq(calls.join(','), 'parse,upload,upload,upload,upload,apply,notify:danger:"Addresses via proxy" has invalid lines: abc', 'lists applied before map.save; error shown');
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

// Provider-first form and event contracts (Tasks 11-14).
(async () => {
 class Option {
  constructor(name, title, description) { Object.assign(this, { name, title, description, dependencies: [], values: [] }); }
  depends(k, v) { this.dependencies.push([k, v]); }
  value(k, label) { this.values.push([k, label]); }
  remove() {}
  isActive() { return true; }
  renderWidget() { return E('input'); }
 }
 class Flag extends Option {}
 class Map {
  constructor() { this.options = {}; }
  render() { return Promise.resolve(E('form')); }
 }
 // Section children are used to move provider fields next to their flags.
 Map.prototype.section = function() {
  const section = { children: [], tab() {} };
  section.taboption = (tab, Type, name, title, description) => {
   const o = new Type(name, title, description);
   this.options[name] = o; section.children.push(o); return o;
  };
  return section;
 };
 const form = { Map, Flag, Value: Option, DummyValue: Option, ListValue: Option, TextValue: Option, NamedSection: Option };
 let overrides = ['bypass_ntp'];
 const uci = { get: () => overrides, set: (pkg, section, key, value) => { overrides = value; }, unset: () => { overrides = []; } };
 const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
  E, api, view: { extend: v => v }, form, uci, widgets: { DeviceSelect: Option }, rpc: { declare: () => () => Promise.resolve({}) }
 }).module;
 const renderTraffic = async p => {
  await tv.render(['dst', 'src', 'direct', 'devices', p, {}]);
  return tv.map.options;
 };
 let opts = await renderTraffic({ mode: 'direct-first', dns: 'fake-ip', provider: { disable_quic: '0' }, lists: { dst: { provided: true, provider_count: 12, own_count: 3 } } });
 h.assertEq(opts._mode.cfgvalue(), 'Only selected traffic via proxy (set by the subscription: fake-IP whitelist)', 'direct mode reason');
 h.assert(!opts.policy_mode && !opts._direct && !opts._direct_src, 'manual mode and inactive lists absent');
 h.assertEq(opts._prov_disable_quic.cfgvalue(), 'Disabled', 'provider value rendered');
 h.assertEq(opts._prov_disable_quic.description, 'Set by your provider.', 'provider explanation');
 h.assertEq(JSON.stringify(opts.disable_quic.dependencies), '[["_own_disable_quic","1"]]', 'own field dependency');
 h.assertEq(JSON.stringify(opts._prov_disable_quic.dependencies), '[["_own_disable_quic","0"]]', 'provider field dependency');
 h.assert(!opts._own_dns_hijack, 'nonprovider scalar stays plain');
 opts._own_disable_quic.write('settings', '1');
 h.assertEq(overrides.join(','), 'bypass_ntp,disable_quic', 'own flag preserves other entries');
 opts._own_disable_quic.write('settings', '0');
 h.assertEq(overrides.join(','), 'bypass_ntp', 'own flag removes only its entry');
 h.assertEq(JSON.stringify(opts.dst_list_source.values), '[["provider","Provider list (12 entries)"],["merge","Provider list + mine"],["own","Only mine"]]', 'provider sources');
 h.assertEq(opts._dst_note.cfgvalue(), '3 of your entries are not applied.', 'unapplied own entries note');
 h.assertEq(JSON.stringify(opts._dst.dependencies), '[["dst_list_source","merge"],["dst_list_source","own"]]', 'textarea visible for merge and own');
 h.assert(!opts.src_list_source, 'devices always user-owned');
 opts = await renderTraffic({ mode: 'direct-first', dns: 'fake-ip', lists: { dst: { provided: true, own_count: 0 } } });
 h.assert(!opts._dst_note, 'no empty-own note');
 opts = await renderTraffic({ mode: 'proxy-first', dns: 'redir-host', provider: {}, lists: {} });
 h.assertEq(opts._mode.cfgvalue(), 'All traffic via proxy except exclusions (subscription DNS: redir-host)', 'proxy mode reason');
 h.assert(!Object.keys(opts).some(k => k.startsWith('_own_') || k.endsWith('_list_source')), 'no override controls without provider keys');
 h.assert(!opts._direct_src.readonly && !opts._dst && !opts._src, 'redir-host direct devices editable, inactive lists absent');
 opts = await renderTraffic({ mode: 'proxy-first', dns: 'fake-ip' });
 h.assert(opts._direct_src.readonly, 'fake-IP direct devices read-only');
 h.assertEq(opts._direct_src.description, 'Needs subscription DNS mode redir-host or normal.', 'fake-IP hint');
 const uploads = [], writes = [];
 const saved = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
  E, api: Object.assign({}, api, { upload: async (prefix, content) => { uploads.push(content); return content; }, write: async (...args) => writes.push(args) }),
  view: { extend: v => v }, form, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }
 }).module;
 saved.lists = { dst: 'dst', src: 'src', direct: 'direct', direct_src: 'direct_src' };
 saved.map = { parse: async () => { saved.edited.dst = 'edited'; }, save: async () => {} };
 await saved.handleSave();
 h.assertEq(uploads.join(','), 'edited,src,direct,direct_src', 'four uploads in stable order');
 h.assertEq(writes[0].join(','), 'apply-lists,edited,src,direct,direct_src', 'four list paths sent');
 console.log('ok - provider-first Traffic form and save');

 // DOM properties used by subscription events mirror actual browser inputs.
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children);
  n.value = n.attrs.value || (tag === 'textarea' ? (n.children || []).join('') : '');
  n.checked = n.attrs.checked != null;
  return n;
 }
 const subCalls = [], notices = [];
 const subview = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', {
  E: DOM, view: { extend: v => v }, location: { reload() {} },
  api: Object.assign({}, api, { busy: async (el, fn) => fn(), write: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, notify: s => notices.push(s) })
 }).module;
 for (const [on, period, hint] of [
  [true, 12, 'Your provider decides how often (now every 12 h).'],
  [true, 0, 'Your provider does not set an update period, so the subscription is updated only when you press Update now.'],
  [false, 12, 'Only when you press Update now.']
 ]) {
  const p = subview.render([{ url: 'https://p.example/sub', auto_update: on, effective_interval: period }, { content: 'proxies: []' }]);
  const nodes = collect(p), checkbox = nodes.find(n => n.attrs.id === 'mw-auto');
  h.assertEq(checkbox.attrs.type, 'checkbox', 'auto-update checkbox');
  h.assertEq(checkbox.checked, on, 'auto-update checkbox state');
  h.assert(nodes.some(n => n.textContent === hint), 'auto-update explanation ' + hint);
  h.assert(!nodes.some(n => n.attrs.type === 'number'), 'no numeric interval input');
  await nodes.find(n => n.tag === 'button' && texts(n).includes('Save')).listeners.click();
  h.assertEq(subCalls.at(-1).join(','), 'set-subscription,https://p.example/sub,' + (on ? '1' : '0'), 'Save sends boolean');
  await nodes.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(notices.at(-1), 'Subscription is up to date.', 'unchanged update notice');
  h.assert(texts(p).includes('Link to a Clash/Mihomo (YAML) subscription from your provider. Leave empty to manage the YAML yourself.'), 'Clash URL hint');
  h.assert(texts(p).includes('MihoWRT manages ports, routing mark, TUN, the controller and the dashboard itself; those keys are overridden. Updating the subscription, including automatic updates, replaces this file.'), 'Advanced update warning');
 }
 console.log('ok - subscription checkbox, hints, save and unchanged notice');

 const calls = [];
 let reject = false;
 const groupsView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', {
  E, view: { extend: v => v }, location: {}, window: {},
  api: Object.assign({}, api, {
   busy: async (el, fn) => { try { return await fn(); } catch (_) { return undefined; } },
   write: async (...args) => { calls.push(args); if (reject) throw new Error('failed'); return { A: 12, B: 20 }; },
   read: async cmd => { calls.push([cmd]); return [{ name: 'G', type: 'URLTest', now: 'A', fixed: 'A', all: ['A', 'B'] }]; }, notify() {}
  })
 }).module;
 for (const type of ['URLTest', 'Fallback']) {
  const p = groupsView.render([Object.assign({}, base, { running: true, subscription_configured: true }), {}, [{ name: 'G', type, now: 'B', fixed: '', all: ['A','B'] }]]);
  const nodes = collect(p), s = nodes.find(n => n.tag === 'select');
  h.assertEq(s.children[0].attrs.value, '', 'Auto option value');
  h.assertEq(texts(s.children[0]).join(''), 'Auto — B', 'Auto option now label');
  h.assertEq(s.value, '', 'Auto selected');
  h.assert(s.attrs.disabled == null, 'automatic group selectable');
  reject = true; s.value = 'A'; await s.listeners.change();
  h.assertEq(s.value, '', 'failed switch restores prior value');
  reject = false;
  await nodes.find(n => n.tag === 'button' && texts(n).includes('Test')).listeners.click();
  h.assertEq(calls.at(-1)[0], 'proxies-json', 'refresh groups after test');
  h.assertEq(s.value, 'A', 'fresh fixed server selected');
  h.assert(texts(s).some(t => t.includes('12 ms')), 'options rebuilt after test');
 }
 const pinned = groupsView.render([Object.assign({}, base, { subscription_configured: true, running: true }), {}, [{ name: 'G', type: 'URLTest', now: 'B', fixed: 'A', all: ['A','B'] }]]);
 h.assertEq(collect(pinned).find(n => n.tag === 'select').value, 'A', 'initial fixed node selected');
 const p = groupsView.render([Object.assign({}, base, { subscription_configured: true }), { announce: 'Pay: https://p.example/pay now\nhttp://x.example' }, []]);
 const links = collect(p).filter(n => n.tag === 'a' && ['https://p.example/pay','http://x.example'].includes(n.attrs.href));
 h.assertEq(links.length, 2, 'announce HTTP links');
 h.assert(links.every(n => n.attrs.rel === 'noopener noreferrer' && n.attrs.target === '_blank'), 'announce safe link attributes');
 h.assert(texts(p).some(t => t.includes(' now\n')), 'announce newline preserved');
 const unsafe = groupsView.render([Object.assign({}, base, { subscription_configured: true }), { announce: 'javascript:alert(1) <b>x</b>' }, []]);
 h.assert(texts(unsafe).includes('javascript:alert(1) <b>x</b>'), 'unsafe announce plain text');
 h.assert(!collect(unsafe).some(n => n.tag === 'a' && String(n.attrs.href).startsWith('javascript:')), 'no unsafe links');
 console.log('ok - automatic group events and safe announce links');
 for (const valid of [null, false]) {
  const p = diag.render([Object.assign({}, base, { config_valid: valid, config_error: 'bad yaml', dns_mode: 'redir-host' }), { provider: { disable_quic: '0' }, lists: { dst: { provided: true, provider_count: 12 } } }]);
  const t = texts(p);
  if (valid == null) h.assert(t.includes('Configuration not checked yet (it is checked at start)') && t.includes('–'), 'unknown check neutral');
  else h.assert(t.some(s => s.includes('bad yaml')), 'last core error shown');
  for (const label of ['Mode','DNS mode','Provider settings','Provider lists']) h.assert(t.includes(label), 'diagnostic detail ' + label);
 }
 console.log('ok - diagnostics unknown/error and profile details');
})().catch(err => { console.error(err); process.exitCode = 1; });
NODE
