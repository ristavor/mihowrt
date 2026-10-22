'use strict';
'require view';
'require poll';
'require mihowrt.api as api';

function firstRunCard() {
	const url = E('input', {
		// type=text: some themes (openwrt-2020) style only text inputs.
		id: 'mw-sub-url', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false',
		class: 'cbi-input-text', style: 'flex: 1 1 16em; min-width: 0; width: auto',
		placeholder: 'https://provider.example/sub/…', 'aria-label': _('Subscription URL')
	});
	const connect = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Connect')));

	connect.addEventListener('click', () => api.busy(connect, async () => {
		const value = url.value.trim();
		if (!/^https?:\/\//i.test(value))
			throw new Error(_('Enter the subscription link that starts with https://'));
		// The link is saved only after a successful download.
		try {
			await api.job('connect', value);
		}
		catch (e) {
			throw new Error(api.subscriptionError(e.message));
		}
		api.notify(_('Subscription connected. MihoWRT is starting.'));
		window.setTimeout(() => location.reload(), 1500);
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Connect a subscription'))),
		E('p', text(_('Paste the Clash/Mihomo (YAML) subscription link from your VPN provider. MihoWRT downloads the configuration, checks it and starts routing.'))),
		E('label', { for: 'mw-sub-url' }, text(_('Subscription URL'))),
		E('div', { class: 'mw-row' }, [ url, connect ])
	]);
}

// Running on a YAML entered by hand: no big card, just a pointer.
function subscriptionHint() {
	return E('div', { class: 'cbi-section' }, [
		E('p', { class: 'mw-muted' }, [
			text(_('No subscription: MihoWRT uses the YAML entered on the Subscription page.'))[0], ' ',
			E('a', { href: L.url('admin/services/mihowrt/subscription') }, text(_('Connect a subscription')))
		])
	]);
}

function coreMissingCard() {
	const install = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Install Mihomo core')));

	install.addEventListener('click', () => api.busy(install, async () => {
		const res = await api.job('core-update');
		api.notify(_('Mihomo core %s installed.').format(res.version || ''));
		location.reload();
	}));
	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Mihomo core is not installed'))),
		E('p', text(_('MihoWRT needs the Mihomo core (about 20 MB download, about 60 MB on flash).'))),
		E('div', { class: 'mw-row' }, [ install ])
	]);
}

function statusSection(status) {
	const toggle = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button ' + (status.running ? 'cbi-button-reset' : 'cbi-button-action') },
		text(status.running ? _('Stop') : _('Start')));
	const restart = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button' }, text(_('Restart')));

	toggle.addEventListener('click', () => api.busy(toggle, async () => {
		if (!status.running && !status.enabled)
			await api.service('enable');
		await api.job('service', status.running ? 'stop' : 'start');
		location.reload();
	}));
	restart.addEventListener('click', () => api.busy(restart, async () => {
		await api.job('service', 'restart');
		location.reload();
	}));

	const headline = E('strong', { 'aria-live': 'polite' });
	const boot = E('span', { class: 'mw-muted' });
	const block = E('div', { class: 'cbi-section' }, [
		E('div', { class: 'mw-status' }, [
			headline,
			E('span', { class: 'mw-muted' }, text(api.modeLabel(status.mode))),
			boot
		]),
		E('div', { class: 'mw-row' }, [ toggle, restart ])
	]);
	const update = fresh => {
		status = Object.assign({}, status, fresh);
		const state = status.state || (status.running ? 'running' : 'stopped');
		let label = _('Stopped');
		if (state === 'starting')
			label = _('Starting…');
		else if (state === 'degraded')
			label = _('Mihomo DNS does not answer: traffic goes direct until it recovers');
		else if (state === 'failed')
			label = status.last_error ? _('Stopped after an error: %s').format(status.last_error) : _('Stopped');
		else if (state === 'running')
			label = status.dns_ok === false ? _('Running, but DNS does not answer — see Diagnostics') : _('Running');
		else if (status.config_valid === false)
			label = _('Stopped: the configuration has errors — see Diagnostics');
		if (headline.textContent !== label)
			headline.textContent = label;
		boot.textContent = status.enabled ? _('Starts at boot') : _('Does not start at boot');
		toggle.textContent = status.running ? _('Stop') : _('Start');
		toggle.setAttribute('class', 'cbi-button ' + (status.running ? 'cbi-button-reset' : 'cbi-button-action'));
	};
	update(status);
	return { block, update };
}

function liveStatus(status) {
	const section = statusSection(status);
	let pollFailed = false;
	poll.add(async () => {
		if (api.jobRunning)
			return;
		try {
			const fresh = await api.read('service-state-json');
			pollFailed = false;
			if (api.jobRunning)
				return;
			section.update(fresh);
		}
		catch (e) {
			if (!pollFailed)
				api.notify(api.errorText(e), 'error');
			pollFailed = true;
		}
	}, 5);
	return section.block;
}

