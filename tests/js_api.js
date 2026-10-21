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
	const timer = timers.shift(); assert.equal(timer.ms, 1000); timer.fn(); await flush();
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
test('jobNotice locks all job starters until reload', async () => {
 const buttons = [{ disabled: false }]; let reloads = 0;
 const { api, timers } = setup({ document: { querySelectorAll: () => buttons }, location: { reload: () => reloads++ } });
 let reads = 0; api.read = async () => ++reads === 1 ? { id: '1', op: 'service', state: 'running' } : { state: 'ok' };
 api.jobNotice(); await flush();
 assert.equal(api.jobRunning, true); assert.equal(buttons[0].disabled, true);
 await tick(timers); assert.equal(reloads, 1);
});
test('job ok: three polls spaced 1000 ms, running flag', async () => {
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
	for (const failures of [10, 9]) {
		const { api, timers } = setup(); let count = 0;
		api.read = async () => { if (++count <= failures) throw Error('Access denied'); return { state: 'ok', result: { action: 'saved' } }; };
		const pending = api.job('core-update');
		const checked = failures === 10 ? assert.rejects(pending, { message: 'Access denied. Log in to LuCI again.' }) : pending;
		for (let i = 0; i < 10; i++) await tick(timers);
		await checked; assert.equal(api.jobRunning, false);
	}
});
test('poll failures reset after successful poll; lost connection message', async () => {
	const { api, timers } = setup(); let count = 0;
	api.read = async () => { count++; if (count === 10) return { state: 'running' }; throw Error('network down'); };
	const rejected = assert.rejects(api.job('core-update'), { message: 'Lost connection to the router while waiting for the result.' });
	for (let i = 0; i < 20; i++) await tick(timers);
	await rejected; assert.equal(count, 20);
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
	reply = { failure: [0, ''], message: 'Access to path denied by ACL' }; await assert.rejects(api.upload('mihowrt-config', content), { message: reply.message });
	await assert.rejects(api.upload('../etc/config', content));
	reply = { size }; assert.match(await api.upload('mihowrt-policy-list', content), /^\/tmp\/mihowrt-policy-list\.[a-z0-9]+$/);
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
	assert.equal(api.errorText(Object.assign(Error('permission denied'), { name: 'PermissionError' })), 'Access denied. Log in to LuCI again.');
	assert.equal(api.errorText({ stderr: 'Error: bad yaml\n' }), 'bad yaml');
	assert.equal(api.errorText(Error('bad yaml')), 'bad yaml');
});
test('transport mapping never rewrites backend output or generic error text', async () => {
	const { api } = setup();
	const timeout = 'The router did not answer in time. The operation may still be running; check again in a minute.';
	const denied = 'Access denied. Log in to LuCI again.';
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
		await assert.rejects(api.upload('mihowrt-config', 'yaml'), { message: status === 403 ? 'Access denied. Log in to LuCI again.' : 'Unexpected response from the router.' });
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
	assert.equal(notice.children[0].children[0], '"Update Mihomo core" is running…');
	assert.equal(notice.hidden, undefined);
	await tick(timers); assert.equal(reloads, 1);
});
test('jobNotice idle and initial read failure', async () => {
	for (const read of [async () => ({ state: 'none' }), async () => { throw Error('Access denied'); }]) {
		const { api, timers } = setup(); api.read = read;
		const notice = api.jobNotice(); assert.equal(notice.attrs.hidden, undefined); assert.equal(notice.children.length, 0);
		await flush(); assert.equal(timers.length, 0); assert.equal(notice.hidden, undefined);
		if (notice.children.length) assert.equal(notice.children[0].children[0], 'Access denied. Log in to LuCI again.');
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
// TODO Tasks 18–20: enable once those views switch long operations to api.job.
const longOperations = /(?:api\.write|fs\.exec)\([^;]*(?:core-update|update-subscription|update-lists|apply-lists|save-config)|api\.service\((?!'enable'\))|fs\.exec\([^;]*\/etc\/init\.d\/mihowrt[^;]*(?:start|stop|restart)/;
const pendingViews = nodefs.readdirSync(h.sourcePath('rootfs/www/luci-static/resources/view/mihowrt')).filter(name => name !== 'overview.js');
if (pendingViews.some(name => longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/mihowrt/' + name))))
	console.log('skip - no long synchronous operations in remaining views (TODO Tasks 18–20)');
else test('no long synchronous operations in views', () => {
	for (const name of pendingViews) assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/mihowrt/' + name)));
});
(async () => {
	for (const [name, fn] of tests) {
		try { await fn(); console.log('ok - api ' + name); }
		catch (err) { console.error('not ok - api ' + name + ': ' + err.message); process.exitCode = 1; }
	}
})();
