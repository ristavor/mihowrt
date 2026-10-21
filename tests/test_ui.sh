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
 n.setAttribute = (k, v) => { n.attrs[k] = v; };
 n.addEventListener = (type, fn) => { n.listeners[type] = fn; };
 n.appendChild = c => n.children.push(c);
 n.removeChild = c => n.children.splice(n.children.indexOf(c), 1);
 Object.defineProperty(n, 'firstChild', { get: () => n.children[0] });
 return n;
}
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
// Historical proof mode accumulates assertion failures instead of stopping at
// the first old behaviour. Missing helpers get deliberately non-working stubs
// so their callers can report each failed contract as well.
if (process.env.MIHOWRT_REGRESSION_PROOF) {
 api.subscriptionError ||= () => '';
 api.toggle ||= (show, hide, content) => {
  const button = E('button', {}, [show]); button.addEventListener('click', () => {});
  return E('div', {}, [button, content]);
 };
}


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
const firstUrl = collect(page).find(n => n.attrs.id === 'mw-sub-url');
h.assertEq(firstUrl.attrs.type, 'text', 'theme-native first-run text input');
h.assertEq(firstUrl.attrs.inputmode, 'url', 'first-run URL keyboard');

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
h.assertEq(JSON.stringify(hours.attrs), '{"inputmode":"numeric"}', 'list interval is a number field like the subscription one');
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
  await tv.render(['dst', 'src', 'direct', 'devices', p, {}]);
  for (const name of ['_dst', '_src', '_direct', '_direct_src']) {
   if (tv.map.options[name]) h.assertEq(tv.map.options[name].monospace, true, name + ' native TextValue monospace');
  }
  return tv.map.options;
 };
 let opts = await renderTraffic({ mode: 'direct-first', dns: 'fake-ip', provider: { disable_quic: '0' }, lists: { dst: { provided: true, provider_count: 12, own_count: 3 } } });
 h.assertEq(opts._mode.cfgvalue(), 'Only selected traffic via proxy (chosen by your subscription)', 'direct mode reason');
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
  E, api: Object.assign({}, api, { upload: async (prefix, content) => { uploads.push(content); return content; }, write: async (...args) => writes.push(args) }),
  view: { extend: v => v }, form, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }
 }).module;
 saved.lists = { dst: 'dst', src: 'src', direct: 'direct', direct_src: 'direct_src' };
 saved.map = { parse: async () => { saved.edited.dst = 'edited'; }, save: async () => {} };
 await saved.handleSave();
 h.assertEq(uploads.join(','), 'edited,src,direct,direct_src', 'four uploads in stable order');
 h.assertEq(writes[0].join(','), 'apply-lists,edited,src,direct,direct_src', 'four list paths sent');
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
  E: DOM, ui, view: { extend: v => v }, location: { reload() {} },
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
 // Exercise the widget contract and handlers using the actual returned textarea.
 const yamlUploads = [], confirmations = [];
 let allowUpdate = false;
 const yamlView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', {
  E: DOM, ui, view: { extend: v => v }, location: { reload() {} },
  confirm: message => { confirmations.push(message); return allowUpdate; },
  api: { ...api, busy: async (el, fn) => fn(), upload: async (...args) => { yamlUploads.push(args); return '/tmp/yaml'; },
   write: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, notify: message => notices.push(message) }
 }).module;
 const yamlNodes = collect(yamlView.render([{ url: 'https://p.example/sub' }, { content: 'proxies: []\n' }]));
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
 console.log('ok - YAML native monospace widget, live upload and unsaved edits');
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

