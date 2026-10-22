'use strict';
'require view';
'require mihowrt.api as api';

const text = api.text;

// Only Mihomo's error messages, without timestamps and temp paths.
function coreError(raw) {
	const msgs = [ ...String(raw).matchAll(/level=(?:error|fatal) msg="((?:[^"\\]|\\.)*)"/g) ].map((m) => m[1].replace(/\\"/g, '"'));
	return msgs.length ? msgs.join('\n')
		: String(raw).split('\n').filter((l) => l && !/level=(info|debug|warning)/.test(l) && !/test failed$/.test(l)).join('\n');
}

// Each check: passed? (null = unknown), label, hint shown when it fails.
function checks(st, diagnostics) {
	const state = st.state || (st.running ? 'running' : 'stopped');
	const up = state === 'running' || state === 'degraded';
	const serviceHint = _('Press Start on Overview. If it stops again, check the log below.') +
		(state === 'failed' && st.last_error ? '\n' + _('Last error: %s').format(st.last_error) : '');
	const kb = (value) => typeof value === 'number' && isFinite(value) ? value : null;
	const flash = kb(diagnostics?.flash_free_kb);
	const ram = kb(diagnostics?.ram_available_kb);
	const list = [
		[ st.core_installed, _('Mihomo core installed') + (st.core ? ' (%s)'.format(st.core) : ''),
			_('Open Overview and install the core.') ],
		st.config_valid == null
			? [ null, _('Configuration not checked yet (it is checked at start)'), '' ]
			: [ st.config_valid, st.config_valid ? _('Configuration is valid') : _('Configuration has errors'),
				_('Update the subscription or fix the YAML on the Subscription page.') +
				(st.config_error ? '\n' + _('Mihomo says: %s').format(coreError(st.config_error)) : '') ],
		[ st.subscription_configured, _('Subscription configured'),
			_('Without a subscription only the YAML you entered is used.') ],
		state === 'starting' ? [ null, _('Starting…'), '' ] : [ up, _('Service is running'), serviceHint ]
	];
	if (state === 'degraded')
		list.push([ false, _('Mihomo DNS does not answer: traffic goes direct until it recovers'),
			_('Mihomo cannot resolve names: check that the proxy servers and DNS servers in the config are reachable.') ]);
	if (up) {
		if (state !== 'degraded')
			list.push([ st.dns_ok == null ? null : st.dns_ok === true, _('Mihomo answers DNS queries'),
				_('Mihomo cannot resolve names: check that the proxy servers and DNS servers in the config are reachable.') ]);
		list.push([ st.policy_active, _('Traffic rules are active'), _('Restart the service; if it persists, see the log.') ]);
	}
	if ((st.custom_dns_servers || []).length)
		list.push([ false, _('dnsmasq has its own upstream servers: %s').format(st.custom_dns_servers.join(', ')),
			_('These servers answer next to Mihomo, so some sites may bypass the proxy. Move them to the Mihomo YAML (dns.nameserver) and remove them from Network → DHCP and DNS.') ]);
	const conflicts = diagnostics?.conflicts || [];
	if (conflicts.length)
		list.push([ false, _('Other proxy packages are installed: %s').format(conflicts.join(', ')),
			_('They change DNS and firewall too. Use only one of them at a time.') ]);
	if (flash != null && flash < 5120)
		list.push([ false, _('Little free flash: %d MiB').format(Math.floor(flash / 1024)),
			_('Free some space or the core update may fail.') ]);
	if (ram != null && ram < 20480)
		list.push([ false, _('Little free memory: %d MiB').format(Math.floor(ram / 1024)),
			_('Mihomo may be stopped by the system when memory runs out. Stop other services or use a smaller configuration.') ]);
	const ports = diagnostics?.open_proxy_ports || [];
	if (ports.length)
		list.push([ false, _('Mihomo proxy ports %s accept any device in your network without a password').format(ports.join(', ')),
			_('Add authentication to the YAML or remove these ports if you do not use them.') ]);
	return list;
}

