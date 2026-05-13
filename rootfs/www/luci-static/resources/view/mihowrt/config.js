'use strict';
'require view';
'require fs';
'require mihowrt.ace as aceHelper';
'require mihowrt.backend as backendHelper';
'require mihowrt.config as configHelper';
'require mihowrt.ui as mihowrtUi';

const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';
const CLASH_CONFIG = '/opt/clash/config.yaml';
const SERVICE_STATE_POLL_INTERVAL_MS = 1000;
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
	// Any active backend operation disables controls to prevent overlap.
	return serviceActionInFlight || saveInFlight || subscriptionInFlight;
}

function updateControlDisabledState() {
	// Keep every control in the same disabled state while action is in flight.
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
	// Serialize start/stop/enable/disable actions from this page.
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
	// Surface stderr/stdout on failure.
	const result = await fs.exec(SERVICE_SCRIPT, [action]);
	if (result.code !== 0)
		throw new Error(mihowrtUi.execErrorDetail(result));
}

async function handleServiceAction(steps, errorMsg) {
	// Undo completed steps when possible if a multi-step action fails.
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

async function pollServiceState(predicate, timeout = SERVICE_STATE_TIMEOUT_MS) {
	// Poll only after explicit service actions; normal page display does not poll.
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

function applyServiceState(running, enabled) {
	// Reflect latest service state in button labels and badges.
	if (startStopButton)
		startStopButton.textContent = configHelper.serviceToggleLabel(running);
	if (enableDisableButton)
		enableDisableButton.textContent = configHelper.serviceEnabledToggleLabel(enabled);

	if (serviceStatusBadge) {
		serviceStatusBadge.textContent = configHelper.serviceBadgeText(running);
		serviceStatusBadge.style.backgroundColor = configHelper.serviceBadgeColor(running);
	}

	if (serviceEnabledBadge) {
		serviceEnabledBadge.textContent = configHelper.serviceEnabledBadgeText(enabled);
		serviceEnabledBadge.style.backgroundColor = configHelper.serviceEnabledBadgeColor(enabled);
	}
}

async function readServiceState() {
	// Read compact service-state JSON through read-only backend.
	const status = await backendHelper.readServiceState();

	if (!status.available)
		throw new Error(configHelper.serviceStateErrorDetail(status));

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
	// Keep last known values if backend is temporarily unavailable.
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
	// Wait until start reaches ready or stop reaches not-running.
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
	// Toggle autostart and refresh state.
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

async function openDashboard() {
	return configHelper.openDashboard({
		serviceName: SERVICE_NAME,
		serviceScript: SERVICE_SCRIPT,
		backendHelper: backendHelper,
		uiHelper: mihowrtUi,
		windowObject: window
	});
}

async function initializeAceEditor(node, content) {
	editor = await aceHelper.createEditor(node, 'yaml', {
		fontSize: '12px'
	});
	editor.setValue(content, -1);
}

async function restartRunningService(wasRunning) {
	return configHelper.restartRunningService(backendHelper, wasRunning);
}

function subscriptionUrlInputValue(input = subscriptionUrlInput) {
	return configHelper.subscriptionUrlInputValue(input);
}

async function persistSubscriptionUrlIfChanged(subscriptionUrl) {
	// Avoid UCI commit when subscription URL did not change.
	const value = String(subscriptionUrl || '').trim();

	if (savedSubscriptionUrl !== null && value === savedSubscriptionUrl)
		return false;

	await backendHelper.saveSubscriptionUrl(value);
	savedSubscriptionUrl = value;
	return true;
}

function editorHasUnsavedChanges() {
	// Compare editor content with the last validated/saved content.
	return !!editor && configHelper.editorContentForSave(editor.getValue()) !== savedConfigContent;
}

function confirmSubscriptionOverwrite() {
	// Protect unsaved manual edits from being overwritten by subscription fetch.
	if (!editorHasUnsavedChanges())
		return true;

	return window.confirm(_('Replace unsaved editor contents with downloaded subscription?'));
}

async function withSubscriptionLock(fn) {
	// Serialize subscription save/fetch operations.
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
	// Abort if editor content changed during download.
	if (!editor)
		throw new Error(_('Editor is still loading. Please try again in a moment.'));

	const contents = await backendHelper.fetchSubscription(subscriptionUrl);
	if (expectedEditorContent != null && configHelper.editorContentForSave(editor.getValue()) !== expectedEditorContent)
		throw new Error(_('Editor content changed during subscription download. Fetch again after saving or discarding edits.'));

	editor.setValue(configHelper.editorContentForSave(contents), -1);
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

		// Cache loaded values as the baseline for dirty checks and no-op saves.
		try {
			serviceState = await readServiceState();
		}
		catch (e) {
			mihowrtUi.notify(_('Unable to read service state: %s').format(e.message), 'warning');
		}
		if (subscriptionState.errors && subscriptionState.errors.length)
			mihowrtUi.notify(_('Unable to read subscription URL: %s').format(configHelper.subscriptionStateErrorDetail(subscriptionState)), 'warning');
		savedConfigContent = configHelper.editorContentForSave(config);
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

				const expectedEditorContent = editor ? configHelper.editorContentForSave(editor.getValue()) : null;
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

				const value = configHelper.editorContentForSave(editor.getValue());
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

				const applyResult = await backendHelper.applyConfig(value) || { restartRequired: wasRunning };
				savedConfigContent = value;
				mihowrtUi.notify(_('Configuration saved successfully.'), 'info');

				if (!applyResult.restartRequired) {
					await refreshServiceState();
					if (applyResult.policyReloaded)
						mihowrtUi.notify(_('Configuration hot-reloaded; policy updated.'), 'info');
					else if (applyResult.hotReloaded)
						mihowrtUi.notify(_('Configuration hot-reloaded.'), 'info');
					return;
				}

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
				}, configHelper.serviceToggleLabel(serviceState.running))),
				(enableDisableButton = E('button', {
					class: 'btn',
					click: toggleServiceEnabled
				}, configHelper.serviceEnabledToggleLabel(serviceState.enabled))),
				(dashboardButton = E('button', {
					class: 'btn',
					click: openDashboard
				}, _('Open Mihomo Dashboard'))),
				(serviceStatusBadge = E('span', {
					class: 'label',
					style: 'padding: 4px 10px; border-radius: 3px; font-size: 12px; color: white; background-color: ' + configHelper.serviceBadgeColor(serviceState.running) + ';'
				}, configHelper.serviceBadgeText(serviceState.running))),
				(serviceEnabledBadge = E('span', {
					class: 'label',
					style: 'padding: 4px 10px; border-radius: 3px; font-size: 12px; color: white; background-color: ' + configHelper.serviceEnabledBadgeColor(serviceState.enabled) + ';'
				}, configHelper.serviceEnabledBadgeText(serviceState.enabled)))
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