// Design-review regression cases use the rendered DOM and real event handlers.
(async () => {
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
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { E, view: { extend: v => v }, api: { ...api,
  busy: (el, fn) => fn(), write: async (...args) => { calls.push(args); return { A: 10, B: 2 }; }, read: async () => [], notify: s => notices.push(s)
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
 const live = collect(gp).find(n => n.attrs['aria-live'] === 'polite');
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
 h.assertEq(shown(pingOf(hp, 3)), 'Responding: 2 of 3', 'LoadBalance summary');
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
 const ov2 = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { E, view: { extend: v => v }, api: { ...api,
  busy: (el, fn) => fn(), write: async (...args) => { ov2calls.push(args); return {}; },
  read: async (...args) => { ov2calls.push(args); return [{ name: 'U', type: 'URLTest', now: 'B', fixed: '', all: ['A', 'B'], delays: { B: 30 } }]; }, notify: s => notices.push(s)
 } }).module;
 const up = ov2.render([active, {}, [{ name: 'U', type: 'URLTest', now: 'A', fixed: 'A', all: ['A', 'B'], delays: { A: 12 } }]]);
 const us = collect(up).find(n => n.tag === 'select');
 h.assertEq(us.value, 'A', 'pinned server selected');
 us.value = ''; await us.listeners.change();
 h.assert(ov2calls.some(c => c[0] === 'proxies-json'), 'unpin re-reads groups');
 h.assertEq(texts(us.children[0]).join(''), 'Auto — B', 'Auto shows the server Mihomo chose now');
 h.assertEq(shown(pingOf(up)), '30 ms', 'ping of the new automatic choice');
 h.assertEq(notices.length, 0, 'no notifications at all');
 const ov3 = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/overview.js', { E, view: { extend: v => v }, api: { ...api,
  busy: (el, fn) => fn(), write: async () => ({ A: 12 }), read: async () => { throw new Error('down'); }, notify: s => notices.push(s)
 } }).module;
 const fp = ov3.render([active, {}, [{ name: 'U', type: 'URLTest', now: 'A', fixed: 'A', all: ['A', 'B'] }]]);
 const fs3 = collect(fp).find(n => n.tag === 'select');
 fs3.value = ''; await fs3.listeners.change();
 h.assertEq(fs3.value, '', 'unpinned group stays on Auto when the re-read fails');
 await collect(fp).find(n => n.tag === 'button' && texts(n).includes('Test')).listeners.click();
 h.assertEq(fs3.disabled, false, 'select usable again after the test');
 const subCalls = [], errors = []; let fail = false;
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/subscription.js', { ui, E: (tag, attrs, children) => {
  const n = E(tag, attrs, children); n.value = n.attrs.value || (tag === 'textarea' ? n.children.join('') : ''); n.checked = n.attrs.checked != null; return n;
 }, view: { extend: v => v }, location: { reload() {} }, api: { ...api, busy: async (el, fn) => { try { return await fn(); } catch(e) { errors.push(e.message); } }, write: async (...args) => { subCalls.push(args); if (fail && args[0] === 'update-subscription') throw Error('Subscription download failed: http_404'); return {}; }, notify() {} } }).module;
 for (const changed of [false, true]) {
  const p = sv.render([{ url: 'https://old.example', auto_update: true }, { content: 'yaml' }]);
  const ns = collect(p); ns.find(n => n.attrs.id === 'mw-url').value = changed ? 'https://new.example' : 'https://old.example';
  const auto = ns.find(n => n.attrs.id === 'mw-auto'); auto.checked = false; auto.listeners.change();
  h.assert(ns.some(n => String(n.textContent).includes('Not saved yet: press Save or Update now.')), 'unsaved hint');
  subCalls.length = 0; await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(subCalls.map(c => c[0]).join(','), changed ? 'update-subscription,set-subscription' : 'set-subscription,update-subscription', 'update order changed=' + changed);
  if (changed) {
   h.assertEq(subCalls[0][1], 'https://new.example', 'new link passed to updater');
   fail = true; subCalls.length = 0; await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
   h.assertEq(subCalls.length, 1, 'failed new link never set'); h.assert(errors.at(-1).includes('The previous link is kept.'), 'previous link explanation');
  }
 }
 let logReads = 0;
 const logs = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js', { E, view: { extend: v => v }, api: { ...api, read: async () => { logReads++; return { available: true, lines: ['hello'] }; } } }).module;
 const lp = logs.render([base, {}]); h.assertEq(logReads, 0, 'log lazy');
 const logButton = collect(lp).find(n => n.tag === 'button' && texts(n).includes('Show the log'));
 h.assert(!!logButton, 'theme log toggle button');
 logButton?.listeners.click();
 await Promise.resolve(); h.assertEq(logReads, 1, 'log loads on open');
 console.log('ok - design-review DOM and event regressions');
})().catch(err => { console.error(err); process.exitCode = 1; });
NODE
