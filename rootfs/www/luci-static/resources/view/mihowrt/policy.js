'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require mihowrt.ui as mihowrtUi';

const DST_LIST_FILE = '/opt/clash/lst/always_proxy_dst.txt';
const SRC_LIST_FILE = '/opt/clash/lst/always_proxy_src.txt';
const SETTINGS_SECTION_ID = 'settings';
const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';

let dstValueCache = null;
let srcValueCache = null;
let policyMap = null;
let dstListOption = null;
let srcListOption = null;

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

function syncListCaches(dstValue, srcValue) {
	dstValueCache = normalizeBlock(dstValue || '');
	srcValueCache = normalizeBlock(srcValue || '');
}

function hasListValueChanges() {
	return currentNormalizedListValue(dstListOption) !== (dstValueCache || '') ||
		currentNormalizedListValue(srcListOption) !== (srcValueCache || '');
}

function hasMihowrtUciChanges(changes) {
	const mihowrtChanges = changes?.mihowrt;
	return Array.isArray(mihowrtChanges) && mihowrtChanges.length > 0;
}

async function reloadPolicyIfNeeded(listChanged, wasRunning) {
	if (!listChanged || !wasRunning)
		return;

	const reloadResult = await fs.exec(SERVICE_SCRIPT, ['reload']);
	if (reloadResult.code !== 0)
		mihowrtUi.notify(_('Saved, but failed to reload policy: %s').format(mihowrtUi.execErrorDetail(reloadResult)), 'error');
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
		return cacheName === 'dst' ? (dstValueCache || '') : (srcValueCache || '');
	};
	option.write = async function(section_id, value) {
		const normalized = normalizeBlock(value);
		const current = cacheName === 'dst' ? (dstValueCache || '') : (srcValueCache || '');
		if (normalized === current)
			return;

		if (normalized)
			await fs.write(filePath, normalized);
		else
			await removeListFileIfPresent(filePath);

		if (cacheName === 'dst')
			dstValueCache = normalized;
		else
			srcValueCache = normalized;
	};
	option.remove = async function() {
		const current = cacheName === 'dst' ? (dstValueCache || '') : (srcValueCache || '');
		if (!current)
			return;

		await removeListFileIfPresent(filePath);
		if (cacheName === 'dst')
			dstValueCache = '';
		else
			srcValueCache = '';
	};
}

return view.extend({
	handleSave: function() {
		return policyMap ? policyMap.save() : Promise.resolve();
	},

	handleSaveApply: async function(ev, mode) {
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

		await this.handleSave(ev);

		const changes = await uci.changes();
		if (hasMihowrtUciChanges(changes)) {
			await ui.changes.apply(mode == '0');
			await reloadPolicyIfNeeded(listChanged, wasRunning);
			return;
		}

		await reloadPolicyIfNeeded(listChanged, wasRunning);
	},

	load: function() {
		return Promise.all([
			uci.load('mihowrt'),
			L.resolveDefault(fs.read(DST_LIST_FILE), ''),
			L.resolveDefault(fs.read(SRC_LIST_FILE), '')
		]);
	},

	render: function(data) {
		syncListCaches(data[1], data[2]);

		const m = new form.Map('mihowrt', _('MihoWRT Traffic Policy'), _('Direct-first traffic policy. Selected traffic is marked by nftables before Mihomo TPROXY handling.'));
		policyMap = m;
		const s = m.section(form.NamedSection, 'settings', 'settings', _('Traffic Policy Settings'));

		s.anonymous = true;
		s.addremove = false;

		let o = s.option(form.Flag, 'enabled', _('Enable Traffic Policy'));
		o.rmempty = false;
		o.default = '1';

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
		o.description = _('Reject UDP/443 only for traffic selected into Mihomo by these nft policy blocks.');

		o = s.option(form.TextValue, '_always_proxy_dst', _('Proxy Destinations (IP/CIDR[:Port] or :Port)'));
		dstListOption = o;
		bindTextFileOption(o, 'dst', DST_LIST_FILE, _('One IPv4 or CIDR per line. Optional :port, :port-port, or :port,port filters destination port; :port without IP matches any IPv4 destination.'));

		o = s.option(form.TextValue, '_always_proxy_src', _('Proxy Clients (IP/CIDR[:Port] or :Port)'));
		srcListOption = o;
		bindTextFileOption(o, 'src', SRC_LIST_FILE, _('One IPv4 or CIDR per line. Optional :port, :port-port, or :port,port filters destination port; :port without IP matches any IPv4 client.'));

		return m.render();
	}
});