function checklist(st, diagnostics) {
	// Plain blocks, not a list: some themes draw bullets next to the marks.
	return E('div', { class: 'mw-check' }, checks(st, diagnostics).map(([ ok, label, hint ]) => E('div', [
		E('span', { class: 'mw-mark', 'aria-hidden': 'true' }, text(ok == null ? '–' : ok ? '✓' : '✗')),
		E('span', { class: 'mw-sr' }, text(ok == null ? _('Unknown:') : ok ? _('OK:') : _('Problem:'))),
		E('strong', text(label)),
		(ok || ok == null) ? '' : E('div', { class: 'mw-muted', style: 'margin-left:1.6em; white-space:pre-wrap' }, text(hint))
	])));
}

function providerLists(profile) {
	const lists = profile?.lists || {};
	const parts = [];
	if (lists.dst?.provided)
		parts.push(_('via proxy %d').format(lists.dst.provider_count || 0));
	if (lists.direct?.provided)
		parts.push(_('direct %d').format(lists.direct.provider_count || 0));
	return parts.length ? parts.join(', ') : _('none');
}

function details(st, profile, diagnostics) {
	const rows = [
		[ _('MihoWRT version'), st.version ],
		[ _('Mode'), api.modeLabel(st.mode) ],
		[ _('DNS mode'), st.dns_mode || '' ],
		[ _('Provider settings'), Object.keys(profile?.provider || {}).join(', ') || _('none') ],
		[ _('Provider lists'), providerLists(profile) ],
		[ _('Client interfaces'), (st.interfaces || []).join(', ') ],
		[ _('List entries'), _('proxy %d, devices %d, direct %d, direct devices %d').format(st.lists?.dst || 0, st.lists?.src || 0, st.lists?.direct || 0, st.lists?.direct_src || 0) ],
		[ _('Routing table'), st.route?.table ? _('%s (priority %s)').format(st.route.table, st.route.priority) : _('not active') ],
		[ _('Starts at boot'), st.enabled ? _('yes') : _('no') ]
	];
	// RSS is shown as the nearest MiB; free flash/RAM floor so a warning never overstates what is left.
	if (typeof diagnostics?.mihomo_rss_kb === 'number')
		rows.push([ _('Mihomo memory'), _('%d MiB').format(Math.round(diagnostics.mihomo_rss_kb / 1024)) ]);
	return api.infoGrid(rows);
}

return view.extend({
	load: () => Promise.all([
		api.read('status-json'),
		api.read('profile-json').catch(() => ({})),
		api.read('diagnostics-json').catch((e) => ({ unavailable: api.errorText(e) }))
	]),

	render: ([ st, profile, diagnostics ]) => {
		const logBox = E('pre', { class: 'mw-log' }, text(_('Loading…')));
		const loadLog = () => api.readLarge('logs-json', '300')
			.then((res) => {
				logBox.textContent = res.available ? (res.lines.join('\n') || _('No MihoWRT log lines yet.')) : _('System log is not available.');
				logBox.scrollTop = logBox.scrollHeight;
			})
			.catch((e) => { logBox.textContent = _('Cannot read the log: %s').format(api.errorText(e)); });
		const refresh = E('button', { class: 'cbi-button' }, text(_('Check again')));

		refresh.addEventListener('click', () => location.reload());

		return E('div', { class: 'mw-page' }, [
			api.style(),
			E('h2', text(_('Diagnostics'))),
			api.jobNotice(),
			diagnostics?.unavailable != null ? E('div', { class: 'alert-message warning' }, [
				E('div', text(_('Cannot load diagnostics: %s').format(diagnostics.unavailable))),
				E('div', text(_('Reload the page to try again.'))) ]) : '',
			E('div', { class: 'cbi-section' }, [ checklist(st, diagnostics), E('div', { class: 'mw-row' }, [ refresh ]) ]),
			(st.errors || []).length ? E('div', { class: 'alert-message warning' }, text(st.errors.join('; '))) : '',
			E('div', { class: 'cbi-section' }, [ E('h3', text(_('Details'))),
				api.toggle(_('Show details'), _('Hide details'), details(st, profile, diagnostics)) ]),
			E('div', { class: 'cbi-section' }, [ E('h3', text(_('Log'))),
				api.toggle(_('Show the log'), _('Hide the log'), logBox, loadLog) ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
