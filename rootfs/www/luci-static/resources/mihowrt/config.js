'use strict';
'require baseclass';

const SERVICE_OK_COLOR = '#5cb85c';
const SERVICE_ERROR_COLOR = '#d9534f';

function errorDetail(state) {
	// Convert backend error arrays into one user-facing message.
	const errors = Array.isArray(state?.errors) ? state.errors.map(String).filter(Boolean) : [];
	return errors.join('; ') || _('unknown error');
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
	return running ? SERVICE_OK_COLOR : SERVICE_ERROR_COLOR;
}

function serviceEnabledBadgeText(enabled) {
	return enabled ? _('Enabled at boot') : _('Disabled at boot');
}

function serviceEnabledBadgeColor(enabled) {
	return enabled ? SERVICE_OK_COLOR : SERVICE_ERROR_COLOR;
}

function normalizeHostPortFromAddr(addr, fallbackHost, fallbackPort) {
	// Keep router hostname as fallback for wildcard/loopback binds.
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
	// Mihomo can expose dashboard as external-ui-name or simple external-ui dir.
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

function dashboardUrl(config, baseHost) {
	// Include Mihomo controller query parameters expected by dashboard UI.
	const ec = config.externalController;
	const ecTls = config.externalControllerTls;
	const secret = config.secret;
	const externalUi = config.externalUi;
	const externalUiName = config.externalUiName;
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

	return `${scheme}//${safeHost}:${hostPort.port}${uiPath}?${qp.toString()}`;
}

async function openDashboard(options) {
	// Avoid opening stale dashboard URL when service/config is not available.
	const serviceName = options.serviceName;
	const serviceScript = options.serviceScript;
	const backendHelper = options.backendHelper;
	const uiHelper = options.uiHelper;
	const windowObject = options.windowObject || window;

	try {
		if (!(await uiHelper.getServiceStatus(serviceName, serviceScript))) {
			uiHelper.notify(_('Service is not running.'), 'error');
			return;
		}

		const config = await backendHelper.readConfig();
		if (config.errors && config.errors.length) {
			uiHelper.notify(_('Unable to open dashboard: %s').format(config.errors.join('; ')), 'error');
			return;
		}

		const newWindow = windowObject.open(dashboardUrl(config, windowObject.location.hostname), '_blank');
		if (!newWindow)
			uiHelper.notify(_('Popup was blocked. Please allow popups for this site.'), 'warning');
	}
	catch (e) {
		uiHelper.notify(_('Failed to open dashboard: %s').format(e.message), 'error');
	}
}

function editorContentForSave(value) {
	return value == null ? '' : String(value);
}

async function restartRunningService(backendHelper, wasRunning) {
	// Restart only if service was running before config apply.
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

function subscriptionUrlInputValue(input) {
	// Trim subscription URL exactly once at UI boundary.
	return String(input?.value || '').trim();
}

return baseclass.extend({
	dashboardUrl: dashboardUrl,
	editorContentForSave: editorContentForSave,
	normalizeHostPortFromAddr: normalizeHostPortFromAddr,
	openDashboard: openDashboard,
	restartRunningService: restartRunningService,
	serviceBadgeColor: serviceBadgeColor,
	serviceBadgeText: serviceBadgeText,
	serviceEnabledBadgeColor: serviceEnabledBadgeColor,
	serviceEnabledBadgeText: serviceEnabledBadgeText,
	serviceEnabledToggleLabel: serviceEnabledToggleLabel,
	serviceStateErrorDetail: errorDetail,
	serviceToggleLabel: serviceToggleLabel,
	subscriptionStateErrorDetail: errorDetail,
	subscriptionUrlInputValue: subscriptionUrlInputValue
});
