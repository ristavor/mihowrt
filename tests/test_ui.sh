#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

command -v node >/dev/null 2>&1 || {
	printf 'skip - ui tests (node missing)\n'
	exit 0
}

node "$ROOT_DIR/tests/js_api.js"

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
 n.setAttribute = (k, v) => { n.attrs[k] = v; };
 n.addEventListener = (type, fn) => { n.listeners[type] = fn; };
 n.appendChild = c => n.children.push(c);
 n.removeChild = c => n.children.splice(n.children.indexOf(c), 1);
 n.replaceChildren = (...nodes) => { n.children = nodes; };
 Object.defineProperty(n, 'textContent', { get: () => n.children.filter(c => typeof c === 'string').join(''), set: value => { n.children = [value]; } });
 Object.defineProperty(n, 'firstChild', { get: () => n.children[0] });
 return n;
}
// Async blocks share stubs (reads, notices): run them one after another.
let chain = Promise.resolve();
const seq = fn => (chain = chain.then(fn));
const textareaOptions = [];
const ui = { addNotification() {}, Textarea: class {
 constructor(value, options) { this.value = value; this.options = options; textareaOptions.push(options); }
 render() {
  const area = E('textarea', { id: 'widget.' + this.options.id, class: 'cbi-input-textarea' }, [this.value]);
  area.value = this.value;
  area.classList.add = cls => { area.attrs.class = [area.attrs.class, cls].filter(Boolean).join(' '); };
  const wrapper = E('div', { id: this.options.id }, [area]);
  wrapper.querySelector = selector => selector === 'textarea' ? area : null;
  return wrapper;
 }
} };
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
function findButton(node, label) { return collect(node).find((n) => n.tag === 'button' && texts(n).includes(label)); }
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
// The Subscription view's load()/render() data shape is not part of the contract:
// views are mounted through load() with stubbed api.read/api.readLarge.
const reads = { calls: [], sub: {}, status: {}, responses: {} };
function resetReads(sub = {}, config = { content: 'proxies: []\n' }, status = {}) {
	Object.assign(reads, { calls: [], sub, status, responses: { 'read-config': config, 'runtime-config': { content: '', generated: false } } });
}
const readStubs = {
	read: async (cmd) => {
		reads.calls.push(cmd);
		if (cmd === 'subscription-json') return reads.sub;
		if (cmd === 'status-json') return reads.status;
		throw Error('unexpected read ' + cmd);
	},
	readLarge: async (cmd) => {
		reads.calls.push(cmd);
		if (!(cmd in reads.responses)) throw Error('unexpected readLarge ' + cmd);
		const reply = reads.responses[cmd];
		if (reply instanceof Error) throw reply;
		return reply;
	}
};
async function mountSubscription(view, sub, config, status) {
	resetReads(sub, config, status);
	return view.render(await view.load());
}
async function openToggle(page, label) { await findButton(page, label).listeners.click(); await settle(); }
function toggleOf(page, button) { return collect(page).find((n) => n.attrs.class === 'mw-toggle' && collect(n).includes(button)); }

api.jobNotice = () => E('div', { 'aria-live': 'polite' });

const overview = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { poll: { add() {} },
	E, api, view: { extend: (v) => v }, location: {}, window: {}
}).module;
const base = { core_installed: true, subscription_configured: false, running: false, enabled: false, mode: 'direct-first', version: '0.8.0', core: 'v1.19.32' };

{
	const running = { ...base, subscription_configured: true, running: true };
	const rowValue = (sub) => { const nodes = collect(overview.render([ running, sub, [] ])); return nodes.map(n => n.children.filter(c => typeof c === 'string')).flat(); };
	h.assert(rowValue({ auto_update: true, effective_interval: 0 }).includes('On, but the subscription does not send an update period'), 'auto-update on without a period');
	h.assert(rowValue({ auto_update: false, effective_interval: 0 }).includes('Off'), 'auto-update off');
	h.assert(rowValue({ auto_update: true, effective_interval: 6 }).includes('every 6 h'), 'auto-update period');
}
let page = overview.render([ base, {}, [] ]);
h.assert(texts(page).includes('Connect a subscription'), 'first-run card shown without subscription');
const firstUrl = collect(page).find(n => n.attrs.id === 'mw-sub-url');
h.assertEq(firstUrl.attrs.type, 'text', 'theme-native first-run text input');
h.assertEq(firstUrl.attrs.inputmode, 'url', 'first-run URL keyboard');

page = overview.render([ Object.assign({}, base, { core_installed: false }), {}, [] ]);
h.assert(texts(page).includes('Mihomo core is not installed'), 'core card shown when core is missing');
h.assert(texts(page).includes('MihoWRT needs the Mihomo core (about 20 MB download, about 55 MB unpacked; less on compressing flash file systems).'), 'core card states download and unpacked size');

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

// DOM helper shared by Traffic controls and dashboard events.
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
const hours = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, style: {} };
const hoursWidget = { querySelector: (q) => q === 'input' ? hours : null };
const refreshBtn = { tag: 'button' };
const intervalRow = traffic.intervalField(hoursWidget, refreshBtn);
h.assertEq(JSON.stringify(hours.attrs), '{"inputmode":"numeric"}', 'list interval is a number field like the subscription one');
h.assert(intervalRow.children[0] === hoursWidget && intervalRow.children[1] === refreshBtn, 'refresh button sits next to the interval');
console.log('ok - traffic interval field');

// Saving: a rejected list keeps the form (no map.save) and shows the error.
seq(async () => {
	const calls = [];
	const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
		E: EL, view: { extend: (v) => v }, form: {}, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }, Event,
		api: Object.assign({}, api, {
			upload: async (prefix, c) => { calls.push('upload'); return '/tmp/x'; },
			job: async () => { calls.push('apply'); throw new Error('Invalid dst entries: abc'); },
			notify: (msg, level) => calls.push('notify:' + level + ':' + msg)
		})
	}).module;
	tv.lists = { dst: '', src: '', direct: '', direct_src: '' };
	tv.titles = { dst: 'Addresses via proxy' };
	tv.map = { parse: async () => { tv.edited.dst = 'abc'; calls.push('parse'); }, save: async () => calls.push('save') };
	let failed = false;
	await tv.handleSaveApply().catch(() => { failed = true; });
	h.assert(failed, 'save rejects when a list is invalid');
	h.assertEq(calls.join(','), 'parse,upload,apply,notify:error:"Addresses via proxy" has invalid lines: abc', 'lists applied before map.save; error shown');
	console.log('ok - traffic save order');
});

