'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require rpc';
'require mihowrt.backend as backendHelper';
'require mihowrt.ui as mihowrtUi';

const DST_LIST_FILE = '/opt/clash/lst/always_proxy_dst.txt';
const SRC_LIST_FILE = '/opt/clash/lst/always_proxy_src.txt';
const DIRECT_DST_LIST_FILE = '/opt/clash/lst/direct_dst.txt';
const SETTINGS_SECTION_ID = 'settings';
const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';
const commitUciPackage = rpc.declare({
	object: 'uci',
	method: 'commit',
	params: [ 'config' ],
	reject: true
});

let dstValueCache = null;
let srcValueCache = null;
let directDstValueCache = null;
let policyMap = null;
let policyModeOption = null;
let policySettingOptions = {};
let policySettingsCache = {};
let dstListOption = null;
let srcListOption = null;
let directDstListOption = null;
let updateListsButton = null;
let policyActionInFlight = false;
let policyListWriteTransaction = null;
let policyModeCache = 'direct-first';

function validateNumericRange(value, label, min, max) {
	// Empty value means backend auto-select.
	if (!value)
		return true;
	if (!/^[0-9]+$/.test(value))
		return _('%s must be numeric').format(label);

	const parsed = parseInt(value, 10);
	return parsed >= min && parsed <= max
		? true
		: _('%s must be between %s and %s').format(label, min, max);
}

