'use strict';
'require baseclass';
'require fs';

const BACKEND = '/usr/bin/mihowrt';

function emptyConfigState() {
	return {
		configPath: '/opt/clash/config.yaml',
		dnsPort: '',
		mihomoDnsListen: '',
		tproxyPort: '',
		routingMark: '',
		enhancedMode: '',
		catchFakeip: false,
		fakeIpRange: '',
		externalController: '',
		externalControllerTls: '',
		secret: '',
		externalUi: '',
		externalUiName: '',
		errors: []
	};
}

function execErrorDetail(result) {
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

async function readConfig(configPath) {
	const state = emptyConfigState();
	const args = [ 'read-config' ];

	if (configPath)
		args.push(configPath);

	try {
		const result = await fs.exec(BACKEND, args);

		if (result.code !== 0) {
			state.errors = [ execErrorDetail(result) ];
			return state;
		}

		const payload = JSON.parse(result.stdout || '{}');
		state.configPath = String(payload.config_path || state.configPath);
		state.dnsPort = String(payload.dns_port || '');
		state.mihomoDnsListen = String(payload.mihomo_dns_listen || '');
		state.tproxyPort = String(payload.tproxy_port || '');
		state.routingMark = String(payload.routing_mark || '');
		state.enhancedMode = String(payload.enhanced_mode || '');
		state.catchFakeip = !!payload.catch_fakeip;
		state.fakeIpRange = String(payload.fake_ip_range || '');
		state.externalController = String(payload.external_controller || '');
		state.externalControllerTls = String(payload.external_controller_tls || '');
		state.secret = String(payload.secret || '');
		state.externalUi = String(payload.external_ui || '');
		state.externalUiName = String(payload.external_ui_name || '');
		state.errors = Array.isArray(payload.errors) ? payload.errors.map(String) : [];
		return state;
	}
	catch (e) {
		state.errors = [ e.message || String(e) ];
		return state;
	}
}

return baseclass.extend({
	readConfig: readConfig,

	applyConfig: async function(configPath) {
		const result = await fs.exec(BACKEND, [ 'apply-config', configPath ]);

		if (result.code !== 0)
			throw new Error(execErrorDetail(result));
	}
});