// Dashboard link: the setup route makes zashboard use the given secret even
// when the browser stores an older backend for the same host and port.
let opened = '';
const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { poll: { add() {} },
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
seq(async () => {
 class Option {
  constructor(name, title, description) { Object.assign(this, { name, title, description, dependencies: [], values: [] }); }
  depends(k, v) { this.dependencies.push([k, v]); }
  value(k, label) { this.values.push([k, label]); }
  remove() {}
  isActive() { return true; }
  renderWidget() { const n = E('input'); n.querySelector = () => n; return n; }
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
  await tv.render([{ dst: 'dst', src: 'src', direct: 'direct', direct_src: 'devices' }, p, {}]);
  for (const name of ['_dst', '_src', '_direct', '_direct_src']) {
   if (tv.map.options[name]) h.assertEq(tv.map.options[name].monospace, true, name + ' native TextValue monospace');
  }
  return tv.map.options;
 };
 let opts = await renderTraffic({ mode: 'direct-first', dns: 'fake-ip', provider: { disable_quic: '0' }, lists: { dst: { provided: true, provider_count: 12, own_count: 3 } } });
 h.assertEq(opts._mode.cfgvalue(), 'Only selected traffic via proxy (chosen by your subscription)', 'mode value is only the label and its reason');
 h.assert(opts._mode.description.startsWith('To change the mode'), 'mode help is the option description');
 h.assert(!opts.policy_mode && !opts._direct && !opts._direct_src, 'manual mode and inactive lists absent');
 h.assertEq(opts._prov_disable_quic.cfgvalue(), 'Disabled', 'provider value rendered');
 h.assertEq(opts._prov_disable_quic.description, 'Set by your provider.', 'provider explanation');
 h.assertEq(opts._provoff_disable_quic?.cfgvalue(), 'Disabled', 'provider visible with override');
 h.assertEq(JSON.stringify(opts._provoff_disable_quic?.dependencies), '[["_own_disable_quic","1"]]', 'override provider dependency');
 h.assertEq(opts.disable_quic.title, 'My value', 'own option title');
 // The native widget is wrapped by extendWidget; inspect its rendered input.
 const flagNode = opts._own_disable_quic.renderWidget();
 h.assertEq(flagNode.attrs['aria-label'], 'Use my own value for "Block QUIC for proxied traffic"', 'flag accessible name');
 h.assertEq(JSON.stringify(opts.disable_quic.dependencies), '[["_own_disable_quic","1"]]', 'own field dependency');
 h.assertEq(JSON.stringify(opts._prov_disable_quic.dependencies), '[["_own_disable_quic","0"]]', 'provider field dependency');
 h.assert(!opts._own_dns_hijack, 'nonprovider scalar stays plain');
 opts._own_disable_quic.write('settings', '1');
 h.assertEq(overrides.join(','), 'bypass_ntp,disable_quic', 'own flag preserves other entries');
 opts._own_disable_quic.write('settings', '0');
 h.assertEq(overrides.join(','), 'bypass_ntp', 'own flag removes only its entry');
 h.assertEq(JSON.stringify(opts.dst_list_source.values), '[["provider","Provider list (12 entries)"],["merge","Provider list + mine"],["own","Only mine"]]', 'provider sources');
 h.assert(!opts._dst_note, 'no separate note row');
 h.assertEq(opts.dst_list_source.description, 'Set by your provider. You also have 3 own entries: they apply with "Provider list + mine" or "Only mine".', 'own entries description');
 h.assertEq(JSON.stringify(opts._dst.dependencies), '[["dst_list_source","merge"],["dst_list_source","own"]]', 'textarea visible for merge and own');
 h.assert(!opts.src_list_source, 'devices always user-owned');
 h.assertEq(opts._dst.title, 'My entries', 'provider-owned list editor caption');
 opts = await renderTraffic({ mode: 'direct-first', dns: 'fake-ip', lists: { dst: { provided: true, own_count: 0 } } });
 h.assert(!opts._dst_note, 'no empty-own note');
 opts = await renderTraffic({ mode: 'proxy-first', dns: 'redir-host', provider: {}, lists: {} });
 h.assertEq(opts._mode.cfgvalue(), 'All traffic via proxy except exclusions (chosen by your subscription)', 'proxy mode reason');
 h.assert(!Object.keys(opts).some(k => k.startsWith('_own_') || k.endsWith('_list_source')), 'no override controls without provider keys');
 h.assert(!opts._direct_src.readonly && !opts._dst && !opts._src, 'redir-host direct devices editable, inactive lists absent');
 opts = await renderTraffic({ mode: 'proxy-first', dns: 'fake-ip' });
 h.assert(!opts._direct_src && opts._direct_src_off instanceof form.DummyValue, 'fake-IP has no textarea');
 h.assertEq(opts._direct_src_off?.cfgvalue(), 'Not available with this subscription (it uses fake-IP DNS). Saved: 1 entry.', 'fake-IP saved count');
 const uploads = [], writes = [];
 const saved = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
  E, api: Object.assign({}, api, { upload: async (prefix, content) => { uploads.push(content); return content; }, job: async (...args) => writes.push(args), notify() {} }),
  uci: { changes: async () => ({}) }, ui, view: { extend: v => v }, form, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }
 }).module;
 saved.lists = { dst: 'dst', src: 'src', direct: 'direct', direct_src: 'direct_src' };
 saved.map = { parse: async () => { saved.edited.dst = 'edited'; }, save: async () => {} };
 await saved.handleSaveApply();
 h.assertEq(uploads.join(','), 'edited', 'only edited list uploaded');
 h.assertEq(writes[0].join(','), 'apply-lists,edited,-,-,-', 'unchanged list placeholders sent');
 for (const count of [1, 2, 5]) {
  const pluralOpts = await renderTraffic({ mode: 'proxy-first', dns: 'fake-ip', lists: { direct: { provided: true, provider_count: count, own_count: count } } });
  h.assertEq(pluralOpts.direct_list_source.values[0][1], `Provider list (${count} ${count === 1 ? 'entry' : 'entries'})`, 'provider list plural ' + count);
  h.assert(pluralOpts.direct_list_source.description.includes(count === 1 ? '1 own entry:' : count + ' own entries:'), 'own entries plural ' + count);
 }
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
  E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} },
  api: Object.assign({}, api, readStubs, { busy: async (el, fn) => fn(), write: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, job: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, notify: s => notices.push(s), reloadWithNotice: s => notices.push(s) })
 }).module;
 for (const [on, period, hint] of [
  [true, 12, 'Your provider decides how often (now every 12 h).'],
  [true, 0, 'Your provider does not set an update period, so the subscription is updated only when you press Update now.'],
  [false, 12, 'Only when you press Update now.']
 ]) {
  const p = await mountSubscription(subview, { url: 'https://p.example/sub', auto_update: on, effective_interval: period });
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
 // Exercise the widget contract and handlers using the actual returned textarea.
 const yamlUploads = [], confirmations = [];
 let allowUpdate = false;
 const yamlView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', {
  E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} },
  confirm: message => { confirmations.push(message); return allowUpdate; },
  api: { ...api, ...readStubs, busy: async (el, fn) => fn(), upload: async (...args) => { yamlUploads.push(args); return '/tmp/yaml'; },
   write: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, job: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, notify: message => notices.push(message), reloadWithNotice: message => notices.push(message) }
 }).module;
 const yamlPage = await mountSubscription(yamlView, { url: 'https://p.example/sub' });
 await openToggle(yamlPage, 'Show the YAML editor');
 const yamlNodes = collect(yamlPage);
 const yaml = yamlNodes.find(n => n.tag === 'textarea');
 h.assertEq(textareaOptions.at(-1)?.monospace, true, 'YAML ui.Textarea monospace');
 h.assertEq(textareaOptions.at(-1)?.wrap, false, 'YAML ui.Textarea no wrap');
 h.assert(yamlNodes.some(n => n.attrs.id === 'mw-yaml' && n.children.includes(yaml)), 'YAML widget id');
 h.assertEq(yaml.attrs.id, 'widget.mw-yaml', 'LuCI textarea id');
 h.assert(yaml.attrs.class.split(' ').includes('mw-yaml'), 'YAML editor class');
 h.assertEq(yaml.value, 'proxies: []\n', 'YAML content initialized');
 yaml.value = 'proxies: []\n# edited';
 await yamlNodes.find(n => n.tag === 'button' && texts(n).includes('Check and apply')).listeners.click();
 h.assertEq(yamlUploads.at(-1).join(','), 'mihowrt-config,' + yaml.value, 'apply uploads live YAML textarea value');
 h.assertEq(subCalls.at(-1).join(','), 'save-config,/tmp/yaml', 'apply saves uploaded YAML');
 h.assertEq(notices.at(-1), 'Configuration is unchanged.', 'unchanged apply notice');
 subCalls.length = 0;
 const updateYaml = yamlNodes.find(n => n.tag === 'button' && texts(n).includes('Update now'));
 await updateYaml.listeners.click();
 h.assertEq(confirmations.at(-1), 'Updating replaces your unsaved YAML edits. Continue?', 'Update now detects unsaved YAML');
 h.assertEq(subCalls.length, 0, 'cancel leaves YAML edits intact');
 allowUpdate = true; await updateYaml.listeners.click();
 h.assert(subCalls.some(c => c[0] === 'update-subscription'), 'confirmed update proceeds');
 for (const [action, msg] of [['unchanged', 'Subscription is up to date.'], ['hot_reloaded', 'Subscription updated and applied.'], ['saved', 'Subscription updated.']]) {
  notices.length = 0;
  const view = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', {
   E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} }, confirm: () => true,
   api: { ...api, ...readStubs, busy: async (el, fn) => fn(), job: async () => ({ action }), write: async () => ({}), reloadWithNotice: m => notices.push(m) }
  }).module;
  const ns = collect(await mountSubscription(view, { url: 'https://p.example/sub' }));
  await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(JSON.stringify(notices), JSON.stringify([msg]), 'update notice ' + action);
 }
 console.log('ok - YAML native monospace widget, live upload and unsaved edits');
 console.log('ok - subscription checkbox, hints, save and unchanged notice');

 const calls = [];
 let reject = false;
 const groupsView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { poll: { add() {} },
  E, view: { extend: v => v }, location: {}, window: {},
  api: Object.assign({}, api, {
   busy: async (el, fn) => { try { return await fn(); } catch (_) { return undefined; } },
   write: async (...args) => { calls.push(args); if (reject) throw new Error('failed'); return { A: 12, B: 20 }; },
   readLarge: async cmd => { calls.push([cmd]); return [{ name: 'G', type: 'URLTest', now: 'A', fixed: 'A', all: ['A', 'B'] }]; }, notify() {}
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
}).catch(err => { console.error(err); process.exitCode = 1; });

// Design-review regression cases use the rendered DOM and real event handlers.
seq(async () => {
 h.assertEq(api.safeLink('https://example.org', 'Support', 'cbi-button').attrs.class, 'cbi-button', 'safeLink theme class');
 const messages = {
  http_404: 'not found (HTTP 404)', http_401: 'refused access (HTTP 401)', http_403: 'refused access (HTTP 403)',
  http_500: 'error (HTTP 500)', network: 'cannot reach', too_large: 'too large', invalid_url: 'starts with https://'
 };
 for (const [code, expected] of Object.entries(messages))
  h.assert(api.subscriptionError('Subscription download failed: ' + code).includes(expected), 'subscription error ' + code);
 h.assertEq(api.subscriptionError('unrelated'), 'unrelated', 'unrelated errors preserved');
 const content = E('pre'); let opens = 0;
 const toggle = api.toggle('Show', 'Hide', content, () => opens++), button = collect(toggle).find(n => n.tag === 'button');
 h.assert(content.hidden && button.attrs['aria-expanded'] === 'false', 'toggle initially hidden');
 button.listeners.click(); h.assert(!content.hidden && button.attrs['aria-expanded'] === 'true' && opens === 1, 'toggle opens and loads');
 button.listeners.click(); h.assert(content.hidden && opens === 1, 'toggle closes without loading');
 button.listeners.click(); h.assertEq(opens, 2, 'toggle reloads on reopen');
 const dates = [];
 class LocaleDate extends Date { toLocaleString(...args) { dates.push(args); return 'date'; } }
 const dateApi = h.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/api.js', { E, ui, fs: {}, Date: LocaleDate, document: { documentElement: { lang: 'ru' } } }).module;
 dateApi.formatDate(1700000000);
 h.assertEq(JSON.stringify(dates[0]), '["ru",{"dateStyle":"medium","timeStyle":"short"}]', 'date uses document language');
 const active = { ...base, subscription_configured: true, running: true };
 const groups = ['⚖️ Балансировка', '⚡ Самый быстрый'].map(name => ({ name, type: 'LoadBalance', now: null, all: ['A'] }));
 const groupNodes = collect(overview.render([active, {}, groups]));
 h.assertEq(groupNodes.filter(n => n.tag === 'select').map(n => n.attrs.id).join(','), 'mw-group-0,mw-group-1', 'unique indexed ids');
 h.assert(groupNodes.filter(n => n.tag === 'select').every(n => n.value === '' && texts(n.children[0])[0] === 'All servers in turn'), 'LoadBalance placeholder selected');
 h.assert(groupNodes.filter(n => n.tag === 'button' && texts(n).includes('Test')).every((n, i) => n.attrs['aria-label'] === 'Test servers of ' + groups[i].name), 'Test accessible names');
 const missing = overview.render([{ ...base, core_installed: false }, {}, []]);
 h.assertEq(collect(missing).filter(n => n.tag === 'button').length, 1, 'missing core only install button');
 const manual = overview.render([{ ...active, subscription_configured: false }, {}, []]);
 h.assert(texts(manual).includes('No subscription: MihoWRT uses the YAML entered on the Subscription page.') && !collect(manual).some(n => n.attrs.id === 'mw-sub-url'), 'manual YAML one-line hint');
 h.assert(texts(overview.render([{ ...base, config_valid: false }, {}, []])).includes('Stopped: the configuration has errors — see Diagnostics'), 'invalid config headline');
 for (const [sub, expected] of [
  [{ expire: 1 }, 'The subscription has expired. Renew it with your provider.'],
  [{ expire: Date.now()/1000 + 86400 }, 'The subscription expires on'],
  [{ total: 100, download: 90 }, 'Over 90% of the subscription traffic is used.'],
  [{ total: 100, upload: 100 }, 'The subscription traffic is used up.']
 ]) h.assert(texts(overview.render([active, sub, []])).some(t => t.includes(expected)), 'subscription warning ' + expected);
 h.assert(!collect(diag.render([base, {}])).some(n => n.tag === 'ul' || n.tag === 'li'), 'checklist without bullets');
 const translated = [];
 const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', { E, api, view: { extend: v => v }, _: s => { translated.push(s); return s; } }).module;
 const dp = dv.render([{ ...base, config_valid: false, config_error: 'level=info msg="noise"\nlevel=error msg="bad proxy"\nconfiguration file /tmp/x test failed', route: { table: 100, priority: 10 } }, { provider: { dns_hijack: '1', disable_quic: '0' } }]);
 h.assert(texts(dp).includes('Configuration has errors'), 'negative config wording');
 h.assert(texts(dp).some(t => t.includes('Mihomo says: bad proxy') && !t.includes('noise') && !t.includes('/tmp/')), 'core error extraction');
 h.assert(texts(dp).includes('dns_hijack, disable_quic'), 'provider names');
 h.assert(translated.includes('%s (priority %s)'), 'priority translated');
 const calls = [], notices = [];
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { poll: { add() {} }, E, view: { extend: v => v }, api: { ...api,
  busy: (el, fn) => fn(), write: async (...args) => { calls.push(args); return { A: 10, B: 2 }; }, readLarge: async () => [], notify: s => notices.push(s)
 } }).module;
 const gp = ov.render([active, {}, [{ name: 'G', type: 'Selector', now: 'A', all: ['A','B'] }]]);
 const gs = collect(gp).find(n => n.tag === 'select');
 gs.value = 'B'; await gs.listeners.change(); await gs.listeners.change();
 h.assertEq(calls.length, 1, 'footstrap repeated change ignored'); h.assertEq(notices.length, 0, 'server switch adds no page notification');
 await collect(gp).find(n => n.tag === 'button' && texts(n).includes('Test')).listeners.click();
 h.assertEq(notices.length, 0, 'latency test adds no page notification');
 const pingOf = (root, i = 0) => collect(root).filter(n => /\bmw-ping\b/.test(n.attrs.class || ''))[i];
 const shown = n => n.textContent !== undefined ? n.textContent : texts(n).join('');
 h.assertEq(shown(pingOf(gp)), '2 ms', 'ping of the current server after test');
 h.assertEq(texts(gs.children.find(o => o.attrs.value === 'A')).join(''), 'A — 10 ms', 'options keep per-server latency');
 h.assertEq(gs.attrs['aria-describedby'], pingOf(gp).attrs.id, 'select described by its ping');
 const live = collect(gp).find(n => n.attrs['aria-live'] === 'polite' && /\bmw-sr\b/.test(n.attrs.class || ''));
 h.assert(live && /\bmw-sr\b/.test(live.attrs.class), 'one invisible live region');
 h.assertEq(shown(live), 'G: B — 2 ms', 'test result announced');
 // Mihomo history: shown before any test, nothing when absent.
 const hp = ov.render([active, {}, [
  { name: 'U', type: 'URLTest', now: 'A', fixed: '', all: ['A', 'B'], delays: { A: 12, B: 0 } },
  { name: 'S', type: 'Selector', now: 'B', all: ['A', 'B'], delays: { A: 7 } },
  { name: 'N', type: 'Selector', now: 'C', all: ['C'] },
  { name: 'L', type: 'LoadBalance', now: null, all: ['A', 'B', 'C'], delays: { A: 5, B: 0, C: 9 } }
 ]]);
 const hs = collect(hp).filter(n => n.tag === 'select');
 h.assertEq(shown(pingOf(hp, 0)), '12 ms', 'history ping of the auto-chosen server');
 h.assertEq(texts(hs[0].children[0]).join(''), 'Auto — A', 'Auto option without latency');
 h.assertEq(texts(hs[0].children[2]).join(''), 'B — no response', 'failed history check');
 h.assertEq(shown(pingOf(hp, 1)), '', 'no history for the current server: empty');
 h.assertEq(texts(hs[1].children[0]).join(''), 'A — 7 ms', 'history latency in options');
 h.assertEq(shown(pingOf(hp, 2)), '', 'no history: empty ping');
 const lbStatus = collect(hp).find(n => n.attrs.id === hs[3].attrs['aria-describedby']);
 h.assertEq(shown(lbStatus), 'Responding: 2 of 3', 'LoadBalance summary');
 h.assert(!/mw-ping/.test(lbStatus.attrs.class || '') && shown(pingOf(hp, 3)) === '', 'LoadBalance summary on the note line, row ping only keeps the column');
 h.assertEq(texts(hs[3].children[1]).join(''), 'A', 'LoadBalance options without latency');
 // A test result without a server means it timed out.
 calls.length = 0;
 await collect(hp).filter(n => n.tag === 'button' && texts(n).includes('Test'))[2].listeners.click();
 h.assertEq(shown(pingOf(hp, 2)), 'no response', 'current server missing from test result');
 // Manual switch: ping from the last results, no new request.
 hs[1].value = 'A'; await hs[1].listeners.change();
 h.assertEq(shown(pingOf(hp, 1)), '7 ms', 'ping follows manual switch');
 h.assertEq(calls.filter(c => c[0] === 'group-delay').length, 1, 'switch does not re-test');
 // Back to Auto: re-read the group so "Auto — X" and the ping are current.
 const ov2calls = [];
 const ov2 = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { poll: { add() {} }, E, view: { extend: v => v }, api: { ...api,
  busy: (el, fn) => fn(), write: async (...args) => { ov2calls.push(args); return {}; },
  readLarge: async (...args) => { ov2calls.push(args); return [{ name: 'U', type: 'URLTest', now: 'B', fixed: '', all: ['A', 'B'], delays: { B: 30 } }]; }, notify: s => notices.push(s)
 } }).module;
 const up = ov2.render([active, {}, [{ name: 'U', type: 'URLTest', now: 'A', fixed: 'A', all: ['A', 'B'], delays: { A: 12 } }]]);
 const us = collect(up).find(n => n.tag === 'select');
 h.assertEq(us.value, 'A', 'pinned server selected');
 us.value = ''; await us.listeners.change();
 h.assert(ov2calls.some(c => c[0] === 'proxies-json'), 'unpin re-reads groups');
 h.assertEq(texts(us.children[0]).join(''), 'Auto — B', 'Auto shows the server Mihomo chose now');
 h.assertEq(shown(pingOf(up)), '30 ms', 'ping of the new automatic choice');
 h.assertEq(notices.length, 0, 'no notifications at all');
 const ov3 = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { poll: { add() {} }, E, view: { extend: v => v }, api: { ...api,
  busy: (el, fn) => fn(), write: async () => ({ A: 12 }), readLarge: async () => { throw new Error('down'); }, notify: s => notices.push(s)
 } }).module;
 const fp = ov3.render([active, {}, [{ name: 'U', type: 'URLTest', now: 'A', fixed: 'A', all: ['A', 'B'] }]]);
 const fs3 = collect(fp).find(n => n.tag === 'select');
 fs3.value = ''; await fs3.listeners.change();
 h.assertEq(fs3.value, '', 'unpinned group stays on Auto when the re-read fails');
 await collect(fp).find(n => n.tag === 'button' && texts(n).includes('Test')).listeners.click();
 h.assertEq(fs3.disabled, false, 'select usable again after the test');
 const subCalls = [], errors = []; let fail = false;
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', { ui, Blob, E: (tag, attrs, children) => {
  const n = E(tag, attrs, children); n.value = n.attrs.value || (tag === 'textarea' ? n.children.join('') : ''); n.checked = n.attrs.checked != null; return n;
 }, view: { extend: v => v }, location: { reload() {} }, api: { ...api, ...readStubs, busy: async (el, fn) => { try { return await fn(); } catch(e) { errors.push(e.message); } }, write: async (...args) => { subCalls.push(args); return {}; }, job: async (...args) => { subCalls.push(args); if (fail) throw Error('Subscription download failed: http_404'); return {}; }, notify() {} } }).module;
 for (const changed of [false, true]) {
  const p = await mountSubscription(sv, { url: 'https://old.example', auto_update: true }, { content: 'yaml' });
  const ns = collect(p); ns.find(n => n.attrs.id === 'mw-url').value = changed ? 'https://new.example' : 'https://old.example';
  const auto = ns.find(n => n.attrs.id === 'mw-auto'); auto.checked = false; auto.listeners.change();
  h.assert(ns.some(n => String(n.textContent).includes('Not saved yet: press Save or Update now.')), 'unsaved hint');
  subCalls.length = 0; await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(subCalls.map(c => c[0]).join(','), changed ? 'update-subscription,set-subscription' : 'set-subscription,update-subscription', 'update order changed=' + changed);
  if (changed) {
   h.assertEq(subCalls[0][1], 'https://new.example', 'new link passed to updater');
   fail = true; subCalls.length = 0; await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
   h.assertEq(subCalls.length, 1, 'failed new link never set'); h.assert(errors.at(-1).includes('The previous link is kept.'), 'previous link explanation');
   h.assert(errors.at(-1).includes('not found (HTTP 404)'), 'job failure keeps subscriptionError mapping');
  }
 }
 let logReads = 0;
 const logs = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', { E, view: { extend: v => v }, api: { ...api, readLarge: async () => { logReads++; return { available: true, lines: ['hello'] }; } } }).module;
 const lp = logs.render([base, {}]); h.assertEq(logReads, 0, 'log lazy');
 const logButton = collect(lp).find(n => n.tag === 'button' && texts(n).includes('Show the log'));
 h.assert(!!logButton, 'theme log toggle button');
 logButton?.listeners.click();
 await Promise.resolve(); h.assertEq(logReads, 1, 'log loads on open');
 console.log('ok - design-review DOM and event regressions');
}).catch(err => { console.error(err); process.exitCode = 1; });

