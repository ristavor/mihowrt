#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/policy.js'), 'utf8');
if (!source.includes("s.option(form.Button, '_update_remote_lists'"))
	throw new Error('policy.js should render update remote lists button near remote list settings');
if (source.includes('const toolbar = E('))
	throw new Error('policy.js should not render update remote lists as a detached toolbar');
const normalizeMatch = source.match(/function normalizeBlock[\s\S]*?\n}\n\nfunction currentNormalizedListValue/);
const syncMatch = source.match(/function syncListCaches[\s\S]*?\n}\n\nfunction hasListValueChanges/);
const listChangesMatch = source.match(/function hasListValueChanges[\s\S]*?\n}\n\nfunction hasMihowrtUciChanges/);
const mihowrtChangesMatch = source.match(/function hasMihowrtUciChanges[\s\S]*?\n}\n\nfunction changeMentionsOption/);
const policyRemoteChangeMatch = source.match(/function changeMentionsOption[\s\S]*?\n}\n\nasync function reloadPolicyIfNeeded/);
		const reloadMatch = source.match(/async function reloadPolicyIfNeeded[\s\S]*?\n}\n\nasync function updateRemoteLists/);
		const updateMatch = source.match(/async function updateRemoteLists[\s\S]*?\n}\n\nfunction bindTextFileOption/);
const bindMatch = source.match(/function bindTextFileOption[\s\S]*?\n}\n\nreturn view.extend/);
const handleSaveStart = source.indexOf('\thandleSave: async function() {');
const handleSaveEnd = source.indexOf('\n\t},\n\n\thandleSaveApply:', handleSaveStart);
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
if (!policyRemoteChangeMatch)
	throw new Error('policyRemoteAutoUpdateChanged() not found');
	if (!reloadMatch)
		throw new Error('reloadPolicyIfNeeded() not found');
	if (!updateMatch)
		throw new Error('updateRemoteLists() not found');
	if (!bindMatch)
		throw new Error('bindTextFileOption() not found');
if (handleSaveStart === -1 || handleSaveEnd === -1)
	throw new Error('handleSave() not found');
if (handleSaveApplyStart === -1 || handleSaveApplyEnd === -1)
	throw new Error('handleSaveApply() not found');

const normalizeFnSource = normalizeMatch[0].replace(/\n\nfunction currentNormalizedListValue$/, '');
const syncFnSource = syncMatch[0].replace(/\n\nfunction hasListValueChanges$/, '');
const listChangesFnSource = listChangesMatch[0].replace(/\n\nfunction hasMihowrtUciChanges$/, '');
const mihowrtChangesFnSource = mihowrtChangesMatch[0].replace(/\n\nfunction changeMentionsOption$/, '');
const policyRemoteChangeFnSource = policyRemoteChangeMatch[0].replace(/\n\nasync function reloadPolicyIfNeeded$/, '');
		const reloadFnSource = reloadMatch[0].replace(/\n\nasync function updateRemoteLists$/, '');
			const updateFnSource = updateMatch[0].replace(/\n\nfunction bindTextFileOption$/, '');
const bindFnSource = bindMatch[0].replace(/\n\nreturn view.extend$/, '');
const handleSaveSource = source
	.slice(handleSaveStart, handleSaveEnd + 3)
	.trim()
	.replace(/^handleSave: /, '');
const handleSaveApplySource = source
	.slice(handleSaveApplyStart, handleSaveApplyEnd + 3)
	.trim()
	.replace(/^handleSaveApply: /, '');
