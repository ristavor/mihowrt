'use strict';
'require view';
'require fs';
'require mihowrt.ace as aceHelper';
'require mihowrt.backend as backendHelper';
'require mihowrt.ui as mihowrtUi';

const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';
const CLASH_CONFIG = '/opt/clash/config.yaml';
const SERVICE_STATE_POLL_INTERVAL_MS = 500;
const SERVICE_STATE_TIMEOUT_MS = 35000;

let startStopButton = null;
let enableDisableButton = null;
let dashboardButton = null;
let saveApplyButton = null;
let subscriptionUrlInput = null;
let subscriptionSaveButton = null;
let subscriptionFetchButton = null;
let serviceStatusBadge = null;
let serviceEnabledBadge = null;
let editor = null;
let serviceActionInFlight = false;
let saveInFlight = false;
let subscriptionInFlight = false;
let savedConfigContent = '';
let savedSubscriptionUrl = null;
let lastServiceState = {
	running: false,
	enabled: false,
	ready: false
};

function controlsBusy() {
	return serviceActionInFlight || saveInFlight || subscriptionInFlight;
}

function updateControlDisabledState() {
	const disabled = controlsBusy();

	if (startStopButton)
		startStopButton.disabled = disabled;
	if (enableDisableButton)
		enableDisableButton.disabled = disabled;
	if (dashboardButton)
		dashboardButton.disabled = disabled;
	if (saveApplyButton)
		saveApplyButton.disabled = disabled;
	if (subscriptionUrlInput)
		subscriptionUrlInput.disabled = disabled;
	if (subscriptionSaveButton)
		subscriptionSaveButton.disabled = disabled;
	if (subscriptionFetchButton)
		subscriptionFetchButton.disabled = disabled;
}

async function withServiceActionLock(fn) {
	serviceActionInFlight = true;
	updateControlDisabledState();

	try {
		return await fn();
	}
	finally {
		serviceActionInFlight = false;
		updateControlDisabledState();
	}
}

async function runServiceAction(action) {
	const result = await fs.exec(SERVICE_SCRIPT, [action]);
	if (result.code !== 0)
		throw new Error(mihowrtUi.execErrorDetail(result));
}

async function handleServiceAction(steps, errorMsg) {
	const completed = [];
	try {
		for (const step of steps) {
			await runServiceAction(step.action);
			completed.push(step);
		}
		return true;
	}
	catch (e) {
		const rollbackErrors = [];

		for (let i = completed.length - 1; i >= 0; i--) {
			const rollback = completed[i].rollback;
			if (!rollback)
				continue;

			try {
				await runServiceAction(rollback);
			}
			catch (rollbackError) {
				rollbackErrors.push('%s: %s'.format(rollback, rollbackError.message));
			}
		}

		const detail = rollbackErrors.length
			? _('%s Rollback failed: %s').format(e.message, rollbackErrors.join('; '))
			: e.message;
		mihowrtUi.notify(errorMsg.format(detail), 'error');
		return false;
	}
}

async function startService() {
	return handleServiceAction([
		{ action: 'start', rollback: 'stop' }
	], _('Unable to start service: %s'));
}

async function stopService() {
	return handleServiceAction([
		{ action: 'stop', rollback: 'start' }
	], _('Unable to stop service: %s'));
}

async function setServiceEnabled(enabled) {
	return handleServiceAction([
		{ action: enabled ? 'enable' : 'disable' }
	], enabled
		? _('Unable to enable service at boot: %s')
		: _('Unable to disable service at boot: %s'));
}

function serviceStateErrorDetail(status) {
	const errors = Array.isArray(status?.errors) ? status.errors.map(String).filter(Boolean) : [];
	return errors.join('; ') || _('unknown error');
}

async function pollServiceState(predicate, timeout = SERVICE_STATE_TIMEOUT_MS) {
	const startTime = Date.now();
	let lastError = null;

	while (Date.now() - startTime < timeout) {
		try {
			const state = await readServiceState();
			lastError = null;
			if (predicate(state))
				return state;
		}
		catch (e) {
			lastError = e;
		}

		await new Promise(resolve => setTimeout(resolve, SERVICE_STATE_POLL_INTERVAL_MS));
	}

	if (lastError)
		throw lastError;

	return null;
}

