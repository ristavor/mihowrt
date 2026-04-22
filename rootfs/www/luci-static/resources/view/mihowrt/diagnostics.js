'use strict';
'require view';
'require ui';
'require mihowrt.backend as backendHelper';

const LOG_LINE_LIMIT = 200;

function badge(text, ok) {
	return E('span', {
		class: 'label',
		style: 'display:inline-block;padding:4px 10px;border-radius:999px;font-size:12px;color:white;background-color:' + (ok ? '#5cb85c' : '#d9534f') + ';'
	}, text);
}

function renderField(label, value) {
	return E('div', {
		style: 'padding:10px 12px;border:1px solid #ddd;border-radius:6px;background:#fff;'
	}, [
		E('div', {
			style: 'font-size:12px;color:#666;margin-bottom:4px;'
		}, label),
		E('div', {
			style: 'font-family:monospace;word-break:break-word;'
		}, value)
	]);
}

function setChildren(node, children) {
	while (node.firstChild)
		node.removeChild(node.firstChild);

	children.forEach(child => node.appendChild(child));
}

function renderErrorList(errors) {
	if (!errors || !errors.length)
		return E('div', { style: 'color:#666;' }, _('No errors reported.'));

	return E('ul', { style: 'margin:0;padding-left:20px;' }, errors.map(error =>
		E('li', { style: 'color:#b94a48;' }, error)
	));
}

function renderLogLines(logs) {
	if (logs.errors && logs.errors.length)
		return E('div', { style: 'color:#b94a48;' }, logs.errors.join('; '));

	if (!logs.available)
		return E('div', { style: 'color:#666;' }, _('System log reader is not available on this device.'));

	if (!logs.lines.length)
		return E('div', { style: 'color:#666;' }, _('No MihoWRT-related log lines found.'));

	return E('pre', {
		style: 'margin:0;max-height:480px;overflow:auto;padding:14px;border:1px solid #ddd;border-radius:6px;background:#111;color:#e9f6e9;white-space:pre-wrap;word-break:break-word;'
	}, logs.lines.join('\n'));
}

function renderAppliedPolicyBadge(status, active) {
	if (status.runtimeSnapshotPresent && !status.runtimeSnapshotValid)
		return badge(_('Applied Runtime Snapshot Invalid'), false);

	if (status.runtimeLiveStatePresent && !status.runtimeSnapshotPresent)
		return badge(_('Applied Runtime Untracked'), false);

	if (!active.present)
		return badge(_('Applied Runtime Not Active'), false);

	return badge(active.enabled ? _('Applied Policy Enabled') : _('Applied Policy Disabled'), active.enabled);
}

function renderAppliedBoolean(value) {
	if (value == null)
		return _('not active');

	return value ? _('enabled') : _('disabled');
}

function renderAppliedList(values) {
	if (!values)
		return _('not active');

	return values.length ? values.join(', ') : _('none');
}

function renderAppliedCount(value) {
	return value == null ? _('not active') : String(value);
}

function deriveAppliedState(status) {
	if (status.active && status.active.present)
		return status.active;

	return {
		present: false,
		enabled: false,
		routeTableId: '',
		routeRulePriority: '',
		dnsHijack: null,
		disableQuic: null,
		sourceNetworkInterfaces: null,
		alwaysProxyDstCount: null,
		alwaysProxySrcCount: null
	};
}

