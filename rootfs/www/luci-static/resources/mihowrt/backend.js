'use strict';
'require baseclass';
'require fs';
'require mihowrt.exec as execHelper';

const READ_BACKEND = '/usr/bin/mihowrt-read';
const WRITE_BACKEND = '/usr/bin/mihowrt';

function emptyConfigState() {
	// Keep LuCI rendering stable when backend JSON is partial.
	return {
		configPath: '/opt/clash/config.yaml',
		dnsPort: '',
		mihomoDnsListen: '',
		port: '',
		socksPort: '',
		mixedPort: '',
		redirPort: '',
		tproxyPort: '',
		routingMark: '',
		enhancedMode: '',
		catchFakeip: false,
		fakeIpRange: '',
		externalController: '',
		externalControllerTls: '',
		externalControllerUnix: '',
		secret: '',
		externalUi: '',
		externalUiName: '',
		errors: []
	};
}

function emptyStatusState() {
	// Mirror status-json while keeping a UI-safe shape.
	return {
		available: false,
		serviceEnabled: false,
		serviceRunning: false,
		serviceReady: false,
		dnsBackupExists: false,
		dnsBackupValid: false,
		dnsRecoveryBackupActive: false,
		dnsRecoveryBackupValid: false,
		routeStatePresent: false,
		routeTableIdEffective: '',
		routeRulePriorityEffective: '',
		enabled: false,
		dnsHijack: false,
		routeTableId: 'auto',
		routeRulePriority: 'auto',
		policyMode: 'direct-first',
		disableQuic: false,
		sourceNetworkInterfaces: [],
		alwaysProxyDstCount: 0,
		alwaysProxySrcCount: 0,
		directDstCount: 0,
		alwaysProxyDstRemoteUrlCount: 0,
		alwaysProxySrcRemoteUrlCount: 0,
		directDstRemoteUrlCount: 0,
		runtimeSnapshotPresent: false,
		runtimeSnapshotValid: false,
		runtimeLiveStatePresent: false,
		runtimeSafeReloadReady: false,
		runtimeMatchesDesired: false,
		active: {
			present: false,
			enabled: false,
			dnsHijack: false,
			mihomoDnsPort: '',
			mihomoDnsListen: '',
			mihomoTproxyPort: '',
			mihomoRoutingMark: '',
			routeTableId: '',
			routeRulePriority: '',
			policyMode: 'direct-first',
			disableQuic: false,
			dnsEnhancedMode: '',
			catchFakeip: false,
			fakeIpRange: '',
			sourceNetworkInterfaces: [],
			alwaysProxyDstCount: 0,
			alwaysProxySrcCount: 0,
			directDstCount: 0
		},
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

function emptySubscriptionState() {
	return {
		subscriptionUrl: '',
		subscriptionIntervalOverride: false,
		subscriptionUpdateInterval: '',
		subscriptionHeaderInterval: '',
		subscriptionEffectiveInterval: '',
		subscriptionAutoUpdateEnabled: false,
		subscriptionLastUpdate: '',
		subscriptionNextUpdate: '',
		subscriptionAutoUpdateReason: '',
		subscriptionManualRestartRequired: false,
		subscriptionManualRestartReason: '',
		errors: []
	};
}

function tempConfigPath() {
	// Candidate configs live under /tmp until backend validation moves them.
	const suffix = '%s-%s'.format(Date.now(), Math.floor(Math.random() * 0x100000000).toString(16));
	return `/tmp/mihowrt-config.${suffix}`;
}

async function removeTempFile(path) {
	// Missing temp files are not errors; backend may already have removed them.
	try {
		await fs.remove(path);
	}
	catch (e) {
		if (e && (e.name === 'NotFoundError' || /not found/i.test(e.message || '')))
			return;
		throw e;
	}
}

function assignConfigState(state, payload) {
	// Convert backend snake_case fields into LuCI camelCase state.
	state.configPath = String(payload?.config_path || state.configPath);
	state.dnsPort = String(payload?.dns_port || '');
	state.mihomoDnsListen = String(payload?.mihomo_dns_listen || '');
	state.port = String(payload?.port || '');
	state.socksPort = String(payload?.socks_port || '');
	state.mixedPort = String(payload?.mixed_port || '');
	state.redirPort = String(payload?.redir_port || '');
	state.tproxyPort = String(payload?.tproxy_port || '');
	state.routingMark = String(payload?.routing_mark || '');
	state.enhancedMode = String(payload?.enhanced_mode || '');
	state.catchFakeip = !!payload?.catch_fakeip;
	state.fakeIpRange = String(payload?.fake_ip_range || '');
	state.externalController = String(payload?.external_controller || '');
	state.externalControllerTls = String(payload?.external_controller_tls || '');
	state.externalControllerUnix = String(payload?.external_controller_unix || '');
	state.secret = String(payload?.secret || '');
	state.externalUi = String(payload?.external_ui || '');
	state.externalUiName = String(payload?.external_ui_name || '');
	state.errors = Array.isArray(payload?.errors) ? payload.errors.map(String) : [];
	return state;
}

function assignServiceState(state, payload) {
	// Keep polling state small and predictable.
	state.available = true;
	state.serviceEnabled = !!payload?.service_enabled;
	state.serviceRunning = !!payload?.service_running;
	state.serviceReady = !!payload?.service_ready;
	state.errors = Array.isArray(payload?.errors) ? payload.errors.map(String) : [];
	return state;
}

async function readBackendJson(args, state, assignPayload) {
	// Read calls use mihowrt-read so read ACL cannot execute mutating commands.
	try {
		const result = await fs.exec(READ_BACKEND, args);

		if (result.code !== 0) {
			state.errors = [ execHelper.errorDetail(result) ];
			return state;
		}

		return assignPayload(state, JSON.parse(result.stdout || '{}'));
	}
	catch (e) {
		state.errors = [ e.message || String(e) ];
		return state;
	}
}

function assignSubscriptionState(state, payload) {
	state.subscriptionUrl = String(payload.subscription_url || '');
	state.subscriptionIntervalOverride = !!payload.subscription_interval_override;
	state.subscriptionUpdateInterval = String(payload.subscription_update_interval || '');
	state.subscriptionHeaderInterval = String(payload.subscription_header_interval || '');
	state.subscriptionEffectiveInterval = String(payload.subscription_effective_interval || '');
	state.subscriptionAutoUpdateEnabled = !!payload.subscription_auto_update_enabled;
	state.subscriptionLastUpdate = String(payload.subscription_last_update || '');
	state.subscriptionNextUpdate = String(payload.subscription_next_update || '');
	state.subscriptionAutoUpdateReason = String(payload.subscription_auto_update_reason || '');
	state.subscriptionManualRestartRequired = !!payload.subscription_manual_restart_required;
	state.subscriptionManualRestartReason = String(payload.subscription_manual_restart_reason || '');
	return state;
}

function assignStatusState(state, payload) {
	// Missing fields stay harmless defaults for diagnostics UI.
	state.available = true;
	state.serviceEnabled = !!payload.service_enabled;
	state.serviceRunning = !!payload.service_running;
	state.serviceReady = !!payload.service_ready;
	state.dnsBackupExists = !!payload.dns_backup_exists;
	state.dnsBackupValid = !!payload.dns_backup_valid;
	state.dnsRecoveryBackupActive = !!payload.dns_recovery_backup_active;
	state.dnsRecoveryBackupValid = !!payload.dns_recovery_backup_valid;
	state.routeStatePresent = !!payload.route_state_present;
	state.routeTableIdEffective = String(payload.route_table_id_effective || '');
	state.routeRulePriorityEffective = String(payload.route_rule_priority_effective || '');
	state.enabled = !!payload.enabled;
	state.dnsHijack = !!payload.dns_hijack;
	state.routeTableId = String(payload.route_table_id || 'auto');
	state.routeRulePriority = String(payload.route_rule_priority || 'auto');
	state.policyMode = String(payload.policy_mode || 'direct-first');
	state.disableQuic = !!payload.disable_quic;
	state.sourceNetworkInterfaces = Array.isArray(payload.source_network_interfaces) ? payload.source_network_interfaces.map(String) : [];
	state.alwaysProxyDstCount = Number(payload.always_proxy_dst_count || 0);
	state.alwaysProxySrcCount = Number(payload.always_proxy_src_count || 0);
	state.directDstCount = Number(payload.direct_dst_count || 0);
	state.alwaysProxyDstRemoteUrlCount = Number(payload.always_proxy_dst_remote_url_count || 0);
	state.alwaysProxySrcRemoteUrlCount = Number(payload.always_proxy_src_remote_url_count || 0);
	state.directDstRemoteUrlCount = Number(payload.direct_dst_remote_url_count || 0);
	state.runtimeSnapshotPresent = !!payload.runtime_snapshot_present;
	state.runtimeSnapshotValid = !!payload.runtime_snapshot_valid;
	state.runtimeLiveStatePresent = !!payload.runtime_live_state_present;
	state.runtimeSafeReloadReady = !!payload.runtime_safe_reload_ready;
	state.runtimeMatchesDesired = !!payload.runtime_matches_desired;
	state.active = Object.assign(state.active, {
		present: !!payload.active?.present,
		enabled: !!payload.active?.enabled,
		dnsHijack: !!payload.active?.dns_hijack,
		mihomoDnsPort: String(payload.active?.mihomo_dns_port || ''),
		mihomoDnsListen: String(payload.active?.mihomo_dns_listen || ''),
		mihomoTproxyPort: String(payload.active?.mihomo_tproxy_port || ''),
		mihomoRoutingMark: String(payload.active?.mihomo_routing_mark || ''),
		routeTableId: String(payload.active?.route_table_id || ''),
		routeRulePriority: String(payload.active?.route_rule_priority || ''),
		policyMode: String(payload.active?.policy_mode || 'direct-first'),
		disableQuic: !!payload.active?.disable_quic,
		dnsEnhancedMode: String(payload.active?.dns_enhanced_mode || ''),
		catchFakeip: !!payload.active?.catch_fakeip,
		fakeIpRange: String(payload.active?.fakeip_range || ''),
		sourceNetworkInterfaces: Array.isArray(payload.active?.source_network_interfaces) ? payload.active.source_network_interfaces.map(String) : [],
		alwaysProxyDstCount: Number(payload.active?.always_proxy_dst_count || 0),
		alwaysProxySrcCount: Number(payload.active?.always_proxy_src_count || 0),
		directDstCount: Number(payload.active?.direct_dst_count || 0)
	});
	state.config = assignConfigState(emptyConfigState(), payload.config || {});
	state.errors = Array.isArray(payload.errors) ? payload.errors.map(String) : [];
	return state;
}

function assignLogState(state, payload) {
	state.available = !!payload.available;
	state.limit = Number(payload.limit || state.limit);
	state.lines = Array.isArray(payload.lines) ? payload.lines.map(String) : [];
	return state;
}

function assignApplyResult(payload) {
	const restartRequired = payload?.restart_required;

	return {
		action: String(payload?.action || 'restart_required'),
		saved: payload?.saved !== false,
		restartRequired: restartRequired == null ? true : !!restartRequired,
		hotReloaded: !!payload?.hot_reloaded,
		policyReloaded: !!payload?.policy_reloaded,
		reason: String(payload?.reason || ''),
		httpCode: String(payload?.http_code || '')
	};
}

function subscriptionFetchErrorDetail(error) {
	const kind = String(error?.kind || '');
	const message = String(error?.message || '').trim();
	const httpCode = error?.http_code == null ? '' : String(error.http_code);

	if (httpCode)
		return _('HTTP %s').format(httpCode);
	if (kind === 'timeout')
		return _('timeout');
	return message || kind || _('unknown error');
}

async function readConfig(configPath) {
	// Read current or candidate config through the read-only backend.
	const args = [ 'read-config' ];

	if (configPath)
		args.push(configPath);

	return readBackendJson(args, emptyConfigState(), assignConfigState);
}

async function readLiveApiConfig() {
	// Dashboard must use the controller Mihomo listens on now, not pending config.
	return readBackendJson([ 'live-api-json' ], emptyConfigState(), assignConfigState);
}

return baseclass.extend({
	readConfig: readConfig,
	readLiveApiConfig: readLiveApiConfig,

	// Write candidate config to /tmp and let the write backend validate/apply it.
	applyConfig: async function(configContents) {
		const tempPath = tempConfigPath();

		await fs.write(tempPath, String(configContents ?? ''));
		try {
			const result = await fs.exec(WRITE_BACKEND, [ 'apply-config', tempPath ]);

			if (result.code !== 0)
				throw new Error(execHelper.errorDetail(result));

			return assignApplyResult(JSON.parse(result.stdout || '{}'));
		}
		finally {
			await removeTempFile(tempPath);
		}
	},

	// Restart via backend helper that can skip duplicate Mihomo validation only
	// for the exact config already validated by applyConfig.
	restartValidatedService: async function() {
		const result = await fs.exec(WRITE_BACKEND, [ 'restart-validated-service' ]);

		if (result.code !== 0)
			throw new Error(execHelper.errorDetail(result));
	},

	readSubscriptionUrl: async function() {
		return readBackendJson([ 'subscription-json' ], emptySubscriptionState(), assignSubscriptionState);
	},

	saveSubscriptionUrl: async function(subscriptionUrl) {
		const result = await fs.exec(WRITE_BACKEND, [ 'set-subscription-url', String(subscriptionUrl ?? '') ]);

		if (result.code !== 0)
			throw new Error(execHelper.errorDetail(result));
	},

	saveSubscriptionSettings: async function(subscriptionUrl, overrideInterval, updateInterval, headerInterval, hotReloadSupported) {
		const args = [
			'set-subscription-settings',
			String(subscriptionUrl ?? ''),
			overrideInterval ? '1' : '0',
			String(updateInterval ?? '')
		];

		if (headerInterval != null)
			args.push(String(headerInterval));
		if (hotReloadSupported != null) {
			if (headerInterval == null)
				args.push('');
			args.push(hotReloadSupported ? '1' : '0');
		}

		const result = await fs.exec(WRITE_BACKEND, args);
		if (result.code !== 0)
			throw new Error(execHelper.errorDetail(result));
	},

	fetchSubscription: async function(subscriptionUrl) {
		const payload = await fs.exec_direct(WRITE_BACKEND, [ 'fetch-subscription-json', String(subscriptionUrl ?? '') ], 'json');

		if (!payload?.ok)
			throw new Error(subscriptionFetchErrorDetail(payload?.error || {}));

		return {
			content: String(payload.content || ''),
			profileUpdateInterval: String(payload.profile_update_interval || ''),
			hotReloadSupported: payload.hot_reload_supported !== false,
			hotReloadReason: String(payload.hot_reload_reason || '')
		};
	},

	// Backend prints updated=1 only when effective remote list content changed.
	updatePolicyLists: async function() {
		const result = await fs.exec(WRITE_BACKEND, [ 'update-policy-lists' ]);

		if (result.code !== 0)
			throw new Error(execHelper.errorDetail(result));

		return /^updated=1$/m.test(String(result.stdout || ''));
	},

	syncPolicyRemoteAutoUpdate: async function() {
		const result = await fs.exec(WRITE_BACKEND, [ 'sync-policy-remote-auto-update' ]);

		if (result.code !== 0)
			throw new Error(execHelper.errorDetail(result));
	},

	readServiceState: async function() {
		return readBackendJson([ 'service-state-json' ], {
			available: false,
			serviceEnabled: false,
			serviceRunning: false,
			serviceReady: false,
			errors: []
		}, assignServiceState);
	},

	readStatus: async function() {
		return readBackendJson([ 'status-json' ], emptyStatusState(), assignStatusState);
	},

	readLogs: async function(limit) {
		const args = [ 'logs-json' ];

		if (limit)
			args.push(String(limit));

		return readBackendJson(args, emptyLogState(), assignLogState);
	}
});
