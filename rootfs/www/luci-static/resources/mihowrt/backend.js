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

function emptyStatusState() {
	return {
		serviceEnabled: false,
		serviceRunning: false,
		dnsBackupExists: false,
		dnsBackupValid: false,
		routeStatePresent: false,
		routeTableIdEffective: '',
		routeRulePriorityEffective: '',
		enabled: false,
		dnsHijack: false,
		routeTableId: 'auto',
		routeRulePriority: 'auto',
		disableQuic: false,
		sourceNetworkInterfaces: [],
		alwaysProxyDstCount: 0,
		alwaysProxySrcCount: 0,
		config: emptyConfigState(),
		errors: []
	};
}

function emptyLogState() {
	return {
		available: false,
		limit: 200,
		lines: [],
		errors: []
	};
}

function execErrorDetail(result) {
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

function assignConfigState(state, payload) {
	state.configPath = String(payload?.config_path || state.configPath);
	state.dnsPort = String(payload?.dns_port || '');
	state.mihomoDnsListen = String(payload?.mihomo_dns_listen || '');
	state.tproxyPort = String(payload?.tproxy_port || '');
	state.routingMark = String(payload?.routing_mark || '');
	state.enhancedMode = String(payload?.enhanced_mode || '');
	state.catchFakeip = !!payload?.catch_fakeip;
	state.fakeIpRange = String(payload?.fake_ip_range || '');
	state.externalController = String(payload?.external_controller || '');
	state.externalControllerTls = String(payload?.external_controller_tls || '');
	state.secret = String(payload?.secret || '');
	state.externalUi = String(payload?.external_ui || '');
	state.externalUiName = String(payload?.external_ui_name || '');
	state.errors = Array.isArray(payload?.errors) ? payload.errors.map(String) : [];
	return state;
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
		return assignConfigState(state, payload);
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
	},

	readStatus: async function() {
		const state = emptyStatusState();

		try {
			const result = await fs.exec(BACKEND, [ 'status-json' ]);

			if (result.code !== 0) {
				state.errors = [ execErrorDetail(result) ];
				return state;
			}

			const payload = JSON.parse(result.stdout || '{}');
			state.serviceEnabled = !!payload.service_enabled;
			state.serviceRunning = !!payload.service_running;
			state.dnsBackupExists = !!payload.dns_backup_exists;
			state.dnsBackupValid = !!payload.dns_backup_valid;
			state.routeStatePresent = !!payload.route_state_present;
			state.routeTableIdEffective = String(payload.route_table_id_effective || '');
			state.routeRulePriorityEffective = String(payload.route_rule_priority_effective || '');
			state.enabled = !!payload.enabled;
			state.dnsHijack = !!payload.dns_hijack;
			state.routeTableId = String(payload.route_table_id || 'auto');
			state.routeRulePriority = String(payload.route_rule_priority || 'auto');
			state.disableQuic = !!payload.disable_quic;
			state.sourceNetworkInterfaces = Array.isArray(payload.source_network_interfaces) ? payload.source_network_interfaces.map(String) : [];
			state.alwaysProxyDstCount = Number(payload.always_proxy_dst_count || 0);
			state.alwaysProxySrcCount = Number(payload.always_proxy_src_count || 0);
			state.config = assignConfigState(emptyConfigState(), payload.config || {});
			state.errors = Array.isArray(payload.errors) ? payload.errors.map(String) : [];
			return state;
		}
		catch (e) {
			state.errors = [ e.message || String(e) ];
			return state;
		}
	},

	readLogs: async function(limit) {
		const state = emptyLogState();
		const args = [ 'logs-json' ];

		if (limit)
			args.push(String(limit));

		try {
			const result = await fs.exec(BACKEND, args);

			if (result.code !== 0) {
				state.errors = [ execErrorDetail(result) ];
				return state;
			}

			const payload = JSON.parse(result.stdout || '{}');
			state.available = !!payload.available;
			state.limit = Number(payload.limit || state.limit);
			state.lines = Array.isArray(payload.lines) ? payload.lines.map(String) : [];
			return state;
		}
		catch (e) {
			state.errors = [ e.message || String(e) ];
			return state;
		}
	}
});
