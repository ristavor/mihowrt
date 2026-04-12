'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require mihowrt.backend as backendHelper';

const DST_LIST_FILE = '/opt/clash/lst/always_proxy_dst.txt';
const SRC_LIST_FILE = '/opt/clash/lst/always_proxy_src.txt';
let dstValueCache = null;
let srcValueCache = null;

function normalizeBlock(value) {
	value = (value || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
	value = value.trim();
	return value ? value + '\n' : '';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('mihowrt'),
			L.resolveDefault(fs.read(DST_LIST_FILE), ''),
			L.resolveDefault(fs.read(SRC_LIST_FILE), ''),
			backendHelper.readConfig()
		]);
	},

	render: function(data) {
		if (dstValueCache == null)
			dstValueCache = data[1] || '';
		if (srcValueCache == null)
			srcValueCache = data[2] || '';
		const runtimeSettings = data[3];

		const m = new form.Map('mihowrt', _('MihoWRT Policy'), _('Direct-first policy layer. External DNS/53 from selected interfaces can be hijacked to Mihomo DNS. Ports, routing mark, and fake-ip behavior are derived by backend parsing of `/opt/clash/config.yaml`.'));
		const s = m.section(form.NamedSection, 'settings', 'settings', _('Runtime Settings'));

		s.anonymous = true;
		s.addremove = false;

		let o = s.option(form.Flag, 'enabled', _('Enable Policy Layer'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.DynamicList, 'source_network_interfaces', _('Source Interfaces'));
		o.placeholder = 'br-lan';
		o.description = _('Interfaces from which prerouting traffic may enter the Mihomo policy path. Empty list auto-detects `network.lan` device at runtime without writing back to UCI.');
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			return /^[A-Za-z0-9_.:@-]+$/.test(value) ? true : _('Interface name contains unsupported characters');
		};

		o = s.option(form.Flag, 'dns_hijack', _('Hijack DNS/53 To Mihomo DNS'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Redirect client TCP/UDP DNS requests from selected interfaces to Mihomo DNS listener.');

		o = s.option(form.DummyValue, '_config_status', _('Config.yaml Status'));
		o.description = _('These values come from backend parsing of `/opt/clash/config.yaml`. Missing required entries prevent service start.');
		o.cfgvalue = function() {
			return runtimeSettings.errors.length ? runtimeSettings.errors.join(' | ') : _('OK');
		};

		o = s.option(form.DummyValue, '_mihomo_dns_port', _('Mihomo DNS Port'));
		o.description = _('Derived from `dns.listen`. Policy always uses `127.0.0.1#<port>` for dnsmasq.');
		o.cfgvalue = function() {
			return runtimeSettings.dnsPort || _('Missing in config.yaml');
		};

		o = s.option(form.DummyValue, '_mihomo_tproxy_port', _('Mihomo TPROXY Port'));
		o.description = _('Derived from `tproxy-port` in `/opt/clash/config.yaml`.');
		o.cfgvalue = function() {
			return runtimeSettings.tproxyPort || _('Missing in config.yaml');
		};

		o = s.option(form.DummyValue, '_mihomo_routing_mark', _('Mihomo Routing Mark'));
		o.description = _('Derived from `routing-mark` in `/opt/clash/config.yaml`.');
		o.cfgvalue = function() {
			return runtimeSettings.routingMark || _('Missing in config.yaml');
		};

		o = s.option(form.Value, 'route_table_id', _('Route Table ID'));
		o.placeholder = _('auto');
		o.description = _('Optional. Empty value auto-selects free route table id.');
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			if (!/^[0-9]+$/.test(value))
				return _('Route table id must be numeric');
			const tableId = parseInt(value, 10);
			if (tableId < 1 || tableId > 252)
				return _('Route table id must be between 1 and 252');
			return true;
		};

		o = s.option(form.Value, 'route_rule_priority', _('Route Rule Priority'));
		o.placeholder = _('auto');
		o.description = _('Optional. Empty value auto-selects free route rule priority.');
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			if (!/^[0-9]+$/.test(value))
				return _('Route rule priority must be numeric');
			const priority = parseInt(value, 10);
			if (priority < 1 || priority > 32765)
				return _('Route rule priority must be between 1 and 32765');
			return true;
		};

		o = s.option(form.Flag, 'disable_quic', _('Disable QUIC For Mihomo-Bound Traffic'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Reject UDP/443 only for traffic selected into Mihomo by these nft policy blocks.');

		o = s.option(form.DummyValue, '_catch_fakeip', _('Catch Fake-IP Traffic'));
		o.description = _('Enabled only when `dns.enhanced-mode` equals `fake-ip` in `/opt/clash/config.yaml`.');
		o.cfgvalue = function() {
			return runtimeSettings.catchFakeip ? _('Enabled') : _('Disabled');
		};

		o = s.option(form.DummyValue, '_fakeip_range', _('Fake-IP Range'));
		o.description = _('Derived from `dns.fake-ip-range` when `dns.enhanced-mode` is `fake-ip`.');
		o.cfgvalue = function() {
			if (!runtimeSettings.catchFakeip)
				return _('Not used');
			return runtimeSettings.fakeIpRange || _('Missing in config.yaml');
		};

		o = s.option(form.TextValue, '_always_proxy_dst', _('Always Proxy Destination IP/CIDR'));
		o.rows = 18;
		o.wrap = 'off';
		o.monospace = true;
		o.description = _('One IPv4 or CIDR per line. Packets with matching destination will be sent into Mihomo.');
		o.cfgvalue = function() {
			return dstValueCache || '';
		};
		o.write = function(section_id, value) {
			dstValueCache = normalizeBlock(value);
			return fs.write(DST_LIST_FILE, dstValueCache);
		};
		o.remove = function() {
			dstValueCache = '';
			return fs.write(DST_LIST_FILE, '');
		};

		o = s.option(form.TextValue, '_always_proxy_src', _('Always Proxy Source IP/CIDR'));
		o.rows = 18;
		o.wrap = 'off';
		o.monospace = true;
		o.description = _('One IPv4 or CIDR per line. Packets from matching clients will be sent into Mihomo.');
		o.cfgvalue = function() {
			return srcValueCache || '';
		};
		o.write = function(section_id, value) {
			srcValueCache = normalizeBlock(value);
			return fs.write(SRC_LIST_FILE, srcValueCache);
		};
		o.remove = function() {
			srcValueCache = '';
			return fs.write(SRC_LIST_FILE, '');
		};

		return m.render();
	}
});