const context = {
		applyPolicyListError: null,
		execCalls: [],
		applyPolicyListCalls: [],
		notifications: [],
		uciChanges: {},
		uciValues: {
			policy_mode: 'direct-first',
			source_network_interfaces: ['br-lan'],
			dns_hijack: '1',
			route_table_id: '',
			route_rule_priority: '',
			disable_quic: '1',
			policy_remote_update_interval: '0'
		},
			applyCalls: [],
			commitCalls: [],
			initCalls: [],
			serviceStatus: true,
			serviceStatusCalls: [],
			updateChanged: false,
		updateError: null,
		syncPolicyRemoteError: null,
		updateButtonNode: { disabled: false },
		updateButtonOption: {
			readonly: null,
			cbid: sectionId => `cbid.mihowrt.${sectionId}._update_remote_lists`
		},
		document: {
			getElementById(id) {
				context.lastButtonLookupId = id;
				return {
					previousElementSibling: {
						querySelector(selector) {
							context.lastButtonQuerySelector = selector;
							return context.updateButtonNode;
						}
					}
				};
			}
		},
		fs: {
			exec(cmd, args) {
				context.execCalls.push({ cmd, args });
				return Promise.resolve({ code: context.reloadRc || 0, stdout: '', stderr: context.reloadRc ? 'reload failed' : '' });
		}
		},
		uci: {
			get: (config, section, optionName) => context.uciValues[optionName],
			changes: async() => context.uciChanges
		},
	ui: {
		changes: {
			apply: async(mode) => {
				context.applyCalls.push(mode);
				if (context.applyError)
					throw new Error(context.applyError);
			},
			init: async() => context.initCalls.push(true)
		}
		},
			mihowrtUi: {
				getServiceStatus: async(name, script) => {
					context.serviceStatusCalls.push({ name, script });
					return context.serviceStatus;
				},
				execErrorDetail: result => String(result?.stderr || result?.stdout || '').trim() || 'unknown error',
				notify: (message, level) => context.notifications.push({ message, level })
			},
			backendHelper: {
				applyPolicyLists: async(values, reload) => {
					if (context.applyPolicyListError)
						throw new Error(context.applyPolicyListError);
					context.applyPolicyListCalls.push({
						values: Object.assign({}, values),
						reload: !!reload
					});
					return { saved: true, changed: true, reloaded: !!reload };
				},
				updatePolicyLists: async() => {
					if (context.updateError)
						throw new Error(context.updateError);
				context.execCalls.push({ cmd: '/usr/bin/mihowrt', args: ['update-policy-lists'] });
				return context.updateChanged;
			},
			syncPolicyRemoteAutoUpdate: async() => {
				if (context.syncPolicyRemoteError)
					throw new Error(context.syncPolicyRemoteError);
				context.execCalls.push({ cmd: '/usr/bin/mihowrt', args: ['sync-policy-remote-auto-update'] });
			}
		},
		SERVICE_SCRIPT: '/etc/init.d/mihowrt'
	};

	vm.createContext(context);
	vm.runInContext(`function _(value) { return value; }\nif (!String.prototype.format) { String.prototype.format = function() { let i = 0; const args = arguments; return this.replace(/%s/g, () => String(args[i++])); }; }\nlet dstValueCache = null; let srcValueCache = null; let directDstValueCache = null; let policyMap = null; let policyModeOption = null; let policySettingOptions = {}; let policySettingsCache = {}; let dstListOption = null; let srcListOption = null; let directDstListOption = null; let updateListsButton = null; let policyActionInFlight = false; let policyListWriteTransaction = null; let policyModeCache = 'direct-first';\nconst DST_LIST_FILE = '/opt/clash/lst/always_proxy_dst.txt';\nconst SRC_LIST_FILE = '/opt/clash/lst/always_proxy_src.txt';\nconst DIRECT_DST_LIST_FILE = '/opt/clash/lst/direct_dst.txt';\nconst SETTINGS_SECTION_ID = 'settings';\nconst SERVICE_NAME = 'mihowrt';\nconst SERVICE_SCRIPT = '/etc/init.d/mihowrt';\nconst commitUciPackage = async(config) => { globalThis.commitCalls.push(config); };\n${normalizeFnSource}\nfunction currentNormalizedListValue(option) { return option ? normalizeBlock(option.formvalue(SETTINGS_SECTION_ID)) : ''; }\n${syncFnSource}\n${listChangesFnSource}\n${mihowrtChangesFnSource}\n${policyRemoteChangeFnSource}\n${reloadFnSource}\n${updateFnSource}\n${bindFnSource}\nglobalThis.bindTextFileOption = bindTextFileOption;\nglobalThis.syncListCaches = syncListCaches;\nglobalThis.hasListValueChanges = hasListValueChanges;\nglobalThis.hasMihowrtUciChanges = hasMihowrtUciChanges;\nglobalThis.policyRemoteAutoUpdateChanged = policyRemoteAutoUpdateChanged;\nglobalThis.mihowrtUciChangesOnlyPolicyRemoteAutoUpdate = mihowrtUciChangesOnlyPolicyRemoteAutoUpdate;\nglobalThis.reloadPolicyIfNeeded = reloadPolicyIfNeeded;\nglobalThis.updateRemoteLists = updateRemoteLists;\nglobalThis.beginPolicyListWriteTransaction = beginPolicyListWriteTransaction;\nglobalThis.flushPolicyListWrites = flushPolicyListWrites;\nglobalThis.rollbackPolicyListWrites = rollbackPolicyListWrites;\nglobalThis.clearPolicyListWriteTransaction = clearPolicyListWriteTransaction;\nglobalThis.isPolicyListWriteTransactionActive = () => !!policyListWriteTransaction;\nglobalThis.getDstCache = () => dstValueCache;\nglobalThis.getSrcCache = () => srcValueCache;\nglobalThis.getDirectDstCache = () => directDstValueCache;\nglobalThis.getPolicyActionInFlight = () => policyActionInFlight;\nglobalThis.setDstCache = value => { dstValueCache = value; };\nglobalThis.setSrcCache = value => { srcValueCache = value; };\nglobalThis.setDirectDstCache = value => { directDstValueCache = value; };\nglobalThis.setPolicyMap = value => { policyMap = value; };\nglobalThis.setUpdateListsButton = value => { updateListsButton = value; };\nglobalThis.setPolicyActionBusy = setPolicyActionBusy;\nglobalThis.setPolicyMode = value => { policyModeOption = { formvalue: () => value }; };\nglobalThis.setPolicyModeCache = value => { policyModeCache = value; policySettingsCache.policy_mode = value; };\nglobalThis.setListOptions = (dst, src, directDst) => { dstListOption = dst; srcListOption = src; directDstListOption = directDst; };\nglobalThis.handleSave = ${handleSaveSource};\nglobalThis.handleSaveApply = ${handleSaveApplySource};`, context);

