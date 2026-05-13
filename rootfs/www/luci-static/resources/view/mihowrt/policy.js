'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require mihowrt.backend as backendHelper';
'require mihowrt.ui as mihowrtUi';

const DST_LIST_FILE = '/opt/clash/lst/always_proxy_dst.txt';
const SRC_LIST_FILE = '/opt/clash/lst/always_proxy_src.txt';
const DIRECT_DST_LIST_FILE = '/opt/clash/lst/direct_dst.txt';
const SETTINGS_SECTION_ID = 'settings';
const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';

let dstValueCache = null;
let srcValueCache = null;
let directDstValueCache = null;
let policyMap = null;
let policyModeOption = null;
let dstListOption = null;
let srcListOption = null;
let directDstListOption = null;
let updateListsButton = null;
let policyActionInFlight = false;

function validateNumericRange(value, label, min, max) {
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
}

function currentPolicyMode() {
	return policyModeOption ? (policyModeOption.formvalue(SETTINGS_SECTION_ID) || 'direct-first') : 'direct-first';
}

function hasListValueChanges() {
	if (currentPolicyMode() === 'proxy-first')
		return currentNormalizedListValue(directDstListOption) !== (directDstValueCache || '');

	return currentNormalizedListValue(dstListOption) !== (dstValueCache || '') ||
		currentNormalizedListValue(srcListOption) !== (srcValueCache || '');
}

function hasMihowrtUciChanges(changes) {
	const mihowrtChanges = changes?.mihowrt;
	return Array.isArray(mihowrtChanges) && mihowrtChanges.length > 0;
}

function setPolicyActionBusy(busy) {
	policyActionInFlight = busy;
	if (updateListsButton)
		updateListsButton.disabled = busy;
}

async function savePolicyMap() {
	return policyMap ? policyMap.save() : Promise.resolve();
}

async function reloadPolicyIfNeeded(listChanged, wasRunning) {
	if (!listChanged || !wasRunning)
		return;

	const reloadResult = await fs.exec(SERVICE_SCRIPT, ['reload']);
	if (reloadResult.code !== 0)
		mihowrtUi.notify(_('Saved, but failed to reload policy: %s').format(mihowrtUi.execErrorDetail(reloadResult)), 'error');
}

