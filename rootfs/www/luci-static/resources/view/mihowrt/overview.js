'use strict';
'require view';
'require mihowrt.api as api';

function modeLabel(mode) {
	return mode === 'proxy-first'
		? _('All traffic via proxy except exclusions')
		: _('Only selected traffic via proxy');
}

function firstRunCard() {
	const url = E('input', {
		id: 'mw-sub-url', type: 'url', class: 'cbi-input-text', style: 'flex: 1 1 16em; min-width: 0; width: auto',
		placeholder: 'https://provider.example/sub/…', 'aria-label': _('Subscription URL')
	});
	const connect = E('button', { class: 'cbi-button cbi-button-action important' }, text(_('Connect')));

	connect.addEventListener('click', () => api.busy(connect, async () => {
		const value = url.value.trim();
		if (!/^https?:\/\//i.test(value))
			throw new Error(_('Enter the subscription link that starts with https://'));
		await api.write('set-subscription', value, '');
		await api.write('update-subscription');
		await api.service('enable');
		await api.service('restart');
		api.notify(_('Subscription connected. MihoWRT is starting.'));
		window.setTimeout(() => location.reload(), 1500);
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Connect a subscription'))),
		E('p', text(_('Paste the link from your VPN provider. MihoWRT downloads the configuration, checks it and starts routing.'))),
		E('label', { for: 'mw-sub-url' }, text(_('Subscription URL'))),
		E('div', { class: 'mw-row' }, [ url, connect ])
	]);
}

function coreMissingCard() {
	const install = E('button', { class: 'cbi-button cbi-button-action important' }, text(_('Install Mihomo core')));

	install.addEventListener('click', () => api.busy(install, async () => {
		const res = await api.write('core-update');
		api.notify(_('Mihomo core %s installed.').format(res.version || ''));
		location.reload();
	}));
	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Mihomo core is not installed'))),
		E('p', text(_('MihoWRT needs the Mihomo core (about 20 MB download, about 60 MB on flash).'))),
		install
	]);
}

function statusSection(status) {
	const toggle = E('button', { class: 'cbi-button ' + (status.running ? 'cbi-button-reset' : 'cbi-button-action') },
		text(status.running ? _('Stop') : _('Start')));
	const restart = E('button', { class: 'cbi-button' }, text(_('Restart')));

	toggle.addEventListener('click', () => api.busy(toggle, async () => {
		if (!status.running && !status.enabled)
			await api.service('enable');
		await api.service(status.running ? 'stop' : 'start');
		location.reload();
	}));
	restart.addEventListener('click', () => api.busy(restart, async () => {
		await api.service('restart');
		location.reload();
	}));

	let headline = status.running ? _('Running') : _('Stopped');
	if (status.running && status.dns_ok === false)
		headline = _('Running, but DNS does not answer — see Diagnostics');

	return E('div', { class: 'cbi-section' }, [
		E('div', { class: 'mw-status', role: 'status' }, [
			E('strong', text(headline)),
			E('span', { class: 'mw-muted' }, text(modeLabel(status.mode))),
			E('span', { class: 'mw-muted' }, text(status.enabled ? _('Starts at boot') : _('Does not start at boot')))
		]),
		E('div', { class: 'mw-row' }, [ toggle, restart ])
	]);
}

function subscriptionSection(sub) {
	const update = E('button', { class: 'cbi-button cbi-button-action' }, text(_('Update subscription')));
	const rows = [
		[ _('Traffic'), api.trafficSummary(sub) ],
		[ _('Expires'), sub.expire ? api.formatDate(sub.expire) : _('Never') ],
		[ _('Last update'), sub.last_update ? api.formatDate(sub.last_update) : _('Not yet') ],
		[ _('Auto-update'), sub.effective_interval > 0 ? _('every %d h').format(sub.effective_interval) : _('Off') ]
	];
	const links = [ api.safeLink(sub.support_url, _('Support')), api.safeLink(sub.web_page_url, _('Website')) ].filter(Boolean);

	update.addEventListener('click', () => api.busy(update, async () => {
		const res = await api.write('update-subscription');
		api.notify(res.action === 'hot_reloaded' ? _('Subscription updated and applied.') : _('Subscription updated.'));
		location.reload();
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(sub.profile_title || _('Subscription'))),
		sub.announce ? E('p', { class: 'mw-announce' }, text(sub.announce)) : '',
		E('div', { class: 'mw-grid' }, rows.flatMap(([ k, v ]) => [ E('span', { class: 'mw-muted' }, text(k)), E('span', text(v)) ])),
		E('div', { class: 'mw-row' }, [ update ].concat(links))
	]);
}