// Provider text stays text; only http(s) runs become safe links.
function announce(value) {
	return String(value).split(/(https?:\/\/\S+)/i).map((part, i) =>
		(i % 2) ? (api.safeLink(part, part) || part) : part).filter((part) => part !== '');
}

// Expiry within 3 days or 90 % of the traffic used: the provider's limits
// are the usual reason a working router suddenly stops proxying.
function subscriptionWarning(sub) {
	const now = Date.now() / 1000;
	const expire = Number(sub.expire);
	const total = Number(sub.total);
	const used = (Number(sub.upload) || 0) + (Number(sub.download) || 0);
	if (expire > 0 && expire < now)
		return _('The subscription has expired. Renew it with your provider.');
	if (expire > 0 && expire - now < 3 * 86400)
		return _('The subscription expires on %s. Renew it with your provider.').format(api.formatDate(expire));
	if (total > 0 && used >= total)
		return _('The subscription traffic is used up.');
	if (total > 0 && used >= total * 0.9)
		return _('Over 90% of the subscription traffic is used.');
	return '';
}

function subscriptionSection(sub) {
	const update = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action' }, text(_('Update subscription')));
	const rows = [
		[ _('Traffic'), api.trafficSummary(sub) ],
		[ _('Expires'), sub.expire ? api.formatDate(sub.expire) : _('Never') ],
		[ _('Last update'), sub.last_update ? api.formatDate(sub.last_update) : _('Not yet') ],
		[ _('Auto-update'), sub.effective_interval > 0 ? _('every %d h').format(sub.effective_interval)
			: sub.auto_update !== false ? _('On, but the subscription does not send an update period') : _('Off') ]
	];
	const links = [ api.linkButton(sub.support_url, _('Support')), api.linkButton(sub.web_page_url, _('Website')) ].filter(Boolean);
	const warning = subscriptionWarning(sub);

	update.addEventListener('click', () => api.busy(update, async () => {
		let res;
		try {
			res = await api.job('update-subscription');
		}
		catch (e) {
			throw new Error(api.subscriptionError(e.message));
		}
		api.notify(api.actionNotice(res.action));
		location.reload();
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(sub.profile_title || _('Subscription'))),
		warning ? E('div', { class: 'alert-message warning' }, text(warning)) : '',
		sub.announce ? E('p', { class: 'mw-announce' }, announce(sub.announce)) : '',
		api.infoGrid(rows),
		E('div', { class: 'mw-row mw-actions' }, [ update ].concat(links))
	]);
}

// Latency text of one server, '' when it was never checked (0 = no response).
function delayText(delays, name) {
	const ms = (delays || {})[name];
	return ms == null ? '' : ms > 0 ? _('%d ms').format(ms) : _('no response');
}

// What the ping next to the Test button shows: the current server's latency,
// or for LoadBalance how many servers answer.
function pingText(group) {
	const delays = group.delays || {};
	if (group.type === 'LoadBalance') {
		const checked = (group.all || []).filter((name) => delays[name] != null);
		return checked.length ? _('Responding: %d of %d').format(checked.filter((name) => delays[name] > 0).length, group.all.length) : '';
	}
	return delayText(delays, group.now);
}

// Options of one group select. URLTest/Fallback start with "Auto — <now>"
// (value "", unpins); a pinned server shows as selected.
function groupOptions(select, group) {
	const auto = group.type === 'URLTest' || group.type === 'Fallback';
	const current = auto ? (group.fixed || '') : group.now;
	// The disabled LoadBalance select cannot be opened: no per-server latency.
	const label = (name) => {
		const ms = group.type === 'LoadBalance' ? '' : delayText(group.delays, name);
		return ms ? '%s — %s'.format(name, ms) : name;
	};
	// LoadBalance has no current server: it uses all of them in turn.
	const first = group.type === 'LoadBalance' ? _('All servers in turn')
		: auto ? _('Auto — %s').format(group.now || '…') : null;
	const options = (first != null ? [ E('option', { value: '' }, text(first)) ] : [])
		.concat(group.all.map((name) => E('option', { value: name }, text(label(name)))));

	while (select.firstChild)
		select.removeChild(select.firstChild);
	options.forEach((o) => select.appendChild(o));
	select.value = group.type === 'LoadBalance' ? '' : current;
	return select.value;
}