seq(async () => {
 const polls = [], notices = []; let fail = true;
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', {
  E, view: { extend: v => v }, poll: { add: fn => polls.push(fn) }, api: { ...api,
   read: async () => { if (fail) throw Error('down'); return { state: 'stopped' }; }, notify: s => notices.push(s)
  }
 }).module;
 ov.render([base, {}, []]);
 await polls[0](); await polls[0](); h.assertEq(notices.length, 1, 'poll error notified once');
 fail = false; await polls[0](); fail = true; await polls[0]();
 h.assertEq(notices.length, 2, 'successful poll resets error notification');
 console.log('ok - overview poll notification recovery');
}).catch(err => { console.error(err); process.exitCode = 1; });

for (const [name, check] of [
 ['empty failure headline', () => h.assert(texts(overview.render([{ ...base, state: 'failed', last_error: '' }, {}, []])).includes('Stopped'), 'failed without detail is Stopped')],
 ['starting groups notice', () => h.assert(texts(overview.render([{ ...base, running: true, state: 'starting' }, {}, { error: 'x' }])).includes('Mihomo is starting. Reload the page in a moment to see the proxy groups.'), 'starting groups failure is informational')],
 ['headline-only live region', () => { const p = overview.render([base, {}, []]); const headline = collect(p).find(n => n.tag === 'strong'); h.assertEq(headline.attrs['aria-live'], 'polite', 'headline itself is live'); }]
]) { try { check(); console.log('ok - overview ' + name); } catch (e) { console.error(e); process.exitCode = 1; } }
seq(async () => {
 const polls = [];
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { E, view: { extend: v => v }, poll: { add: fn => polls.push(fn) }, api: { ...api, read: async () => ({ state: 'running', running: true }) } }).module;
 const p = ov.render([base, {}, []]); const buttons = collect(p).filter(n => n.tag === 'button');
 await polls[0](); h.assert(buttons.every(b => collect(p).includes(b)), 'status buttons stay mounted to preserve keyboard focus');
 console.log('ok - overview stable status controls');
}).catch(e => { console.error(e); process.exitCode = 1; });