async function updateRemoteLists() {
	if (policyActionInFlight)
		return;

	if (hasListValueChanges()) {
		mihowrtUi.notify(_('Save policy list changes before updating remote lists.'), 'warning');
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

async function removeListFileIfPresent(filePath) {
	try {
		await fs.remove(filePath);
	}
	catch (e) {
		if (e && (e.name === 'NotFoundError' || /not found/i.test(e.message || '')))
			return;
		throw e;
	}
}

function bindTextFileOption(option, cacheName, filePath, description) {
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
		if (normalized === current)
			return;

		if (normalized)
			await fs.write(filePath, normalized);
		else
			await removeListFileIfPresent(filePath);

		if (cacheName === 'dst')
			dstValueCache = normalized;
		else if (cacheName === 'src')
			srcValueCache = normalized;
		else
			directDstValueCache = normalized;
	};
	option.remove = async function() {
		const current = this.cfgvalue(SETTINGS_SECTION_ID);
		if (!current)
			return;

		await removeListFileIfPresent(filePath);
		if (cacheName === 'dst')
			dstValueCache = '';
		else if (cacheName === 'src')
			srcValueCache = '';
		else
			directDstValueCache = '';
	};
}

return view.extend({
	handleSave: async function() {
		if (policyActionInFlight) {
			mihowrtUi.notify(_('Another policy action is still running.'), 'warning');
			return;
		}

		setPolicyActionBusy(true);
		try {
			await savePolicyMap();
		}
		finally {
			setPolicyActionBusy(false);
		}
	},

	handleSaveApply: async function(ev, mode) {
		if (policyActionInFlight) {
			mihowrtUi.notify(_('Another policy action is still running.'), 'warning');
			return;
		}

		setPolicyActionBusy(true);

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
			if (hasMihowrtUciChanges(changes)) {
				await ui.changes.apply(mode == '0');
				return;
			}

			await reloadPolicyIfNeeded(listChanged, wasRunning);
		}
		finally {
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

		const m = new form.Map('mihowrt', _('MihoWRT Traffic Policy'), _('Fake-IP policy layer. Direct-first proxies selected traffic; proxy-first proxies non-local traffic except direct destinations. DNS/53 hijack, when enabled, is always handled by Mihomo DNS before proxy policy.'));
		policyMap = m;
		const s = m.section(form.NamedSection, 'settings', 'settings', _('Traffic Policy Settings'));

		s.anonymous = true;
		s.addremove = false;

		let o = s.option(form.ListValue, 'policy_mode', _('Policy Mode'));
		policyModeOption = o;
		o.default = 'direct-first';
		o.rmempty = false;
		o.value('direct-first', _('Direct-first'));
		o.value('proxy-first', _('Proxy-first'));

		o = s.option(form.DynamicList, 'source_network_interfaces', _('Source Interfaces'));
		o.placeholder = 'br-lan';
		o.description = _('Interfaces from which prerouting traffic may enter the Mihomo policy path.');
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			return /^[A-Za-z0-9_.:@-]+$/.test(value) ? true : _('Interface name contains unsupported characters');
		};

		o = s.option(form.Flag, 'dns_hijack', _('Redirect DNS/53 to Mihomo'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Redirect client TCP/UDP DNS requests from selected interfaces to Mihomo DNS listener.');

		o = s.option(form.Value, 'route_table_id', _('Route Table ID'));
		o.placeholder = _('auto');
		o.description = _('Optional. Empty value auto-selects free route table id.');
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Route table id'), 1, 252);
		};

		o = s.option(form.Value, 'route_rule_priority', _('Route Rule Priority'));
		o.placeholder = _('auto');
		o.description = _('Optional. Empty value auto-selects free route rule priority.');
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Route rule priority'), 1, 32765);
		};

		o = s.option(form.Flag, 'disable_quic', _('Block QUIC for Proxied Traffic'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Reject UDP/443 only for traffic selected into Mihomo by these nft policy blocks. DNS/53 hijack is not affected.');

		o = s.option(form.TextValue, '_always_proxy_dst', _('Proxy Destinations (IP/CIDR[;Port], ;Port, or URL[;Port])'));
		o.depends('policy_mode', 'direct-first');
		dstListOption = o;
		bindTextFileOption(o, 'dst', DST_LIST_FILE, _('One IPv4, CIDR, port-scoped entry, or http(s) URL per line. Use ; before ports, including URL;port. Remote lists are fetched on apply/start and merged with manual entries without changing this file.'));

		o = s.option(form.TextValue, '_always_proxy_src', _('Proxy Clients (IP/CIDR[;Port], ;Port, or URL[;Port])'));
		o.depends('policy_mode', 'direct-first');
		srcListOption = o;
		bindTextFileOption(o, 'src', SRC_LIST_FILE, _('One IPv4, CIDR, port-scoped entry, or http(s) URL per line. Use ; before ports, including URL;port. Remote lists are fetched on apply/start and merged with manual entries without changing this file.'));

		o = s.option(form.TextValue, '_direct_dst', _('Direct Destinations (IP/CIDR[;Port], ;Port, or URL[;Port])'));
		o.depends('policy_mode', 'proxy-first');
		directDstListOption = o;
		bindTextFileOption(o, 'direct-dst', DIRECT_DST_LIST_FILE, _('One IPv4, CIDR, port-scoped entry, or http(s) URL per line. Use ; before ports, including URL;port. Remote lists are fetched on apply/start and merged with manual entries without changing this file. Matching traffic bypasses Mihomo in proxy-first mode. DNS/53 hijack still goes to Mihomo DNS.'));

		const toolbar = E('div', {
			style: 'margin-bottom: 15px; display: flex; justify-content: flex-end;'
		}, [
			(updateListsButton = E('button', {
				class: 'btn cbi-button-action',
				click: updateRemoteLists
			}, _('Update Remote Lists')))
		]);

		return Promise.resolve(m.render()).then(mapNode => E([toolbar, mapNode]));
	}
});
