'use strict';
'require view';
'require form';
'require uci';
'require fs';

const DST_LIST_FILE = '/opt/clash/lst/always_proxy_dst.txt';
const SRC_LIST_FILE = '/opt/clash/lst/always_proxy_src.txt';
let dstValueCache = null;
let srcValueCache = null;

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
	load: function() {
		return Promise.all([
			uci.load('mihowrt'),
			L.resolveDefault(fs.read(DST_LIST_FILE), ''),
			L.resolveDefault(fs.read(SRC_LIST_FILE), '')
		]);
	},

	render: function(data) {
		if (dstValueCache == null)
			dstValueCache = data[1] || '';
		if (srcValueCache == null)
			srcValueCache = data[2] || '';

		const m = new form.Map('mihowrt', _('MihoWRT Policy'), _('Direct-first policy layer. External DNS/53 from selected interfaces can be hijacked to Mihomo DNS.'));
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
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Route table id'), 1, 252);
		};

		o = s.option(form.Value, 'route_rule_priority', _('Route Rule Priority'));
		o.validate = function(section_id, value) {
			return validateNumericRange(value, _('Route rule priority'), 1, 32765);
		};

		o = s.option(form.Flag, 'disable_quic', _('Disable QUIC For Mihomo-Bound Traffic'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Reject UDP/443 only for traffic selected into Mihomo by these nft policy blocks.');

		o = s.option(form.TextValue, '_always_proxy_dst', _('Always Proxy Destination IP/CIDR'));
		bindTextFileOption(o, 'dst', DST_LIST_FILE, _('One IPv4 or CIDR per line. Packets with matching destination will be sent into Mihomo.'));

		o = s.option(form.TextValue, '_always_proxy_src', _('Always Proxy Source IP/CIDR'));
		bindTextFileOption(o, 'src', SRC_LIST_FILE, _('One IPv4 or CIDR per line. Packets from matching clients will be sent into Mihomo.'));

		return m.render();
	}
});
