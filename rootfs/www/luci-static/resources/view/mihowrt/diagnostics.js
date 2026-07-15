'use strict';
'require view';
'require ui';
'require mihowrt.backend as backendHelper';

const LOG_LINE_LIMIT = 200;
const DIAGNOSTICS_CSS = `
	.mihowrt-status-head {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
		margin-bottom: 16px;
	}

	.mihowrt-status-badges {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-bottom: 14px;
	}

	.mihowrt-status-badge {
		display: inline-block;
		padding: 4px 9px;
		font-size: 12px;
	}

	.mihowrt-status-table {
		width: 100%;
		border-collapse: collapse;
		margin-bottom: 12px;
	}

	.mihowrt-status-table td {
		padding: 7px 8px;
		border-bottom: 1px solid rgba(127, 127, 127, 0.18);
		vertical-align: top;
	}

	.mihowrt-status-table td:first-child {
		width: 210px;
		opacity: 0.72;
	}

	.mihowrt-status-mono {
		font-family: monospace;
		word-break: break-word;
	}

	.mihowrt-status-error {
		font-weight: 600;
	}

	.mihowrt-status-muted {
		opacity: 0.72;
	}

	.mihowrt-status-details {
		margin-top: 10px;
	}

	.mihowrt-status-details summary {
		cursor: pointer;
		font-weight: 600;
		margin-bottom: 8px;
	}

	.mihowrt-status-log {
		margin: 0;
		max-height: 420px;
		overflow: auto;
		padding: 10px;
		border: 1px solid rgba(127, 127, 127, 0.2);
		background: rgba(127, 127, 127, 0.06);
		color: inherit;
		white-space: pre-wrap;
		word-break: break-word;
	}
`;

function badge(text, ok) {
	return E('span', {
		class: 'mihowrt-status-badge label ' + (ok ? 'success' : 'warning')
	}, text);
}

function setChildren(node, children) {
	while (node.firstChild)
		node.removeChild(node.firstChild);

	children.forEach(child => node.appendChild(child));
}

function textOrNone(value) {
	if (value == null || value === '')
		return _('none');
	if (Array.isArray(value))
		return value.length ? value.join(', ') : _('none');
	return String(value);
}

function row(label, value, error = false) {
	return E('tr', [
		E('td', label),
		E('td', {
			class: 'mihowrt-status-mono' + (error ? ' mihowrt-status-error' : '')
		}, textOrNone(value))
	]);
}

function renderErrors(errors) {
	if (!errors || !errors.length)
		return E('div', { class: 'mihowrt-status-muted' }, _('No errors reported.'));

	return E('ul', { style: 'margin:0;padding-left:20px;' }, errors.map(error =>
		E('li', { class: 'mihowrt-status-error' }, String(error))
	));
}

function renderLogs(logs) {
	if (logs.errors && logs.errors.length)
		return E('div', { class: 'mihowrt-status-error' }, logs.errors.join('; '));
	if (!logs.available)
		return E('div', { class: 'mihowrt-status-muted' }, _('System log reader is unavailable.'));
	if (!logs.lines.length)
		return E('div', { class: 'mihowrt-status-muted' }, _('No MihoWRT log lines found.'));

	return E('pre', { class: 'mihowrt-status-log' }, logs.lines.join('\n'));
}

function activeState(status) {
	if (status.active && status.active.present)
		return status.active;

	return {
		present: false,
		enabled: false,
		routeTableId: '',
		routeRulePriority: '',
		policyMode: '',
		sourceNetworkInterfaces: [],
		alwaysProxyDstCount: null,
		alwaysProxySrcCount: null,
		directDstCount: null
	};
}

function statusFromServiceState(state) {
	return {
		summaryOnly: true,
		serviceEnabled: !!state?.serviceEnabled,
		serviceRunning: !!state?.serviceRunning,
		serviceReady: !!state?.serviceReady,
		runtimeSafeReloadReady: false,
		runtimeMatchesDesired: false,
		errors: Array.isArray(state?.errors) ? state.errors.map(String) : []
	};
}