(async () => {
	context.setPolicyMap({ readonly: false, save: async() => {} });
	context.setUpdateListsButton(context.updateButtonOption);
	context.setPolicyActionBusy(true);
	if (!context.updateButtonNode.disabled || context.updateButtonOption.readonly !== true)
		throw new Error('setPolicyActionBusy should disable rendered update remote lists button');
	if (context.lastButtonLookupId !== 'cbid.mihowrt.settings._update_remote_lists' || context.lastButtonQuerySelector !== 'button')
		throw new Error('setPolicyActionBusy should find rendered form button node');
	context.setPolicyActionBusy(false);
	if (context.updateButtonNode.disabled || context.updateButtonOption.readonly !== null)
		throw new Error('setPolicyActionBusy should re-enable rendered update remote lists button');

	const option = {};
	context.setDstCache('1.1.1.1\n');
	context.bindTextFileOption(option, 'dst', '/opt/clash/lst/always_proxy_dst.txt', 'desc');
		await option.write('settings', '1.1.1.1');
		if (context.applyPolicyListCalls.length !== 0)
			throw new Error('bindTextFileOption.write should skip no-op writes');

		await option.write('settings', '2.2.2.2');
		if (context.applyPolicyListCalls.length !== 1)
			throw new Error('bindTextFileOption.write should apply changed content through backend once');
		if (context.applyPolicyListCalls[0].values.dst !== '2.2.2.2\n')
			throw new Error('bindTextFileOption.write should normalize changed content');
		if (context.getDstCache() !== '2.2.2.2\n')
			throw new Error('bindTextFileOption.write should update cache after changed content');

		context.applyPolicyListCalls.length = 0;
		context.setDstCache('2.2.2.2\n');
		context.beginPolicyListWriteTransaction();
		await option.write('settings', '3.3.3.3');
		if (context.applyPolicyListCalls.length !== 0)
			throw new Error('bindTextFileOption.write should stage list writes inside transaction');
		if (context.getDstCache() !== '2.2.2.2\n')
			throw new Error('bindTextFileOption.write should keep cache unchanged until transaction flush');
		await context.flushPolicyListWrites();
		if (context.applyPolicyListCalls.length !== 1 || context.applyPolicyListCalls[0].values.dst !== '3.3.3.3\n')
			throw new Error('flushPolicyListWrites should apply staged list writes');
		if (context.getDstCache() !== '3.3.3.3\n')
			throw new Error('flushPolicyListWrites should update cache after staged write');
		await context.rollbackPolicyListWrites();
		if (context.applyPolicyListCalls.length !== 2 || context.applyPolicyListCalls[1].values.dst !== '2.2.2.2\n')
			throw new Error('rollbackPolicyListWrites should restore previous list content');
		if (context.getDstCache() !== '2.2.2.2\n')
			throw new Error('rollbackPolicyListWrites should restore cache');
		context.clearPolicyListWriteTransaction();

		context.applyPolicyListCalls.length = 0;
		context.setDstCache('2.2.2.2\n');
		context.beginPolicyListWriteTransaction();
		await option.write('settings', '2.2.2.2');
		await context.flushPolicyListWrites();
		await context.rollbackPolicyListWrites();
		if (context.applyPolicyListCalls.length !== 0)
			throw new Error('policy list transaction should not write unchanged files during flush or rollback');
		context.clearPolicyListWriteTransaction();

		context.applyPolicyListCalls.length = 0;
		context.setDstCache('2.2.2.2\n');
		context.beginPolicyListWriteTransaction();
		await option.write('settings', '3.3.3.3');
		await option.write('settings', '2.2.2.2');
		await context.flushPolicyListWrites();
		await context.rollbackPolicyListWrites();
		if (context.applyPolicyListCalls.length !== 0)
			throw new Error('policy list transaction should not write when staged content returns to original value');
		context.clearPolicyListWriteTransaction();

		context.applyPolicyListError = 'disk full';
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
		context.applyPolicyListError = null;

		context.applyPolicyListCalls.length = 0;
			context.setSrcCache('');
			const removeOption = {};
			context.bindTextFileOption(removeOption, 'src', '/opt/clash/lst/always_proxy_src.txt', 'desc');
			await removeOption.remove();
			if (context.applyPolicyListCalls.length !== 0)
				throw new Error('bindTextFileOption.remove should skip no-op empty deletes');

			context.setSrcCache('hidden-mode-list\n');
			await removeOption.remove();
			if (context.applyPolicyListCalls.length !== 0)
				throw new Error('bindTextFileOption.remove should preserve hidden depends() list files');
			if (context.getSrcCache() !== 'hidden-mode-list\n')
				throw new Error('bindTextFileOption.remove should keep cache for hidden depends() lists');

			context.setSrcCache('erase-me\n');
			await removeOption.write('settings', '');
			if (context.applyPolicyListCalls.length !== 1 || context.applyPolicyListCalls[0].values.src !== '')
				throw new Error('bindTextFileOption.write should ask backend to delete file when content becomes empty');
			if (context.getSrcCache() !== '')
				throw new Error('bindTextFileOption.write should clear cache after delete');

		context.applyPolicyListCalls.length = 0;
		context.setDirectDstCache('8.8.8.8\n');
		const directOption = {};
		context.bindTextFileOption(directOption, 'direct-dst', '/opt/clash/lst/direct_dst.txt', 'desc');
		await directOption.write('settings', '9.9.9.9');
		if (context.applyPolicyListCalls.length !== 1 || context.applyPolicyListCalls[0].values.direct !== '9.9.9.9\n')
			throw new Error('bindTextFileOption.write should apply direct destination content through backend');
		if (context.getDirectDstCache() !== '9.9.9.9\n')
			throw new Error('bindTextFileOption.write should update direct destination cache');

	context.setDstCache('stale\n');
	context.setSrcCache('old\n');
	context.setDirectDstCache('direct-old\n');
	context.syncListCaches(' 3.3.3.3\r\n', '', ' 8.8.8.8\r\n');
	if (context.getDstCache() !== '3.3.3.3\n')
		throw new Error('syncListCaches should refresh destination cache from latest file contents');
	if (context.getSrcCache() !== '')
		throw new Error('syncListCaches should refresh source cache from latest file contents');
	if (context.getDirectDstCache() !== '8.8.8.8\n')
		throw new Error('syncListCaches should refresh direct destination cache from latest file contents');

	context.setPolicyMode('direct-first');
	context.setListOptions({ formvalue: () => '1.1.1.1\n' }, { formvalue: () => '' }, { formvalue: () => 'changed-direct\n' });
	context.syncListCaches('1.1.1.1\n', '', 'old-direct\n');
	if (context.hasListValueChanges())
		throw new Error('hasListValueChanges should ignore direct list changes in direct-first mode');

	context.setPolicyMode('proxy-first');
	if (!context.hasListValueChanges())
		throw new Error('hasListValueChanges should detect direct list changes in proxy-first mode');

	if (context.hasMihowrtUciChanges({ network: [['set']] }))
		throw new Error('hasMihowrtUciChanges should ignore unrelated UCI package changes');
	if (!context.hasMihowrtUciChanges({ mihowrt: [['set']], network: [['set']] }))
		throw new Error('hasMihowrtUciChanges should detect mihowrt package changes');
	if (context.policyRemoteAutoUpdateChanged({ mihowrt: [['set', 'settings', 'policy_mode', 'proxy-first']] }))
		throw new Error('policyRemoteAutoUpdateChanged should ignore unrelated mihowrt options');
	if (!context.policyRemoteAutoUpdateChanged({ mihowrt: [['set', 'settings', 'policy_remote_update_interval', '12']] }))
		throw new Error('policyRemoteAutoUpdateChanged should detect policy remote interval changes');
	if (!context.mihowrtUciChangesOnlyPolicyRemoteAutoUpdate({ mihowrt: [['set', 'settings', 'policy_remote_update_interval', '12']] }))
		throw new Error('mihowrtUciChangesOnlyPolicyRemoteAutoUpdate should accept only policy remote interval changes');
	if (!context.mihowrtUciChangesOnlyPolicyRemoteAutoUpdate({ mihowrt: [['remove', 'settings', 'policy_remote_update_interval']] }))
		throw new Error('mihowrtUciChangesOnlyPolicyRemoteAutoUpdate should accept policy remote interval removal');
	if (context.mihowrtUciChangesOnlyPolicyRemoteAutoUpdate({ mihowrt: [['set', 'settings', 'policy_remote_update_interval', '12']], network: [['set', 'lan', 'ipaddr', '192.168.1.1']] }))
		throw new Error('mihowrtUciChangesOnlyPolicyRemoteAutoUpdate should reject mixed package changes');
		if (context.mihowrtUciChangesOnlyPolicyRemoteAutoUpdate({ mihowrt: [['set', 'settings', 'policy_mode', 'proxy-first']] }))
			throw new Error('mihowrtUciChangesOnlyPolicyRemoteAutoUpdate should reject other mihowrt options');

			context.applyPolicyListCalls.length = 0;
			context.serviceStatusCalls.length = 0;
			context.serviceStatus = true;
			context.setPolicyMode('direct-first');
			context.syncListCaches('1.1.1.1\n', '', '');
			context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
			context.setPolicyMap({ readonly: false, save: async() => option.write('settings', '2.2.2.2') });
			await context.handleSave.call({});
			if (context.applyPolicyListCalls.length !== 1 ||
				context.applyPolicyListCalls[0].values.dst !== '2.2.2.2\n' ||
				context.applyPolicyListCalls[0].reload !== true)
				throw new Error('handleSave should reload live policy for list-only saves while service is running');
			if (context.serviceStatusCalls.length !== 1)
				throw new Error('handleSave should check service status before applying list-only save');

			context.applyPolicyListCalls.length = 0;
			context.serviceStatusCalls.length = 0;
			context.syncListCaches('2.2.2.2\n', '', '');
			context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
			context.setPolicyMap({ readonly: false, save: async() => {} });
			await context.handleSave.call({});
			if (context.applyPolicyListCalls.length !== 0)
				throw new Error('handleSave should skip backend list apply when no list changed');
			if (context.serviceStatusCalls.length !== 0)
				throw new Error('handleSave should skip service status check when no list changed');

			context.execCalls.length = 0;
	context.applyPolicyListCalls.length = 0;
	context.applyCalls.length = 0;
	context.notifications.length = 0;
	context.uciChanges = { mihowrt: [['set', 'settings', 'policy_mode', 'proxy-first']] };
	context.applyError = 'apply failed';
	context.setPolicyMode('direct-first');
	context.syncListCaches('1.1.1.1\n', '', '');
	context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
	context.setPolicyMap({ readonly: false, save: async() => option.write('settings', '2.2.2.2') });
	let applyFailed = false;
	try {
		await context.handleSaveApply.call({ handleSave: async() => {} }, null, '1');
	}
	catch (e) {
		applyFailed = e.message === 'apply failed';
	}
	if (!applyFailed)
		throw new Error('handleSaveApply should surface LuCI apply failure');
	if (context.applyPolicyListCalls.length !== 2 ||
		context.applyPolicyListCalls[0].values.dst !== '2.2.2.2\n' ||
		context.applyPolicyListCalls[1].values.dst !== '1.1.1.1\n')
		throw new Error('handleSaveApply should roll back staged list files after LuCI apply failure');
	if (context.getDstCache() !== '1.1.1.1\n')
		throw new Error('handleSaveApply should restore list cache after LuCI apply failure');
	if (context.isPolicyListWriteTransactionActive())
		throw new Error('handleSaveApply should clear list write transaction after failure');
	context.applyError = null;
	context.setPolicyMap({ readonly: false, save: async() => {} });

	context.execCalls.length = 0;
	context.applyPolicyListCalls.length = 0;
	context.applyCalls.length = 0;
	context.commitCalls.length = 0;
	context.initCalls.length = 0;
	context.notifications.length = 0;
	context.uciChanges = { network: [['set', 'lan']] };
	context.setPolicyMode('direct-first');
	context.syncListCaches('1.1.1.1\n', '', '');
	context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
	context.setPolicyMap({ readonly: false, save: async() => option.write('settings', '2.2.2.2') });
	await context.handleSaveApply.call({ handleSave: async() => {} }, null, '0');
	if (context.applyCalls.length !== 0)
		throw new Error('handleSaveApply should not apply unrelated pending UCI changes');
	if (context.applyPolicyListCalls.length !== 1 ||
		context.applyPolicyListCalls[0].values.dst !== '2.2.2.2\n' ||
		context.applyPolicyListCalls[0].reload !== true)
		throw new Error('handleSaveApply should apply and reload list-only changes through backend');

	context.execCalls.length = 0;
	context.applyPolicyListCalls.length = 0;
	context.applyCalls.length = 0;
	context.commitCalls.length = 0;
	context.initCalls.length = 0;
	context.uciChanges = { mihowrt: [['set', 'settings']] };
	context.setPolicyMode('direct-first');
	context.syncListCaches('1.1.1.1\n', '', '');
	context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
	context.setPolicyMap({ readonly: false, save: async() => option.write('settings', '2.2.2.2') });
	await context.handleSaveApply.call({ handleSave: async() => {} }, null, '1');
	if (context.applyCalls.length !== 1 || context.applyCalls[0] !== false)
		throw new Error('handleSaveApply should apply mihowrt UCI changes through LuCI');
	if (context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'sync-policy-remote-auto-update'))
		throw new Error('handleSaveApply should not sync remote cron when interval did not change');
	if (context.applyPolicyListCalls.length !== 1 ||
		context.applyPolicyListCalls[0].values.dst !== '2.2.2.2\n' ||
		context.applyPolicyListCalls[0].reload !== false)
		throw new Error('handleSaveApply should save list files before LuCI apply without separate list reload');

	context.execCalls.length = 0;
	context.applyPolicyListCalls.length = 0;
	context.applyCalls.length = 0;
	context.commitCalls.length = 0;
	context.initCalls.length = 0;
	context.uciChanges = { mihowrt: [['set', 'settings', 'policy_remote_update_interval', '12']] };
	context.setPolicyMode('direct-first');
	context.syncListCaches('1.1.1.1\n', '', '');
	context.setListOptions({ formvalue: () => '1.1.1.1\n' }, { formvalue: () => '' }, { formvalue: () => '' });
	context.setPolicyMap({ readonly: false, save: async() => {} });
	await context.handleSaveApply.call({ handleSave: async() => {} }, null, '1');
	if (context.applyCalls.length !== 0)
		throw new Error('handleSaveApply should not apply service reload for interval-only changes');
	if (context.commitCalls.length !== 1 || context.commitCalls[0] !== 'mihowrt')
		throw new Error('handleSaveApply should commit interval-only changes without applying service reload');
	if (context.initCalls.length !== 1)
		throw new Error('handleSaveApply should refresh LuCI change state after interval-only commit');
	if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'sync-policy-remote-auto-update'))
		throw new Error('handleSaveApply should strictly sync policy remote cron after interval changes');
	if (context.applyPolicyListCalls.length !== 0)
		throw new Error('handleSaveApply should not write list files for interval-only changes without list edits');

	context.execCalls.length = 0;
	context.applyCalls.length = 0;
	context.commitCalls.length = 0;
	context.initCalls.length = 0;
	context.uciChanges = {
		mihowrt: [['set', 'settings', 'policy_remote_update_interval', '12']],
		network: [['set', 'lan', 'ipaddr', '192.168.1.1']]
	};
	await context.handleSaveApply.call({ handleSave: async() => {} }, null, '1');
	if (context.applyCalls.length !== 1)
		throw new Error('handleSaveApply should fall back to LuCI apply when interval changes are mixed with other packages');
	if (context.commitCalls.length !== 0)
		throw new Error('handleSaveApply should not commit mixed package changes without LuCI apply');

	context.execCalls.length = 0;
	context.applyCalls.length = 0;
	context.commitCalls.length = 0;
	context.initCalls.length = 0;
	context.uciChanges = { mihowrt: [['set', 'settings', 'policy_remote_update_interval', '12']] };
	context.syncPolicyRemoteError = 'cron write failed';
	let syncFailed = false;
	try {
		await context.handleSaveApply.call({ handleSave: async() => {} }, null, '1');
	}
	catch (e) {
		syncFailed = e.message === 'cron write failed';
	}
	if (!syncFailed)
		throw new Error('handleSaveApply should surface policy remote cron sync failures');
	context.syncPolicyRemoteError = null;

		context.execCalls.length = 0;
		context.notifications.length = 0;
		context.uciChanges = {};
		context.setPolicyMode('direct-first');
		context.setPolicyModeCache('direct-first');
		context.syncListCaches('1.1.1.1\n', '', '');
		context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
		context.updateChanged = false;
		await context.updateRemoteLists();
		if (context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'update-policy-lists'))
			throw new Error('updateRemoteLists should not run backend while active list edits are unsaved');
		if (!context.notifications.some(item => item.level === 'warning' && item.message.includes('Save policy list changes')))
			throw new Error('updateRemoteLists should ask to save unsaved list edits before update');

		context.execCalls.length = 0;
		context.notifications.length = 0;
		context.uciChanges = {};
		context.setPolicyMode('proxy-first');
		context.setPolicyModeCache('direct-first');
		context.syncListCaches('2.2.2.2\n', '', '');
		context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
		context.updateChanged = false;
		await context.updateRemoteLists();
		if (context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'update-policy-lists'))
			throw new Error('updateRemoteLists should not run backend while policy settings are unsaved');
		if (!context.notifications.some(item => item.level === 'warning' && item.message.includes('Save policy settings')))
			throw new Error('updateRemoteLists should ask to save unsaved policy settings before update');

		context.execCalls.length = 0;
		context.notifications.length = 0;
		context.uciChanges = {};
		context.setPolicyMode('direct-first');
		context.setPolicyModeCache('direct-first');
		context.syncListCaches('2.2.2.2\n', '', '');
		context.setListOptions({ formvalue: () => '2.2.2.2\n' }, { formvalue: () => '' }, { formvalue: () => '' });
		context.updateChanged = false;
		await context.updateRemoteLists();
		if (!context.execCalls.some(call => call.cmd === '/usr/bin/mihowrt' && call.args[0] === 'update-policy-lists'))
		throw new Error('updateRemoteLists should call backend remote-list update command');
	if (!context.notifications.some(item => item.level === 'info' && item.message.includes('unchanged')))
		throw new Error('updateRemoteLists should report unchanged lists without error');

	context.execCalls.length = 0;
	context.notifications.length = 0;
	context.updateChanged = true;
	await context.updateRemoteLists();
	if (!context.notifications.some(item => item.level === 'info' && item.message.includes('updated')))
		throw new Error('updateRemoteLists should report changed lists after backend update');

	context.notifications.length = 0;
	context.updateError = 'fetch failed';
	await context.updateRemoteLists();
	if (!context.notifications.some(item => item.level === 'error' && item.message.includes('fetch failed')))
		throw new Error('updateRemoteLists should surface backend update failures');
	})().catch(err => {
		throw err;
	});
EOF

pass "policy view helpers"
