'use strict';
'require view';
'require form';
'require ui';
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
			api.readLarge('lists-json').then((lists) => {
				if (!LIST_KINDS.every((kind) => typeof lists?.[kind] === 'string'))
					throw new Error(_('Unexpected response from the router.'));
				return lists;
			}).catch((e) => ({ error: api.errorText(e) })),
			api.read('profile-json').catch(() => ({})),
			callLeases().catch(() => null)
		]);
	},

	// Lists are files, not UCI: buffer edits and upload them on save.
	listOption: function(s, tab, kind, title, description) {
		const o = s.taboption(tab, form.TextValue, '_' + kind, title, description || LIST_HELP);
		o.rows = 6;
		o.monospace = true;
		o.readonly = !!this.listsError;
		o.cfgvalue = () => this.lists[kind];
		o.write = (sid, value) => {
			if (!this.listsError)
				this.edited[kind] = value;
		};
		// Hidden (provider list only): keep the list. Visible and empty: cleared.
		o.remove = (sid) => {
			if (!this.listsError && o.isActive(sid))
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
		o.rmempty = false;
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
		this.listsError = lists.error;
		this.lists = this.listsError ? { dst: '', src: '', direct: '', direct_src: '' } : lists;
		this.edited = {};
		this.profile = profile || {};
		const proxyFirst = this.profile.mode === 'proxy-first';
		const fakeip = this.profile.dns === 'fake-ip';
		const m = new form.Map('mihowrt', _('Traffic'), _('Choose which traffic goes through Mihomo. Save & Apply applies the changes.'));
		const s = m.section(form.NamedSection, 'settings', 'settings');
		s.tab('basic', _('Basic'));
		s.tab('advanced', _('Advanced'));

		// The mode follows the DNS settings of the YAML; it is not a setting.
		let o = s.taboption('basic', form.DummyValue, '_mode', _('Traffic mode'),
			_('To change the mode, the YAML must use dns.enhanced-mode: fake-ip with dns.fake-ip-filter-mode: whitelist for "Only selected", anything else for "All traffic".'));
		o.cfgvalue = () => api.modeLabel(this.profile.mode) + ' ' +
			(uci.get('mihowrt', 'settings', 'subscription_url') ? _('(chosen by your subscription)') : _('(follows the DNS settings of your YAML)'));

		this.titles = { dst: _('Addresses via proxy'), src: _('Devices via proxy'), direct: _('Addresses always direct'), direct_src: _('Devices always direct') };
		for (const kind of proxyFirst ? [ 'dst', 'src' ] : [ 'direct', 'direct_src' ]) {
			const count = this.lists[kind].split('\n').filter((line) => line.trim() && !/^\s*#/.test(line)).length;
			if (count) {
				o = s.taboption('basic', form.DummyValue, '_' + kind + '_inactive', this.titles[kind]);
				o.cfgvalue = () => N_(count, '%s: %d saved entry, used in the other mode.', '%s: %d saved entries, used in the other mode.').format(this.titles[kind], count);
			}
		}
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
				this.devicesOption(s, 'direct_src', _('All traffic of these devices bypasses Mihomo. Use a MAC address to cover both IPv4 and IPv6, or an IP address.'), leases);
			}
		}
		else {
			this.providerList(s, 'basic', 'dst', this.titles.dst);
			this.devicesOption(s, 'src', _('All traffic of these devices goes through Mihomo. Use a MAC address to cover both IPv4 and IPv6, or an IP address.'), leases);
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
			// Shipped values equal to the default must stay in UCI.
			f.rmempty = false;
			return f;
		});
		flag('dns_hijack', _('Redirect client DNS to Mihomo'), _('Devices with a hard-coded DNS server (port 53) still get Mihomo answers.'));
		flag('disable_quic', _('Block QUIC for proxied traffic'), _('Forces browsers to use TCP, which proxies handle better.'));
		flag('bypass_ntp', _('Time sync without Mihomo'), _('NTP servers resolve through the WAN interface DNS and UDP/123 bypasses Mihomo, so the clock syncs even if Mihomo fails.'));
		flag('bypass_subscription_dns', _('Subscription server without Mihomo'), _('While the subscription updates, its server is resolved through the WAN interface DNS and downloaded directly. Other traffic to the same addresses is not affected.'));
		o = s.taboption('advanced', form.Flag, 'netbird_proxy', _('Route outbound NetBird through Mihomo'), _('NetBird control, relay and peer transport follow Mihomo rules. Incoming NetBird traffic is never touched.'));
		o.default = '0';
		o.rmempty = false;

		this.map = m;
		return m.render().then((node) => {
			// Right after the heading and description, like on the other pages.
			const notice = api.jobNotice();
			const heading = node.querySelector?.('.cbi-map-descr') || node.querySelector?.('h2');
			if (heading?.after)
				heading.after(notice);
			return E('div', {}, [
				api.style(), heading?.after ? null : notice,
				this.listsError ? E('div', { class: 'alert-message error' }, text(
					_('Cannot load the lists: %s').format(this.listsError) + ' ' + _('Reload the page to try again.'))) : null,
				node
			].filter(Boolean));
		});
	},

	// A device list with the lease picker. The picker carries the description
	// itself, so its notes come after it and not above it.
	devicesOption: function(s, kind, description, leases) {
		const o = this.listOption(s, 'basic', kind, this.titles[kind], description);
		this.extendWidget(o, (node) => {
			const picker = this.listsError ? node : this.addLeasePicker(node, leases, description);
			o.description = picker === node ? description : '';
			return picker;
		});
		return o;
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
		const refresh = E('button', { class: 'cbi-button', type: 'button', 'data-mw-job': '', disabled: api.jobRunning || null }, text(_('Update remote lists')));
		refresh.addEventListener('click', () => api.busy(refresh, async () => {
			const res = await api.job('update-lists');
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

	// A MAC covers both address families. DHCPv6 leases may have no MAC.
	addLeasePicker: function(node, leases, description) {
		const area = node.querySelector('textarea');
		if (!area || leases == null)
			return node;
		const address = (lease) => lease.ipaddr || [...(lease.ip6addrs || []), lease.ip6addr]
			.find((addr) => addr && (!addr.includes('/') || /\/128$/.test(addr)))?.replace(/\/128$/, '') || '';
		const all = (leases.dhcp_leases || []).concat(leases.dhcp6_leases || [])
			.filter((lease) => lease.macaddr || address(lease));
		const entries = () => area.value.split('\n').map((line) => line.split('#')[0].trim().toLowerCase()).filter(Boolean);
		const connected = new Set(all.flatMap((lease) => [ lease.macaddr?.toLowerCase(), lease.ipaddr ].filter(Boolean)));
		// Locally administered (randomized) Wi-Fi MAC. Marked statically: a
		// message that appears after adding would shift the layout.
		const isPrivate = (lease) => /^[0-9a-f][26ae]:/i.test(lease.macaddr || '');
		const missing = E('div', { class: 'cbi-value-description', 'aria-live': 'polite' });
		const updateMissing = () => {
			const absent = [...new Set(entries())].filter((entry) =>
				(/^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(entry) || /^\d+\.\d+\.\d+\.\d+$/.test(entry)) && !connected.has(entry));
			missing.textContent = absent.length ? _('Not connected now: %s').format(absent.join(', ')) : '';
		};
		area.addEventListener('change', updateMissing);
		updateMissing();

		// No visible labels: the first option says what the picker does.
		const select = E('select', { class: 'cbi-input-select', 'aria-label': _('Add a device') }, [
			E('option', { value: '' }, text(_('Add a device…')))
		].concat(all.map((lease, index) => E('option', { value: String(index) },
			text((isPrivate(lease) ? _('%s (%s, private MAC)') : '%s (%s)')
				.format(lease.hostname || _('unknown'), address(lease) || lease.macaddr || ''))))));
		select.value = '';
		const addAs = E('select', { class: 'cbi-input-select', 'aria-label': _('Add as') }, [
			E('option', { value: 'mac' }, text(_('MAC (IPv4 + IPv6)'))),
			E('option', { value: 'ip' }, text(_('IP address')))
		]);
		addAs.value = 'mac';
		select.addEventListener('change', () => {
			const lease = select.value === '' ? null : all[select.value];
			select.value = '';
			if (!lease)
				return;
			const byMac = addAs.value === 'mac' && !!lease.macaddr;
			const entry = byMac ? lease.macaddr.toLowerCase() : address(lease);
			if (!entry || entries().includes(entry.toLowerCase()))
				return;
			// Keep a hostname on one comment line, never as list syntax.
			const hostname = (lease.hostname || '').replace(/[\r\n]+/g, ' ');
			area.value = (area.value.replace(/\s*$/, '') + '\n' + entry + (hostname ? ' # ' + hostname : '')).replace(/^\n/, '') + '\n';
			area.dispatchEvent(new Event('change', { bubbles: true }));
		});
		return E('div', {}, [ node, all.length ? E('div', { class: 'mw-row mw-picker' }, [ select, addAs ]) : null,
			description ? E('div', { class: 'cbi-value-description' }, text(description + (all.some(isPrivate)
				? ' ' + _('A device with a private Wi-Fi address must keep it for your network: choose "Fixed" (iPhone, iPad, Mac) or the per-network randomized MAC (Android) for this Wi-Fi, not a rotating one; otherwise the entry stops matching.') : ''))) : null, missing ]);
	},

	handleSave: null,

	// Lists first: a rejected list must not save or re-render the form.
	handleSaveApply: async function(ev, mode) {
		if (api.jobRunning) {
			try {
				const status = await api.read('job-status');
				api.notify(_('"%s" is running…').format(api.jobLabel(status.op)));
			}
			catch (e) {
				api.notify(api.errorText(e), 'error');
			}
			return;
		}
		if (this.saving)
			return;
		this.saving = true;
		try {
			this.edited = {};
			await this.map.parse();
			const edited = this.listsError ? [] : LIST_KINDS.filter((kind) =>
				kind in this.edited && this.edited[kind] !== this.lists[kind]);
			if (edited.length) {
				const paths = await Promise.all(LIST_KINDS.map((kind) => edited.includes(kind)
					? api.upload('mihowrt-policy-list', this.edited[kind]) : '-'));
				await api.job('apply-lists', ...paths);
				for (const kind of edited)
					this.lists[kind] = this.edited[kind];
			}
			try {
				await this.map.save(null, true);
			}
			catch (e) {
				if (edited.length)
					throw new Error(_('Lists were applied, but settings could not be saved: %s. Review the settings and try Save & Apply again.').format(api.errorText(e)));
				throw e;
			}
			const changes = await uci.changes();
			if (Object.keys(changes).some((config) => changes[config].length))
				return ui.changes.apply(mode == '0');
			api.notify(_('Changes applied.'));
		}
		catch (e) {
			const bad = /^Invalid (direct_src|dst|src|direct) entries: (.*)$/.exec(e.message);
			api.notify(bad ? _('"%s" has invalid lines: %s').format(this.titles[bad[1]], bad[2]) : api.errorText(e), 'error');
			throw e;
		}
		finally {
			this.saving = false;
		}
	}
});
