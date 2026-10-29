'use strict';

const assert = require('assert').strict;
const nodefs = require('fs');
const h = require('./js_luci_harness');
const apiPath = 'rootfs/www/luci-static/resources/mihowrt/api.js';
function E(tag, attrs, children) {
	if (Array.isArray(attrs)) { children = attrs; attrs = {}; }
	return { tag, attrs: attrs || {}, children: children || [], addEventListener(type, fn) { this[type] = fn; }, appendChild(child) { this.children.push(child); } };
}
function setup(overrides = {}) {
	const timers = [], calls = [];
	const module = h.evaluateLuCIModule(apiPath, {
		E, ui: { addNotification() {} }, Blob, FormData, crypto: require('crypto').webcrypto,
		L: { env: { cgi_base: '/cgi-bin' } },
		rpc: { getSessionID: () => 'session-secret' },
		request: { post: async () => ({ ok: true, status: 200, json: () => ({}) }) },
		fs: { exec: async (bin, args) => { calls.push([bin, args]); return { code: 0, stdout: JSON.stringify({ id: '1-2' }) }; } },
		setTimeout: (fn, ms) => { timers.push({ fn, ms }); },
		...overrides
	}).module;
	return { api: module, timers, calls };
}
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
async function tick(timers) {
	await flush();
	assert(timers.length, 'a poll must be scheduled');
	const timer = timers.shift(); assert.equal(timer.ms, 2000); timer.fn(); await flush();
}
const tests = [];
function test(name, fn) { tests.push([name, fn]); }
test('job buttons lock together through busy preparation and job completion', async () => {
 const buttons = [false, false, true].map(disabled => ({ disabled, hasAttribute: () => true, classList: { add() {}, remove() {} } }));
 const { api, timers } = setup({ document: { querySelectorAll: () => buttons } });
 api.read = async () => ({ state: 'ok', result: {} });
 let prepare;
 const preparation = new Promise(resolve => { prepare = resolve; });
 const pending = api.busy(buttons[0], async () => { await preparation; return api.job('service', 'start'); });
 assert(buttons.every(b => b.disabled), 'all job buttons disabled before async preparation');
 let invoked = false; await api.busy(buttons[1], () => { invoked = true; });
 assert.equal(invoked, false, 'disabled job button cannot start another action');
 prepare(); await tick(timers); await pending;
 assert.deepEqual(buttons.map(b => b.disabled), [false, false, true]);
 const direct = api.job('core-update'); assert(buttons.every(b => b.disabled));
 await tick(timers); await direct;
 assert.deepEqual(buttons.map(b => b.disabled), [false, false, true]);
});
for (const outcome of ['ok', 'error', 'start-error']) test('job clears old notices on start and running notice on completion: ' + outcome, async () => {
 const notice = { children: ['stale error'], replaceChildren(...children) { this.children = children; } };
 const { api, timers } = setup({ document: { querySelectorAll: selector => selector === '.mw-job' ? [notice] : [] } });
 api.write = async () => {
  assert(!notice.children.includes('stale error'), 'stale notice cleared before job-start');
  assert(notice.children[0].children[0].includes('is running'), 'running notice shown');
  if (outcome === 'start-error') throw Error('start failed');
  return { id: '1' };
 };
 api.read = async () => outcome === 'ok' ? { state: 'ok' } : { state: 'error', error: 'failed' };
 const pending = outcome === 'ok' ? api.job('update-lists') : assert.rejects(api.job('update-lists'));
 if (outcome !== 'start-error') await tick(timers);
 await pending;
 assert.equal(notice.children.length, 0, 'no stale running notice after completion');
});
for (const accepted of [false, true]) test('confirm modal resolves once for confirm or cancel: ' + accepted, async () => {
 let modal, hides = 0;
 const { api } = setup({ ui: { showModal: (title, children) => { modal = { title, children }; }, hideModal: () => { hides++; } } });
 const pending = api.confirm('Restore YAML', 'Replace the current YAML?', 'Restore', { danger: true });
 assert.equal(modal.title, 'Restore YAML');
 assert.equal(modal.children[0].children.join(''), 'Replace the current YAML?');
 const buttons = modal.children[1].children.filter(n => n.tag === 'button');
 assert.equal(buttons[0].children[0], 'Cancel');
 assert(buttons[1].attrs.class.includes('cbi-button-negative'));
 buttons[accepted ? 1 : 0].click();
 buttons[accepted ? 0 : 1].click();
 assert.equal(await pending, accepted);
 assert.equal(hides, 1, 'only the first choice closes the modal');
});
test('jobLabel reuses known labels and falls back to operation', () => {
 const { api } = setup();
 assert.equal(api.jobLabel('apply-lists'), 'Applying lists and settings');
 assert.equal(api.jobLabel('auto-update'), 'Automatic update');
 assert.equal(api.jobLabel('custom-op'), 'custom-op');
});
test('jobNotice locks all job starters until reload', async () => {
 const buttons = [{ disabled: false }]; let reloads = 0;
 const { api, timers } = setup({ document: { querySelectorAll: () => buttons }, location: { reload: () => reloads++ } });
 let reads = 0; api.read = async () => ++reads === 1 ? { id: '1', op: 'service', state: 'running' } : { state: 'ok' };
 api.jobNotice(); await flush();
 assert.equal(api.jobRunning, true); assert.equal(buttons[0].disabled, true);
 await tick(timers); assert.equal(reloads, 1);
});
// C1: a finished background job must not reload over unsaved edits.
for (const outcome of ['ok', 'error']) test('jobNotice keeps unsaved edits when the job ends: ' + outcome, async () => {
 const buttons = [{ disabled: false }], listeners = {}; let reloads = 0, count = 0;
 const { store, sessionStorage } = storage();
 const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ },
  document: { querySelectorAll: () => buttons, addEventListener: (type, fn) => { listeners[type] = fn; } } });
 api.read = async () => ++count === 1 ? { id: '9-1', op: 'update-lists', state: 'running' }
  : outcome === 'ok' ? { state: 'ok' } : { state: 'error', error: 'Interrupted: stopped' };
 const notice = api.jobNotice(); await flush();
 assert.equal(buttons[0].disabled, true);
 listeners.input();
 await tick(timers);
 assert.equal(reloads, 0, 'no reload over edits');
 assert.equal(store['mihowrt-notice'], undefined, 'nothing kept for a reload');
 assert.equal(notice.children[0].textContent, outcome === 'ok'
  ? '"Remote list update" finished. Reload the page to see the result; your unsaved edits are still here.'
  : '"Remote list update" failed: The operation was interrupted (for example, by a router reboot). You can run it again.');
 assert.equal(api.jobRunning, false, 'job no longer running');
 assert.equal(buttons[0].disabled, false, 'buttons usable to save the edits');
 assert.equal(store['mihowrt-seen-job'], '9-1', 'result shown once');
});
test('jobNotice still reloads without edits', async () => {
 const listeners = {}; let reloads = 0, count = 0;
 const { api, timers } = setup({ location: { reload: () => reloads++ },
  document: { querySelectorAll: () => [], addEventListener: (type, fn) => { listeners[type] = fn; } } });
 api.read = async () => ++count === 1 ? { id: '9-2', op: 'update-lists', state: 'running' } : { state: 'ok' };
 api.jobNotice(); await flush(); await tick(timers);
 assert.equal(reloads, 1);
 assert.equal(typeof listeners.input, 'function', 'edits are watched');
});
test('job ok: three polls spaced 2000 ms, running flag', async () => {
	let polls = 0;
	const { api, timers, calls } = setup();
	api.read = async (...args) => { assert.deepEqual(args, ['job-status', '1-2']); return ++polls < 3 ? { state: 'running' } : { state: 'ok', result: { action: 'saved' } }; };
	assert.equal(api.jobRunning, false);
	const pending = api.job('save-config', '/tmp/mihowrt-config.a');
	assert.equal(api.jobRunning, true);
	for (let i = 0; i < 3; i++) await tick(timers);
	assert.equal((await pending).action, 'saved'); assert.equal(polls, 3); assert.equal(api.jobRunning, false);
	assert.equal(JSON.stringify(calls), JSON.stringify([['/usr/bin/mihowrt', ['job-start', 'save-config', '/tmp/mihowrt-config.a']]]));
});
test('job error preserves backend message and clears flag', async () => {
	const { api, timers } = setup();
	api.read = async () => ({ state: 'error', error: 'Mihomo rejected the configuration' });
	const pending = api.job('save-config');
	const rejected = assert.rejects(pending, /Mihomo rejected the configuration/);
	await tick(timers); await rejected; assert.equal(api.jobRunning, false);
});
test('poll access denied limit and recovery', async () => {
	for (const failures of [5, 4]) {
		const { api, timers } = setup(); let count = 0;
		api.read = async () => { if (++count <= failures) throw Error('Access denied'); return { state: 'ok', result: { action: 'saved' } }; };
		const pending = api.job('core-update');
		const checked = failures === 5 ? assert.rejects(pending, { message: 'Access denied. Log in to LuCI again, or ask for write access.' }) : pending;
		for (let i = 0; i < 5; i++) await tick(timers);
		await checked; assert.equal(api.jobRunning, false);
	}
});
test('poll expired session shapes map to access denied', async () => {
	const shapes = [
		() => Object.assign(Error('RPC call to file/exec failed with error -32002: Access denied'), { name: 'RPCError' }),
		() => Object.assign(Error('Login session is expired'), { name: 'SessionError' })
	];
	for (const make of shapes) {
		const { api, timers } = setup();
		api.read = async () => { throw make(); };
		const pending = api.job('core-update');
		const checked = assert.rejects(pending, { message: 'Access denied. Log in to LuCI again, or ask for write access.' });
		for (let i = 0; i < 5; i++) await tick(timers);
		await checked; assert.equal(api.jobRunning, false);
	}
});
test('poll failures reset after successful poll; lost connection message', async () => {
	const { api, timers } = setup(); let count = 0;
	api.read = async () => { count++; if (count === 5) return { state: 'running' }; throw Error('network down'); };
	const rejected = assert.rejects(api.job('core-update'), { message: 'Lost connection to the router while waiting for the result.' });
	for (let i = 0; i < 10; i++) await tick(timers);
	await rejected; assert.equal(count, 10);
});
test('upload byte size, session, URL, ACL errors and allowed prefixes', async () => {
	let reply, seen;
	const { api } = setup({ request: { post: async (...args) => { seen = args; return { ok: true, status: 200, json: () => reply }; } } });
	const content = '\uFEFFданные: 1\n', size = new Blob([content]).size;
	reply = { size };
	const path = await api.upload('mihowrt-config', content);
	assert.match(path, /^\/tmp\/mihowrt-config\.[a-z0-9]+$/);
	assert.equal(seen[0], '/cgi-bin/cgi-upload'); assert.equal(seen[2].timeout, 0);
	assert.equal(seen[1].get('sessionid'), 'session-secret'); assert.equal(seen[1].get('filename'), path);
	assert.equal(seen[1].get('filedata').size, size); assert.equal(Buffer.from(await seen[1].get('filedata').arrayBuffer()).toString('utf8'), content);
	reply = { size: size - 1 }; await assert.rejects(api.upload('mihowrt-config', content), { message: 'The upload was incomplete. Try again.' });
	for (const message of ['Access to path denied by ACL', 'Cannot create file', undefined]) {
  reply = { failure: [0, ''], message };
  await assert.rejects(api.upload('mihowrt-config', content), { message: 'The upload failed. Check your LuCI permissions and try again.' });
 }
	await assert.rejects(api.upload('../etc/config', content));
	reply = { size }; assert.match(await api.upload('mihowrt-policy-list', content), /^\/tmp\/mihowrt-policy-list\.[a-z0-9]+$/);
});
test('upload of empty content sends one newline because cgi-upload refuses empty files', async () => {
	let seen;
	const { api } = setup({ request: { post: async (...args) => { seen = args; return { ok: true, status: 200, json: () => ({ size: seen[1].get('filedata').size }) }; } } });
	const path = await api.upload('mihowrt-policy-list', '');
	assert.match(path, /^\/tmp\/mihowrt-policy-list\.[a-z0-9]+$/);
	assert.equal(Buffer.from(await seen[1].get('filedata').arrayBuffer()).toString('utf8'), '\n');
});
test('readLarge uses cgi-exec JSON and rejects non-objects', async () => {
	let reply = { content: 'yaml' }, seen;
	const { api } = setup({ fs: { exec_direct: async (...args) => { seen = args; return reply; } } });
	assert.equal(await api.readLarge('read-config'), reply);
	assert.equal(JSON.stringify(seen), JSON.stringify(['/usr/bin/mihowrt-read', ['read-config'], 'json']));
	for (reply of ['yaml', null, 3]) await assert.rejects(api.readLarge('read-config'), { message: 'Unexpected response from the router.' });
	reply = []; assert.equal(await api.readLarge('proxies-json'), reply);
});
test('errorText maps transport errors and preserves useful causes', () => {
	const { api } = setup();
	assert.equal(api.errorText(Object.assign(Error('request timed out'), { name: 'TimeoutError' })), 'The router did not answer in time. The operation may still be running; check again in a minute.');
	assert.equal(api.errorText(Object.assign(Error('permission denied'), { name: 'PermissionError' })), 'Access denied. Log in to LuCI again, or ask for write access.');
	assert.equal(api.errorText({ stderr: 'Error: bad yaml\n' }), 'bad yaml');
	assert.equal(api.errorText(Error('bad yaml')), 'bad yaml');
});
test('transport mapping never rewrites backend output or generic error text', async () => {
	const { api } = setup();
	const timeout = 'The router did not answer in time. The operation may still be running; check again in a minute.';
	const denied = 'Access denied. Log in to LuCI again, or ask for write access.';
	assert.equal(api.errorText(Error('XHR request timed out')), timeout);
	assert.equal(api.errorText(Object.assign(Error('RPC call to file/exec failed with ubus code 6: Permission denied'), { name: 'RPCError' })), denied);
	assert.equal(api.errorText(Object.assign(Error('RPC call to file/exec failed with HTTP error 403: Forbidden'), { name: 'RPCError' })), denied);
	assert.equal(api.errorText(Error('Access denied')), denied);
	for (const message of ['dial tcp: i/o timeout', 'Access denied by provider', 'XHR request timed out', 'Access denied']) {
		for (const field of ['stderr', 'stdout']) {
			assert.equal(api.errorText({ [field]: message }), message);
			const { api: commandApi } = setup({ fs: { exec: async () => ({ code: 1, [field]: message }) } });
			try { await commandApi.read('read-config'); assert.fail('command must reject'); }
			catch (e) { assert.equal(commandApi.errorText(e), message); }
		}
	}
	for (const message of ['dial tcp: i/o timeout', 'Access denied by provider']) assert.equal(api.errorText(Error(message)), message);
});
// C2: backend errors the user can act on, in plain words (EN source; RU in the PO).
const BACKEND_ERRORS = [
	["The provider returned something that is not a Clash/Mihomo config (V2Ray links, base64, sing-box JSON or a web page). Use the Clash/Mihomo link from your provider's account.",
		"The link does not give a Clash/Mihomo config (it looks like V2Ray links, base64, sing-box JSON or a web page). Take the Clash/Mihomo link from your provider's account."],
	['Another operation is running: update-lists', 'Another operation is running: "Remote list update". Wait until it finishes.'],
	['Another operation is running: custom-op', 'Another operation is running: "custom-op". Wait until it finishes.'],
	['Interrupted: the operation was stopped before it finished.', 'The operation was interrupted (for example, by a router reboot). You can run it again.'],
	['Subscription returned an empty config', 'The subscription returned an empty configuration.'],
	['Subscription URL must start with http:// or https://', 'Enter the subscription link that starts with https://'],
	['Subscription download failed: http_404', 'The subscription link was not found (HTTP 404). Check the link with your provider.'],
	['Failed to apply routing rules: nft: syntax error', 'Mihomo started, but the routing rules could not be applied: nft: syntax error'],
	['Failed to apply the new subscription settings: Unsupported dns form: use a block mapping; the previous config is restored',
		'The new subscription settings could not be applied: The "dns" section of the YAML must be a block mapping (one key per line), not {…}, […] or a single value. The previous configuration is back in use.'],
	['Failed to apply the new subscription settings: bad policy; restoring the previous config failed: reload failed; the previous config is saved in /tmp/mihowrt-old.1',
		'The new subscription settings could not be applied: bad policy. Returning to the previous configuration also failed: reload failed. The previous configuration is saved in /tmp/mihowrt-old.1.'],
	['Unsupported x-mihowrt form: use a block mapping', 'The "x-mihowrt" section of the YAML must be a block mapping (one key per line), not {…}, […] or a single value.'],
	['Failed to update 1 of 3 remote lists: Remote lists exceed 8 MiB in total',
		'Could not update 1 of 3 remote lists: The remote lists are larger than 8 MiB in total. Remove some list links or use smaller lists.'],
	['Failed to update 1 of 1 remote lists: Remote list download failed: example.org', 'Could not update 1 of 1 remote list: Remote list download failed: example.org'],
	['Remote lists exceed 8 MiB in total', 'The remote lists are larger than 8 MiB in total. Remove some list links or use smaller lists.'],
	// R13: core update
	['Core update: cannot reach GitHub', 'Could not download the Mihomo core from GitHub. Check the router\'s internet connection. If GitHub is blocked, install the core manually (README, "If GitHub is unavailable").'],
	['Core update: download failed (http_403)', 'Could not download the Mihomo core from GitHub. Check the router\'s internet connection. If GitHub is blocked, install the core manually (README, "If GitHub is unavailable").'],
	['Core update: no asset for mipsle in v1.19.0', 'Could not download the Mihomo core from GitHub. Check the router\'s internet connection. If GitHub is blocked, install the core manually (README, "If GitHub is unavailable").'],
	['Core update: not enough flash: need 24 MiB, free 10 MiB', 'Not enough free flash for the Mihomo core: 24 MiB needed, 10 MiB free.'],
	['Core update: not enough flash: free 5 MiB before unpacking', 'Not enough free flash for the Mihomo core. The current core is kept.'],
	['Core update: unsupported architecture', 'This router\'s CPU is not supported by the Mihomo core.'],
	['Core update: new binary does not run on this router', 'The downloaded core does not run on this router. The current core is kept.'],
	['Core update: new core rejects the current config', 'The new core does not accept your current configuration; the core was not updated.'],
	['Core update: sha256 mismatch', 'The downloaded core file is damaged. Try again.'],
	['Another core update is running', 'The core is already being updated.'],
	['Mihomo core updated, but the service restart failed: config test failed', 'The Mihomo core was updated, but MihoWRT could not restart: config test failed. Press Start on Overview.'],
	['Mihomo core updated, but the service restart failed', 'The Mihomo core was updated, but MihoWRT could not restart. Press Start on Overview.'],
	// R13: backend errors
	['The YAML is empty: nothing was changed.', 'The YAML is empty: nothing was changed.'],
	['There is no previous configuration.', 'There is no previous configuration.'],
	['List dst is larger than 1 MiB.', 'The "Addresses via proxy" list is larger than 1 MiB.'],
	['List custom is larger than 1 MiB.', 'The "custom" list is larger than 1 MiB.'],
	['Runtime is busy (process 1234)', 'The router is busy with another task. Try again in a minute.'],
	['Mihomo hot reload failed', 'Mihomo could not apply the new configuration; the previous one is kept.'],
	['MihoWRT could not start. See the system log.', 'MihoWRT could not start. See the log on the Diagnostics page.'],
	['Invalid MihoWRT settings', 'MihoWRT settings are damaged. Save the Traffic page again or reinstall the package.'],
	['Mihomo config not found: /etc/mihowrt/clash.yaml', 'Mihomo configuration file not found: /etc/mihowrt/clash.yaml'],
	['Failed to apply nftables policy (see /tmp/ruleset.nft)', 'Failed to apply nftables policy: see /tmp/ruleset.nft. Restart MihoWRT; if it happens again, see the log on Diagnostics.']
];
test('errorText maps backend errors to plain words and is idempotent', () => {
	const { api } = setup();
	for (const [raw, plain] of BACKEND_ERRORS) {
		assert.equal(api.errorText({ stderr: 'Error: ' + raw + '\n' }), plain, raw);
		assert.equal(api.errorText(Object.assign(Error(raw), { name: 'JobError' })), plain, 'job error: ' + raw);
		assert.equal(api.errorText({ stderr: plain }), plain, 'mapped text stays: ' + plain);
	}
});
test('public error path maps status strings and summarizes Mihomo rejection', () => {
 const { api } = setup();
 const plain = 'The "dns" section of the YAML must be a block mapping (one key per line), not {…}, […] or a single value.';
 assert.equal(api.errorText('Unsupported dns form: use a block mapping'), plain);
 for (const level of ['error', 'fatal']) {
  const raw = `time="2026-10-27" level=info msg="noise"\ntime="2026-10-27" level=${level} msg="yaml: bad configuration /tmp/mihowrt-config.123"\nconfiguration file /tmp/mihowrt/runtime.candidate.yaml test failed\nMihomo rejected the configuration`;
  const expected = 'Mihomo rejected the configuration. yaml: bad configuration …';
  for (const value of [raw, { name: 'JobError', message: raw }, { stderr: raw }])
   assert.equal(api.errorText(value), expected);
  assert.equal(api.errorText(expected), expected, 'already mapped text stays unchanged');
 }
 assert.equal(api.errorText('Mihomo rejected the configuration'), 'Mihomo rejected the configuration.');
 const yamlSyntax = 'time="2026-10-27" level=error msg="yaml: line 3: did not find expected key"\nconfiguration file /tmp/mihowrt/runtime.candidate.yaml test failed\nMihomo rejected the configuration';
 assert.equal(api.errorText(yamlSyntax), 'Mihomo rejected the configuration. YAML error on line 3: did not find expected key');
 const groupMissing = 'time="2026-10-27" level=error msg="proxy group[0]: G: \'NOPE-MISSING\' not found"\nconfiguration file /tmp/mihowrt/runtime.candidate.yaml test failed\nMihomo rejected the configuration';
 assert.equal(api.errorText(groupMissing), 'Mihomo rejected the configuration. Group "G" refers to a server "NOPE-MISSING" that does not exist.');
});
test('core restart errors take priority over nested rejection', () => {
 const { api } = setup();
 assert.equal(api.errorText('Mihomo core updated, but the service restart failed: Mihomo rejected the configuration'),
  'The Mihomo core was updated, but MihoWRT could not restart: Mihomo rejected the configuration. Press Start on Overview.');
});
test('one-line backend errors map the last non-empty line of job stderr', () => {
 const { api } = setup();
 for (const [raw, plain] of BACKEND_ERRORS)
  assert.equal(api.errorText('time="2026-10-27" level=info msg="checking"\ntime="2026-10-27" level=error msg="bad config"\n' + raw + '\n\n'), plain, raw);
});
for (const op of ['save-config', 'restore-config', 'connect', 'update-subscription', 'auto-update', 'service', 'core-update']) {
 test('unchanged-config note is limited to rejected config-install jobs: ' + op, async () => {
  const { api, timers } = setup();
  const configInstall = !['service', 'core-update'].includes(op);
  api.read = async () => ({ state: 'error', error: 'Mihomo rejected the configuration' });
  const rejected = assert.rejects(api.job(op), { name: 'JobError', message: 'Mihomo rejected the configuration.' +
   (configInstall ? ' Nothing was changed, the previous configuration is still running.' : '') });
  await tick(timers); await rejected;
  let shown;
  const status = async () => ({ state: 'error', id: 'config-1', op, finished: 1000, now: 1001, error: 'Mihomo rejected the configuration' });
  const { api: unseen } = setup({ ui: { addNotification: (a, node) => { shown = node.children.join(''); } }, sessionStorage: storage().sessionStorage });
  unseen.read = status;
  unseen.jobNotice(); await flush();
  assert.equal(shown.includes('Nothing was changed'), configInstall, 'background job notice uses the same scope');
 });
}
test('command errors carry the plain backend text', async () => {
	const { api } = setup({ fs: { exec: async () => ({ code: 1, stderr: 'Error: Another operation is running: core-update\n' }) } });
	await assert.rejects(api.job('update-lists'), { name: 'CommandError', message: 'Another operation is running: "Mihomo core update". Wait until it finishes.' });
	assert.equal(api.jobRunning, false);
});
test('background job errors of any operation use the plain backend text', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '6-1', op: 'update-lists', finished: 1000, now: 1001, error: 'Interrupted: the operation was stopped before it finished.' });
	api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ '"Remote list update" failed: The operation was interrupted (for example, by a router reboot). You can run it again.', 'error' ]]);
});
test('readOnly follows the LuCI view permission', () => {
	assert.equal(setup().api.readOnly(), false, 'no permission info: actions stay');
	for (const [permission, readOnly] of [[false, true], [true, false], [null, false]])
		assert.equal(setup({ L: { env: {}, hasViewPermission: () => permission } }).api.readOnly(), readOnly, String(permission));
});
// E9: one formatter for terminal job errors, applied where the job ends.
for (const op of ['connect', 'update-subscription']) {
	test(`${op} terminal errors carry the plain backend text and stay JobError`, async () => {
		const { store, sessionStorage } = storage();
		const { api, timers } = setup({ sessionStorage });
		api.write = async () => ({ id: '10-1' });
		api.read = async () => ({ state: 'error', error: 'Subscription download failed: http_404' });
		const pending = assert.rejects(api.job(op, 'https://p.example/sub'), { name: 'JobError', message: 'The subscription link was not found (HTTP 404). Check the link with your provider.' });
		await tick(timers); await pending;
		assert.equal(store['mihowrt-seen-job'], '10-1', 'job remembered as seen');
	});
}
test('dead helpers are gone', () => {
	const { api } = setup();
	assert.equal(api.readFile, undefined);
	assert.equal(api.safeLink('https://example.org', 'x', 'cbi-button').attrs.class, undefined, 'safeLink has no class parameter');
	assert(!/safeLink\(/.test(h.extractBetween(h.readSource(apiPath), 'function linkButton', '\n}\n')), 'linkButton checks the URL itself');
});
test('job backend errors reach busy notification unchanged', async () => {
	for (const message of ['dial tcp: i/o timeout', 'Access denied by provider', 'XHR request timed out', 'Access denied']) {
		let notified;
		const { api, timers } = setup({ ui: { addNotification: (title, node) => { notified = node.children[0]; } } });
		api.read = async () => ({ state: 'error', error: message });
		const pending = api.busy(null, () => api.job('save-config'));
		await tick(timers); await pending;
		assert.equal(notified, message);
	}
});
test('readLarge JSON parse errors become a clear router response error; transport stays intact', async () => {
	for (const body of ['', '<html>403 Forbidden</html>', '<html>500 Internal Server Error</html>']) {
		const { api } = setup({ fs: { exec_direct: async () => JSON.parse(body) } });
		await assert.rejects(api.readLarge('read-config'), { message: 'Unexpected response from the router.' });
	}
	for (const err of [Object.assign(Error('Forbidden'), { name: 'PermissionError' }), Error('XHR request timed out')]) {
		const { api } = setup({ fs: { exec_direct: async () => { throw err; } } });
		try { await api.readLarge('read-config'); assert.fail('must reject'); }
		catch (e) { assert.equal(api.errorText(e), api.errorText(err)); }
	}
});
test('upload checks HTTP status before parsing and hides non-JSON errors', async () => {
	for (const status of [200, 403, 500]) for (const body of ['', '<html>403 Forbidden</html>', '<html>500 Internal Server Error</html>']) {
		let parsed = false;
		const { api } = setup({ request: { post: async () => ({ ok: status === 200, status, json: () => { parsed = true; return JSON.parse(body); } }) } });
		await assert.rejects(api.upload('mihowrt-config', 'yaml'), { message: status === 403 ? 'Access denied. Log in to LuCI again, or ask for write access.' : 'Unexpected response from the router.' });
		assert.equal(parsed, status === 200);
	}
});
test('upload suffix uses cryptographic bytes encoded as lowercase hex', async () => {
	let calls = 0;
	const bytes = [0, 1, 10, 15, 16, 127, 128, 255];
	const { api } = setup({
		crypto: { getRandomValues: array => { calls++; assert(array.byteLength >= 8); array.forEach((_, i) => { array[i] = bytes[i % bytes.length]; }); return array; } },
		request: { post: async () => ({ ok: true, status: 200, json: () => ({ size: 4 }) }) }
	});
	const path = await api.upload('mihowrt-config', 'yaml');
	assert.equal(calls, 1);
	assert.match(path, /^\/tmp\/mihowrt-config\.[0-9a-f]{16,}$/);
	assert(path.split('.')[1].startsWith('00010a0f107f80ff'));
});
test('shared helpers', () => {
	const { api } = setup();
	assert.equal(api.modeLabel('proxy-first'), 'All traffic via proxy except exclusions');
	assert.equal(api.linkButton('javascript:x', 'y'), null);
	assert.equal(api.linkButton('https://example.org', '<unsafe>').tag, 'button');
	assert.equal(api.infoGrid([['Key', '<unsafe>']]).attrs.class, 'mw-grid');
	for (const [action, message] of Object.entries({ unchanged: 'Subscription is up to date.', hot_reloaded: 'Subscription updated and applied.', saved: 'Subscription updated.' })) assert.equal(api.actionNotice(action), message);
});
test('jobNotice fills live notice and reloads after completion', async () => {
	let count = 0, reloads = 0;
	const { api, timers } = setup({ location: { reload: () => reloads++ } });
	api.read = async (...args) => { assert.deepEqual(args, count ? ['job-status', '1-2'] : ['job-status']); return ++count === 1 ? { id: '1-2', op: 'core-update', state: 'running' } : { state: 'ok' }; };
	const notice = api.jobNotice(); assert.equal(notice.attrs['aria-live'], 'polite');
	assert.equal(notice.attrs.hidden, undefined); assert.equal(notice.hidden, undefined);
	assert.equal(notice.children.length, 0);
	await flush(); assert.equal(notice.children[0].attrs.class, 'alert-message notice');
	assert.equal(notice.children[0].children[0], '"Mihomo core update" is running…');
	assert.equal(notice.hidden, undefined);
	await tick(timers); assert.equal(reloads, 1);
});
test('jobNotice idle and initial read failure', async () => {
	for (const read of [async () => ({ state: 'none' }), async () => { throw Error('Access denied'); }]) {
		const { api, timers } = setup(); api.read = read;
		const notice = api.jobNotice(); assert.equal(notice.attrs.hidden, undefined); assert.equal(notice.children.length, 0);
		await flush(); assert.equal(timers.length, 0); assert.equal(notice.hidden, undefined);
		if (notice.children.length) assert.equal(notice.children[0].children[0], 'Access denied. Log in to LuCI again, or ask for write access.');
	}
});
// Task 11: a failed background job always shows its error.
function storage() {
	const store = {};
	return { store, sessionStorage: { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = String(v); }, removeItem: k => { delete store[k]; } } };
}
function notifications() {
	const shown = [], roles = [];
	return { shown, roles, ui: { addNotification: (t, node, level) => {
		shown.push([node.children[0], level]);
		return { setAttribute: (k, v) => k === 'role' && roles.push(v) };
	} } };
}
const nowSeconds = () => Math.floor(Date.now() / 1000);
test('running job error reloads with notice', async () => {
	const { store, sessionStorage } = storage(); let reloads = 0, count = 0;
	const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ } });
	api.read = async () => ++count === 1 ? { id: '4-1', op: 'update-subscription', state: 'running' } : { id: '4-1', state: 'error', error: 'boom' };
	api.jobNotice(); await flush();
	await tick(timers);
	assert.equal(reloads, 1);
	assert.deepEqual(JSON.parse(store['mihowrt-notice']), { text: '"Subscription update" failed: boom', type: 'error' });
});
test('running job ok still reloads without a notice', async () => {
	const { store, sessionStorage } = storage(); let reloads = 0, count = 0;
	const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ } });
	api.read = async () => ++count === 1 ? { id: '4-2', op: 'update-subscription', state: 'running' } : { state: 'ok' };
	api.jobNotice(); await flush();
	await tick(timers);
	assert.equal(reloads, 1); assert.equal(store['mihowrt-notice'], undefined);
});
test('finished error shown once', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-1', op: 'core-update', finished: nowSeconds() - 100, error: 'x' });
	api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ '"Mihomo core update" failed: x', 'error' ]]);
	api.jobNotice(); await flush();
	assert.equal(shown.length, 1, 'second page load shows nothing');
});
test('background subscription error is the plain text, announced as alert', async () => {
	const { sessionStorage } = storage(), { shown, roles, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-8', op: 'update-subscription', finished: 1000, now: 1001, error: 'Subscription download failed: http_404' });
	api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ '"Subscription update" failed: The subscription link was not found (HTTP 404). Check the link with your provider.', 'error' ]]);
	assert.deepEqual(roles, [ 'alert' ]);
});
test('error window uses the router clock', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-9', op: 'core-update', finished: 1000, now: 1100, error: 'x' });
	api.jobNotice(); await flush();
	assert.equal(shown.length, 1, 'recent on the router clock even if the browser clock differs');
});
test('old error silent', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-2', op: 'core-update', finished: nowSeconds() - 601, error: 'x' });
	api.jobNotice(); await flush();
	assert.equal(shown.length, 0);
});
test('seen error silent', async () => {
	const { store, sessionStorage } = storage(), { shown, ui } = notifications();
	const { api, timers } = setup({ sessionStorage, ui });
	api.write = async () => ({ id: '7-3' });
	api.read = async (cmd, id) => id ? { state: 'error', error: 'bad' } : { state: 'error', id: '7-3', op: 'core-update', finished: nowSeconds() - 1, error: 'bad' };
	const pending = assert.rejects(api.job('core-update'), { message: 'bad' });
	await tick(timers); await pending;
	assert(String(store['mihowrt-seen-job']).includes('7-3'), 'job() remembers the id it waited for');
	api.jobNotice(); await flush();
	assert.equal(shown.length, 0);
});
test('seen ok job id is stored too', async () => {
	const { store, sessionStorage } = storage();
	const { api, timers } = setup({ sessionStorage });
	api.write = async () => ({ id: '8-1' });
	api.read = async () => ({ state: 'ok', result: {} });
	const pending = api.job('core-update');
	await tick(timers); await pending;
	assert(String(store['mihowrt-seen-job']).includes('8-1'));
});
test('reloadWithNotice survives the reload and shows once', async () => {
	const store = {}; let reloads = 0; const shown = [];
	const sessionStorage = { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: k => { delete store[k]; } };
	const ui = { addNotification: (t, node, level) => shown.push([node.children[0], level]) };
	const first = setup({ sessionStorage, ui, location: { reload: () => reloads++ } });
	first.api.reloadWithNotice('MihoWRT restarted.', 'info');
	assert.equal(reloads, 1); assert.equal(shown.length, 0, 'nothing shown before the reload');
	const next = setup({ sessionStorage, ui }); next.api.read = async () => ({ state: 'none' });
	next.api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ 'MihoWRT restarted.', 'info' ]]);
	next.api.jobNotice(); await flush(); assert.equal(shown.length, 1, 'notice shown once');
});
test('reloadWithNotice stores plain text; empty message shows nothing', async () => {
	for (const [message, expected] of [ [ 'Done.', 'Done.' ], [ undefined, '' ], [ null, '' ], [ '', '' ] ]) {
		const store = {}; const shown = [];
		const sessionStorage = { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: k => { delete store[k]; } };
		const ui = { addNotification: (t, node, level) => shown.push(node.children[0]) };
		setup({ sessionStorage, ui, location: { reload() {} } }).api.reloadWithNotice(message);
		assert.equal(JSON.parse(store['mihowrt-notice']).text, expected);
		const next = setup({ sessionStorage, ui }); next.api.read = async () => ({ state: 'none' });
		next.api.jobNotice(); await flush();
		assert.deepEqual(shown, expected ? [ expected ] : []);
	}
});
test('reloadWithNotice falls back to notify when storage throws, and still reloads', () => {
	let reloads = 0; const shown = [];
	const sessionStorage = { getItem: () => null, removeItem() {}, setItem() { throw new Error('quota'); } };
	const ui = { addNotification: (t, node, level) => shown.push([node.children[0], level]) };
	setup({ sessionStorage, ui, location: { reload: () => reloads++ } }).api.reloadWithNotice('Saved.', 'warning');
	assert.deepEqual(shown, [[ 'Saved.', 'warning' ]]); assert.equal(reloads, 1);
});
test('damaged stored notice is dropped silently and the page renders', async () => {
	for (const raw of [ '{not json', '"str"', 'null', '{"text":""}' ]) {
		const store = { 'mihowrt-notice': raw }; const shown = [];
		const sessionStorage = { getItem: k => store[k] ?? null, setItem() {}, removeItem: k => { delete store[k]; } };
		const { api } = setup({ sessionStorage, ui: { addNotification: () => shown.push(1) } }); api.read = async () => ({ state: 'none' });
		const notice = api.jobNotice(); await flush();
		assert.equal(shown.length, 0); assert.equal(notice.tag, 'div'); assert.equal(store['mihowrt-notice'], undefined);
	}
});
test('views keep action notices across reloads except plain load-error retry', () => {
	for (const name of [ 'overview.js', 'subscription.js' ]) {
		const source = h.readSource('rootfs/www/luci-static/resources/view/mihowrt/' + name);
		assert(!/location\.reload/.test(source.replace("again.addEventListener('click', () => location.reload());", '')), name + ': raw action reload loses the notice');
	}
});
test('no shared helper copies in views', () => {
	for (const name of nodefs.readdirSync(h.sourcePath('rootfs/www/luci-static/resources/view/mihowrt'))) {
		const source = h.readSource('rootfs/www/luci-static/resources/view/mihowrt/' + name);
		assert(!/function\s+(modeLabel|linkButton)\s*\(/.test(source), name + ': helper copy');
		assert(!/rows\.flatMap\(\(\[\s*k,\s*v\s*\]/.test(source), name + ': key/value grid copy');
		assert(!source.includes("res.action === 'hot_reloaded' ? _('Subscription"), name + ': action notice copy');
	}
});
test('overview has no long synchronous operations', () => {
	assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/mihowrt/overview.js')));
});
test('subscription has no long synchronous operations', () => {
	assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/mihowrt/subscription.js')));
});
test('traffic has no long synchronous operations', () => {
	assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/mihowrt/traffic.js')));
});
const longOperations = /(?:api\.write|fs\.exec)\([^;]*(?:core-update|update-subscription|update-lists|apply-lists|save-config)|api\.service\((?!'enable'\))|fs\.exec\([^;]*\/etc\/init\.d\/mihowrt[^;]*(?:start|stop|restart)/;
test('no long synchronous operations in views', () => {
	for (const name of nodefs.readdirSync(h.sourcePath('rootfs/www/luci-static/resources/view/mihowrt')))
		assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/mihowrt/' + name)), name);
});
(async () => {
	for (const [name, fn] of tests) {
		try { await fn(); console.log('ok - api ' + name); }
		catch (err) { console.error('not ok - api ' + name + ': ' + err.message); process.exitCode = 1; }
	}
})();
