'use strict';
'require view';
'require form';
'require rpc';
'require tools.widgets as widgets';
'require mihowrt.api as api';

const text = api.text;
const LIST_FILES = {
	dst: '/opt/clash/lst/always_proxy_dst.txt',
	src: '/opt/clash/lst/always_proxy_src.txt',
	direct: '/opt/clash/lst/direct_dst.txt'
};

const callLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} } });

const LIST_HELP = _('One entry per line: IPv4 or IPv6 address or subnet, optionally with ports (1.1.1.1;443, 2001:db8::/32). A line with a list URL (https://…) adds a remote list. Lines starting with # are comments.');

return view.extend({
	lists: {},
	edited: {},

	load: function() {
		return Promise.all([
			api.readFile(LIST_FILES.dst),
			api.readFile(LIST_FILES.src),
			api.readFile(LIST_FILES.direct),
			callLeases().catch(() => ({}))
		]);
	},

	// Lists are files, not UCI: buffer edits and upload them on save.
	listOption: function(s, tab, kind, title, mode) {
		const o = s.taboption(tab, form.TextValue, '_' + kind, title, LIST_HELP);
		o.rows = 6;
		o.monospace = true;
		o.depends('policy_mode', mode);
		o.cfgvalue = () => this.lists[kind];
		o.write = (sid, value) => { this.edited[kind] = value; };
		// Hidden by the other mode: keep the list. Visible and empty: cleared.
		o.remove = (sid) => {
			if (o.isActive(sid))
				this.edited[kind] = '';
		};
		return o;
	},

	render: function([ dst, src, direct, leases ]) {
		this.lists = { dst: dst || '', src: src || '', direct: direct || '' };
		const m = new form.Map('mihowrt', _('Traffic'), _('Choose which traffic goes through Mihomo. Saving applies the changes immediately.'));
		const s = m.section(form.NamedSection, 'settings', 'settings');
		s.tab('basic', _('Basic'));
		s.tab('advanced', _('Advanced'));

		let o = s.taboption('basic', form.ListValue, 'policy_mode', _('Mode'));
		o.widget = 'radio';
		o.orientation = 'vertical';
		o.value('direct-first', _('Only selected traffic via proxy'));
		o.value('proxy-first', _('All traffic via proxy except exclusions'));
		o.default = 'direct-first';
		o.description = _('In the first mode only the lists below and blocked sites from your subscription use the proxy.');

		this.listOption(s, 'basic', 'dst', _('Addresses via proxy'), 'direct-first');
		const devices = this.listOption(s, 'basic', 'src', _('Devices via proxy'), 'direct-first');
		devices.description = _('All traffic of these devices goes through Mihomo. Use static DHCP leases so addresses do not change.');
		this.listOption(s, 'basic', 'direct', _('Addresses always direct'), 'proxy-first');

		o = s.taboption('basic', form.Value, 'lists_interval', _('Update remote lists every (hours)'), _('0: only when you press "Update remote lists".'));
		o.datatype = 'range(0,8760)';
		o.placeholder = '0';

		o = s.taboption('advanced', widgets.DeviceSelect, 'source_network_interfaces', _('Client interfaces'), _('Traffic from these interfaces is handled. Usually br-lan.'));
		o.multiple = true;
		o.noaliases = true;
		o = s.taboption('advanced', form.Flag, 'dns_hijack', _('Redirect client DNS to Mihomo'), _('Devices with a hard-coded DNS server (port 53) still get Mihomo answers.'));
		o.default = '1';
		o = s.taboption('advanced', form.Flag, 'disable_quic', _('Block QUIC for proxied traffic'), _('Forces browsers to use TCP, which proxies handle better.'));
		o.default = '1';
		o = s.taboption('advanced', form.Flag, 'bypass_ntp', _('Time sync without Mihomo'), _('NTP servers resolve through the WAN interface DNS and UDP/123 bypasses Mihomo, so the clock syncs even if Mihomo fails.'));
		o.default = '1';
		o = s.taboption('advanced', form.Flag, 'bypass_subscription_dns', _('Subscription server without Mihomo'), _('While the subscription updates, its server is resolved through the WAN interface DNS and downloaded directly. Other traffic to the same addresses is not affected.'));
		o.default = '1';
		o = s.taboption('advanced', form.Flag, 'netbird_proxy', _('Route outbound NetBird through Mihomo'), _('NetBird control, relay and peer transport follow Mihomo rules. Incoming NetBird traffic is never touched.'));
		o.default = '0';

		const refresh = E('button', { class: 'cbi-button' }, text(_('Update remote lists')));
		refresh.addEventListener('click', () => api.busy(refresh, async () => {
			const res = await api.write('update-lists');
			api.notify(res.changed ? _('Remote lists updated.') : _('Remote lists are up to date.'));
		}));

		return m.render().then((node) => {
			this.map = m;
			this.addLeasePicker(node, leases);
			node.appendChild(E('div', { class: 'mw-row' }, [ refresh ]));
			return E('div', {}, [ api.style(), node ]);
		});
	},

	// "Add device" select under the devices list, filled from DHCP leases.
	addLeasePicker: function(node, leases) {
		const area = node.querySelector('textarea[id$="._src"]');
		const all = (leases?.dhcp_leases || []).concat(leases?.dhcp6_leases || []);
		if (!area || !all.length)
			return;

		const select = E('select', { class: 'cbi-input-select', 'aria-label': _('Add a device') }, [
			E('option', { value: '' }, text(_('Add a device…')))
		].concat(all.map((l) => {
			const addr = l.ipaddr || (l.ip6addrs || [])[0] || '';
			return E('option', { value: addr.replace(/\/\d+$/, '') }, text('%s (%s)'.format(l.hostname || _('unknown'), addr)));
		})));
		select.addEventListener('change', () => {
			if (!select.value)
				return;
			area.value = (area.value.replace(/\s*$/, '') + '\n' + select.value).replace(/^\n/, '') + '\n';
			area.dispatchEvent(new Event('change', { bubbles: true }));
			select.value = '';
		});
		area.parentNode.appendChild(E('div', { class: 'mw-row' }, [ select ]));
	},

	handleSave: async function(ev) {
		this.edited = {};
		await this.map.save();
		const kinds = Object.keys(this.edited);
		if (!kinds.length)
			return;
		const paths = await Promise.all([ 'dst', 'src', 'direct' ].map((kind) =>
			api.upload('mihowrt-policy-list', kind in this.edited ? this.edited[kind] : this.lists[kind])));
		await api.write('apply-lists', ...paths);
		Object.assign(this.lists, this.edited);
	}
});