function groupsSection(groups) {
	if (!groups.length)
		return '';

	return E('div', { class: 'cbi-section mw-groups' }, [
		E('h3', text(_('Proxy servers'))),
		E('div', { class: 'mw-grid' }, groups.flatMap((group) => {
			const id = 'mw-group-' + group.name.replace(/[^A-Za-z0-9_-]/g, '_');
			// Fallback/URLTest/LoadBalance pick the server themselves: show
			// the current one and allow a latency test, not a choice.
			const select = E('select', { id, class: 'cbi-input-select', disabled: group.auto ? '' : null },
				group.all.map((name) => E('option', { value: name, selected: name === group.now ? '' : null }, text(name))));
			const test = E('button', { class: 'cbi-button', title: _('Measure latency of every server in this group') }, text(_('Test')));

			select.addEventListener('change', () => api.busy(select, async () => {
				await api.write('select-proxy', group.name, select.value);
				api.notify(_('%s now uses %s.').format(group.name, select.value));
			}));
			test.addEventListener('click', () => api.busy(test, async () => {
				const delays = await api.write('group-delay', group.name);
				for (const option of select.options) {
					const ms = delays[option.value];
					option.textContent = ms ? '%s — %d ms'.format(option.value, ms) : '%s — %s'.format(option.value, _('timeout'));
				}
			}));
			const row = [ select, test ];
			if (group.auto)
				row.push(E('span', { class: 'mw-muted' }, text(_('Chosen automatically by Mihomo'))));
			return [ E('label', { for: id }, text(group.name)), E('div', { class: 'mw-row' }, row) ];
		}))
	]);
}

function toolsSection(status) {
	const dashboard = E('button', { class: 'cbi-button' }, text(_('Open dashboard')));
	const core = E('button', { class: 'cbi-button' }, text(_('Update Mihomo core')));

	dashboard.addEventListener('click', () => api.busy(dashboard, async () => {
		const d = await api.write('dashboard-json');
		if (!d.running)
			throw new Error(_('Start MihoWRT to use the dashboard.'));
		// The setup route applies these values even when the browser keeps an
		// older backend (e.g. without a secret) for the same host and port.
		const qs = 'hostname=%s&port=%s&secret=%s'.format(encodeURIComponent(d.host), d.port, encodeURIComponent(d.secret));
		window.open('http://%s:%s/ui/#/setup?%s'.format(d.host, d.port, qs), '_blank', 'noopener');
	}));
	core.addEventListener('click', () => api.busy(core, async () => {
		const res = await api.write('core-update');
		api.notify(res.updated ? _('Mihomo core updated to %s.').format(res.version) : _('Mihomo core %s is up to date.').format(res.version));
	}));

	return E('div', { class: 'cbi-section' }, [
		E('div', { class: 'mw-row' }, [ dashboard, core,
			E('span', { class: 'mw-muted' }, text(_('MihoWRT %s, Mihomo %s').format(status.version, status.core || '—'))) ])
	]);
}

const text = api.text;

return view.extend({
	load: () => Promise.all([
		api.read('status-json'),
		api.read('subscription-json').catch(() => ({})),
		api.read('proxies-json').catch(() => [])
	]),

	render: ([ status, sub, groups ]) => {
		const body = [ api.style(), E('h2', text(_('MihoWRT'))) ];

		if (!status.core_installed)
			body.push(coreMissingCard());
		else if (!status.subscription_configured)
			body.push(firstRunCard());
		body.push(statusSection(status));
		if (status.subscription_configured)
			body.push(subscriptionSection(sub));
		if (status.running)
			body.push(groupsSection(Array.isArray(groups) ? groups : []));
		body.push(toolsSection(status));
		return E('div', { class: 'mw-page' }, body);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
