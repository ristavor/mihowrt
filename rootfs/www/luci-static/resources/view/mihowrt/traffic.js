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

		this.titles = { dst: _('Addresses via proxy'), src: _('Devices via proxy'), direct: _('Addresses always direct') };
		this.listOption(s, 'basic', 'dst', this.titles.dst, 'direct-first');
		const devices = this.listOption(s, 'basic', 'src', this.titles.src, 'direct-first');
		devices.description = _('All traffic of these devices goes through Mihomo. Use static DHCP leases so addresses do not change.');
		this.listOption(s, 'basic', 'direct', this.titles.direct, 'proxy-first');
		this.extendWidget(devices, (node) => this.addLeasePicker(node, leases));

		o = s.taboption('basic', form.Value, 'lists_interval', _('Update remote lists every (hours)'), _('0: only when you press "Update remote lists".'));
		o.datatype = 'range(0,8760)';
		o.placeholder = '0';
		this.extendWidget(o, (node) => this.intervalField(node, this.refreshButton()));

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

		this.map = m;
		return m.render().then((node) => E('div', {}, [ api.style(), node ]));
	},

	// LuCI re-renders the form after saving: extras are added inside the
	// option's widget so they survive that (with any theme).
	extendWidget: function(o, extra) {
		const render = o.renderWidget;
		o.renderWidget = function() {
			return extra(render.apply(this, arguments));
		};
	},

	refreshButton: function() {
		const refresh = E('button', { class: 'cbi-button', type: 'button' }, text(_('Update remote lists')));
		refresh.addEventListener('click', () => api.busy(refresh, async () => {
			const res = await api.write('update-lists');
			api.notify(res.changed ? _('Remote lists updated.') : _('Remote lists are up to date.'));
		}));
		return refresh;
	},

	// Number field (with arrows) like the subscription interval, with the
	// "Update remote lists" button next to it.
	intervalField: function(node, refresh) {
		const input = node.querySelector('input');
		if (input) {
			input.setAttribute('type', 'number');
			input.setAttribute('min', '0');
			input.setAttribute('max', '8760');
			input.style.width = '8em';
		}
		return E('div', { class: 'mw-row' }, [ node, refresh ]);
	},

	// "Add device" select under the devices list, filled from DHCP leases.
	addLeasePicker: function(node, leases) {
		const area = node.querySelector('textarea');
		const all = (leases?.dhcp_leases || []).concat(leases?.dhcp6_leases || []);
		if (!area || !all.length)
			return node;

		const select = E('select', { class: 'cbi-input-select', 'aria-label': _('Add a device') }, [
			E('option', { value: '' }, text(_('Add a device…')))
		].concat(all.map((l) => {
			const addr = l.ipaddr || (l.ip6addrs || [])[0] || '';
			return E('option', { value: addr.replace(/\/\d+$/, '') }, text('%s (%s)'.format(l.hostname || _('unknown'), addr)));
		})));
		select.addEventListener('change', () => {
			const addr = select.value;
			if (!addr)
				return;
			select.value = '';
			// Themes with custom dropdowns may repeat "change": add each device once.
			if (area.value.split('\n').some((l) => l.trim() === addr))
				return;
			area.value = (area.value.replace(/\s*$/, '') + '\n' + addr).replace(/^\n/, '') + '\n';
			area.dispatchEvent(new Event('change', { bubbles: true }));
		});
		return E('div', {}, [ node, E('div', { class: 'mw-row' }, [ select ]) ]);
	},

	// Lists first: if one is rejected, nothing is saved and the edits stay
	// in the form (map.save() re-renders it from the saved values).
	handleSave: async function(ev) {
		this.edited = {};
		await this.map.parse();
		const edited = this.edited;
		if (Object.keys(edited).length) {
			try {
				const paths = await Promise.all([ 'dst', 'src', 'direct' ].map((kind) =>
					api.upload('mihowrt-policy-list', kind in edited ? edited[kind] : this.lists[kind])));
				await api.write('apply-lists', ...paths);
			}
			catch (e) {
				const bad = /^Invalid (dst|src|direct) entries: (.*)$/.exec(e.message);
				api.notify(bad ? _('"%s" has invalid lines: %s').format(this.titles[bad[1]], bad[2]) : e.message, 'danger');
				throw e;
			}
			Object.assign(this.lists, edited);
		}
		await this.map.save();
	}
});
