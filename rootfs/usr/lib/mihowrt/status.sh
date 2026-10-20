#!/bin/ash

# Read-only status for LuCI and the CLI.

service_enabled() {
	/etc/init.d/mihowrt enabled >/dev/null 2>&1
}

json_bool() {
	if "$@"; then echo true; else echo false; fi
}

service_state_json() {
	printf '{"running":%s,"enabled":%s}\n' "$(json_bool service_running)" "$(json_bool service_enabled)"
}

# Plain upstream servers in dnsmasq bypass Mihomo; domain-scoped ones are fine.
dns_global_custom_servers() {
	local server=""

	for server in $(dns_custom_servers); do
		case "$server" in
		/*) ;;
		*) echo "$server" ;;
		esac
	done
}

status_json() {
	local running=false dns_ok=null policy=false config_valid=false errors=""

	settings_load 2>/dev/null || errors="Invalid MihoWRT settings"
	service_running && running=true
	if [ "$running" = true ]; then
		dns_ok="$(json_bool api_dns_probe)"
		nft_active && route_active && policy=true
	fi
	if [ -s "$RUNTIME_CONFIG" ]; then
		config_valid=true
	elif [ -r "$CLASH_CONFIG" ] && [ -x "$CLASH_BIN" ] &&
		mihomo_config_generate "$CLASH_CONFIG" "$PKG_TMP_DIR/status.yaml" 2>/dev/null &&
		mihomo_config_test "$PKG_TMP_DIR/status.yaml" 2>/dev/null; then
		config_valid=true
	fi
	rm -f "$PKG_TMP_DIR/status.yaml"
	route_state_read 2>/dev/null

	jq -nc \
		--argjson running "$running" \
		--argjson enabled "$(json_bool service_enabled)" \
		--argjson dns_ok "$dns_ok" \
		--argjson policy "$policy" \
		--argjson config_valid "$config_valid" \
		--arg version "$PKG_VERSION" \
		--arg core "$(core_version)" \
		--arg mode "${POLICY_MODE:-}" \
		--arg url "${SUBSCRIPTION_URL:-}" \
		--arg custom "$(dns_global_custom_servers | tr '\n' ' ')" \
		--arg table "${ROUTE_TABLE:-}" \
		--arg priority "${ROUTE_PRIORITY:-}" \
		--arg interfaces "${SOURCE_INTERFACES:-}" \
		--arg dst "$(lists_count dst)" --arg src "$(lists_count src)" --arg direct "$(lists_count direct)" \
		--arg errors "$errors" '
		def words: split(" ") | map(select(length > 0));
		{running: $running, enabled: $enabled, version: $version, core: $core,
		 core_installed: ($core != ""), subscription_configured: ($url != ""),
		 config_valid: $config_valid, dns_ok: $dns_ok, policy_active: $policy,
		 mode: $mode, interfaces: ($interfaces | words),
		 custom_dns_servers: ($custom | words),
		 lists: {dst: ($dst | tonumber), src: ($src | tonumber), direct: ($direct | tonumber)},
		 route: {table: $table, priority: $priority},
		 errors: ([$errors] | map(select(length > 0)))}'
}

logs_json() {
	local limit="${1:-200}" lines=""

	is_uint "$limit" && [ "$limit" -ge 1 ] || limit=200
	[ "$limit" -le 1000 ] || limit=1000
	have_command logread || {
		jq -nc '{available: false, lines: []}'
		return 0
	}
	lines="$(logread 2>/dev/null | grep -iE 'mihowrt|mihomo|clash' | tail -n "$limit")"
	jq -nc --arg l "$lines" '{available: true, lines: ($l | split("\n") | map(select(length > 0)))}'
}