// Task 17: long actions, service state polling and partial group failures.
seq(async () => {
 const calls = [], polls = [];
 let fresh = { running: true, enabled: true, state: 'running', dns_ok: true };
 let failGroups = false;
 const notices = [], delays = [];
 const bridge = { ...api, jobRunning: false,
  busy: (button, fn) => fn(),
  job: async (...args) => { calls.push(['job', ...args]); return { version: 'v1', action: 'unchanged' }; },
  service: async (...args) => calls.push(['service', ...args]),
  write: async (...args) => { throw Error('unexpected synchronous write: ' + args); },
  read: async cmd => { calls.push(['read', cmd]); return cmd === 'service-state-json' ? fresh : cmd === 'status-json' ? { ...base, running: true, state: 'running' } : {}; },
  readLarge: async cmd => { calls.push(['readLarge', cmd]); if (failGroups) throw Error('x'); return []; },
  notify() {}, reloadWithNotice: (...args) => notices.push(args)
 };
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', {
  E, api: bridge, poll: { add: (fn, seconds) => polls.push({ fn, seconds }) },
  view: { extend: v => v }, location: { reload() {} }, window: { setTimeout: (fn, ms) => { delays.push(ms); setTimeout(fn, 0); } }
 }).module;
 const click = async (status, label) => {
  const p = ov.render([status, {}, []]);
  if (label === 'Connect') collect(p).find(n => n.attrs.id === 'mw-sub-url').value = ' https://p.example/sub ';
  await collect(p).find(n => n.tag === 'button' && texts(n).includes(label)).listeners.click();
 };
 for (const [status, label, expected, notice] of [
  [base, 'Connect', [['job', 'connect', 'https://p.example/sub']], 'Subscription connected. MihoWRT is starting.'],
  [{ ...base, core_installed: false }, 'Install Mihomo core', [['job', 'core-update']], 'Mihomo core v1 installed.'],
  [base, 'Update Mihomo core', [['job', 'core-update']], null],
  [{ ...base, subscription_configured: true }, 'Update subscription', [['job', 'update-subscription']], 'Subscription is up to date.'],
  [base, 'Start', [['service', 'enable'], ['job', 'service', 'start']], 'MihoWRT started.'],
  [{ ...base, enabled: true }, 'Start', [['job', 'service', 'start']], 'MihoWRT started.'],
  [{ ...base, running: true }, 'Stop', [['job', 'service', 'stop']], 'MihoWRT stopped.'],
  [base, 'Restart', [['job', 'service', 'restart']], 'MihoWRT restarted.']
 ]) {
  calls.length = 0; notices.length = 0; delays.length = 0; await click(status, label);
  h.assertEq(JSON.stringify(calls), JSON.stringify(expected), 'jobs used: ' + label);
  if (notice !== null) h.assertEq(JSON.stringify(notices), JSON.stringify([[notice]]), 'notice passed to reloadWithNotice (before busy ends): ' + label);
  if (label === 'Connect') h.assertEq(JSON.stringify(delays), '[1500]', 'Connect waits 1.5 s inside busy');
 }
 console.log('ok - overview jobs used');
 h.assert(collect(ov.render([base, {}, []])).filter(n => n.attrs['data-mw-job'] != null).every(n => n.attrs.disabled == null), 'idle buttons omit disabled attribute (LuCI stringifies false)');
 bridge.jobRunning = true;
 h.assert(collect(ov.render([base, {}, []])).filter(n => n.attrs['data-mw-job'] != null).every(n => n.attrs.disabled === true), 'already-running job disables buttons at render');
 bridge.jobRunning = false;
 const marked = ov.render([{ ...base, subscription_configured: true }, {}, []]);
 for (const label of ['Start', 'Restart', 'Update subscription', 'Update Mihomo core'])
  h.assert(collect(marked).find(n => n.tag === 'button' && texts(n).includes(label)).attrs['data-mw-job'] != null, label + ' marked as job starter');
 for (const [details, expected] of [
  [{ state: 'starting' }, 'Starting…'],
  [{ state: 'degraded', running: true }, 'Mihomo DNS does not answer: traffic goes direct until it recovers'],
  [{ state: 'failed', last_error: 'x' }, 'Stopped after an error: x'],
  [{ state: 'failed', last_error: '' }, 'Stopped'],
  [{ state: 'stopped', config_valid: false }, 'Stopped: the configuration has errors — see Diagnostics'],
  [{ state: 'running', running: true, dns_ok: false }, 'Running, but DNS does not answer — see Diagnostics']
 ]) {
  const p = ov.render([{ ...base, ...details }, {}, []]);
  h.assert(texts(p).includes(expected), 'headline per state: ' + details.state);
  h.assert(collect(p).some(n => n.attrs['aria-live'] === 'polite' && texts(n).includes(expected)), 'headline is polite');
 }
 console.log('ok - overview headline per state');
 polls.length = 0;
 const p = ov.render([{ ...base, state: 'stopped', config_valid: false }, {}, []]);
 h.assertEq(polls.length, 1, 'one status poll'); h.assertEq(polls[0].seconds, 5, 'poll every 5 seconds');
 const before = collect(p).find(n => n.tag === 'strong');
 calls.length = 0; bridge.jobRunning = true; await polls[0].fn();
 h.assertEq(calls.length, 0, 'poll paused during job');
 bridge.jobRunning = false; await polls[0].fn();
 h.assertEq(JSON.stringify(calls), JSON.stringify([['read', 'service-state-json']]), 'poll uses cheap state read');
 h.assert(collect(p).includes(before), 'status headline stays mounted (focus-safe update)');
 h.assertEq(before.textContent, 'Running', 'headline updated in place');
 await collect(p).find(n => n.tag === 'button' && texts(n).includes('Stop')).listeners.click();
 h.assertEq(JSON.stringify(calls.at(-1)), JSON.stringify(['job', 'service', 'stop']), 'preserved control uses fresh service state');
 h.assertEq(before.attrs['aria-live'], 'polite', 'only headline announces status');
 h.assert(!collect(p).some(n => n.attrs['aria-live'] && collect(n).some(c => c.tag === 'button')), 'live region excludes buttons');
 fresh = { ...fresh, dns_ok: false }; await polls[0].fn();
 h.assert(texts(p).includes('Running, but DNS does not answer — see Diagnostics'), 'same-state DNS change updates headline');
 fresh = { running: false, state: 'stopped', enabled: false }; await polls[0].fn();
 h.assert(texts(p).includes('Stopped: the configuration has errors — see Diagnostics'), 'poll preserves full status fields');
 console.log('ok - overview poll');
 failGroups = true; calls.length = 0;
 const loaded = await ov.load();
 h.assert(calls.some(c => c[0] === 'readLarge' && c[1] === 'proxies-json'), 'groups use readLarge');
 h.assert(texts(ov.render(loaded)).includes('Cannot load the proxy groups: x'), 'groups error visible');
 console.log('ok - overview groups error');
 const starting = ov.render([{ ...base, running: true, state: 'starting' }, {}, { error: 'x' }]);
 h.assert(texts(starting).includes('Mihomo is starting. Reload the page in a moment to see the proxy groups.'), 'starting groups failure is a notice');
 h.assert(!collect(starting).some(n => /alert-message error/.test(n.attrs.class || '')), 'starting has no red groups error');
 const noticeApi = h.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/api.js', {
  E, ui, fs: {}, setTimeout() {}, location: { reload() {} }
 }).module;
 noticeApi.read = async cmd => { h.assertEq(cmd, 'job-status', 'notice reads current job'); return { state: 'running', op: 'core-update', id: '1' }; };
 const noticeView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', {
  E, api: noticeApi, poll: { add() {} }, view: { extend: v => v }
 }).module;
 for (const status of [base, { ...base, core_installed: false }]) {
  const p = noticeView.render([status, {}, []]); await Promise.resolve(); await Promise.resolve();
  h.assert(texts(p).includes('"Update Mihomo core" is running…'), 'job notice shown on page');
 }
 console.log('ok - overview job notice');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 18: safe editor, large uploads, restore and shared job controls.
