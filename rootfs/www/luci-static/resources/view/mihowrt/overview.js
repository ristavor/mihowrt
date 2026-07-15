'use strict';
'require view';
'require fs';
'require mihowrt.backend as backendHelper';
'require mihowrt.config as configHelper';
'require mihowrt.ui as mihowrtUi';

const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';
const POLL_INTERVAL_MS = 1000;
const POLL_TIMEOUT_MS = 35000;

const OVERVIEW_CSS = `
	.mihowrt-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
		gap: 16px;
	}
	.mihowrt-card {
		min-width: 0;
	}
	.mihowrt-card h3 {
		margin-top: 0;
	}
	.mihowrt-actions, .mihowrt-badges {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 8px;
	}
	.mihowrt-actions {
		margin-top: 14px;
	}
	.mihowrt-facts {
		display: grid;
		grid-template-columns: minmax(120px, auto) minmax(0, 1fr);
		gap: 8px 16px;
		margin: 14px 0 0;
	}
	.mihowrt-facts dt {
		opacity: .7;
	}
	.mihowrt-facts dd {
		margin: 0;
		word-break: break-word;
	}
	.mihowrt-announce {
		margin-bottom: 16px;
		white-space: pre-wrap;
	}
	@media (max-width: 520px) {
		.mihowrt-facts { grid-template-columns: 1fr; gap: 3px; }
		.mihowrt-facts dd { margin-bottom: 8px; }
	}
`;

function badge(text, ok) {
	return E('span', { class: 'label ' + (ok ? 'success' : 'warning') }, text);
}

function setBadge(node, text, ok) {
	node.textContent = text;
	node.className = 'label ' + (ok ? 'success' : 'warning');
}

function fact(label, value) {
	return [ E('dt', label), E('dd', value) ];
}

function safeExternalUrl(value) {
	value = String(value || '').trim();
	if (!value)
		return '';

	try {
		const url = new URL(value);
		return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : '';
	}
	catch (e) {
		return '';
	}
}

function externalButton(url, text) {
	return E('a', {
		class: 'btn',
		href: url,
		target: '_blank',
		rel: 'noopener noreferrer'
	}, text);
}

function numericHeader(value) {
	const number = Number(String(value || ''));
	return Number.isFinite(number) && number >= 0 ? number : null;
}

function formatBytes(value) {
	if (!Number.isFinite(value) || value < 0)
		return _('Not provided');

	const units = [ _('B'), _('KiB'), _('MiB'), _('GiB'), _('TiB'), _('PiB') ];
	let unit = 0;
	while (value >= 1024 && unit < units.length - 1) {
		value /= 1024;
		unit++;
	}
	const digits = unit === 0 ? 0 : (value >= 100 ? 0 : value >= 10 ? 1 : 2);
	return '%s %s'.format(value.toFixed(digits), units[unit]);
}

function subscriptionTraffic(state) {
	const upload = numericHeader(state.upload);
	const download = numericHeader(state.download);
	const total = numericHeader(state.total);
	const used = upload == null || download == null ? null : upload + download;

	return {
		used: used == null ? _('Not provided') : formatBytes(used),
		total: total == null ? _('Not provided') : total === 0 ? _('Unlimited') : formatBytes(total),
		remaining: used == null || total == null
			? _('Not provided')
			: total === 0 ? _('Unlimited') : formatBytes(Math.max(0, total - used))
	};
}

function formatEpoch(value) {
	const seconds = numericHeader(value);
	if (seconds == null || seconds === 0)
		return _('Not provided');

	const date = new Date(seconds * 1000);
	return Number.isNaN(date.getTime()) ? _('Not provided') : date.toLocaleString();
}

function intervalText(state) {
	const interval = String(state.subscriptionEffectiveInterval || '').trim();
	if (!state.subscriptionUrl)
		return _('Disabled: no subscription URL');
	if (!interval || interval === '0')
		return _('Disabled');
	return state.subscriptionIntervalOverride
		? _('%s hours (manual)').format(interval)
		: _('%s hours (from subscription)').format(interval);
}

function serviceStateError(state) {
	return (state?.errors || []).filter(Boolean).join('; ') || _('unknown error');
}