function normalizeBlock(value) {
	// Normalize line endings and keep a trailing newline for stable file writes.
	value = (value || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
	value = value.trim();
	return value ? value + '\n' : '';
}

function currentNormalizedListValue(option) {
	return option ? normalizeBlock(option.formvalue(SETTINGS_SECTION_ID)) : '';
}

function syncListCaches(dstValue, srcValue, directDstValue) {
	dstValueCache = normalizeBlock(dstValue || '');
	srcValueCache = normalizeBlock(srcValue || '');
	directDstValueCache = normalizeBlock(directDstValue || '');
	syncPolicySettingsCacheFromUci();
}

function policySettingOptionNames() {
	return [
		'policy_mode',
		'source_network_interfaces',
		'dns_hijack',
		'route_table_id',
		'route_rule_priority',
		'disable_quic',
		'policy_remote_update_interval'
	];
}

function normalizePolicySettingValue(value) {
	if (Array.isArray(value))
		return value.map(String).join('\n');

	return String(value ?? '');
}

function savedPolicySettingValue(optionName) {
	return normalizePolicySettingValue(uci.get('mihowrt', SETTINGS_SECTION_ID, optionName));
}

function currentPolicySettingValue(optionName) {
	const option = policySettingOptions[optionName] ||
		(optionName === 'policy_mode' ? policyModeOption : null);

	if (!option)
		return policySettingsCache[optionName] || '';

	return normalizePolicySettingValue(option.formvalue(SETTINGS_SECTION_ID));
}

function syncPolicySettingsCacheFromUci() {
	policySettingOptionNames().forEach(optionName => {
		policySettingsCache[optionName] = savedPolicySettingValue(optionName);
	});
	policyModeCache = uci.get('mihowrt', SETTINGS_SECTION_ID, 'policy_mode') || 'direct-first';
}

function syncPolicySettingsCacheFromForm() {
	policySettingOptionNames().forEach(optionName => {
		policySettingsCache[optionName] = currentPolicySettingValue(optionName);
	});
	policyModeCache = policySettingsCache.policy_mode || 'direct-first';
}

function bindPolicySettingOption(optionName, option) {
	policySettingOptions[optionName] = option;
}

function currentPolicyMode() {
	// Current mode controls which list files matter for dirty-check.
	return currentPolicySettingValue('policy_mode') || 'direct-first';
}

function hasListValueChanges() {
	// Compare active textarea values with cached disk values, mode-aware.
	if (currentPolicyMode() === 'proxy-first')
		return currentNormalizedListValue(directDstListOption) !== (directDstValueCache || '');

	return currentNormalizedListValue(dstListOption) !== (dstValueCache || '') ||
		currentNormalizedListValue(srcListOption) !== (srcValueCache || '');
}

function hasMihowrtUciChanges(changes) {
	// LuCI UCI changes and raw list file changes have different apply paths.
	const mihowrtChanges = changes?.mihowrt;
	return Array.isArray(mihowrtChanges) && mihowrtChanges.length > 0;
}

function hasUnsavedPolicyModeChange() {
	return currentPolicyMode() !== policyModeCache;
}

function hasUnsavedPolicySettingsChange() {
	return hasUnsavedPolicyModeChange() ||
		policySettingOptionNames().some(optionName =>
			currentPolicySettingValue(optionName) !== (policySettingsCache[optionName] || ''));
}

function changeMentionsOption(change, optionName) {
	if (Array.isArray(change))
		return change.some(item => changeMentionsOption(item, optionName));
	return String(change) === optionName;
}

function policyRemoteAutoUpdateChanged(changes) {
	const mihowrtChanges = changes?.mihowrt;
	return Array.isArray(mihowrtChanges) &&
		mihowrtChanges.some(change => changeMentionsOption(change, 'policy_remote_update_interval'));
}

function mihowrtUciChangesOnlyPolicyRemoteAutoUpdate(changes) {
	const changedPackages = Object.keys(changes || {}).filter(name =>
		Array.isArray(changes[name]) && changes[name].length > 0);
	const mihowrtChanges = changes?.mihowrt;
	return changedPackages.length === 1 &&
		changedPackages[0] === 'mihowrt' &&
		Array.isArray(mihowrtChanges) &&
		mihowrtChanges.length > 0 &&
		mihowrtChanges.every(change => Array.isArray(change) &&
			(String(change[0]) === 'set' || String(change[0]) === 'remove') &&
			String(change[2]) === 'policy_remote_update_interval');
}

function updateRemoteListsButtonNode() {
	if (!updateListsButton || !updateListsButton.cbid || typeof document === 'undefined')
		return null;

	const hidden = document.getElementById(updateListsButton.cbid(SETTINGS_SECTION_ID));
	const output = hidden ? hidden.previousElementSibling : null;
	return output ? output.querySelector('button') : null;
}

function setPolicyActionBusy(busy) {
	// Block overlapping save/update actions so file writes and reloads cannot race.
	policyActionInFlight = busy;
	if (updateListsButton)
		updateListsButton.readonly = busy ? true : null;

	const buttonNode = updateRemoteListsButtonNode();
	if (buttonNode)
		buttonNode.disabled = busy || !!(policyMap && policyMap.readonly);
}

function policyListCacheValue(cacheName) {
	if (cacheName === 'dst')
		return dstValueCache || '';
	if (cacheName === 'src')
		return srcValueCache || '';
	return directDstValueCache || '';
}

function setPolicyListCacheValue(cacheName, value) {
	if (cacheName === 'dst')
		dstValueCache = value;
	else if (cacheName === 'src')
		srcValueCache = value;
	else
		directDstValueCache = value;
}

function policyListTransactionValue(cacheName, filePath, snapshots) {
	const transaction = policyListWriteTransaction;

	if (transaction) {
		if (snapshots && objectHasOwn(transaction.snapshots, filePath))
			return transaction.snapshots[filePath].value;
		if (!snapshots && objectHasOwn(transaction.pending, filePath))
			return transaction.pending[filePath].value;
	}

	return policyListCacheValue(cacheName);
}

function policyListTransactionValues(snapshots = false) {
	return {
		dst: policyListTransactionValue('dst', DST_LIST_FILE, snapshots),
		src: policyListTransactionValue('src', SRC_LIST_FILE, snapshots),
		direct: policyListTransactionValue('direct-dst', DIRECT_DST_LIST_FILE, snapshots)
	};
}

function syncListCachesFromValues(values) {
	dstValueCache = normalizeBlock(values?.dst || '');
	srcValueCache = normalizeBlock(values?.src || '');
	directDstValueCache = normalizeBlock(values?.direct || '');
}

function objectHasOwn(object, key) {
	return Object.prototype.hasOwnProperty.call(object, key);
}

function beginPolicyListWriteTransaction() {
	policyListWriteTransaction = {
		snapshots: {},
		pending: {},
		flushStarted: false,
		flushed: false
	};
}

function clearPolicyListWriteTransaction() {
	policyListWriteTransaction = null;
}

function stagePolicyListWrite(cacheName, filePath, value) {
	const transaction = policyListWriteTransaction;
	const key = filePath;

	if (!objectHasOwn(transaction.snapshots, key)) {
		transaction.snapshots[key] = {
			cacheName,
			filePath,
			value: policyListCacheValue(cacheName)
		};
	}

	if (value === transaction.snapshots[key].value)
		delete transaction.pending[key];
	else
		transaction.pending[key] = { cacheName, filePath, value };
}

async function writePolicyListFile(cacheName, filePath, value) {
	if (policyListWriteTransaction) {
		if (!objectHasOwn(policyListWriteTransaction.snapshots, filePath) && value === policyListCacheValue(cacheName))
			return;
		stagePolicyListWrite(cacheName, filePath, value);
		return;
	}

	if (value === policyListCacheValue(cacheName))
		return;

	beginPolicyListWriteTransaction();
	try {
		stagePolicyListWrite(cacheName, filePath, value);
		await flushPolicyListWrites(false);
	}
	finally {
		clearPolicyListWriteTransaction();
	}
}

async function rollbackPolicyListWrites() {
	const transaction = policyListWriteTransaction;
	if (!transaction || !transaction.flushStarted)
		return;

	const values = policyListTransactionValues(true);
	await backendHelper.applyPolicyLists(values, false);
	syncListCachesFromValues(values);
}

async function flushPolicyListWrites(reload = false) {
	const transaction = policyListWriteTransaction;
	if (!transaction || transaction.flushed)
		return { changed: false, reloaded: false };

	const writes = Object.keys(transaction.pending).map(key => transaction.pending[key]);
	if (writes.length === 0) {
		transaction.flushed = true;
		return { changed: false, reloaded: false };
	}
	transaction.flushStarted = true;

	const values = policyListTransactionValues(false);
	const result = await backendHelper.applyPolicyLists(values, reload);
	syncListCachesFromValues(values);
	transaction.flushed = true;
	return result;
}

async function savePolicyMap() {
	return policyMap ? policyMap.save() : Promise.resolve();
}

async function reloadPolicyIfNeeded(listChanged, wasRunning) {
	// Backend applies list files under runtime lock and rolls back on reload failure.
	if (!listChanged)
		return { changed: false, reloaded: false };

	return flushPolicyListWrites(wasRunning);
}

async function updateRemoteLists() {
	// Backend decides whether effective remote content changed and nft was updated.
	if (policyActionInFlight)
		return;

	if (hasUnsavedPolicySettingsChange()) {
		mihowrtUi.notify(_('Save policy settings before updating remote lists.'), 'warning');
		return;
	}

	if (hasListValueChanges()) {
		mihowrtUi.notify(_('Save policy list changes before updating remote lists.'), 'warning');
		return;
	}

	const changes = await uci.changes();
	if (hasMihowrtUciChanges(changes)) {
		mihowrtUi.notify(_('Save policy settings before updating remote lists.'), 'warning');
		return;
	}

	setPolicyActionBusy(true);

	try {
		const changed = await backendHelper.updatePolicyLists();
		mihowrtUi.notify(changed
			? _('Remote policy lists changed; nft policy updated.')
			: _('Remote policy lists unchanged; nft policy left untouched.'), 'info');
	}
	catch (e) {
		mihowrtUi.notify(_('Unable to update remote policy lists: %s').format(e.message), 'error');
	}
	finally {
		setPolicyActionBusy(false);
	}
}

function bindTextFileOption(option, cacheName, filePath, description) {
	// Bind TextValue to raw file instead of UCI and avoid no-op writes.
	option.rows = 18;
	option.wrap = 'off';
	option.monospace = true;
	option.description = description;
	option.cfgvalue = function() {
		if (cacheName === 'dst')
			return dstValueCache || '';
		if (cacheName === 'src')
			return srcValueCache || '';
		return directDstValueCache || '';
	};
	option.write = async function(section_id, value) {
		const normalized = normalizeBlock(value);
		const current = this.cfgvalue(section_id);
		if (!policyListWriteTransaction && normalized === current)
			return;

		await writePolicyListFile(cacheName, filePath, normalized);
	};
	option.remove = async function() {
		// LuCI calls remove() for inactive depends() options; keep hidden mode lists.
	};
}

return view.extend({
	handleSave: async function() {
		if (policyActionInFlight) {
			mihowrtUi.notify(_('Another policy action is still running.'), 'warning');
			return;
		}

		setPolicyActionBusy(true);
		beginPolicyListWriteTransaction();
		try {
			const listChanged = hasListValueChanges();
			const wasRunning = listChanged ? await mihowrtUi.getServiceStatus(SERVICE_NAME, SERVICE_SCRIPT) : false;
			await savePolicyMap();
			await reloadPolicyIfNeeded(listChanged, wasRunning);
		}
		finally {
			clearPolicyListWriteTransaction();
			setPolicyActionBusy(false);
		}
	},

	handleSaveApply: async function(ev, mode) {
		if (policyActionInFlight) {
			mihowrtUi.notify(_('Another policy action is still running.'), 'warning');
			return;
		}

		setPolicyActionBusy(true);
		beginPolicyListWriteTransaction();

		try {
			const listChanged = hasListValueChanges();
			let wasRunning = false;

			if (listChanged) {
				try {
					wasRunning = await mihowrtUi.getServiceStatus(SERVICE_NAME, SERVICE_SCRIPT);
				}
				catch (e) {
					mihowrtUi.notify(_('Unable to determine service state before reload: %s').format(e.message), 'error');
					return;
				}
			}

			await savePolicyMap();

			const changes = await uci.changes();
			if (mihowrtUciChangesOnlyPolicyRemoteAutoUpdate(changes)) {
				await commitUciPackage('mihowrt');
				await ui.changes.init();
				await backendHelper.syncPolicyRemoteAutoUpdate();
				await reloadPolicyIfNeeded(listChanged, wasRunning);
				syncPolicySettingsCacheFromForm();
				return;
			}

			if (hasMihowrtUciChanges(changes)) {
				await flushPolicyListWrites(false);
				try {
					await ui.changes.apply(mode == '0');
				}
				catch (e) {
					await rollbackPolicyListWrites();
					throw e;
				}
				if (policyRemoteAutoUpdateChanged(changes))
					await backendHelper.syncPolicyRemoteAutoUpdate();
				syncPolicySettingsCacheFromForm();
				return;
			}

			await reloadPolicyIfNeeded(listChanged, wasRunning);
		}
		finally {
			clearPolicyListWriteTransaction();
			setPolicyActionBusy(false);
		}
	},

	load: function() {
		return Promise.all([
			uci.load('mihowrt'),
			L.resolveDefault(fs.read(DST_LIST_FILE), ''),
			L.resolveDefault(fs.read(SRC_LIST_FILE), ''),
			L.resolveDefault(fs.read(DIRECT_DST_LIST_FILE), '')
		]);
	},

	render: function(data) {
		syncListCaches(data[1], data[2], data[3]);

		const m = new form.Map('mihowrt', _('MihoWRT Policy'), _('Direct-first proxies selected traffic. Proxy-first proxies non-local traffic except direct destinations.'));
		policyMap = m;
		const s = m.section(form.NamedSection, 'settings', 'settings', _('Routing'));

		s.anonymous = true;
		s.addremove = false;

		let o = s.option(form.ListValue, 'policy_mode', _('Policy Mode'));
		policyModeOption = o;
		bindPolicySettingOption('policy_mode', o);
		o.default = 'direct-first';
		o.rmempty = false;
		o.value('direct-first', _('Direct-first'));
		o.value('proxy-first', _('Proxy-first'));

		o = s.option(form.DynamicList, 'source_network_interfaces', _('Source Interfaces'));
		bindPolicySettingOption('source_network_interfaces', o);
		o.placeholder = 'br-lan';
		o.description = _('Ingress interfaces for client traffic.');
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			return /^[A-Za-z0-9_.:@-]+$/.test(value) ? true : _('Interface name contains unsupported characters');
		};

		o = s.option(form.Flag, 'dns_hijack', _('Redirect DNS/53 to Mihomo'));
		bindPolicySettingOption('dns_hijack', o);
		o.default = '1';
		o.rmempty = false;
		o.description = _('Redirect client TCP/UDP DNS requests before policy routing.');

		o = s.option(form.Value, 'route_table_id', _('Route Table ID'));
		bindPolicySettingOption('route_table_id', o);
		o.placeholder = _('auto');
		o.description = _('Empty value auto-selects a free table.');
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Route table id'), 1, 252);
		};

		o = s.option(form.Value, 'route_rule_priority', _('Route Rule Priority'));
		bindPolicySettingOption('route_rule_priority', o);
		o.placeholder = _('auto');
		o.description = _('Empty value auto-selects a free priority.');
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Route rule priority'), 1, 32765);
		};

		o = s.option(form.Flag, 'disable_quic', _('Block QUIC for Proxied Traffic'));
		bindPolicySettingOption('disable_quic', o);
		o.default = '1';
		o.rmempty = false;
		o.description = _('Reject UDP/443 only for traffic selected into Mihomo.');

		o = s.option(form.Value, 'policy_remote_update_interval', _('Remote List Auto-update (hours)'));
		bindPolicySettingOption('policy_remote_update_interval', o);
		o.placeholder = '0';
		o.default = '0';
		o.rmempty = false;
		o.description = _('0 disables auto-update.');
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Remote list auto-update interval'), 0, 8760);
		};

		o = s.option(form.Button, '_update_remote_lists', _('Update Remote Lists'));
		updateListsButton = o;
		o.inputstyle = 'action';
		o.description = _('Save changes before updating.');
		o.onclick = updateRemoteLists;

		o = s.option(form.TextValue, '_always_proxy_dst', _('Proxy Destinations'));
		o.depends('policy_mode', 'direct-first');
		dstListOption = o;
		bindTextFileOption(o, 'dst', DST_LIST_FILE, _('IPv4, CIDR, ;port, IPv4;port, CIDR;port, or URL;port. One entry per line.'));

		o = s.option(form.TextValue, '_always_proxy_src', _('Proxy Clients'));
		o.depends('policy_mode', 'direct-first');
		srcListOption = o;
		bindTextFileOption(o, 'src', SRC_LIST_FILE, _('IPv4, CIDR, ;port, IPv4;port, CIDR;port, or URL;port. One entry per line.'));

		o = s.option(form.TextValue, '_direct_dst', _('Direct Destinations'));
		o.depends('policy_mode', 'proxy-first');
		directDstListOption = o;
		bindTextFileOption(o, 'direct-dst', DIRECT_DST_LIST_FILE, _('IPv4, CIDR, ;port, IPv4;port, CIDR;port, or URL;port. One entry per line.'));

		return m.render();
	}
});