seq(async () => {
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null; return n;
 }
 async function check(name, fn) {
  try { await fn(); console.log('ok - subscription ' + name); }
  catch (e) { console.error('not ok - subscription ' + name, e); process.exitCode = 1; }
 }
 const restoreNotices = []; let calls = [], allow = false, reloads = 0, noticeCalls = 0, applyEvents = [];
 const bridge = { ...api, ...readStubs, jobRunning: false,
  busy: (b, fn) => fn(),
  upload: async (...args) => { calls.push(['upload', ...args]); return '/tmp/mihowrt-config.test'; },
  job: async (...args) => { calls.push(['job', ...args]); return { action: 'unchanged' }; },
  write: async (...args) => { calls.push(['write', ...args]); return {}; },
  jobNotice: () => { noticeCalls++; return E('div', { 'aria-live': 'polite' }); }, notify: m => restoreNotices.push(m),
  reloadWithNotice: m => { restoreNotices.push(m); applyEvents.push('notice'); reloads++; applyEvents.push('reload'); }
 };
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', {
  E: DOM, ui, Blob, api: bridge, view: { extend: v => v },
  confirm: message => { h.assertEq(message, 'Replace the current YAML with the previous one?', 'restore question'); return allow; },
  location: { reload: () => { reloads++; applyEvents.push('reload'); } }
 }).module;
 const render = async (backup = true, auto = true) => {
  const p = await mountSubscription(sv, { url: 'https://old.example', auto_update: auto }, { content: 'yaml' }, { config_backup: backup });
  await openToggle(p, 'Show the YAML editor');
  return p;
 };
 const button = (p, label) => collect(p).find(n => n.tag === 'button' && texts(n).includes(label));
 await check('status failure keeps editor usable', async () => {
  const read = bridge.read;
  try {
   resetReads({ url: 'https://old.example' }, { content: 'yaml' });
   bridge.read = async cmd => { if (cmd === 'status-json') throw Error('status unavailable'); return { url: 'https://old.example' }; };
   const p = sv.render(await sv.load());
   await openToggle(p, 'Show the YAML editor');
   h.assert(collect(p).some(n => n.tag === 'textarea'), 'editor remains available');
   h.assert(button(p, 'Check and apply') && button(p, 'Update now'), 'actions remain available');
   h.assert(!button(p, 'Restore the previous YAML'), 'unknown backup hides restore');
  } finally { bridge.read = read; }
 });
 await check('malformed YAML response', async () => {
  {
   for (const reply of [{}, { content: null }, { content: 42 }, null]) {
    const p = await mountSubscription(sv, { url: 'https://old.example' }, reply);
    await openToggle(p, 'Show the YAML editor');
    h.assert(texts(p).includes('Cannot load the YAML: Unexpected response from the router.'), 'malformed response error');
    h.assert(!collect(p).some(n => n.tag === 'textarea') && !button(p, 'Check and apply') && !button(p, 'Restore the previous YAML'), 'no unsafe editor actions');
   }
   const empty = await mountSubscription(sv, { url: 'https://old.example' }, { content: '' });
   await openToggle(empty, 'Show the YAML editor');
   h.assert(collect(empty).some(n => n.tag === 'textarea'), 'empty string is valid YAML content');
  }
 });
 await check('apply reloads after notice', async () => {
  const notify = bridge.notify;
  try {
   for (const [action, msg] of [['unchanged', 'Configuration is unchanged.'], ['hot_reloaded', 'Configuration checked and applied.'], ['saved', 'Configuration checked and saved.']]) {
    const job = bridge.job; applyEvents = []; restoreNotices.length = 0;
    try {
     bridge.job = async () => ({ action });
     const before = reloads;
     await button(await render(), 'Check and apply').listeners.click();
     h.assertEq(reloads, before + 1, 'successful apply reloads');
     h.assertEq(applyEvents.join(','), 'notice,reload', 'notice before reload');
     h.assertEq(JSON.stringify(restoreNotices), JSON.stringify([msg]), 'apply notice ' + action);
    } finally { bridge.job = job; }
   }
  } finally { bridge.notify = notify; reloads = 0; }
 });
 await check('apply large YAML and byte limit', async () => {
  const p = await render(), yaml = collect(p).find(n => n.tag === 'textarea');
  yaml.value = 'x'.repeat(1572864); calls = [];
  await button(p, 'Check and apply').listeners.click();
  h.assertEq(calls[0][0], 'upload', 'upload first'); h.assertEq(calls[0][1], 'mihowrt-config', 'upload prefix');
  h.assertEq(calls[0][2], yaml.value, 'full large content');
  h.assertEq(calls[1].join(','), 'job,save-config,/tmp/mihowrt-config.test', 'save as job');
  for (const content of ['x'.repeat(8388609), 'я'.repeat(4194305)]) {
   yaml.value = content; calls = []; let error = '';
   try { await button(p, 'Check and apply').listeners.click(); } catch(e) { error = e.message; }
   h.assertEq(error, 'The YAML is larger than 8 MiB.', 'byte limit message'); h.assertEq(calls.length, 0, 'oversize not uploaded');
  }
  yaml.value = 'x'.repeat(8388608); calls = []; await button(p, 'Check and apply').listeners.click();
  h.assertEq(calls[0][0], 'upload', 'exact limit accepted');
 });
 await check('editor actions share one row, notice after the heading', async () => {
  const p = await render();
  const row = collect(p).find(n => n.attrs.class === 'mw-row' && n.children.includes(button(p, 'Check and apply')));
  h.assert(row && row.children.includes(button(p, 'Restore the previous YAML')), 'apply and restore in one mw-row');
  const top = p.children.filter(c => c && typeof c === 'object').map(c => c.tag + (c.attrs['aria-live'] ? ':live' : ''));
  h.assert(top.indexOf('h2') < top.indexOf('div:live'), 'job notice right after the heading');
 });
 await check('restore', async () => {
  reloads = 0;
  const p = await render(); const restore = button(p, 'Restore the previous YAML'); h.assert(restore, 'backup restore button');
  h.assert(texts(p).includes('Automatic updates replace it again with the subscription.'), 'automatic update warning');
  calls = []; allow = false; await restore.listeners.click(); h.assertEq(calls.length, 0, 'cancel restore');
  allow = true; await restore.listeners.click(); h.assertEq(calls[0].join(','), 'job,restore-config', 'restore job'); h.assertEq(reloads, 1, 'reload after restore');
  for (const [action, msg] of [['unchanged', 'Configuration is unchanged.'], ['hot_reloaded', 'Configuration checked and applied.'], ['saved', 'Configuration checked and saved.']]) {
   bridge.job = async () => ({ action }); restoreNotices.length = 0; await restore.listeners.click();
   h.assertEq(restoreNotices[0], msg, 'restore notice ' + action);
  }
  bridge.job = async (...args) => { calls.push(['job', ...args]); return { action: 'unchanged' }; };
  h.assert(!button(await render(false), 'Restore the previous YAML'), 'no restore without backup');
  const off = await render(true, false), note = collect(off).find(n => n.textContent === 'Automatic updates replace it again with the subscription.');
  h.assert(note.hidden, 'automatic warning hidden when off');
  const auto = collect(off).find(n => n.attrs.id === 'mw-auto'); auto.checked = true; auto.listeners.change();
  h.assert(!note.hidden, 'automatic warning follows checkbox');
 });
 await check('job notice and shared locks', async () => {
  noticeCalls = 0;
  for (const running of [false, true]) {
   bridge.jobRunning = running; const p = await render();
   for (const label of ['Update now', 'Check and apply', 'Restore the previous YAML']) {
    const b = button(p, label); h.assert(b.attrs['data-mw-job'] != null, label + ' marked');
    h.assert(running ? b.attrs.disabled === true : b.attrs.disabled == null, label + ' running state');
   }
  }
  h.assertEq(noticeCalls, 2, 'job notice on each page'); bridge.jobRunning = false;
 });
 await check('update jobs', async () => {
  for (const changed of [false, true]) {
   const p = await render(); collect(p).find(n => n.attrs.id === 'mw-url').value = changed ? 'https://new.example' : 'https://old.example';
   calls = []; await button(p, 'Update now').listeners.click();
   h.assertEq(JSON.stringify(calls), JSON.stringify(changed ? [['job','update-subscription','https://new.example'],['write','set-subscription','https://new.example','1']] : [['write','set-subscription','https://old.example','1'],['job','update-subscription']]), 'update sequence');
  }
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// Plan task 12: the YAML editor loads on demand; the YAML passed to Mihomo is a second, read-only view.
// The test E() supports appendChild, removeChild and textContent; views may also use replaceChildren.
seq(async () => {
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null;
  n.replaceChildren = (...nodes) => { n.children = nodes; };
  return n;
 }
 async function check(name, fn) {
  try { await fn(); console.log('ok - subscription ' + name); }
  catch (e) { console.error('not ok - subscription ' + name, e); process.exitCode = 1; }
 }
 const confirmations = [], jobs = [];
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', {
  E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} },
  confirm: message => { confirmations.push(message); return true; },
  api: { ...api, ...readStubs, busy: async (el, fn) => fn(), upload: async () => '/tmp/yaml', write: async () => ({}),
   job: async (...args) => { jobs.push(args); return { action: 'unchanged' }; }, notify() {}, reloadWithNotice() {} }
 }).module;
 const editorLabel = 'Show the YAML editor', effectiveShow = 'Show the YAML passed to Mihomo', effectiveHide = 'Hide the YAML passed to Mihomo';
 const readCount = cmd => reads.calls.filter(c => c === cmd).length;
 const editorAreas = p => collect(p).filter(n => n.tag === 'textarea');
 await check('no yaml at load', async () => {
  resetReads({ url: 'https://p.example/sub' });
  const p = sv.render(await sv.load());
  h.assertEq(readCount('read-config'), 0, 'load does not read the YAML');
  h.assertEq(readCount('runtime-config'), 0, 'load does not read the effective YAML');
  const open = findButton(p, editorLabel);
  await open.listeners.click(); await settle();
  h.assertEq(readCount('read-config'), 1, 'first opening reads the YAML');
  h.assertEq(editorAreas(p)[0]?.value, 'proxies: []\n', 'editor shows the loaded YAML');
  await open.listeners.click(); await open.listeners.click(); await settle();
  h.assertEq(readCount('read-config'), 1, 'second opening does not read again after success');
  h.assertEq(editorAreas(p).length, 1, 'still one editor');
 });
 await check('yaml load error retry', async () => {
  resetReads({ url: 'https://p.example/sub' }, Error('x'));
  const p = sv.render(await sv.load());
  const open = findButton(p, editorLabel), box = toggleOf(p, open);
  await open.listeners.click(); await settle();
  h.assert(texts(box).includes('Cannot load the YAML: x'), 'error alert inside the toggle');
  h.assertEq(editorAreas(p).length, 0, 'no textarea after a failed load');
  h.assert(!findButton(p, 'Check and apply'), 'no Check and apply after a failed load');
  await open.listeners.click();
  reads.responses['read-config'] = { content: 'proxies: []\n' };
  await open.listeners.click(); await settle();
  h.assertEq(readCount('read-config'), 2, 'reopening retries');
  h.assertEq(editorAreas(p).length, 1, 'editor after a successful retry');
  h.assert(findButton(p, 'Check and apply'), 'Check and apply after a successful retry');
  h.assert(!texts(box).includes('Cannot load the YAML: x'), 'error alert gone after the retry');
 });
 await check('update confirm only when edited', async () => {
  const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
  confirmations.length = 0; jobs.length = 0;
  await findButton(p, 'Update now').listeners.click();
  h.assertEq(confirmations.length, 0, 'editor never opened: no confirm');
  h.assert(jobs.some(j => j[0] === 'update-subscription'), 'update ran');
  await openToggle(p, editorLabel);
  jobs.length = 0;
  await findButton(p, 'Update now').listeners.click();
  h.assertEq(confirmations.length, 0, 'editor opened but not edited: no confirm');
  h.assert(jobs.some(j => j[0] === 'update-subscription'), 'update ran after an unedited opening');
 });
 await check('effective yaml', async () => {
  const content = 'mixed-port: 7890\nsecret: "s"\ntproxy-port: 7894\n';
  for (const generated of [false, true]) {
   const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
   reads.responses['runtime-config'] = { content, generated };
   const show = findButton(p, effectiveShow), box = toggleOf(p, show);
   h.assert(show, 'toggle label ' + effectiveShow);
   h.assertEq(readCount('runtime-config'), 0, 'not read before opening');
   const before = textareaOptions.length;
   await show.listeners.click(); await settle();
   h.assert(texts(show).includes(effectiveHide), 'toggle label ' + effectiveHide);
   h.assertEq(readCount('runtime-config'), 1, 'opening reads runtime-config');
   const area = collect(box).find(n => n.tag === 'textarea');
   h.assert(area, 'read-only textarea inside the toggle');
   h.assertEq(area.value, content, 'textarea equals the reply');
   const opts = textareaOptions.slice(before).find(o => o.readonly);
   h.assert(opts, 'ui.Textarea created with readonly');
   h.assertEq(opts.monospace, true, 'monospace');
   h.assertEq(opts.wrap, false, 'no wrap');
   h.assertEq(opts.rows, 24, '24 rows');
   h.assert(texts(box).includes('Generated by MihoWRT from your YAML: router keys replaced, default DNS and sniffer added when missing, x-mihowrt removed. It contains the controller secret.'), 'note text');
   const stopped = collect(box).some(n => String(n.textContent).includes('MihoWRT is not running; this is what it would pass at start.'));
   h.assertEq(stopped, generated, 'not-running line only when generated');
   await show.listeners.click(); await show.listeners.click(); await settle();
   h.assertEq(readCount('runtime-config'), 2, 'each opening reads again');
   h.assert(!editorAreas(p).some(n => n.attrs.id === 'widget.mw-yaml'), 'the YAML editor stays unloaded');
   h.assertEq(readCount('read-config'), 0, 'effective view does not read the editable YAML');
  }
 });
 await check('effective yaml keeps the latest reply', async () => {
  const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
  let release;
  const slow = new Promise(r => { release = r; });
  const real = reads.responses;
  let n = 0;
  reads.responses = new Proxy(real, { get: (t, k) => k === 'runtime-config' ? (n++ === 0 ? slow : { content: 'new', generated: false }) : t[k], has: (t, k) => k in t });
  const show = findButton(p, effectiveShow), box = toggleOf(p, show);
  await show.listeners.click(); await show.listeners.click(); await show.listeners.click(); await settle();
  release({ content: 'old', generated: false }); await settle();
  h.assertEq(collect(box).find(n => n.tag === 'textarea')?.value, 'new', 'a slower earlier reply does not replace the newer one');
  reads.responses = real;
 });
 await check('effective yaml error', async () => {
  const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
  reads.responses['runtime-config'] = Error('boom');
  const show = findButton(p, effectiveShow), box = toggleOf(p, show);
  await show.listeners.click(); await settle();
  h.assert(texts(box).includes('Cannot load the YAML: boom'), 'error alert inside the effective toggle');
  h.assert(!collect(box).some(n => n.tag === 'textarea'), 'no textarea after a failed load');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 19: one Save & Apply, partial file writes, and MAC-aware leases.
seq(async () => {
 class Option {
  constructor(name, title, description) { Object.assign(this, { name, title, description, dependencies: [], values: [] }); }
  depends(...args) { this.dependencies.push(args); }
  value(...args) { this.values.push(args); }
  isActive() { return true; }
  remove() {}
 }
 class Map {
  constructor(name, title, description) { Object.assign(this, { name, title, description, options: {} }); }
  section() {
   const section = { children: [], tab() {} };
   section.taboption = (tab, Type, name, title, description) => {
    const o = new Type(name, title, description); section.children.push(o); this.options[name] = o; return o;
   };
   return section;
  }
  render() { return Promise.resolve(E('form')); }
 }
 const form = { Map, Flag: class extends Option {}, Value: Option, DummyValue: Option, ListValue: Option, TextValue: Option, NamedSection: Option };
 const lists = { dst: '', src: '', direct: '', direct_src: '' };
 const setup = (overrides = {}, leasesRPC = async () => ({})) => {
  const calls = [], notices = [], edits = {};
  const bridge = { ...api, jobRunning: false, busy: (button, fn) => fn(),
   readLarge: async cmd => { calls.push(['readLarge', cmd]); return { ...lists }; },
   read: async () => ({}), upload: async (...args) => { calls.push(['upload', ...args]); return '/tmp/mihowrt-policy-list.test'; },
   job: async (...args) => { calls.push(['job', ...args]); return {}; },
   notify: (...args) => notices.push(args), jobNotice: () => { calls.push(['jobNotice']); return E('div', { 'aria-live': 'polite' }, ['JOB NOTICE']); },
   ...overrides
  };
  const uci = { get() {}, changes: async () => { calls.push(['changes']); return {}; } };
  const ui = { changes: { apply: checked => calls.push(['apply', checked]) } };
  const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/traffic.js', {
   E, api: bridge, form, uci, ui, Event, widgets: { DeviceSelect: Option }, rpc: { declare: () => leasesRPC }, view: { extend: v => v }
  }).module;
  const render = async (data = { ...lists }, profile = {}) => tv.render([data, profile, {}]);
  const saving = () => {
   tv.map.parse = async () => { calls.push(['parse']); Object.assign(tv.edited, edits); };
   tv.map.save = async (...args) => { calls.push(['save', ...args]); await tv.map.parse(); };
   calls.length = 0;
  };
  return { tv, bridge, calls, notices, edits, uci, render, saving };
 };
 async function check(name, fn) {
  try { await fn(); console.log('ok - traffic ' + name); }
  catch (e) { console.error('not ok - traffic ' + name, e); process.exitCode = 1; }
 }
 await check('buttons', async () => {
  const t = setup(); const p = await t.render();
  h.assertEq(t.tv.handleSave, null, 'no plain Save'); h.assertEq(typeof t.tv.handleSaveApply, 'function', 'Save & Apply defined');
  h.assertEq(t.tv.map.description, 'Choose which traffic goes through Mihomo. Save & Apply applies the changes.', 'map description');
  h.assert(texts(p).includes('JOB NOTICE'), 'job notice on page');
 });
 await check('flags keep explicit values', async () => {
  const t = setup(); await t.render({ ...lists }, { provider: { dns_hijack: '1', lists_interval: '6' } });
  const flags = Object.values(t.tv.map.options).filter(o => o instanceof form.Flag);
  h.assert(flags.length >= 6, 'flags rendered');
  h.assert(flags.every(o => o.rmempty === false), 'flags with a default value must not be removed by form.Flag.parse');
 });
 await check('no null or empty children', async () => {
  const t = setup(); const p = await t.render({ ...lists });
  h.assert(collect(p).every(n => n.children.every(c => c != null && c !== false)), 'no null child that LuCI would print');
  h.assert(texts(p).includes('JOB NOTICE'), 'job notice present');
  h.assert(!t.tv.map.options._mode.cfgvalue().includes('To change the mode'), 'mode help is not part of the value');
 });
 await check('save unchanged lists', async () => {
  for (const snapshot of [lists, { ...lists, src: 'aa:bb:cc:dd:ee:ff # phone\n' }]) {
   const t = setup(); await t.render({ ...snapshot }); t.saving();
   // LuCI removes optional empty values even when they were already empty.
   for (const [kind, value] of Object.entries(snapshot)) t.edits[kind] = value;
   await t.tv.handleSaveApply(null, '0');
   h.assert(!t.calls.some(c => ['upload', 'job', 'apply'].includes(c[0])), 'no uploads, list job, or UCI apply');
   h.assertEq(JSON.stringify(t.calls.find(c => c[0] === 'save')), JSON.stringify(['save', null, true]), 'map saved silently');
   h.assertEq(t.notices.at(-1)[0], 'Changes applied.', 'empty changes success notice');
  }
 });
 await check('save one list', async () => {
  const t = setup(); await t.render(); t.saving(); t.edits.src = '192.168.1.5';
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(JSON.stringify(t.calls.filter(c => ['upload', 'job', 'save'].includes(c[0]))), JSON.stringify([
   ['upload', 'mihowrt-policy-list', '192.168.1.5'], ['job', 'apply-lists', '-', '/tmp/mihowrt-policy-list.test', '-', '-'], ['save', null, true]
  ]), 'one upload then partial job then map.save');
  h.assertEq(t.tv.lists.src, '192.168.1.5', 'snapshot refreshed');
 });
 await check('clearing a list uploads and applies it', async () => {
  const t = setup(); await t.render({ ...lists, src: '192.168.1.5\n' }); t.saving(); t.edits.src = '';
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(JSON.stringify(t.calls.filter(c => ['upload', 'job'].includes(c[0]))), JSON.stringify([
   ['upload', 'mihowrt-policy-list', ''], ['job', 'apply-lists', '-', '/tmp/mihowrt-policy-list.test', '-', '-']
  ]), 'cleared list uploaded and applied');
  h.assertEq(t.tv.lists.src, '', 'snapshot cleared');
 });
 await check('apply with foreign changes', async () => {
  for (const mode of ['0', '1']) for (const changedList of [false, true]) {
   const t = setup(); await t.render(); t.saving();
   if (changedList) t.edits.src = '192.168.1.5';
   t.uci.changes = async () => ({ network: [['set', 'lan', 'ipaddr', '192.168.2.1']] });
   await t.tv.handleSaveApply(null, mode);
   h.assertEq(JSON.stringify(t.calls.filter(c => c[0] === 'apply')), JSON.stringify([['apply', mode === '0']]), 'foreign UCI changes applied like stock LuCI');
  }
  const t = setup(); await t.render(); t.saving(); t.uci.changes = async () => ({ mihowrt: [] });
  await t.tv.handleSaveApply(null, '0'); h.assert(!t.calls.some(c => c[0] === 'apply'), 'empty change arrays do not apply');
 });
 await check('rejected list', async () => {
  const t = setup({ job: async () => { throw Error('Invalid src entries: x'); } }); await t.render(); t.saving(); t.edits.src = 'x';
  try { await t.tv.handleSaveApply(null, '0'); } catch (_) {}
  h.assertEq(t.notices.at(-1)[0], '"Devices via proxy" has invalid lines: x', 'list title in notice');
  h.assert(!t.calls.some(c => c[0] === 'save'), 'settings not saved');
  h.assertEq(t.tv.edited.src, 'x', 'edits retained'); h.assertEq(t.tv.lists.src, '', 'installed snapshot unchanged');
 });
 await check('settings failure after lists', async () => {
  const t = setup(); await t.render(); t.saving(); t.edits.src = '192.168.1.5';
  t.tv.map.save = async () => { throw Error('disk full'); };
  try { await t.tv.handleSaveApply(null, '0'); } catch (_) {}
  h.assert(t.notices.at(-1)[0].includes('Lists were applied, but settings could not be saved: disk full'), 'partial success explained');
  h.assertEq(t.tv.lists.src, '192.168.1.5', 'applied lists remembered');
  h.assert(!t.calls.some(c => c[0] === 'apply'), 'no UCI apply after failed save');
 });
 await check('lists load failure', async () => {
  for (const result of ['reject', null, {}, { ...lists, src: null }]) {
   const t = setup({ readLarge: async cmd => { h.assertEq(cmd, 'lists-json', 'lists use readLarge'); if (result === 'reject') throw Error('read failed'); return result; } });
   const p = await t.tv.render(await t.tv.load());
   h.assert(collect(p).some(n => /alert-message error/.test(n.attrs.class || '')), 'load error box');
   h.assert(texts(p).some(s => s.includes('Cannot load the lists:')), 'error cause shown');
   for (const name of ['_dst', '_src']) h.assertEq(t.tv.map.options[name].readonly, true, name + ' read-only');
   t.saving(); t.edits.src = 'accidental'; await t.tv.handleSaveApply(null, '0');
   h.assert(!t.calls.some(c => c[0] === 'upload' || c[0] === 'job'), 'failed load never uploads');
  }
 });
 await check('mode help and inactive lists', async () => {
  const t = setup(); await t.render({ ...lists, dst: '# comment\n1.1.1.1\n\n2.2.2.2\n3.3.3.3' }, { mode: 'proxy-first' });
  h.assertEq(t.tv.map.options._mode.description, 'To change the mode, the YAML must use dns.enhanced-mode: fake-ip with dns.fake-ip-filter-mode: whitelist for "Only selected", anything else for "All traffic".', 'mode help verbatim as the option description');
  h.assertEq(t.tv.map.options._mode.cfgvalue(), 'All traffic via proxy except exclusions (follows the DNS settings of your YAML)', 'mode value without a subscription');
  const rowText = Object.values(t.tv.map.options).map(o => o.cfgvalue?.()).filter(v => typeof v === 'string');
  h.assert(rowText.includes('Addresses via proxy: 3 saved entries, used in the other mode.'), 'inactive list summary');
 });
 const lease = { hostname: 'phone', macaddr: 'AA:BB:CC:DD:EE:FF', ipaddr: '192.168.1.5' };
 const picker = (t, leases, value = '') => {
  const area = { value, listeners: {}, addEventListener(k, fn) { this.listeners[k] = fn; }, dispatchEvent(ev) { this.listeners[ev.type]?.(); } };
  const widget = E('div'); widget.querySelector = q => q === 'textarea' ? area : null;
  const p = t.tv.addLeasePicker(widget, leases), selects = collect(p).filter(n => n.tag === 'select');
  return { p, area, select: selects[0], addAs: selects[1] };
 };
 const add = (p, index) => { p.select.value = p.select.children[index + 1].attrs.value; p.select.listeners.change(); };
 await check('picker add as', async () => {
  const t = setup();
  const p = picker(t, { dhcp_leases: [lease], dhcp6_leases: [{ hostname: 'tv', ip6addrs: ['2001:db8::5/128'] }, { ip6addr: '2001:db8::6' }] });
  h.assert(p.addAs, 'two selects'); h.assertEq(p.addAs.value, 'mac', 'MAC default');
  add(p, 0); add(p, 0); h.assertEq(p.select.value, '', 'picker resets after repeated selection');
  h.assertEq(p.area.value, 'aa:bb:cc:dd:ee:ff # phone\n', 'MAC lower-case, hostname, once');
  p.addAs.value = 'ip'; add(p, 0); add(p, 0);
  h.assertEq(p.area.value, 'aa:bb:cc:dd:ee:ff # phone\n192.168.1.5 # phone\n', 'IP hostname, once');
  for (const as of ['mac', 'ip']) { p.addAs.value = as; add(p, 1); }
  h.assertEq(p.area.value.split('2001:db8::5').length - 1, 1, 'DHCPv6 fallback strips prefix and deduplicates');
  h.assert(p.area.value.includes('2001:db8::5 # tv'), 'IPv6 hostname'); add(p, 2); h.assert(p.area.value.includes('2001:db8::6'), 'singular ip6addr fallback');
 });
 await check('picker without labels', async () => {
  const p = picker(setup(), { dhcp_leases: [lease] });
  const outsideOptions = collect(p.p).filter(n => n.tag !== 'option').flatMap(n => n.children.filter(c => typeof c === 'string'));
  h.assert(!outsideOptions.includes('Add a device') && !outsideOptions.includes('Add as'), 'no visible label text outside <option>');
  h.assert(!collect(p.p).some(n => n.tag === 'label'), 'no label elements');
  h.assertEq(p.select.attrs['aria-label'], 'Add a device', 'device select accessible name');
  h.assertEq(texts(p.select.children[0]).join(''), 'Add a device…', 'device select placeholder option');
  h.assertEq(p.addAs.attrs['aria-label'], 'Add as', 'Add as select accessible name');
  h.assertEq(JSON.stringify(p.addAs.children.map(o => [o.attrs.value, texts(o).join('')])), JSON.stringify([['mac', 'MAC (IPv4 + IPv6)'], ['ip', 'IP address']]), 'Add as options');
  h.assertEq(p.addAs.value, 'mac', 'MAC is the default');
  const row = collect(p.p).find(n => (n.attrs.class || '').split(' ').includes('mw-picker'));
  h.assert(row && row.attrs.class.split(' ').includes('mw-row'), 'picker row is mw-row mw-picker');
  h.assert(row.children.includes(p.select) && row.children.includes(p.addAs), 'selects are direct children of the picker row (.mw-picker > select)');
 });
 await check('DHCPv6 host address only', async () => {
  const p = picker(setup(), { dhcp6_leases: [
   { ip6addrs: ['2001:db8:1::/56', '2001:db8::7/128'] },
   { ip6addrs: ['2001:db8:2::/64'], ip6addr: '2001:db8::8/128' },
   { ip6addrs: ['2001:db8:3::/64'] },
   { ip6addr: '2001:db8:4::/56' },
   { macaddr: lease.macaddr, ip6addr: '2001:db8:5::/64' },
   { ipaddr: '192.168.1.6', ip6addr: '2001:db8:6::/64' }
  ] });
  h.assertEq(p.select.children.length, 5, 'prefix-only leases without MAC or IPv4 omitted');
  add(p, 0); add(p, 1); add(p, 2); add(p, 3);
  h.assertEq(p.area.value, '2001:db8::7\n2001:db8::8\naa:bb:cc:dd:ee:ff\n192.168.1.6\n', 'host addresses chosen, never delegated prefixes');
 });
 await check('leases unavailable', async () => {
  const t = setup({}, async () => { throw Error('RPC unavailable'); });
  const data = await t.tv.load(); h.assertEq(data[2], null, 'failed leases remain unavailable');
  const p = picker(t, data[2], '192.168.1.9\naa:bb:cc:dd:ee:ff');
  h.assert(!texts(p.p).some(s => s.includes('Not connected now:')), 'no false offline note');
  h.assert(!p.select, 'unavailable picker omitted');
 });
 await check('offline note changes only on change', async () => {
  const p = picker(setup(), {}, '192.168.1.9');
  const note = collect(p.p).find(n => n.textContent.startsWith('Not connected now:'));
  h.assert(note, 'initial note'); p.area.value = '192.168.1.10';
  p.area.listeners.input?.();
  h.assertEq(note.textContent, 'Not connected now: 192.168.1.9', 'typing does not recompute');
  p.area.listeners.change(); h.assertEq(note.textContent, 'Not connected now: 192.168.1.10', 'change recomputes');
 });
 await check('inactive list plurals', async () => {
  for (const count of [1, 2, 5]) {
   const t = setup(); await t.render({ ...lists, dst: Array(count).fill('1.1.1.1').join('\n') }, { mode: 'proxy-first' });
   h.assertEq(t.tv.map.options._dst_inactive.cfgvalue(), `Addresses via proxy: ${count} saved ${count === 1 ? 'entry' : 'entries'}, used in the other mode.`, 'inactive plural ' + count);
  }
 });
 await check('private mac notice', async () => {
  const text = (name, mac) => name + ' (' + mac + ') uses a private Wi-Fi address. The entry works while the device keeps this address for your network: choose "Fixed" (iPhone, iPad, Mac) or the per-network randomized MAC (Android) for this Wi-Fi, not a rotating one.';
  const oldHint = 'This device uses a private Wi-Fi address.';
  const t = setup(), p = picker(t, { dhcp_leases: [{ hostname: 'phone', macaddr: 'DA:A1:19:00:00:01' }, { macaddr: 'DA:A1:19:00:00:02' }, { hostname: 'laptop', macaddr: '00:11:22:33:44:55' }] });
  add(p, 0);
  h.assertEq(t.notices.length, 1, 'one notification for a private MAC');
  h.assertEq(t.notices[0][0], text('phone', 'da:a1:19:00:00:01'), 'notification names the device and the MAC');
  h.assert(!collect(p.p).some(n => String(n.textContent).includes(oldHint)), 'no inline hint element');
  add(p, 0);
  h.assertEq(t.notices.length, 1, 'same lease again: entry exists, no second notification');
  add(p, 1);
  h.assertEq(t.notices.length, 2, 'another private MAC notifies');
  h.assertEq(t.notices[1][0], text('unknown', 'da:a1:19:00:00:02'), 'missing hostname reads unknown');
  add(p, 2);
  h.assertEq(t.notices.length, 2, 'a global MAC adds no notification');
  const known = setup(), k = picker(known, { dhcp_leases: [{ hostname: 'phone', macaddr: 'DA:A1:19:00:00:01' }] }, 'da:a1:19:00:00:01 # phone');
  add(k, 0);
  h.assertEq(known.notices.length, 0, 'entry already in the list: no notification');
  const byIp = setup(), q = picker(byIp, { dhcp_leases: [{ hostname: 'phone', macaddr: 'DA:A1:19:00:00:01', ipaddr: '192.168.1.7' }] });
  q.addAs.value = 'ip'; add(q, 0);
  h.assertEq(byIp.notices.length, 0, 'adding by IP address: no notification');
 });
 await check('not connected now', async () => {
  const value = 'aa:bb:cc:dd:ee:ff # phone\n192.168.1.9\n2001:db8::5';
  for (const present of [false, true]) {
   const leases = { dhcp_leases: [lease, ...(present ? [{ ipaddr: '192.168.1.9' }] : [])] };
   const p = picker(setup(), leases, value);
   const notes = collect(p.p).filter(n => !n.hidden && typeof n.textContent === 'string' && n.textContent.startsWith('Not connected now:'));
   h.assertEq(notes.map(n => n.textContent).join(''), present ? '' : 'Not connected now: 192.168.1.9', 'only absent MAC and IPv4 listed');
  }
  const p = picker(setup(), {}, 'aa:bb:cc:dd:ee:ff # phone');
  h.assert(texts(p.p).includes('Not connected now: aa:bb:cc:dd:ee:ff'), 'absence even without leases');
 });
 await check('update lists job', async () => {
  const t = setup(); const b = t.tv.refreshButton();
  h.assert(b.attrs['data-mw-job'] != null, 'update is a shared job starter');
  await b.listeners.click(); h.assert(t.calls.some(c => c.join(',') === 'job,update-lists'), 'remote list job');
  t.bridge.jobRunning = true; h.assertEq(t.tv.refreshButton().attrs.disabled, true, 'running job disables refresh at render');
  await t.render(); t.saving(); t.bridge.read = async cmd => { h.assertEq(cmd, 'job-status', 'read running operation'); return { op: 'update-lists' }; };
  await t.tv.handleSaveApply(null, '0'); h.assertEq(t.calls.length, 0, 'running jobs do not save');
  h.assertEq(t.notices.at(-1)[0], '"Update remote lists" is running…', 'running job label shown');
  t.bridge.read = async () => { throw Error('status unavailable'); };
  await t.tv.handleSaveApply(null, '0'); h.assertEq(t.notices.at(-1)[0], 'status unavailable', 'status read errors visible');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 20: diagnostics keeps its checklist while exposing runtime risks.
seq(async () => {
 const check = async (name, fn) => {
  try { await fn(); console.log('ok - diagnostics ' + name); }
  catch (e) { console.error('not ok - diagnostics ' + name + ': ' + e.message); process.exitCode = 1; }
 };
 const healthy = { ...base, state: 'running', running: true, dns_ok: true, policy_active: true };
 const resources = { conflicts: [], flash_free_kb: 5120, ram_available_kb: 20480, mihomo_rss_kb: 45000, open_proxy_ports: [] };
 const render = (st = healthy, diagnostics = resources) => diag.render([st, {}, diagnostics]);
 const item = (p, label) => collect(p).find(n => n.tag === 'div' && n.children.some(c => c?.tag === 'strong' && texts(c).includes(label)));
 await check('failed state', () => {
  const row = item(render({ ...healthy, state: 'failed', last_error: 'x' }), 'Service is running');
  h.assert(texts(row).includes('Problem:'), 'failed state overrides stale running boolean');
  h.assert(texts(row).some(t => t.split('\n').includes('Last error: x')), 'last_error in failed hint');
  const stopped = item(render({ ...healthy, state: 'stopped', running: false, last_error: 'x' }), 'Service is running');
  h.assert(!texts(stopped).some(t => t.includes('Last error:')), 'no last_error unless failed');
 });
 await check('unknown DNS answer', () => {
  const row = item(render({ ...healthy, dns_ok: null }), 'Mihomo answers DNS queries');
  h.assert(row && texts(row).includes('Unknown:') && !texts(row).includes('Problem:'), 'null dns_ok is unknown, not a problem');
  h.assert(texts(item(render({ ...healthy, dns_ok: false }), 'Mihomo answers DNS queries')).includes('Problem:'), 'false dns_ok is a problem');
 });
 await check('log read error', async () => {
  const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', { E, view: { extend: v => v }, api: { ...api,
   readLarge: async () => { throw Object.assign(Error('denied'), { name: 'PermissionError' }); } } }).module;
  const p = dv.render([healthy, {}, resources]);
  collect(p).find(n => n.tag === 'button' && texts(n).includes('Show the log')).listeners.click();
  await new Promise(r => setTimeout(r, 0));
  h.assert(texts(p).includes('Cannot read the log: Access denied. Log in to LuCI again.'), 'log error uses errorText');
 });
 await check('degraded state', () => {
  const row = item(render({ ...healthy, state: 'degraded' }), 'Mihomo DNS does not answer: traffic goes direct until it recovers');
  h.assert(row && texts(row).includes('Problem:'), 'degraded service is a failed check');
 });
 await check('starting and stopped states', () => {
  h.assert(texts(render({ ...healthy, state: 'starting' })).includes('Starting…'), 'starting state has neutral wording');
  h.assert(texts(item(render({ ...healthy, state: 'stopped' }), 'Service is running')).includes('Problem:'), 'stopped state is not running');
 });
 await check('conflicts', () => {
  const row = item(render(healthy, { ...resources, conflicts: ['podkop'] }), 'Other proxy packages are installed: podkop');
  h.assert(texts(row).includes('Problem:'), 'conflicting package is a failure');
  h.assert(texts(row).includes('They change DNS and firewall too. Use only one of them at a time.'), 'conflict hint');
  h.assert(!texts(render()).some(t => t.startsWith('Other proxy packages')), 'no conflict item for empty list');
 });
 await check('resources', () => {
  const p = render(healthy, { ...resources, flash_free_kb: 4000, ram_available_kb: 15000 });
  h.assert(texts(p).includes('Little free flash: 3 MiB'), 'flash floor MiB');
  h.assert(texts(p).includes('Little free memory: 14 MiB'), 'memory floor MiB');
  h.assert(texts(p).includes('Mihomo may be stopped by the system when memory runs out. Stop other services or use a smaller configuration.'), 'memory hint');
  h.assert(texts(p).includes('Mihomo memory') && texts(p).includes('44 MiB'), 'RSS detail rounds to MiB');
 });
 await check('resource thresholds and unknowns', () => {
  for (const value of [null, undefined, 5120]) {
   const p = render(healthy, { ...resources, flash_free_kb: value, ram_available_kb: value == 5120 ? 20480 : value, mihomo_rss_kb: null });
   h.assert(!texts(p).some(t => t.startsWith('Little free')), 'no false low resource warning');
   h.assert(!texts(p).includes('0 MiB'), 'unknown RSS not zero');
  }
  h.assert(texts(render(healthy, { ...resources, flash_free_kb: 0 })).includes('Little free flash: 0 MiB'), 'zero flash is low');
 });
 await check('open ports', () => {
  const row = item(render(healthy, { ...resources, open_proxy_ports: [7890] }), 'Mihomo proxy ports 7890 accept any device in your network without a password');
  h.assert(texts(row).includes('Problem:'), 'open proxy is a failure');
  h.assert(texts(row).includes('Add authentication to the YAML or remove these ports if you do not use them.'), 'authentication hint');
  h.assert(!texts(render()).some(t => t.startsWith('Mihomo proxy ports')), 'no empty ports warning');
 });
 await check('diagnostics read and partial failure', async () => {
  const calls = [];
  const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', { E, view: { extend: v => v }, api: { ...api,
   read: async (...args) => { calls.push(args); if (args[0] === 'diagnostics-json') throw Error('Access denied'); return args[0] === 'status-json' ? healthy : {}; }
  } }).module;
  const data = await dv.load(); const p = dv.render(data);
  h.assert(calls.some(c => c.length === 1 && c[0] === 'diagnostics-json'), 'diagnostics-json without args');
  h.assert(texts(p).includes('Service is running') && texts(p).includes('Details'), 'rest remains usable');
  h.assert(texts(p).some(t => t.includes('Cannot load diagnostics: Access denied. Log in to LuCI again.')), 'partial failure cause uses errorText');
  h.assert(texts(p).includes('Reload the page to try again.'), 'partial failure retry hint');
 });
 await check('large log and job notice', async () => {
  const calls = []; let notices = 0;
  const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', { E, view: { extend: v => v }, api: { ...api,
   readLarge: async (...args) => { calls.push(args); return { available: true, lines: ['hello'] }; },
   jobNotice: () => { notices++; return E('div', { 'aria-live': 'polite' }); }
  } }).module;
  const p = dv.render([healthy, {}, resources]);
  h.assertEq(notices, 1, 'shared job notice included');
  h.assertEq(calls.length, 0, 'log remains lazy');
  collect(p).find(n => n.tag === 'button' && texts(n).includes('Show the log')).listeners.click();
  await Promise.resolve();
  h.assertEq(calls.map(c => c.join(',')).join(';'), 'logs-json,300', 'log through readLarge');
  h.assert(texts(p).includes('hello'), 'loaded log shown');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

NODE
