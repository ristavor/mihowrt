'use strict';
'require view';
'require mihowrt.api as api';

const text = api.text;

function modeLabel(mode) {
	return mode === 'proxy-first'
		? _('All traffic via proxy except exclusions')
		: _('Only selected traffic via proxy');
}

// Each check: passed? (null = unknown), label, hint shown when it fails.
function checks(st) {
	const list = [
		[ st.core_installed, _('Mihomo core installed') + (st.core ? ' (%s)'.format(st.core) : ''),
			_('Open Overview and install the core.') ],
		st.config_valid == null
			? [ null, _('Configuration not checked yet (it is checked at start)'), '' ]
			: [ st.config_valid, _('Configuration is valid'),
				_('Update the subscription or fix the YAML on the Subscription page.') +
				(st.config_error ? '\n' + _('Mihomo says: %s').format(st.config_error) : '') ],
		[ st.subscription_configured, _('Subscription configured'),
			_('Without a subscription only the YAML you entered is used.') ],
		[ st.running, _('Service is running'), _('Press Start on Overview. If it stops again, check the log below.') ]
	];
	if (st.running) {
		list.push([ st.dns_ok === true, _('Mihomo answers DNS queries'),
			_('Mihomo cannot resolve names: check that the proxy servers and DNS servers in the config are reachable.') ]);
		list.push([ st.policy_active, _('Traffic rules are active'), _('Restart the service; if it persists, see the log.') ]);
	}
	if ((st.custom_dns_servers || []).length)
		list.push([ false, _('dnsmasq has its own upstream servers: %s').format(st.custom_dns_servers.join(', ')),
			_('These servers answer next to Mihomo, so some sites may bypass the proxy. Move them to the Mihomo YAML (dns.nameserver) and remove them from Network → DHCP and DNS.') ]);
	return list;
}

function checklist(st) {
	return E('ul', { class: 'mw-check' }, checks(st).map(([ ok, label, hint ]) => E('li', [
		E('span', { class: 'mw-mark', 'aria-hidden': 'true' }, text(ok == null ? '–' : ok ? '✓' : '✗')),
		E('span', { class: 'mw-sr', style: 'position:absolute;left:-9999px' }, text(ok == null ? _('Unknown:') : ok ? _('OK:') : _('Problem:'))),
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

function details(st, profile) {
	const rows = [
		[ _('MihoWRT version'), st.version ],
		[ _('Mode'), modeLabel(st.mode) ],
		[ _('DNS mode'), st.dns_mode || '' ],
		[ _('Provider settings'), String(Object.keys(profile?.provider || {}).length) ],
		[ _('Provider lists'), providerLists(profile) ],
		[ _('Client interfaces'), (st.interfaces || []).join(', ') ],
		[ _('List entries'), _('proxy %d, devices %d, direct %d, direct devices %d').format(st.lists?.dst || 0, st.lists?.src || 0, st.lists?.direct || 0, st.lists?.direct_src || 0) ],
		[ _('Routing table'), st.route?.table ? '%s (priority %s)'.format(st.route.table, st.route.priority) : _('not active') ],
		[ _('Starts at boot'), st.enabled ? _('yes') : _('no') ]
	];
	return E('div', { class: 'mw-grid' }, rows.flatMap(([ k, v ]) => [ E('span', { class: 'mw-muted' }, text(k)), E('span', text(v)) ]));
}

return view.extend({
	load: () => Promise.all([
		api.read('status-json'),
		api.read('profile-json').catch(() => ({}))
	]),

	render: ([ st, profile ]) => {
		const logBox = E('pre', { class: 'mw-log' }, text(_('Open to load the log.')));
		const logDetails = E('details', { class: 'cbi-section' }, [ E('summary', text(_('Log'))), logBox ]);
		const loadLog = () => api.read('logs-json', '300')
			.then((res) => {
				logBox.textContent = res.available ? (res.lines.join('\n') || _('No MihoWRT log lines yet.')) : _('System log is not available.');
				logBox.scrollTop = logBox.scrollHeight;
			})
			.catch((e) => { logBox.textContent = _('Cannot read the log: %s').format(e.message); });
		const refresh = E('button', { class: 'cbi-button' }, text(_('Check again')));

		logDetails.addEventListener('toggle', () => logDetails.open && loadLog());
		refresh.addEventListener('click', () => location.reload());

		return E('div', { class: 'mw-page' }, [
			api.style(),
			E('h2', text(_('Diagnostics'))),
			E('div', { class: 'cbi-section' }, [ checklist(st), E('div', { class: 'mw-row' }, [ refresh ]) ]),
			(st.errors || []).length ? E('div', { class: 'alert-message warning' }, text(st.errors.join('; '))) : '',
			E('details', { class: 'cbi-section' }, [ E('summary', text(_('Details'))), details(st, profile) ]),
			logDetails
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
