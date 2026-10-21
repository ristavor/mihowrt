'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require tools.widgets as widgets';
'require mihowrt.api as api';

const text = api.text;
const LIST_KINDS = [ 'dst', 'src', 'direct', 'direct_src' ];

const callLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} } });

const LIST_HELP = _('One entry per line: IPv4 or IPv6 address or subnet, optionally with ports (1.1.1.1;443, 2001:db8::/32). A line with a list URL (https://…) adds a remote list. Lines starting with # are comments.');

return view.extend({
	lists: {},
	edited: {},

	load: function() {
		return Promise.all([
			api.read('lists-json'),
			api.read('profile-json').catch(() => ({})),
			callLeases().catch(() => ({}))
		]);
	},

	// Lists are files, not UCI: buffer edits and upload them on save.
	listOption: function(s, tab, kind, title, description) {
		const o = s.taboption(tab, form.TextValue, '_' + kind, title, description || LIST_HELP);
		o.rows = 6;
		o.monospace = true;
		o.cfgvalue = () => this.lists[kind];
		o.write = (sid, value) => { this.edited[kind] = value; };
		// Hidden (provider list only): keep the list. Visible and empty: cleared.
		o.remove = (sid) => {
			if (o.isActive(sid))
				this.edited[kind] = '';
		};
		return o;
	},

	// A list the provider ships: choose provider, provider + mine, or mine.
	providerList: function(s, tab, kind, title) {
		const info = this.profile.lists?.[kind];
		if (!info?.provided)
			return this.listOption(s, tab, kind, title);

		const name = kind + '_list_source';
		const n = info.provider_count || 0;
		const own = info.own_count || 0;
		let o = s.taboption(tab, form.ListValue, name, title, own > 0
			? N_(own, 'Set by your provider. You also have %d own entry: it applies with "Provider list + mine" or "Only mine".',
				'Set by your provider. You also have %d own entries: they apply with "Provider list + mine" or "Only mine".').format(own)
			: _('Set by your provider.'));
		o.value('provider', N_(n, 'Provider list (%d entry)', 'Provider list (%d entries)').format(n));
		o.value('merge', _('Provider list + mine'));
		o.value('own', _('Only mine'));
		o.default = 'provider';
		o = this.listOption(s, tab, kind, _('My entries'));
		o.depends(name, 'merge');
		o.depends(name, 'own');
		return o;
	},

	// A setting the provider may set (x-mihowrt): its value read-only, a
	// "Use my own value" flag, and the normal option shown when it is checked.
	providerScalar: function(s, tab, name, make) {
		const provider = this.profile.provider || {};
		if (!(name in provider))
			return make();

		const overrides = () => [].concat(uci.get('mihowrt', 'settings', 'provider_override') || []);
		const real = make();
		const title = real.title;
		const value = () => (real instanceof form.Flag)
			? (provider[name] === '1' ? _('Enabled') : _('Disabled'))
			: String(provider[name]);
		// The provider value stays visible; its note says whether it applies.
		let o = s.taboption(tab, form.DummyValue, '_prov_' + name, title, _('Set by your provider.'));
		o.cfgvalue = value;
		o.depends('_own_' + name, '0');
		o = s.taboption(tab, form.DummyValue, '_provoff_' + name, title, _('Provider value, not used: your own value applies.'));
		o.cfgvalue = value;
		o.depends('_own_' + name, '1');

		o = s.taboption(tab, form.Flag, '_own_' + name, _('Use my own value'));
		this.extendWidget(o, (node) => {
			node.querySelector('input')?.setAttribute('aria-label', _('Use my own value for "%s"').format(title));
			return node;
		});
		o.default = '0';
		o.cfgvalue = () => overrides().includes(name) ? '1' : '0';
		o.write = (sid, value) => {
			const list = overrides().filter((v) => v !== name);
			if (value === '1')
				list.push(name);
			if (list.length)
				uci.set('mihowrt', 'settings', 'provider_override', list);
			else
				uci.unset('mihowrt', 'settings', 'provider_override');
		};
		o.remove = (sid) => o.write(sid, '0');

		real.title = _('My value');
		real.depends('_own_' + name, '1');
		// Hidden while the provider value applies: keep the user's value.
		const remove = real.remove;
		real.remove = function(sid) {
			return real.isActive(sid) ? remove.apply(this, arguments) : null;
		};
		// Keep it right after its flag in the form.
		s.children.splice(s.children.indexOf(real), 1);
		s.children.push(real);
		return real;
	},

	render: function([ lists, profile, leases ]) {
		this.lists = lists;
		this.profile = profile || {};
		const proxyFirst = this.profile.mode === 'proxy-first';
		const fakeip = this.profile.dns === 'fake-ip';
		const m = new form.Map('mihowrt', _('Traffic'), _('Choose which traffic goes through Mihomo. Saving applies the changes immediately.'));
		const s = m.section(form.NamedSection, 'settings', 'settings');
		s.tab('basic', _('Basic'));
		s.tab('advanced', _('Advanced'));

		// The mode follows the DNS settings of the YAML; it is not a setting.
		let o = s.taboption('basic', form.DummyValue, '_mode', _('Mode'));
		o.cfgvalue = () => (proxyFirst ? _('All traffic via proxy except exclusions') : _('Only selected traffic via proxy')) + ' ' +
			(uci.get('mihowrt', 'settings', 'subscription_url') ? _('(chosen by your subscription)') : _('(follows the DNS settings of your YAML)'));

		this.titles = { dst: _('Addresses via proxy'), src: _('Devices via proxy'), direct: _('Addresses always direct'), direct_src: _('Devices always direct') };
		// Only the lists of the active mode: the others keep their files.
		if (proxyFirst) {
			this.providerList(s, 'basic', 'direct', this.titles.direct);
			if (fakeip) {
				// With fake-IP DNS the devices could not reach anything directly:
				// say so in plain text; the saved file is kept as it is.
				const saved = this.lists.direct_src.split('\n').filter((l) => l.trim() && !/^\s*#/.test(l)).length;
				o = s.taboption('basic', form.DummyValue, '_direct_src_off', this.titles.direct_src);
				o.cfgvalue = () => _('Not available with this subscription (it uses fake-IP DNS).') +
					(saved ? ' ' + N_(saved, 'Saved: %d entry.', 'Saved: %d entries.').format(saved) : '');
			}
			else {
				const devices = this.listOption(s, 'basic', 'direct_src', this.titles.direct_src,
					_('All traffic of these devices bypasses Mihomo. Use static DHCP leases so addresses do not change.'));
				this.extendWidget(devices, (node) => this.addLeasePicker(node, leases));
			}
		}
		else {
			this.providerList(s, 'basic', 'dst', this.titles.dst);
			const devices = this.listOption(s, 'basic', 'src', this.titles.src,
				_('All traffic of these devices goes through Mihomo. Use static DHCP leases so addresses do not change.'));
			this.extendWidget(devices, (node) => this.addLeasePicker(node, leases));
		}

		this.providerScalar(s, 'basic', 'lists_interval', () => {
			const v = s.taboption('basic', form.Value, 'lists_interval', _('Update remote lists every (hours)'), _('0: only when you press "Update remote lists".'));
			v.datatype = 'range(0,8760)';
			v.placeholder = '0';
			this.extendWidget(v, (node) => this.intervalField(node, this.refreshButton()));
			return v;
		});

		o = s.taboption('advanced', widgets.DeviceSelect, 'source_network_interfaces', _('Client interfaces'), _('Traffic from these interfaces is handled. Usually br-lan.'));
		o.multiple = true;
		o.noaliases = true;
		const flag = (name, title, description) => this.providerScalar(s, 'advanced', name, () => {
			const f = s.taboption('advanced', form.Flag, name, title, description);
			f.default = '1';
			return f;
		});
		flag('dns_hijack', _('Redirect client DNS to Mihomo'), _('Devices with a hard-coded DNS server (port 53) still get Mihomo answers.'));
		flag('disable_quic', _('Block QUIC for proxied traffic'), _('Forces browsers to use TCP, which proxies handle better.'));
		flag('bypass_ntp', _('Time sync without Mihomo'), _('NTP servers resolve through the WAN interface DNS and UDP/123 bypasses Mihomo, so the clock syncs even if Mihomo fails.'));
		flag('bypass_subscription_dns', _('Subscription server without Mihomo'), _('While the subscription updates, its server is resolved through the WAN interface DNS and downloaded directly. Other traffic to the same addresses is not affected.'));
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

	// Numeric field with the
	// "Update remote lists" button next to it.
	intervalField: function(node, refresh) {
		const input = node.querySelector('input');
		if (input) {
			// No type=number: some themes (openwrt-2020) style only text inputs.
			input.setAttribute('inputmode', 'numeric');
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
				const paths = await Promise.all(LIST_KINDS.map((kind) =>
					api.upload('mihowrt-policy-list', kind in edited ? edited[kind] : this.lists[kind])));
				await api.write('apply-lists', ...paths);
			}
			catch (e) {
				const bad = /^Invalid (direct_src|dst|src|direct) entries: (.*)$/.exec(e.message);
				api.notify(bad ? _('"%s" has invalid lines: %s').format(this.titles[bad[1]], bad[2]) : e.message, 'danger');
				throw e;
			}
			Object.assign(this.lists, edited);
		}
		await this.map.save();
	}
});