function groupsSection(groups) {
	if (!groups.length)
		return '';

	// One live region for the section: a freshly filled ping is not announced reliably.
	const live = E('p', { class: 'mw-sr', 'aria-live': 'polite' });
	return E('div', { class: 'cbi-section mw-groups' }, [
		E('h3', text(_('Proxy servers'))),
		live,
		E('div', { class: 'mw-grid' }, groups.flatMap((group, index) => {
			// Position, not name: Cyrillic/emoji names would collide.
			const id = 'mw-group-' + index;
			// Mihomo cannot pin a LoadBalance group: show it, allow a test.
			const fixedOnly = group.type === 'LoadBalance';
			// LoadBalance: the wider "Responding: N of M" goes on the note line, so its
			// empty ping only keeps the Test buttons in one column.
			const status = E('span', { id: id + '-ping', class: fixedOnly ? null : 'mw-muted mw-ping' }, text(pingText(group)));
			const ping = fixedOnly ? E('span', { class: 'mw-muted mw-ping' }) : status;
			const select = E('select', { id, class: 'cbi-input-select', disabled: fixedOnly ? '' : null, 'aria-describedby': id + '-ping' });
			const test = E('button', { class: 'cbi-button', title: _('Measure latency of every server in this group'),
				'aria-label': _('Test servers of %s').format(group.name) }, text(_('Test')));
			let previous = groupOptions(select, group);
			const refresh = async () => {
				const fresh = await api.readLarge('proxies-json').catch(() => []);
				Object.assign(group, (Array.isArray(fresh) ? fresh : []).find((g) => g.name === group.name) || {});
			};
			const show = () => {
				previous = groupOptions(select, group);
				status.textContent = pingText(group);
			};

			select.addEventListener('change', async () => {
				const value = select.value;
				// Themes with custom dropdowns (footstrap) may repeat "change".
				if (value === previous)
					return;
				const ok = await api.busy(select, async () => {
					await api.write('select-proxy', group.name, value);
					return true;
				});
				if (!ok) {
					select.value = previous;
					return;
				}
				if (value === '') {
					// Unpinned: Mihomo picks the server now; "Auto — X" must show it.
					group.fixed = '';
					await refresh();
				}
				else {
					group.now = value;
					group.fixed = value;
				}
				show();
			});
			test.addEventListener('click', async () => {
				const before = status.textContent;
				status.textContent = '…';
				// The test re-reads the group: a switch meanwhile would be overwritten.
				select.disabled = true;
				const done = await api.busy(test, async () => {
					const result = await api.write('group-delay', group.name) || {};
					// A delay test can unpin URLTest/Fallback groups: read them again.
					await refresh();
					// Servers missing from the result timed out.
					group.delays = Object.fromEntries(group.all.map((name) => [ name, result[name] || 0 ]));
					show();
					live.textContent = '';
					live.textContent = '%s: %s — %s'.format(group.name, fixedOnly ? _('All servers in turn') : group.now, status.textContent);
					return true;
				});
				select.disabled = fixedOnly;
				if (!done)
					status.textContent = before;
			});
			const cells = [ E('label', { for: id }, text(group.name)), E('div', { class: 'mw-row' }, [ select, test, ping ]) ];
			// The note gets its own grid row: a wrapped row would push the label off its select.
			if (fixedOnly)
				cells.push(E('span'), E('span', { class: 'mw-muted' }, [ _('Mihomo spreads connections across these servers'), ' · ', status ]));
			return cells;
		}))
	]);
}

function toolsSection(status) {
	const dashboard = E('button', { class: 'cbi-button' }, text(_('Open dashboard')));
	const core = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button' }, text(_('Update Mihomo core')));

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
		const res = await api.job('core-update');
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
		api.readLarge('proxies-json').catch(e => ({ error: api.errorText(e) }))
	]),

	render: ([ status, sub, groups ]) => {
		const body = [ api.style(), E('h2', text(_('MihoWRT'))), api.jobNotice() ];

		// Without the core nothing else can work yet: only the install card.
		if (!status.core_installed) {
			body.push(coreMissingCard());
			return E('div', { class: 'mw-page' }, body);
		}
		if (!status.subscription_configured)
			body.push(status.running ? subscriptionHint() : firstRunCard());
		body.push(liveStatus(status));
		if (status.subscription_configured)
			body.push(subscriptionSection(sub));
		if (status.running)
			body.push(groups.error && status.state === 'starting'
				? E('div', { class: 'cbi-section cbi-section-descr' }, text(_('Mihomo is starting. Reload the page in a moment to see the proxy groups.')))
				: groups.error ? E('div', { class: 'cbi-section alert-message error' },
				text(_('Cannot load the proxy groups: %s').format(groups.error)))
				: groupsSection(Array.isArray(groups) ? groups : []));
		body.push(toolsSection(status));
		return E('div', { class: 'mw-page' }, body);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
