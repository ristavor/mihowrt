#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/policy.js'), 'utf8');
const normalizeMatch = source.match(/function normalizeBlock[\s\S]*?\n}\n\nfunction currentNormalizedListValue/);
const syncMatch = source.match(/function syncListCaches[\s\S]*?\n}\n\nfunction hasListValueChanges/);
const listChangesMatch = source.match(/function hasListValueChanges[\s\S]*?\n}\n\nfunction hasMihowrtUciChanges/);
const mihowrtChangesMatch = source.match(/function hasMihowrtUciChanges[\s\S]*?\n}\n\nasync function reloadPolicyIfNeeded/);
const reloadMatch = source.match(/async function reloadPolicyIfNeeded[\s\S]*?\n}\n\nasync function removeListFileIfPresent/);
const removeMatch = source.match(/async function removeListFileIfPresent[\s\S]*?\n}\n\nfunction bindTextFileOption/);
const bindMatch = source.match(/function bindTextFileOption[\s\S]*?\n}\n\nreturn view.extend/);
const handleSaveApplyStart = source.indexOf('\thandleSaveApply: async function(ev, mode) {');
const handleSaveApplyEnd = source.indexOf('\n\t},\n\n\tload:', handleSaveApplyStart);

if (!normalizeMatch)
	throw new Error('normalizeBlock() not found');
if (!syncMatch)
	throw new Error('syncListCaches() not found');
if (!listChangesMatch)
	throw new Error('hasListValueChanges() not found');
if (!mihowrtChangesMatch)
	throw new Error('hasMihowrtUciChanges() not found');
if (!reloadMatch)
	throw new Error('reloadPolicyIfNeeded() not found');
if (!removeMatch)
	throw new Error('removeListFileIfPresent() not found');
if (!bindMatch)
	throw new Error('bindTextFileOption() not found');
if (handleSaveApplyStart === -1 || handleSaveApplyEnd === -1)
	throw new Error('handleSaveApply() not found');

const normalizeFnSource = normalizeMatch[0].replace(/\n\nfunction currentNormalizedListValue$/, '');
const syncFnSource = syncMatch[0].replace(/\n\nfunction hasListValueChanges$/, '');
const listChangesFnSource = listChangesMatch[0].replace(/\n\nfunction hasMihowrtUciChanges$/, '');
const mihowrtChangesFnSource = mihowrtChangesMatch[0].replace(/\n\nasync function reloadPolicyIfNeeded$/, '');
const reloadFnSource = reloadMatch[0].replace(/\n\nasync function removeListFileIfPresent$/, '');
const removeFnSource = removeMatch[0].replace(/\n\nfunction bindTextFileOption$/, '');
const bindFnSource = bindMatch[0].replace(/\n\nreturn view.extend$/, '');
const handleSaveApplySource = source
	.slice(handleSaveApplyStart, handleSaveApplyEnd + 3)
	.trim()
	.replace(/^handleSaveApply: /, '');
const context = {
	writeError: null,
	removeError: null,
	execCalls: [],
	notifications: [],
	uciChanges: {},
	applyCalls: [],
	fs: {
		writeCalls: [],
		removeCalls: [],
		write(path, value) {
			if (context.writeError)
				return Promise.reject(new Error(context.writeError));
			this.writeCalls.push({ path, value });
			return Promise.resolve();
		},
		remove(path) {
			if (context.removeError) {
				const error = new Error(context.removeError.message || context.removeError);
				if (context.removeError.name)
					error.name = context.removeError.name;
				return Promise.reject(error);
			}
			this.removeCalls.push(path);
			return Promise.resolve();
		},
		exec(cmd, args) {
			context.execCalls.push({ cmd, args });
			return Promise.resolve({ code: context.reloadRc || 0, stdout: '', stderr: context.reloadRc ? 'reload failed' : '' });
		}
	},
	uci: {
		changes: async() => context.uciChanges
	},
	ui: {
		changes: {
			apply: async(mode) => context.applyCalls.push(mode)
		}
	},
	mihowrtUi: {
		getServiceStatus: async() => true,
		execErrorDetail: result => String(result?.stderr || result?.stdout || '').trim() || 'unknown error',
		notify: (message, level) => context.notifications.push({ message, level })
	},
	SERVICE_SCRIPT: '/etc/init.d/mihowrt'
};

vm.createContext(context);
vm.runInContext(`function _(value) { return value; }\nif (!String.prototype.format) { String.prototype.format = function() { let i = 0; const args = arguments; return this.replace(/%s/g, () => String(args[i++])); }; }\nlet dstValueCache = null; let srcValueCache = null; let dstListOption = null; let srcListOption = null;\nconst SETTINGS_SECTION_ID = 'settings';\nconst SERVICE_NAME = 'mihowrt';\nconst SERVICE_SCRIPT = '/etc/init.d/mihowrt';\n${normalizeFnSource}\nfunction currentNormalizedListValue(option) { return option ? normalizeBlock(option.formvalue(SETTINGS_SECTION_ID)) : ''; }\n${syncFnSource}\n${listChangesFnSource}\n${mihowrtChangesFnSource}\n${reloadFnSource}\n${removeFnSource}\n${bindFnSource}\nglobalThis.bindTextFileOption = bindTextFileOption;\nglobalThis.syncListCaches = syncListCaches;\nglobalThis.hasMihowrtUciChanges = hasMihowrtUciChanges;\nglobalThis.reloadPolicyIfNeeded = reloadPolicyIfNeeded;\nglobalThis.getDstCache = () => dstValueCache;\nglobalThis.getSrcCache = () => srcValueCache;\nglobalThis.setDstCache = value => { dstValueCache = value; };\nglobalThis.setSrcCache = value => { srcValueCache = value; };\nglobalThis.setListOptions = (dst, src) => { dstListOption = dst; srcListOption = src; };\nglobalThis.handleSaveApply = ${handleSaveApplySource};`, context);

