'use strict';
'require view';
'require fs';
'require mihowrt.ace as aceHelper';
'require mihowrt.backend as backendHelper';
'require mihowrt.config as configHelper';
'require mihowrt.ui as mihowrtUi';

const CLASH_CONFIG = '/opt/clash/config.yaml';
const SERVICE_STATE_POLL_INTERVAL_MS = 1000;
const SERVICE_STATE_TIMEOUT_MS = 35000;

let saveConfigButton = null;
let saveApplyButton = null;
let subscriptionUrlInput = null;
let subscriptionOverrideInput = null;
let subscriptionIntervalInput = null;
let subscriptionSaveButton = null;
let subscriptionFetchButton = null;
let subscriptionAutoUpdateBadge = null;
let subscriptionAutoUpdateReasonNode = null;
let subscriptionManualRestartNode = null;
let editor = null;
let saveInFlight = false;
let subscriptionInFlight = false;
let savedConfigContent = '';
let savedSubscriptionUrl = null;
let pendingSubscriptionSettings = null;
function controlsBusy() {
	return saveInFlight || subscriptionInFlight;
}

function updateControlDisabledState() {
	// Keep every control in the same disabled state while action is in flight.
	const disabled = controlsBusy();
	const hasSubscriptionUrl = !!String(subscriptionUrlInput?.value || '').trim();

	if (saveApplyButton)
		saveApplyButton.disabled = disabled;
	if (saveConfigButton)
		saveConfigButton.disabled = disabled;
	if (subscriptionUrlInput)
		subscriptionUrlInput.disabled = disabled;
	if (subscriptionOverrideInput)
		subscriptionOverrideInput.disabled = disabled || !hasSubscriptionUrl;
	if (subscriptionIntervalInput)
		subscriptionIntervalInput.disabled = disabled || !hasSubscriptionUrl || !subscriptionOverrideInput?.checked;
	if (subscriptionSaveButton)
		subscriptionSaveButton.disabled = disabled;
	if (subscriptionFetchButton)
		subscriptionFetchButton.disabled = disabled || !hasSubscriptionUrl;
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

async function readServiceState() {
	// Read compact service-state JSON through read-only backend.
	const status = await backendHelper.readServiceState();

	if (!status.available)
		throw new Error(configHelper.serviceStateErrorDetail(status));

	return {
		running: !!status.serviceRunning,
		enabled: !!status.serviceEnabled,
		ready: !!status.serviceReady
	};
}

async function refreshServiceState(notifyOnError = true) {
	// Keep last known values if backend is temporarily unavailable.
	try {
		return await readServiceState();
	}
	catch (e) {
		if (notifyOnError)
			mihowrtUi.notify(_('Unable to read service state: %s').format(e.message), 'warning');
		return null;
	}
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

async function persistSubscriptionSettings(subscriptionUrl, headerInterval, metadata) {
	const normalizedUrl = String(subscriptionUrl || '').trim();
	const overrideInterval = !!subscriptionOverrideInput?.checked;
	const updateInterval = overrideInterval ? String(subscriptionIntervalInput?.value || '').trim() : '';

	await backendHelper.saveSubscriptionSettings(normalizedUrl, overrideInterval, updateInterval, headerInterval, metadata);
	savedSubscriptionUrl = normalizedUrl;
	await refreshSubscriptionState(true);
}

function subscriptionDisplayInterval(subscriptionState) {
	return subscriptionState.subscriptionIntervalOverride
		? String(subscriptionState.subscriptionUpdateInterval || '')
		: String(subscriptionState.subscriptionHeaderInterval || subscriptionState.subscriptionEffectiveInterval || '');
}

function setSubscriptionHeaderIntervalForUrl(headerInterval, subscriptionUrl) {
	const value = String(headerInterval || '').trim();
	const url = String(subscriptionUrl || '').trim();

	if (!subscriptionIntervalInput)
		return;

	subscriptionIntervalInput.dataset.headerInterval = value;
	subscriptionIntervalInput.dataset.headerUrl = url;
	if (!subscriptionOverrideInput?.checked)
		subscriptionIntervalInput.value = value;
}

function applySubscriptionState(subscriptionState, updateInputs = false) {
	const enabled = !!subscriptionState?.subscriptionAutoUpdateEnabled;
	const reason = !enabled ? String(subscriptionState?.subscriptionAutoUpdateReason || '') : '';
	const manualRestartRequired = !!subscriptionState?.subscriptionManualRestartRequired;
	const manualRestartReason = manualRestartRequired
		? String(subscriptionState?.subscriptionManualRestartReason || _('Mihomo API/UI settings changed. Manual service restart is required.'))
		: '';

	if (updateInputs) {
		const url = String(subscriptionState?.subscriptionUrl || '');
		savedSubscriptionUrl = subscriptionUrlInputValue({ value: url });
		if (subscriptionUrlInput)
			subscriptionUrlInput.value = url;
		if (subscriptionOverrideInput)
			subscriptionOverrideInput.checked = !!subscriptionState?.subscriptionIntervalOverride;
		if (subscriptionIntervalInput) {
			subscriptionIntervalInput.dataset.manualInterval = String(subscriptionState?.subscriptionUpdateInterval || '');
			subscriptionIntervalInput.dataset.headerInterval = String(subscriptionState?.subscriptionHeaderInterval || subscriptionState?.subscriptionEffectiveInterval || '');
			subscriptionIntervalInput.dataset.headerUrl = savedSubscriptionUrl;
			subscriptionIntervalInput.value = subscriptionDisplayInterval(subscriptionState || {});
		}
	}

	if (subscriptionAutoUpdateBadge) {
		subscriptionAutoUpdateBadge.textContent = enabled ? _('Auto-update enabled') : _('Auto-update disabled');
		subscriptionAutoUpdateBadge.className = 'label ' + (enabled ? 'success' : 'warning');
	}

	if (subscriptionAutoUpdateReasonNode) {
		subscriptionAutoUpdateReasonNode.textContent = reason;
		subscriptionAutoUpdateReasonNode.style.display = reason ? '' : 'none';
	}

	if (subscriptionManualRestartNode) {
		subscriptionManualRestartNode.textContent = manualRestartReason;
		subscriptionManualRestartNode.style.display = manualRestartReason ? '' : 'none';
	}

	updateControlDisabledState();
}

async function refreshSubscriptionState(updateInputs = true) {
	const state = await backendHelper.readSubscriptionUrl();
	if (state.errors && state.errors.length)
		throw new Error(configHelper.subscriptionStateErrorDetail(state));
	applySubscriptionState(state, updateInputs);
	return state;
}

function updateSubscriptionIntervalInputState() {
	if (!subscriptionIntervalInput)
		return;

	const overrideInterval = !!subscriptionOverrideInput?.checked;
	if (overrideInterval) {
		subscriptionIntervalInput.value = subscriptionIntervalInput.dataset.manualInterval || '';
	}
	else {
		subscriptionIntervalInput.dataset.manualInterval = String(subscriptionIntervalInput.value || '').trim();
		subscriptionIntervalInput.value = subscriptionIntervalInput.dataset.headerInterval || '';
	}
	updateControlDisabledState();
}

function stageSubscriptionSettings(subscriptionUrl, result) {
	const content = configHelper.editorContentForSave(String(result?.content || ''));
	const profileUpdateInterval = String(result?.profileUpdateInterval || '');

	pendingSubscriptionSettings = {
		subscriptionUrl: String(subscriptionUrl || '').trim(),
		profileUpdateInterval: profileUpdateInterval,
		metadata: {
			profileTitle: String(result?.profileTitle || ''),
			subscriptionUserinfo: String(result?.subscriptionUserinfo || ''),
			supportUrl: String(result?.supportUrl || ''),
			profileWebPageUrl: String(result?.profileWebPageUrl || ''),
			announce: String(result?.announce || '')
		},
		configContent: content
	};
	setSubscriptionHeaderIntervalForUrl(profileUpdateInterval, subscriptionUrl);
}

async function persistPendingSubscriptionSettings(configContent) {
	const pending = pendingSubscriptionSettings;

	if (!pending)
		return false;
	if (pending.configContent !== configContent) {
		pendingSubscriptionSettings = null;
		return false;
	}

	await persistSubscriptionSettings(pending.subscriptionUrl, pending.profileUpdateInterval, pending.metadata);
	pendingSubscriptionSettings = null;
	return true;
}

function editorHasUnsavedChanges() {
	// Compare editor content with the last validated/saved content.
	return !!editor && configHelper.editorContentForSave(editor.getValue()) !== savedConfigContent;
}

async function readPersistedConfigContent(fallbackValue) {
	try {
		return configHelper.editorContentForSave(await fs.read(CLASH_CONFIG));
	}
	catch (e) {
		return fallbackValue;
	}
}

async function syncEditorToPersistedConfig(fallbackValue) {
	const persistedValue = await readPersistedConfigContent(fallbackValue);

	if (editor && persistedValue !== fallbackValue)
		editor.setValue(persistedValue, -1);

	return persistedValue;
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

	const fetched = await backendHelper.fetchSubscription(subscriptionUrl);
	const result = typeof fetched === 'string'
		? { content: fetched, profileUpdateInterval: '' }
		: fetched;
	const contents = result.content;
	if (expectedEditorContent != null && configHelper.editorContentForSave(editor.getValue()) !== expectedEditorContent)
		throw new Error(_('Editor content changed during subscription download. Fetch again after saving or discarding edits.'));

	editor.setValue(configHelper.editorContentForSave(contents), -1);
	return result;
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

			// Cache loaded values as the baseline for dirty checks and no-op saves.
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
				await persistSubscriptionSettings(value);
				pendingSubscriptionSettings = null;

				mihowrtUi.notify(value ? _('Subscription URL saved.') : _('Subscription disabled.'), 'info');
			}).catch(e => {
				mihowrtUi.notify(_('Unable to save subscription settings: %s').format(e.message), 'error');
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
				const result = await loadSubscriptionIntoEditor(value, expectedEditorContent);
				const contents = result.content;
				if (!contents) {
					mihowrtUi.notify(_('Subscription returned empty config.'), 'error');
					return;
				}

				stageSubscriptionSettings(value, result);

				mihowrtUi.notify(_('Subscription loaded into editor. Validate & apply to save.'), 'info');
			}).catch(e => {
				mihowrtUi.notify(_('Unable to fetch subscription: %s').format(e.message), 'error');
			});
			};

			const saveConfig = async function() {
				if (controlsBusy())
					return;

				saveInFlight = true;
				updateControlDisabledState();
				try {
					if (!editor)
						throw new Error(_('Editor is still loading. Please try again in a moment.'));

					const value = configHelper.editorContentForSave(editor.getValue());
					if (value !== savedConfigContent) {
						await backendHelper.saveConfig(value);
						savedConfigContent = await syncEditorToPersistedConfig(value);
					}
					await persistPendingSubscriptionSettings(value);
					mihowrtUi.notify(_('Configuration saved. Apply it when ready.'), 'info');
				}
				catch (e) {
					mihowrtUi.notify(_('Unable to save configuration: %s').format(e.message), 'error');
				}
				finally {
					saveInFlight = false;
					updateControlDisabledState();
				}
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
					const configChanged = value !== savedConfigContent;
					if (!configChanged) {
						try {
							await persistPendingSubscriptionSettings(value);
						}
						catch (e) {
							mihowrtUi.notify(_('Unable to save subscription settings: %s').format(e.message), 'error');
							return;
						}
					}

				let wasRunning = false;
				try {
					wasRunning = (await readServiceState()).running;
				}
				catch (e) {
					mihowrtUi.notify(_('Unable to determine service state before apply: %s').format(e.message), 'error');
					return;
				}

					const applyResult = configChanged
						? await backendHelper.applyConfig(value)
						: await backendHelper.applyActiveConfig();
					if (configChanged)
						savedConfigContent = await syncEditorToPersistedConfig(value);

				const persistPendingSubscriptionAfterApply = async function() {
					try {
						await persistPendingSubscriptionSettings(value);
					}
					catch (e) {
						mihowrtUi.notify(_('Configuration saved, but subscription settings were not saved: %s').format(e.message), 'warning');
					}
				};

				if (!applyResult.restartRequired) {
					await persistPendingSubscriptionAfterApply();
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

					await persistPendingSubscriptionAfterApply();
					mihowrtUi.notify(_('Service restarted successfully.'), 'info');
				}
				else {
					await persistPendingSubscriptionAfterApply();
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

			const pageChildren = [
				E('h2', _('Subscription')),
				E('p', { class: 'cbi-section-descr' }, _('Download a subscription or edit the active YAML manually. Every save is validated before it reaches disk.')),
				E('div', { class: 'cbi-section' }, [
					E('h3', _('Subscription source')),
					E('div', {
					style: 'margin-bottom: 15px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px;'
				}, [
				(subscriptionUrlInput = E('input', {
					type: 'url',
					value: String(subscriptionState.subscriptionUrl || ''),
					placeholder: _('Subscription URL'),
						style: 'flex: 1 1 360px; min-width: 220px; max-width: 100%;',
						input: updateControlDisabledState
				})),
				E('label', {
					style: 'display:flex; align-items:center; gap:6px;'
				}, [
					(subscriptionOverrideInput = E('input', {
						type: 'checkbox',
						checked: !!subscriptionState.subscriptionIntervalOverride,
						change: updateSubscriptionIntervalInputState
					})),
					_('Override interval')
				]),
				(subscriptionIntervalInput = E('input', {
					type: 'number',
					min: '0',
					step: '1',
					value: subscriptionDisplayInterval(subscriptionState),
					placeholder: _('Hours'),
					style: 'width: 90px;',
					'data-manual-interval': String(subscriptionState.subscriptionUpdateInterval || ''),
					'data-header-interval': String(subscriptionState.subscriptionHeaderInterval || subscriptionState.subscriptionEffectiveInterval || ''),
					'data-header-url': String(subscriptionState.subscriptionUrl || '')
				})),
				(subscriptionSaveButton = E('button', {
					class: 'btn',
					click: saveSubscription
				}, _('Save Settings'))),
				(subscriptionFetchButton = E('button', {
					class: 'btn cbi-button-action',
					click: fetchSubscription
				}, _('Fetch'))),
					(subscriptionAutoUpdateBadge = E('span', {
						class: 'label ' + (subscriptionState.subscriptionAutoUpdateEnabled ? 'success' : 'warning')
					}, subscriptionState.subscriptionAutoUpdateEnabled ? _('Auto-update enabled') : _('Auto-update disabled')))
					])
				])
			];

		pageChildren.push(subscriptionAutoUpdateReasonNode = E('p', {
			class: 'cbi-section-descr',
			style: !subscriptionState.subscriptionAutoUpdateEnabled && subscriptionState.subscriptionAutoUpdateReason ? '' : 'display:none;'
		}, !subscriptionState.subscriptionAutoUpdateEnabled ? String(subscriptionState.subscriptionAutoUpdateReason || '') : []));

			pageChildren.push(subscriptionManualRestartNode = E('p', {
				class: 'alert-message warning',
				style: subscriptionState.subscriptionManualRestartRequired ? '' : 'display:none;'
		}, subscriptionState.subscriptionManualRestartRequired
			? subscriptionState.subscriptionManualRestartReason || _('Mihomo API/UI settings changed. Manual service restart is required.')
			: []));

			pageChildren.push(
				E('div', { class: 'cbi-section' }, [
					E('h3', _('Active YAML configuration')),
					editorNode,
					E('div', { style: 'display:flex; justify-content:flex-end; flex-wrap:wrap; gap:8px; margin-top:15px;' }, [
						(saveConfigButton = E('button', {
							class: 'btn',
							click: saveConfig
						}, _('Save'))),
					(saveApplyButton = E('button', {
						class: 'btn cbi-button-apply',
						click: saveAndApply
					}, _('Save & Apply')))
					])
				])
			);

		const page = E(pageChildren);

			applySubscriptionState(subscriptionState);
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