function policyLabel(status, active) {
	if (status.summaryOnly)
		return { text: _('Details not loaded'), ok: status.serviceReady };
	if (status.runtimeSnapshotPresent && !status.runtimeSnapshotValid)
		return { text: _('Snapshot invalid'), ok: false };
	if (status.runtimeLiveStatePresent && !status.runtimeSnapshotPresent)
		return { text: _('Runtime untracked'), ok: false };
	if (!active.present)
		return { text: _('Policy inactive'), ok: false };
	if (!status.runtimeMatchesDesired)
		return { text: _('Config drift'), ok: false };
	return { text: _('Policy active'), ok: true };
}

function renderSummary(status, active) {
	const policy = policyLabel(status, active);
	const badges = [
		badge(status.serviceRunning ? _('Running') : _('Stopped'), status.serviceRunning),
		badge(status.serviceEnabled ? _('Autostart on') : _('Autostart off'), status.serviceEnabled),
		badge(status.serviceReady ? _('Ready') : _('Not ready'), status.serviceReady)
	];

	if (status.summaryOnly)
		badges.push(badge(policy.text, policy.ok));
	else {
		badges.push(badge(policy.text, policy.ok));
		badges.push(badge(status.runtimeSafeReloadReady ? _('Reload safe') : _('Reload blocked'), status.runtimeSafeReloadReady));
	}

	return [
		E('div', { class: 'mihowrt-status-badges' }, badges),
		(status.errors && status.errors.length)
			? E('div', { class: 'mihowrt-status-error' }, status.errors.join('; '))
			: E('div', { class: 'mihowrt-status-muted' }, status.summaryOnly
				? _('Open runtime details to load policy state.')
				: status.runtimeMatchesDesired
					? _('Runtime matches current config.')
					: _('Runtime differs from current config. Apply or restart service.'))
	];
}

function renderRuntimeTable(status, active) {
	return E('table', { class: 'mihowrt-status-table' }, [
		row(_('Applied mode'), active.policyMode || _('not active')),
		row(_('Configured mode'), status.policyMode || 'direct-first'),
		row(_('Route table'), active.routeTableId || status.routeTableIdEffective || _('not active')),
		row(_('Rule priority'), active.routeRulePriority || status.routeRulePriorityEffective || _('not active')),
		row(_('Source interfaces'), active.sourceNetworkInterfaces),
		row(_('Proxy lists'), [
			_('dst %d').format(active.alwaysProxyDstCount || 0),
			_('src %d').format(active.alwaysProxySrcCount || 0),
			_('direct %d').format(active.directDstCount || 0)
		].join(', ')),
		row(_('Remote URLs'), [
			_('dst %d').format(status.alwaysProxyDstRemoteUrlCount || 0),
			_('src %d').format(status.alwaysProxySrcRemoteUrlCount || 0),
			_('direct %d').format(status.directDstRemoteUrlCount || 0)
		].join(', ')),
		row(_('DNS backup'), status.dnsBackupValid ? _('valid') : _('missing/invalid'), !status.dnsBackupValid),
		row(_('Snapshot'), status.runtimeSnapshotValid ? _('valid') : (status.runtimeSnapshotPresent ? _('invalid') : _('missing')), !status.runtimeSnapshotValid)
	]);
}

function renderConfigTable(status) {
	const config = status.config || {};

	return E('table', { class: 'mihowrt-status-table' }, [
		row(_('DNS listen'), config.mihomoDnsListen || _('missing'), !config.mihomoDnsListen),
		row(_('DNS port'), config.dnsPort || _('missing'), !config.dnsPort),
		row(_('TPROXY port'), config.tproxyPort || _('missing'), !config.tproxyPort),
		row(_('Routing mark'), config.routingMark || _('missing'), !config.routingMark),
		row(_('Fake-IP range'), config.fakeIpRange || _('missing'), !config.fakeIpRange),
		row(_('Controller'), config.externalController || config.externalControllerUnix || _('none')),
		row(_('Dashboard'), config.externalUiName || config.externalUi || _('none'))
	]);
}