(async () => {
	const option = {};
	context.setDstCache('1.1.1.1\n');
	context.bindTextFileOption(option, 'dst', '/opt/clash/lst/always_proxy_dst.txt', 'desc');
	await option.write('settings', '1.1.1.1');
	if (context.fs.writeCalls.length !== 0)
		throw new Error('bindTextFileOption.write should skip no-op writes');

	await option.write('settings', '2.2.2.2');
	if (context.fs.writeCalls.length !== 1)
		throw new Error('bindTextFileOption.write should persist changed content once');
	if (context.fs.writeCalls[0].value !== '2.2.2.2\n')
		throw new Error('bindTextFileOption.write should normalize changed content');
	if (context.getDstCache() !== '2.2.2.2\n')
		throw new Error('bindTextFileOption.write should update cache after changed content');

	context.writeError = 'disk full';
	let writeFailed = false;
	try {
		await option.write('settings', '4.4.4.4');
	}
	catch (e) {
		writeFailed = e.message === 'disk full';
	}
	if (!writeFailed)
		throw new Error('bindTextFileOption.write should reject when fs.write fails');
	if (context.getDstCache() !== '2.2.2.2\n')
		throw new Error('bindTextFileOption.write should keep cache unchanged on write failure');
	context.writeError = null;

	context.fs.writeCalls.length = 0;
	context.fs.removeCalls.length = 0;
	context.setSrcCache('');
	const removeOption = {};
	context.bindTextFileOption(removeOption, 'src', '/opt/clash/lst/always_proxy_src.txt', 'desc');
	await removeOption.remove();
	if (context.fs.removeCalls.length !== 0)
		throw new Error('bindTextFileOption.remove should skip no-op empty deletes');

	context.setSrcCache('erase-me\n');
	await removeOption.write('settings', '');
	if (context.fs.removeCalls.length !== 1)
		throw new Error('bindTextFileOption.write should delete file when content becomes empty');
	if (context.getSrcCache() !== '')
		throw new Error('bindTextFileOption.write should clear cache after delete');

	context.setSrcCache('missing-ok\n');
	context.removeError = { name: 'NotFoundError', message: 'not found' };
	await removeOption.remove();
	if (context.getSrcCache() !== '')
		throw new Error('bindTextFileOption.remove should clear cache when file already absent');
	context.removeError = null;

	context.setSrcCache('erase-me\n');
	context.removeError = 'permission denied';
	let removeFailed = false;
	try {
		await removeOption.remove();
	}
	catch (e) {
		removeFailed = e.message === 'permission denied';
	}
	if (!removeFailed)
		throw new Error('bindTextFileOption.remove should reject when fs.remove fails');
	if (context.getSrcCache() !== 'erase-me\n')
		throw new Error('bindTextFileOption.remove should keep cache unchanged on remove failure');
	context.removeError = null;

	context.setDstCache('stale\n');
	context.setSrcCache('old\n');
	context.syncListCaches(' 3.3.3.3\r\n', '');
	if (context.getDstCache() !== '3.3.3.3\n')
		throw new Error('syncListCaches should refresh destination cache from latest file contents');
	if (context.getSrcCache() !== '')
		throw new Error('syncListCaches should refresh source cache from latest file contents');

	if (context.hasMihowrtUciChanges({ network: [['set']] }))
		throw new Error('hasMihowrtUciChanges should ignore unrelated UCI package changes');
	if (!context.hasMihowrtUciChanges({ mihowrt: [['set']], network: [['set']] }))
		throw new Error('hasMihowrtUciChanges should detect mihowrt package changes');

	context.execCalls.length = 0;
	context.applyCalls.length = 0;
	context.notifications.length = 0;
	context.uciChanges = { network: [['set', 'lan']] };
	context.syncListCaches('1.1.1.1\n', '');
	context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' });
	await context.handleSaveApply.call({ handleSave: async() => {} }, null, '0');
	if (context.applyCalls.length !== 0)
		throw new Error('handleSaveApply should not apply unrelated pending UCI changes');
	if (!context.execCalls.some(call => call.cmd === '/etc/init.d/mihowrt' && call.args[0] === 'reload'))
		throw new Error('handleSaveApply should reload service for list-only changes even when other packages have pending UCI changes');

	context.execCalls.length = 0;
	context.applyCalls.length = 0;
	context.uciChanges = { mihowrt: [['set', 'settings']] };
	context.syncListCaches('1.1.1.1\n', '');
	context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' });
	await context.handleSaveApply.call({ handleSave: async() => {} }, null, '1');
	if (context.applyCalls.length !== 1 || context.applyCalls[0] !== false)
		throw new Error('handleSaveApply should apply mihowrt UCI changes through LuCI');
	if (!context.execCalls.some(call => call.cmd === '/etc/init.d/mihowrt' && call.args[0] === 'reload'))
		throw new Error('handleSaveApply should reload after applying mihowrt UCI when list files also changed');
	})().catch(err => {
		throw err;
	});
EOF

pass "policy view helpers"
