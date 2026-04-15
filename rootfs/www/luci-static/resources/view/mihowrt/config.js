'use strict';
'require view';
'require fs';
'require ui';
'require rpc';
'require mihowrt.ace as aceHelper';
'require mihowrt.backend as backendHelper';

const SERVICE_NAME = 'mihowrt';
const SERVICE_SCRIPT = '/etc/init.d/mihowrt';

let startStopButton = null;
let editor = null;

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

async function getServiceStatus() {
	try {
		const services = await callServiceList(SERVICE_NAME);
		const instances = services[SERVICE_NAME]?.instances || {};
		return Object.values(instances)[0]?.running || false;
	} catch (e) {
		return false;
	}
}

async function runServiceAction(action) {
	const result = await fs.exec(SERVICE_SCRIPT, [action]);
	if (result.code !== 0) {
		throw new Error(execErrorDetail(result));
	}
}

function execErrorDetail(result) {
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

async function handleServiceAction(steps, errorMsg) {
	if (startStopButton)
		startStopButton.disabled = true;

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
		ui.addNotification(null, E('p', errorMsg.format(detail)), 'error');
		return false;
	}
	finally {
		if (startStopButton)
			startStopButton.disabled = false;
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
		if (await getServiceStatus() === targetStatus)
			return true;
		await new Promise(resolve => setTimeout(resolve, 500));
	}
	return false;
}

async function toggleService() {
	const running = await getServiceStatus();
	if (running) {
		if (!(await stopService()))
			return;
		await pollStatus(false);
	}
	else {
		if (!(await startService()))
			return;
		await pollStatus(true);
	}
	window.location.reload();
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

	if (host === '0.0.0.0' || host === '::' || host === '')
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
		if (!(await getServiceStatus())) {
			ui.addNotification(null, E('p', _('Service is not running.')), 'error');
			return;
		}

		const config = await backendHelper.readConfig();
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
			ui.addNotification(null, E('p', _('Popup was blocked. Please allow popups for this site.')), 'warning');
	}
	catch (e) {
		ui.addNotification(null, E('p', _('Failed to open dashboard: %s').format(e.message)), 'error');
	}
}

async function initializeAceEditor(node, content) {
	editor = await aceHelper.createEditor(node, 'yaml', {
		fontSize: '12px'
	});
	editor.setValue(content, -1);
}

function formatConfigErrors(errors) {
	return (errors || []).filter(Boolean).join('; ');
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read('/opt/clash/config.yaml'), '');
	},

	render: async function(config) {
		const running = await getServiceStatus();
		const editorNode = E('div', {
			id: 'editor',
			style: 'width: 100%; height: 640px; margin-bottom: 15px;'
		});

		const saveAndApply = async function() {
			if (startStopButton)
				startStopButton.disabled = true;

			try {
				if (!editor) {
					ui.addNotification(null, E('p', _('Editor is still loading. Please try again in a moment.')), 'warning');
					return;
				}

				const oldValue = await fs.read('/opt/clash/config.yaml');
				const value = editor.getValue().trim() + '\n';
				await fs.write('/opt/clash/config.yaml', value);

				const testResult = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-t']);
				if (testResult.code !== 0) {
					await fs.write('/opt/clash/config.yaml', oldValue);
					ui.addNotification(null, E('p', _('Configuration test failed: %s').format(execErrorDetail(testResult))), 'error');
					return;
				}

				const configState = await backendHelper.readConfig();
				if (configState.errors.length) {
					await fs.write('/opt/clash/config.yaml', oldValue);
					ui.addNotification(null, E('p', _('Configuration requirements failed: %s').format(formatConfigErrors(configState.errors))), 'error');
					return;
				}

				ui.addNotification(null, E('p', _('Configuration saved successfully.')), 'info');

				if (await getServiceStatus()) {
					const reloadResult = await fs.exec(SERVICE_SCRIPT, ['reload']);
					if (reloadResult.code !== 0) {
						ui.addNotification(null, E('p', _('Service reload failed: %s').format(execErrorDetail(reloadResult))), 'error');
						return;
					}

					ui.addNotification(null, E('p', _('Service reloaded successfully.')), 'info');
				}

				window.location.reload();
			}
			catch (e) {
				ui.addNotification(null, E('p', _('Unable to save contents: %s').format(e.message)), 'error');
			}
			finally {
				if (startStopButton)
					startStopButton.disabled = false;
			}
		};

		const page = E([
			E('div', {
				style: 'margin-bottom: 20px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px;'
			}, [
				E('button', {
					class: 'btn',
					click: openDashboard
				}, _('Open Dashboard')),
				(startStopButton = E('button', {
					class: 'btn',
					click: toggleService
				}, running ? _('Stop Service') : _('Start Service'))),
				E('span', {
					class: 'label',
					style: 'padding: 4px 10px; border-radius: 3px; font-size: 12px; color: white; background-color: ' + (running ? '#5cb85c' : '#d9534f') + ';'
				}, running ? _('MihoWRT is running') : _('MihoWRT stopped'))
			]),
			E('h2', _('MihoWRT Configuration')),
			E('p', { class: 'cbi-section-descr' }, _('Raw Mihomo YAML config. Save validates Mihomo syntax and required policy values before apply.')),
			editorNode,
			E('div', { style: 'text-align: center; margin-top: 15px; margin-bottom: 20px;' }, [
				E('button', {
					class: 'btn cbi-button-apply',
					click: saveAndApply
				}, _('Save & Apply Configuration'))
			])
		]);

		window.requestAnimationFrame(() => {
			initializeAceEditor(editorNode, config).catch(e => {
				ui.addNotification(null, E('p', _('Unable to initialize editor: %s').format(e.message)), 'error');
			});
		});

		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