return view.extend({
	load: function() {
		return Promise.all([
			backendHelper.readServiceState(),
			backendHelper.readSubscriptionUrl(),
			backendHelper.readCoreVersion()
		]);
	},

	render: function(data) {
		let serviceState = data[0] || {};
		const subscription = data[1] || {};
		let core = data[2] || {};
		let busy = false;

		const runningBadge = badge(serviceState.serviceRunning ? _('Running') : _('Stopped'), !!serviceState.serviceRunning);
		const enabledBadge = badge(serviceState.serviceEnabled ? _('Autostart on') : _('Autostart off'), !!serviceState.serviceEnabled);
		const readyBadge = badge(serviceState.serviceReady ? _('Ready') : _('Not ready'), !!serviceState.serviceReady);
		const versionNode = E('span', core.version || _('Not installed'));
		const toggleButton = E('button', { class: 'btn' }, configHelper.serviceToggleLabel(!!serviceState.serviceRunning));
		const autostartButton = E('button', { class: 'btn' }, configHelper.serviceEnabledToggleLabel(!!serviceState.serviceEnabled));
		const dashboardButton = E('button', { class: 'btn' }, _('Open Dashboard'));
		const updateButton = E('button', { class: 'btn cbi-button-action' }, _('Update Core'));
		const actionControls = [ toggleButton, autostartButton, dashboardButton, updateButton ];

		const setBusy = function(value) {
			busy = value;
			actionControls.forEach(node => { node.disabled = value; });
		};

		const applyServiceState = function(next) {
			serviceState = next;
			toggleButton.textContent = configHelper.serviceToggleLabel(!!next.serviceRunning);
			autostartButton.textContent = configHelper.serviceEnabledToggleLabel(!!next.serviceEnabled);
			setBadge(runningBadge, next.serviceRunning ? _('Running') : _('Stopped'), !!next.serviceRunning);
			setBadge(enabledBadge, next.serviceEnabled ? _('Autostart on') : _('Autostart off'), !!next.serviceEnabled);
			setBadge(readyBadge, next.serviceReady ? _('Ready') : _('Not ready'), !!next.serviceReady);
		};

		const readService = async function() {
			const next = await backendHelper.readServiceState();
			if (!next.available)
				throw new Error(serviceStateError(next));
			applyServiceState(next);
			return next;
		};

		const runInitAction = async function(action) {
			const result = await fs.exec(SERVICE_SCRIPT, [ action ]);
			if (result.code !== 0)
				throw new Error(mihowrtUi.execErrorDetail(result));
		};

		const pollService = async function(predicate) {
			const started = Date.now();
			while (Date.now() - started < POLL_TIMEOUT_MS) {
				const next = await readService();
				if (predicate(next))
					return next;
				await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL_MS));
			}
			return null;
		};

		toggleButton.addEventListener('click', async function() {
			if (busy)
				return;
			setBusy(true);
			try {
				const current = await readService();
				const start = !current.serviceRunning;
				await runInitAction(start ? 'start' : 'stop');
				const settled = await pollService(next => start ? next.serviceReady : !next.serviceRunning);
				if (!settled)
					throw new Error(_('Service state change timed out. Check diagnostics.'));
			}
			catch (e) {
				mihowrtUi.notify(_('Unable to change service state: %s').format(e.message), 'error');
			}
			finally {
				setBusy(false);
			}
		});

		autostartButton.addEventListener('click', async function() {
			if (busy)
				return;
			setBusy(true);
			try {
				const current = await readService();
				await runInitAction(current.serviceEnabled ? 'disable' : 'enable');
				await readService();
			}
			catch (e) {
				mihowrtUi.notify(_('Unable to change autostart: %s').format(e.message), 'error');
			}
			finally {
				setBusy(false);
			}
		});

		dashboardButton.addEventListener('click', function() {
			if (!busy)
				configHelper.openDashboard({
					serviceName: SERVICE_NAME,
					serviceScript: SERVICE_SCRIPT,
					backendHelper,
					uiHelper: mihowrtUi,
					windowObject: window
				});
		});

		updateButton.addEventListener('click', async function() {
			if (busy)
				return;
			setBusy(true);
			try {
				const result = await backendHelper.updateKernel();
				if (result.updated && result.restartRequired && serviceState.serviceRunning) {
					await backendHelper.restartValidatedService();
					const settled = await pollService(next => next.serviceReady);
					if (!settled)
						throw new Error(_('Core updated, but service restart timed out.'));
				}
				core = await backendHelper.readCoreVersion();
				versionNode.textContent = core.version || result.latestVersion || _('Not installed');
				mihowrtUi.notify(result.updated
					? _('Mihomo core updated to %s.').format(versionNode.textContent)
					: _('Mihomo core is up to date (%s).').format(versionNode.textContent), 'info');
			}
			catch (e) {
				mihowrtUi.notify(_('Unable to update Mihomo core: %s').format(e.message), 'error');
			}
			finally {
				setBusy(false);
			}
		});

		const traffic = subscriptionTraffic(subscription);
		const supportUrl = safeExternalUrl(subscription.supportUrl);
		const webPageUrl = safeExternalUrl(subscription.profileWebPageUrl);
		const subscriptionFacts = [
			...fact(_('Used traffic'), traffic.used),
			...fact(_('Total traffic'), traffic.total),
			...fact(_('Remaining traffic'), traffic.remaining),
			...fact(_('Expires'), formatEpoch(subscription.expire)),
			...fact(_('Auto-update'), intervalText(subscription))
		];
		if (subscription.subscriptionNextUpdate)
			subscriptionFacts.push(...fact(_('Next update'), formatEpoch(subscription.subscriptionNextUpdate)));

		const subscriptionActions = [];
		if (supportUrl)
			subscriptionActions.push(externalButton(supportUrl, _('Support')));
		if (webPageUrl)
			subscriptionActions.push(externalButton(webPageUrl, _('Website')));

		return E([
			E('style', OVERVIEW_CSS),
			E('h2', _('MihoWRT Overview')),
			subscription.announce
				? E('div', { class: 'cbi-section mihowrt-announce' }, [ E('strong', _('Announcement')), E('p', String(subscription.announce)) ])
				: E([]),
			E('div', { class: 'mihowrt-grid' }, [
				E('div', { class: 'cbi-section mihowrt-card' }, [
					E('h3', _('Service')),
					E('div', { class: 'mihowrt-badges' }, [ runningBadge, enabledBadge, readyBadge ]),
					E('dl', { class: 'mihowrt-facts' }, fact(_('Core version'), versionNode)),
					E('div', { class: 'mihowrt-actions' }, actionControls)
				]),
				E('div', { class: 'cbi-section mihowrt-card' }, [
					E('h3', subscription.profileTitle || _('Subscription')),
					subscription.subscriptionUrl
						? E('dl', { class: 'mihowrt-facts' }, subscriptionFacts)
						: E('p', { class: 'cbi-section-descr' }, _('No subscription configured. Manual YAML remains available on the Subscriptions page.')),
					subscriptionActions.length ? E('div', { class: 'mihowrt-actions' }, subscriptionActions) : E([])
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