return view.extend({
	load: function() {
		return backendHelper.readServiceState().then(statusFromServiceState);
	},

	render: function(status) {
		const summaryNode = E('div');
		const runtimeNode = E('div');
		const configNode = E('div');
		const errorNode = E('div');
		const logsNode = E('div', { class: 'mihowrt-status-muted' }, _('Open logs to load them.'));
		const refreshButton = E('button', {
			class: 'btn cbi-button-action'
		}, _('Refresh'));
		const logsRefreshButton = E('button', {
			class: 'btn'
		}, _('Reload logs'));
		const runtimeDetailsNode = E('details', {
			class: 'mihowrt-status-details'
		});
		let logsLoaded = false;
		let detailsLoaded = !status.summaryOnly;

		const renderStatus = function(nextStatus) {
			status = nextStatus || status;
			const active = activeState(status);

			setChildren(summaryNode, renderSummary(status, active));
			if (status.summaryOnly) {
				setChildren(runtimeNode, [ E('div', { class: 'mihowrt-status-muted' }, _('Open details to load runtime state.')) ]);
				setChildren(configNode, []);
				setChildren(errorNode, []);
				return;
			}

			setChildren(runtimeNode, [ renderRuntimeTable(status, active) ]);
			setChildren(configNode, [ renderConfigTable(status) ]);
			setChildren(errorNode, [ renderErrors((status.config && status.config.errors) || []) ]);
		};

		const refreshSummary = async function() {
			renderStatus(statusFromServiceState(await backendHelper.readServiceState()));
			detailsLoaded = false;
		};

		const loadDetails = async function(force = false) {
			if (detailsLoaded && !force)
				return;

			setChildren(runtimeNode, [ E('div', { class: 'mihowrt-status-muted' }, _('Loading details...')) ]);
			try {
				renderStatus(await backendHelper.readStatus());
				detailsLoaded = true;
			}
			catch (e) {
				detailsLoaded = false;
				setChildren(runtimeNode, [ E('div', { class: 'mihowrt-status-error' }, _('Failed to load details: %s').format(e.message)) ]);
			}
		};

		const refreshStatus = async function() {
			refreshButton.disabled = true;
			try {
				if (runtimeDetailsNode.open)
					await loadDetails(true);
				else
					await refreshSummary();
			}
			catch (e) {
				ui.addNotification(null, E('p', _('Failed to refresh status: %s').format(e.message)), 'error');
			}
			finally {
				refreshButton.disabled = false;
			}
		};

		const loadLogs = async function(force = false) {
			if (logsLoaded && !force)
				return;

			logsRefreshButton.disabled = true;
			setChildren(logsNode, [ E('div', { class: 'mihowrt-status-muted' }, _('Loading logs...')) ]);
			try {
				setChildren(logsNode, [ renderLogs(await backendHelper.readLogs(LOG_LINE_LIMIT)) ]);
				logsLoaded = true;
			}
			catch (e) {
				setChildren(logsNode, [ E('div', { class: 'mihowrt-status-error' }, _('Failed to load logs: %s').format(e.message)) ]);
			}
			finally {
				logsRefreshButton.disabled = false;
			}
		};

			refreshButton.addEventListener('click', refreshStatus);
			logsRefreshButton.addEventListener('click', () => loadLogs(true));
		runtimeDetailsNode.addEventListener('toggle', () => {
			if (runtimeDetailsNode.open)
				loadDetails(false);
		});

			renderStatus(status);
			window.requestAnimationFrame(() => loadLogs(false));
		setChildren(runtimeDetailsNode, [
			E('summary', _('Runtime details')),
			runtimeNode,
			E('details', { class: 'mihowrt-status-details' }, [
				E('summary', _('Parsed config')),
				configNode,
				E('h4', _('Config errors')),
				errorNode
			])
		]);

		return E([
			E('style', DIAGNOSTICS_CSS),
			E('div', { class: 'mihowrt-status-head' }, [
				E('h2', { style: 'margin:0;' }, _('Diagnostics')),
				refreshButton
			]),
			E('div', { class: 'cbi-section' }, [
				summaryNode,
					runtimeDetailsNode
				]),
				E('div', { class: 'cbi-section' }, [
					E('div', { class: 'mihowrt-status-head' }, [
						E('h3', { style: 'margin:0;' }, _('Logs')),
						logsRefreshButton
					]),
					logsNode
				])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
