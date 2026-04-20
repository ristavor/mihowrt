'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require rpc';

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

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

async function getServiceStatus() {
	try {
		const services = await callServiceList(SERVICE_NAME);
		const instances = services[SERVICE_NAME]?.instances || {};
		return Object.values(instances)[0]?.running || false;
	}
	catch (e) {
		return false;
	}
}

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

function execErrorDetail(result) {
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

function notify(message, level) {
	ui.addNotification(null, E('p', message), level);
}

function currentNormalizedListValue(option) {
	return option ? normalizeBlock(option.formvalue(SETTINGS_SECTION_ID)) : '';
}

function hasListValueChanges() {
	return currentNormalizedListValue(dstListOption) !== (dstValueCache || '') ||
		currentNormalizedListValue(srcListOption) !== (srcValueCache || '');
}

function hasPendingUciChanges(changes) {
	return Object.values(changes || {}).some(list => Array.isArray(list) && list.length > 0);
}

function bindTextFileOption(option, cacheName, filePath, description) {
	option.rows = 18;
	option.wrap = 'off';
	option.monospace = true;
	option.description = description;
	option.cfgvalue = function() {
		return cacheName === 'dst' ? (dstValueCache || '') : (srcValueCache || '');
	};
	option.write = function(section_id, value) {
		const normalized = normalizeBlock(value);
		if (cacheName === 'dst')
			dstValueCache = normalized;
		else
			srcValueCache = normalized;
		return fs.write(filePath, normalized);
	};
	option.remove = function() {
		if (cacheName === 'dst')
			dstValueCache = '';
		else
			srcValueCache = '';
		return fs.write(filePath, '');
	};
}

return view.extend({
	handleSave: function() {
		return policyMap ? policyMap.save() : Promise.resolve();
	},

	handleSaveApply: async function(ev, mode) {
		const listChanged = hasListValueChanges();
		const wasRunning = listChanged ? await getServiceStatus() : false;

		await this.handleSave(ev);

		const changes = await uci.changes();
		if (hasPendingUciChanges(changes)) {
			ui.changes.apply(mode == '0');
			return;
		}

		if (!listChanged || !wasRunning)
			return;

		const reloadResult = await fs.exec(SERVICE_SCRIPT, ['reload']);
		if (reloadResult.code !== 0)
			notify(_('Saved, but failed to reload policy: %s').format(execErrorDetail(reloadResult)), 'error');
	},

	load: function() {
		return Promise.all([
			uci.load('mihowrt'),
			L.resolveDefault(fs.read(DST_LIST_FILE), ''),
			L.resolveDefault(fs.read(SRC_LIST_FILE), '')
		]);
	},

	render: function(data) {
		if (dstValueCache == null)
			dstValueCache = normalizeBlock(data[1] || '');
		if (srcValueCache == null)
			srcValueCache = normalizeBlock(data[2] || '');

		const m = new form.Map('mihowrt', _('MihoWRT Policy'), _('Direct-first policy layer. External DNS/53 from selected interfaces can be hijacked to Mihomo DNS.'));
		policyMap = m;
		const s = m.section(form.NamedSection, 'settings', 'settings', _('Runtime Settings'));

		s.anonymous = true;
		s.addremove = false;

		let o = s.option(form.Flag, 'enabled', _('Enable Policy Layer'));
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

		o = s.option(form.Flag, 'dns_hijack', _('Hijack DNS/53 To Mihomo DNS'));
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

		o = s.option(form.Flag, 'disable_quic', _('Disable QUIC For Mihomo-Bound Traffic'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Reject UDP/443 only for traffic selected into Mihomo by these nft policy blocks.');

		o = s.option(form.TextValue, '_always_proxy_dst', _('Always Proxy Destination IP/CIDR'));
		dstListOption = o;
		bindTextFileOption(o, 'dst', DST_LIST_FILE, _('One IPv4 or CIDR per line. Packets with matching destination will be sent into Mihomo.'));

		o = s.option(form.TextValue, '_always_proxy_src', _('Always Proxy Source IP/CIDR'));
		srcListOption = o;
		bindTextFileOption(o, 'src', SRC_LIST_FILE, _('One IPv4 or CIDR per line. Packets from matching clients will be sent into Mihomo.'));

		return m.render();
	}
});
