'use strict';
'require view';
'require fs';
'require mihowrt.ace as aceHelper';
'require mihowrt.backend as backendHelper';
'require mihowrt.ui as mihowrtUi';

const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';
const CLASH_CONFIG = '/opt/clash/config.yaml';
const TMP_CONFIG_PREFIX = '/tmp/mihowrt-config';

let startStopButton = null;
let dashboardButton = null;
let saveApplyButton = null;
let serviceStatusBadge = null;
let editor = null;
let serviceActionInFlight = false;
let saveInFlight = false;

function controlsBusy() {
	return serviceActionInFlight || saveInFlight;
}

function updateControlDisabledState() {
	const disabled = controlsBusy();

	if (startStopButton)
		startStopButton.disabled = disabled;
	if (dashboardButton)
		dashboardButton.disabled = disabled;
	if (saveApplyButton)
		saveApplyButton.disabled = disabled;
}

async function runServiceAction(action) {
	const result = await fs.exec(SERVICE_SCRIPT, [action]);
	if (result.code !== 0)
		throw new Error(mihowrtUi.execErrorDetail(result));
}

async function handleServiceAction(steps, errorMsg) {
	serviceActionInFlight = true;
	updateControlDisabledState();

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
	finally {
		serviceActionInFlight = false;
		updateControlDisabledState();
	}
}

async function startService() {
	return handleServiceAction([
		{ action: 'start', rollback: 'stop' },
		{ action: 'enable', rollback: 'disable' }
	], _('Unable to start and enable service: %s'));
}

async function stopService() {
	return handleServiceAction([
		{ action: 'stop', rollback: 'start' },
		{ action: 'disable', rollback: 'enable' }
	], _('Unable to stop and disable service: %s'));
}

async function pollStatus(targetStatus, timeout = 5000) {
	const startTime = Date.now();
	while (Date.now() - startTime < timeout) {
		if (await mihowrtUi.getServiceStatus(SERVICE_NAME) === targetStatus)
			return true;
		await new Promise(resolve => setTimeout(resolve, 500));
	}
	return false;
}

function serviceToggleLabel(running) {
	return running ? _('Stop Service') : _('Start Service');
}

function serviceBadgeText(running) {
	return running ? _('MihoWRT is running') : _('MihoWRT stopped');
}

function serviceBadgeColor(running) {
	return running ? '#5cb85c' : '#d9534f';
}

function applyServiceState(running) {
	if (startStopButton)
		startStopButton.textContent = serviceToggleLabel(running);

	if (serviceStatusBadge) {
		serviceStatusBadge.textContent = serviceBadgeText(running);
		serviceStatusBadge.style.backgroundColor = serviceBadgeColor(running);
	}
}

async function refreshServiceState() {
	const running = await mihowrtUi.getServiceStatus(SERVICE_NAME);
	applyServiceState(running);
	return running;
}

async function toggleService() {
	if (controlsBusy())
		return;

	const running = await mihowrtUi.getServiceStatus(SERVICE_NAME);
	const targetStatus = !running;

	if (running) {
		if (!(await stopService()))
			return;
	}
	else {
		if (!(await startService()))
			return;
	}

	if (!(await pollStatus(targetStatus))) {
		await refreshServiceState();
		mihowrtUi.notify(targetStatus
			? _('Service start timed out. Check diagnostics and system log.')
			: _('Service stop timed out. Refresh page and verify runtime state.'), 'warning');
		return;
	}

	applyServiceState(targetStatus);
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
		if (!(await mihowrtUi.getServiceStatus(SERVICE_NAME))) {
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

		const url = `${scheme}//${hostPort.host}:${hostPort.port}${uiPath}?${qp.toString()}`;
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

function makeTempConfigPath() {
	const suffix = '%d.%s'.format(Date.now(), Math.random().toString(16).slice(2));
	return '%s.%s.yaml'.format(TMP_CONFIG_PREFIX, suffix);
}

async function removeTempConfig(configPath) {
	if (!configPath)
		return;

	const result = await fs.exec('/bin/sh', ['-c', 'rm -f -- "$1"', 'sh', configPath]);
	if (result.code !== 0)
		throw new Error(mihowrtUi.execErrorDetail(result));
}

async function restartRunningService(wasRunning) {
	if (!wasRunning)
		return { restarted: false, error: null };
	const restartResult = await fs.exec(SERVICE_SCRIPT, ['restart']);
	return {
		restarted: restartResult.code === 0,
		error: restartResult.code === 0 ? null : mihowrtUi.execErrorDetail(restartResult)
	};
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read(CLASH_CONFIG), '');
	},

	render: async function(config) {
		const running = await mihowrtUi.getServiceStatus(SERVICE_NAME);
		const editorNode = E('div', {
			id: 'editor',
			style: 'width: 100%; height: 640px; margin-bottom: 15px;'
		});

		const saveAndApply = async function() {
			let tempConfigPath = null;

			if (controlsBusy())
				return;

			saveInFlight = true;
			updateControlDisabledState();

			try {
				if (!editor) {
					mihowrtUi.notify(_('Editor is still loading. Please try again in a moment.'), 'warning');
					return;
				}

				const wasRunning = await mihowrtUi.getServiceStatus(SERVICE_NAME);
				const value = editorContentForSave(editor.getValue());
				tempConfigPath = makeTempConfigPath();
				await fs.write(tempConfigPath, value);
				await backendHelper.applyConfig(tempConfigPath);
				tempConfigPath = null;
				mihowrtUi.notify(_('Configuration saved successfully.'), 'info');

				const restartState = await restartRunningService(wasRunning);
				if (restartState.error) {
					await refreshServiceState();
					mihowrtUi.notify(_('Service restart failed: %s').format(restartState.error), 'error');
					return;
				}
				if (restartState.restarted) {
					if (!(await pollStatus(true)))
						mihowrtUi.notify(_('Service restart is still in progress. Check diagnostics if it does not recover soon.'), 'warning');

					await refreshServiceState();
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
				if (tempConfigPath) {
					try {
						await removeTempConfig(tempConfigPath);
					}
					catch (e) {
						mihowrtUi.notify(_('Failed to remove temporary config: %s').format(e.message), 'warning');
					}
				}

				saveInFlight = false;
				updateControlDisabledState();
			}
		};

		const page = E([
			E('div', {
				style: 'margin-bottom: 20px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px;'
			}, [
				(dashboardButton = E('button', {
					class: 'btn',
					click: openDashboard
				}, _('Open Dashboard'))),
				(startStopButton = E('button', {
					class: 'btn',
					click: toggleService
				}, serviceToggleLabel(running))),
				(serviceStatusBadge = E('span', {
					class: 'label',
					style: 'padding: 4px 10px; border-radius: 3px; font-size: 12px; color: white; background-color: ' + serviceBadgeColor(running) + ';'
				}, serviceBadgeText(running)))
			]),
			E('h2', _('MihoWRT Configuration')),
			E('p', { class: 'cbi-section-descr' }, _('Raw Mihomo YAML config. Save validates Mihomo syntax and required policy values before apply.')),
				editorNode,
				E('div', { style: 'text-align: center; margin-top: 15px; margin-bottom: 20px;' }, [
					(saveApplyButton = E('button', {
						class: 'btn cbi-button-apply',
						click: saveAndApply
					}, _('Save & Apply Configuration')))
				])
			]);

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