function serviceToggleLabel(running) {
	return running ? _('Stop MihoWRT') : _('Start MihoWRT');
}

function serviceEnabledToggleLabel(enabled) {
	return enabled ? _('Disable Autostart') : _('Enable Autostart');
}

function serviceBadgeText(running) {
	return running ? _('MihoWRT is running') : _('MihoWRT stopped');
}

function serviceBadgeColor(running) {
	return running ? '#5cb85c' : '#d9534f';
}

function serviceEnabledBadgeText(enabled) {
	return enabled ? _('Enabled at boot') : _('Disabled at boot');
}

function serviceEnabledBadgeColor(enabled) {
	return enabled ? '#5cb85c' : '#d9534f';
}

function applyServiceState(running, enabled) {
	if (startStopButton)
		startStopButton.textContent = serviceToggleLabel(running);
	if (enableDisableButton)
		enableDisableButton.textContent = serviceEnabledToggleLabel(enabled);

	if (serviceStatusBadge) {
		serviceStatusBadge.textContent = serviceBadgeText(running);
		serviceStatusBadge.style.backgroundColor = serviceBadgeColor(running);
	}

	if (serviceEnabledBadge) {
		serviceEnabledBadge.textContent = serviceEnabledBadgeText(enabled);
		serviceEnabledBadge.style.backgroundColor = serviceEnabledBadgeColor(enabled);
	}
}

async function readServiceState() {
	const status = await backendHelper.readServiceState();

	if (!status.available)
		throw new Error(serviceStateErrorDetail(status));

	lastServiceState = {
		running: !!status.serviceRunning,
		enabled: !!status.serviceEnabled,
		ready: !!status.serviceReady
	};

	return {
		running: lastServiceState.running,
		enabled: lastServiceState.enabled,
		ready: lastServiceState.ready
	};
}

async function refreshServiceState(notifyOnError = true) {
	try {
		const state = await readServiceState();
		applyServiceState(state.running, state.enabled);
		return state;
	}
	catch (e) {
		applyServiceState(lastServiceState.running, lastServiceState.enabled);
		if (notifyOnError)
			mihowrtUi.notify(_('Unable to read service state: %s').format(e.message), 'warning');
		return lastServiceState;
	}
}

async function toggleService() {
	if (controlsBusy())
		return;

	await withServiceActionLock(async () => {
		let state = null;

		try {
			state = await readServiceState();
		}
		catch (e) {
			await refreshServiceState(false);
			mihowrtUi.notify(_('Unable to read service state: %s').format(e.message), 'warning');
			return;
		}

		const targetStatus = !state.running;

		if (state.running) {
			if (!(await stopService()))
				return;
		}
		else {
			if (!(await startService()))
				return;
		}

		let settledState = null;
		try {
			settledState = await pollServiceState(nextState => targetStatus ? nextState.ready : !nextState.running);
		}
		catch (e) {
			await refreshServiceState(false);
			mihowrtUi.notify(_('Unable to confirm service state: %s').format(e.message), 'warning');
			return;
		}

		if (!settledState) {
			await refreshServiceState(false);
			mihowrtUi.notify(targetStatus
				? _('Service start timed out. Check diagnostics and system log.')
				: _('Service stop timed out. Refresh page and verify runtime state.'), 'warning');
			return;
		}

		applyServiceState(settledState.running, settledState.enabled);
	});
}

async function toggleServiceEnabled() {
	if (controlsBusy())
		return;

	await withServiceActionLock(async () => {
		let state = null;

		try {
			state = await readServiceState();
		}
		catch (e) {
			await refreshServiceState(false);
			mihowrtUi.notify(_('Unable to read service state: %s').format(e.message), 'warning');
			return;
		}

		if (!(await setServiceEnabled(!state.enabled)))
			return;

		await refreshServiceState();
	});
}