return view.extend({
	load: function() {
		return Promise.all([
			backendHelper.readStatus(),
			backendHelper.readLogs(LOG_LINE_LIMIT)
		]);
	},

	render: function(data) {
		const summaryNode = E('div');
		const runtimeNode = E('div');
		const configNode = E('div');
		const logsNode = E('div');
		const refreshButton = E('button', {
			class: 'btn cbi-button-action'
		}, _('Refresh'));

		const renderState = function(status, logs) {
			const active = deriveAppliedState(status);

			setChildren(summaryNode, [
				E('div', {
					style: 'display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:14px;'
				}, [
					badge(status.serviceRunning ? _('Service Running') : _('Service Stopped'), status.serviceRunning),
					badge(status.serviceEnabled ? _('Enabled At Boot') : _('Disabled At Boot'), status.serviceEnabled),
					badge(status.serviceReady ? _('Service Ready') : _('Service Not Ready'), status.serviceReady),
					renderAppliedPolicyBadge(status, active),
					badge(status.dnsBackupValid ? _('DNS Backup Cache Valid') : _('DNS Backup Cache Invalid/Missing'), status.dnsBackupValid),
					badge(status.runtimeSafeReloadReady ? _('Safe Reload Ready') : _('Safe Reload Blocked'), status.runtimeSafeReloadReady),
					badge(
						status.runtimeSnapshotValid
							? _('Runtime Snapshot Valid')
							: (status.runtimeSnapshotPresent ? _('Runtime Snapshot Invalid') : _('Runtime Snapshot Missing')),
						status.runtimeSnapshotValid
					),
					badge(
						(status.runtimeSnapshotPresent && !status.runtimeSnapshotValid)
							? _('Runtime Snapshot Invalid')
							: ((status.runtimeLiveStatePresent && !status.runtimeSnapshotPresent)
							? _('Runtime State Untracked')
							: (active.present
							? (status.runtimeMatchesDesired ? _('Runtime Matches Config') : _('Runtime Rolled Back/Drifted'))
							: _('Runtime Not Active'))),
						active.present && status.runtimeMatchesDesired && status.runtimeSnapshotValid
					)
					]),
					(status.errors && status.errors.length)
						? E('div', { style: 'color:#b94a48;' }, status.errors.join('; '))
						: ((status.runtimeLiveStatePresent && !status.runtimeSnapshotPresent)
							? E('div', { style: 'color:#b94a48;' }, _('Live runtime state exists, but runtime snapshot is missing. Diagnostics are partial and safe reload stays blocked.'))
						: (!active.present
							? E('div', { style: 'color:#666;' }, _('No applied runtime snapshot is active right now.'))
						: (!status.runtimeMatchesDesired
							? E('div', { style: 'color:#b94a48;' }, _('Applied runtime state differs from current config on disk. Run "service mihowrt apply" or restart service after direct file edits.'))
							: (!status.runtimeSafeReloadReady
								? E('div', { style: 'color:#b94a48;' }, _('Safe in-place reload is blocked because live state exists without runtime snapshot.'))
								: E('div', { style: 'color:#666;' }, _('Runtime snapshot from MihoWRT backend.'))))))
			]);

			setChildren(runtimeNode, [
				E('div', {
					style: 'display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;'
				}, [
					renderField(_('Applied Route Table'), active.routeTableId || _('not active')),
					renderField(_('Applied Route Rule Priority'), active.routeRulePriority || _('not active')),
					renderField(_('Configured Route Table'), status.routeTableId),
					renderField(_('Configured Route Rule Priority'), status.routeRulePriority),
					renderField(_('Applied DNS Hijack'), renderAppliedBoolean(active.dnsHijack)),
					renderField(_('Applied Disable QUIC'), renderAppliedBoolean(active.disableQuic)),
					renderField(_('Applied Source Interfaces'), renderAppliedList(active.sourceNetworkInterfaces)),
					renderField(_('Applied Always Proxy Dst Count'), renderAppliedCount(active.alwaysProxyDstCount)),
					renderField(_('Applied Always Proxy Src Count'), renderAppliedCount(active.alwaysProxySrcCount)),
					renderField(_('Service Ready'), status.serviceReady ? _('yes') : _('no')),
					renderField(_('Runtime Snapshot Present'), status.runtimeSnapshotPresent ? _('yes') : _('no')),
					renderField(_('Runtime Snapshot Valid'), status.runtimeSnapshotValid ? _('yes') : _('no')),
					renderField(_('Safe Reload Ready'), status.runtimeSafeReloadReady ? _('yes') : _('no')),
					renderField(_('DNS Backup Cached'), status.dnsBackupExists ? _('yes') : _('no')),
					renderField(_('DNS Recovery Backup Active'), status.dnsRecoveryBackupActive ? _('yes') : _('no')),
					renderField(_('DNS Recovery Backup Valid'), status.dnsRecoveryBackupValid ? _('yes') : _('no')),
					renderField(_('Route State Present'), status.routeStatePresent ? _('yes') : _('no'))
				])
			]);

			setChildren(configNode, [
				E('div', {
					style: 'display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-bottom:12px;'
				}, [
					renderField(_('dns.listen -> local'), status.config.mihomoDnsListen || _('missing')),
					renderField(_('DNS Port'), status.config.dnsPort || _('missing')),
					renderField(_('TPROXY Port'), status.config.tproxyPort || _('missing')),
					renderField(_('Routing Mark'), status.config.routingMark || _('missing')),
					renderField(_('Enhanced Mode'), status.config.enhancedMode || _('none')),
					renderField(_('Fake-IP Range'), status.config.fakeIpRange || _('none')),
					renderField(_('External Controller'), status.config.externalController || _('none')),
					renderField(_('External Controller TLS'), status.config.externalControllerTls || _('none')),
					renderField(_('External UI Name'), status.config.externalUiName || _('none'))
				]),
				E('h3', { style: 'margin:0 0 8px 0;' }, _('Config Parse Errors')),
				renderErrorList(status.config.errors)
			]);

			setChildren(logsNode, [
				E('div', {
					style: 'margin-bottom:10px;color:#666;'
				}, _('Last %d MihoWRT-related system log lines.').format(logs.limit || LOG_LINE_LIMIT)),
				renderLogLines(logs)
			]);
		};

		const updateView = async function() {
			refreshButton.disabled = true;

			try {
				const [status, logs] = await Promise.all([
					backendHelper.readStatus(),
					backendHelper.readLogs(LOG_LINE_LIMIT)
				]);
				renderState(status, logs);
			}
			catch (e) {
				ui.addNotification(null, E('p', _('Failed to refresh diagnostics: %s').format(e.message)), 'error');
			}
			finally {
				refreshButton.disabled = false;
			}
		};

		refreshButton.addEventListener('click', updateView);
		renderState(data[0], data[1]);

		return E([
			E('div', {
				style: 'margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;'
			}, [
				E('div', [
					E('h2', { style: 'margin:0 0 6px 0;' }, _('MihoWRT Diagnostics')),
					E('p', { class: 'cbi-section-descr', style: 'margin:0;' }, _('Runtime state, parsed config view, and system logs filtered for MihoWRT.'))
				]),
				refreshButton
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', { style: 'margin-top:0;' }, _('Summary')),
				summaryNode
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', { style: 'margin-top:0;' }, _('Runtime')),
				runtimeNode
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', { style: 'margin-top:0;' }, _('Parsed Config')),
				configNode
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', { style: 'margin-top:0;' }, _('Logs')),
				logsNode
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