function normalizeHostPortFromAddr(addr, fallbackHost, fallbackPort) {
	if (!addr)
		return { host: fallbackHost, port: fallbackPort };

	const cleaned = addr.replace(/["']/g, '').trim();
	let host = fallbackHost, port = fallbackPort;

	if (cleaned.startsWith('[')) {
		const endBracket = cleaned.indexOf(']');
		if (endBracket !== -1) {
			host = cleaned.slice(1, endBracket);
			if (cleaned.charAt(endBracket + 1) === ':')
				port = cleaned.slice(endBracket + 2);
		}
	}
	else {
		const lastColon = cleaned.lastIndexOf(':');
		if (lastColon !== -1) {
			host = cleaned.slice(0, lastColon);
			port = cleaned.slice(lastColon + 1);
		}
	}

	if (/^(?:127(?:\.\d{1,3}){3}|0\.0\.0\.0|::1|::|localhost)?$/i.test(host))
		host = fallbackHost;

	return { host, port };
}

function computeUiPath(externalUiName, externalUi) {
	if (externalUiName) {
		const name = externalUiName.replace(/(^\/+|\/+$)/g, '');
		return `/${name}/`;
	}

	if (externalUi && !/[\/\\\.]/.test(externalUi)) {
		const name = externalUi.trim();
		return `/${name}/`;
	}

	return '/ui/';
}

async function openDashboard() {
	try {
		if (!(await mihowrtUi.getServiceStatus(SERVICE_NAME, SERVICE_SCRIPT))) {
			mihowrtUi.notify(_('Service is not running.'), 'error');
			return;
		}

		const config = await backendHelper.readConfig();
		if (config.errors && config.errors.length) {
			mihowrtUi.notify(_('Unable to open dashboard: %s').format(config.errors.join('; ')), 'error');
			return;
		}

		const ec = config.externalController;
		const ecTls = config.externalControllerTls;
		const secret = config.secret;
		const externalUi = config.externalUi;
		const externalUiName = config.externalUiName;

		const baseHost = window.location.hostname;
		const basePort = '9090';
		const useTls = !!ecTls;
		const hostPort = normalizeHostPortFromAddr(useTls ? ecTls : ec, baseHost, basePort);
		const scheme = useTls ? 'https:' : 'http:';
		const uiPath = computeUiPath(externalUiName, externalUi);
		const qp = new URLSearchParams();

		if (secret)
			qp.set('secret', secret);

		qp.set('hostname', hostPort.host);
		qp.set('port', hostPort.port);

		const safeHost = hostPort.host.includes(':') && !hostPort.host.startsWith('[')
			? `[${hostPort.host}]`
			: hostPort.host;
		const url = `${scheme}//${safeHost}:${hostPort.port}${uiPath}?${qp.toString()}`;
		const newWindow = window.open(url, '_blank');
		if (!newWindow)
			mihowrtUi.notify(_('Popup was blocked. Please allow popups for this site.'), 'warning');
	}
	catch (e) {
		mihowrtUi.notify(_('Failed to open dashboard: %s').format(e.message), 'error');
	}
}

async function initializeAceEditor(node, content) {
	editor = await aceHelper.createEditor(node, 'yaml', {
		fontSize: '12px'
	});
	editor.setValue(content, -1);
}

function editorContentForSave(value) {
	return value == null ? '' : String(value);
}

async function restartRunningService(wasRunning) {
	if (!wasRunning)
		return { restarted: false, error: null };
	try {
		await backendHelper.restartValidatedService();
		return { restarted: true, error: null };
	}
	catch (e) {
		return { restarted: false, error: e.message || String(e) };
	}
}

function subscriptionStateErrorDetail(state) {
	const errors = Array.isArray(state?.errors) ? state.errors.map(String).filter(Boolean) : [];
	return errors.join('; ') || _('unknown error');
}

function subscriptionUrlInputValue(input = subscriptionUrlInput) {
	return String(input?.value || '').trim();
}

async function persistSubscriptionUrlIfChanged(subscriptionUrl) {
	const value = String(subscriptionUrl || '').trim();

	if (savedSubscriptionUrl !== null && value === savedSubscriptionUrl)
		return false;

	await backendHelper.saveSubscriptionUrl(value);
	savedSubscriptionUrl = value;
	return true;
}

function editorHasUnsavedChanges() {
	return !!editor && editorContentForSave(editor.getValue()) !== savedConfigContent;
}

function confirmSubscriptionOverwrite() {
	if (!editorHasUnsavedChanges())
		return true;

	return window.confirm(_('Replace unsaved editor contents with downloaded subscription?'));
}

async function withSubscriptionLock(fn) {
	subscriptionInFlight = true;
	updateControlDisabledState();

	try {
		return await fn();
	}
	finally {
		subscriptionInFlight = false;
		updateControlDisabledState();
	}
}

async function loadSubscriptionIntoEditor(subscriptionUrl, expectedEditorContent) {
	if (!editor)
		throw new Error(_('Editor is still loading. Please try again in a moment.'));

	const contents = await backendHelper.fetchSubscription(subscriptionUrl);
	if (expectedEditorContent != null && editorContentForSave(editor.getValue()) !== expectedEditorContent)
		throw new Error(_('Editor content changed during subscription download. Fetch again after saving or discarding edits.'));

	editor.setValue(editorContentForSave(contents), -1);
	return contents;
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read(CLASH_CONFIG), ''),
			L.resolveDefault(backendHelper.readSubscriptionUrl(), { subscriptionUrl: '', errors: [ _('Unable to read subscription URL') ] })
		]);
	},

	render: async function(data) {
		const config = data?.[0] ?? '';
		const subscriptionState = data?.[1] || { subscriptionUrl: '', errors: [] };
		let serviceState = lastServiceState;
		try {
			serviceState = await readServiceState();
		}
		catch (e) {
			mihowrtUi.notify(_('Unable to read service state: %s').format(e.message), 'warning');
		}
		if (subscriptionState.errors && subscriptionState.errors.length)
			mihowrtUi.notify(_('Unable to read subscription URL: %s').format(subscriptionStateErrorDetail(subscriptionState)), 'warning');
		savedConfigContent = editorContentForSave(config);
		savedSubscriptionUrl = subscriptionState.errors && subscriptionState.errors.length
			? null
			: subscriptionUrlInputValue({ value: subscriptionState.subscriptionUrl || '' });
		const editorNode = E('div', {
			id: 'editor',
			style: 'width: 100%; height: 640px; margin-bottom: 15px;'
		});

		const saveSubscription = async function() {
			if (controlsBusy())
				return;

			await withSubscriptionLock(async () => {
				const value = subscriptionUrlInputValue();
				const changed = await persistSubscriptionUrlIfChanged(value);
				if (!changed) {
					mihowrtUi.notify(_('Subscription URL is unchanged.'), 'info');
					return;
				}

				mihowrtUi.notify(value ? _('Subscription URL saved.') : _('Subscription disabled.'), 'info');
			}).catch(e => {
				mihowrtUi.notify(_('Unable to save subscription URL: %s').format(e.message), 'error');
			});
		};

		const fetchSubscription = async function() {
			if (controlsBusy())
				return;

			await withSubscriptionLock(async () => {
				const value = subscriptionUrlInputValue();
				if (!value) {
					mihowrtUi.notify(_('Subscription URL is empty.'), 'warning');
					return;
				}

				if (!confirmSubscriptionOverwrite())
					return;

				const expectedEditorContent = editor ? editorContentForSave(editor.getValue()) : null;
				const contents = await loadSubscriptionIntoEditor(value, expectedEditorContent);
				if (!contents) {
					mihowrtUi.notify(_('Subscription returned empty config.'), 'error');
					return;
				}

				try {
					await persistSubscriptionUrlIfChanged(value);
				}
				catch (e) {
					mihowrtUi.notify(_('Subscription loaded, but URL was not saved: %s').format(e.message), 'warning');
				}

				mihowrtUi.notify(_('Subscription loaded into editor. Validate & apply to save.'), 'info');
			}).catch(e => {
				mihowrtUi.notify(_('Unable to fetch subscription: %s').format(e.message), 'error');
			});
		};

		const saveAndApply = async function() {
			if (controlsBusy())
				return;

			saveInFlight = true;
			updateControlDisabledState();

			try {
				if (!editor) {
					mihowrtUi.notify(_('Editor is still loading. Please try again in a moment.'), 'warning');
					return;
				}

				const value = editorContentForSave(editor.getValue());
				if (value === savedConfigContent) {
					mihowrtUi.notify(_('Configuration is unchanged.'), 'info');
					return;
				}

				let wasRunning = false;
				try {
					wasRunning = await mihowrtUi.getServiceStatus(SERVICE_NAME, SERVICE_SCRIPT);
				}
				catch (e) {
					mihowrtUi.notify(_('Unable to determine service state before apply: %s').format(e.message), 'error');
					return;
				}

				await backendHelper.applyConfig(value);
				savedConfigContent = value;
				mihowrtUi.notify(_('Configuration saved successfully.'), 'info');

				const restartState = await restartRunningService(wasRunning);
				if (restartState.error) {
					await refreshServiceState();
					mihowrtUi.notify(_('Service restart failed: %s').format(restartState.error), 'error');
					return;
				}
				if (restartState.restarted) {
					let restartSettled = null;

					try {
						restartSettled = await pollServiceState(state => state.ready);
					}
					catch (e) {
						await refreshServiceState(false);
						mihowrtUi.notify(_('Unable to confirm service restart: %s').format(e.message), 'warning');
						return;
					}

					if (!restartSettled) {
						await refreshServiceState(false);
						mihowrtUi.notify(_('Service restart is still in progress. Check diagnostics if it does not recover soon.'), 'warning');
						return;
					}

					applyServiceState(restartSettled.running, restartSettled.enabled);
					mihowrtUi.notify(_('Service restarted successfully.'), 'info');
				}
				else {
					await refreshServiceState();
				}
			}
			catch (e) {
				mihowrtUi.notify(_('Unable to save contents: %s').format(e.message), 'error');
			}
			finally {
				saveInFlight = false;
				updateControlDisabledState();
			}
		};

		const page = E([
			E('div', {
				style: 'margin-bottom: 20px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px;'
			}, [
				(startStopButton = E('button', {
					class: 'btn',
					click: toggleService
				}, serviceToggleLabel(serviceState.running))),
				(enableDisableButton = E('button', {
					class: 'btn',
					click: toggleServiceEnabled
				}, serviceEnabledToggleLabel(serviceState.enabled))),
				(dashboardButton = E('button', {
					class: 'btn',
					click: openDashboard
				}, _('Open Mihomo Dashboard'))),
				(serviceStatusBadge = E('span', {
					class: 'label',
					style: 'padding: 4px 10px; border-radius: 3px; font-size: 12px; color: white; background-color: ' + serviceBadgeColor(serviceState.running) + ';'
				}, serviceBadgeText(serviceState.running))),
				(serviceEnabledBadge = E('span', {
					class: 'label',
					style: 'padding: 4px 10px; border-radius: 3px; font-size: 12px; color: white; background-color: ' + serviceEnabledBadgeColor(serviceState.enabled) + ';'
				}, serviceEnabledBadgeText(serviceState.enabled)))
			]),
			E('h2', _('Mihomo YAML Configuration')),
			E('p', { class: 'cbi-section-descr' }, _('Raw Mihomo YAML config. Save validates Mihomo syntax and required policy values before apply. Direct shell edits should use "service mihowrt apply".')),
			E('div', {
				style: 'margin-bottom: 15px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px;'
			}, [
				(subscriptionUrlInput = E('input', {
					type: 'url',
					value: String(subscriptionState.subscriptionUrl || ''),
					placeholder: _('Subscription URL'),
					style: 'flex: 1 1 360px; min-width: 220px; max-width: 100%;'
				})),
				(subscriptionSaveButton = E('button', {
					class: 'btn',
					click: saveSubscription
				}, _('Save Subscription URL'))),
				(subscriptionFetchButton = E('button', {
					class: 'btn cbi-button-action',
					click: fetchSubscription
				}, _('Fetch Subscription')))
			]),
			editorNode,
			E('div', { style: 'text-align: center; margin-top: 15px; margin-bottom: 20px;' }, [
				(saveApplyButton = E('button', {
					class: 'btn cbi-button-apply',
					click: saveAndApply
				}, _('Validate & Apply Config')))
			])
		]);

		applyServiceState(serviceState.running, serviceState.enabled);
		updateControlDisabledState();

		window.requestAnimationFrame(() => {
			initializeAceEditor(editorNode, config).catch(e => {
				mihowrtUi.notify(_('Unable to initialize editor: %s').format(e.message), 'error');
			});
		});

		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
