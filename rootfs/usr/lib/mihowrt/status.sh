#!/bin/ash

# Read-only status for LuCI and the CLI.

service_enabled() {
	local link=""

	for link in /etc/rc.d/S*mihowrt; do
		[ -e "$link" ] && return 0
	done
	return 1
}

json_bool() {
	if "$@"; then echo true; else echo false; fi
}

service_state() {
	if service_running; then
		if [ -f "$DEGRADED_FILE" ]; then echo degraded
		elif [ -f "$RUNNING_MARKER" ]; then echo running
		else echo starting
		fi
	elif [ -f "$USER_STOP_FILE" ]; then echo stopped
	elif [ -f "$LAST_ERROR_FILE" ]; then echo failed
	else echo stopped
	fi
}

health_json() {
	case "$(cat "$HEALTH_FILE" 2>/dev/null)" in
	ok) echo true ;;
	fail) echo false ;;
	*) echo null ;;
	esac
}

service_state_json() {
	jq -nc --argjson running "$(json_bool service_running)" \
		--argjson enabled "$(json_bool service_enabled)" \
		--arg state "$(service_state)" \
		--argjson dns_ok "$(health_json)" \
		--arg last_error "$(cat "$LAST_ERROR_FILE" 2>/dev/null)" \
		'{running: $running, enabled: $enabled, state: $state, dns_ok: $dns_ok, last_error: $last_error}'
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

# Last recorded check of the installed YAML: true, false or null (unknown).
# Status never runs the core itself (slow and memory-hungry on routers).
config_valid_json() {
	if [ -f "$CONFIG_OK_FILE" ] && ! [ "$CLASH_CONFIG" -nt "$CONFIG_OK_FILE" ]; then
		echo true
	elif [ -f "$CONFIG_ERR_FILE" ] && ! [ "$CLASH_CONFIG" -nt "$CONFIG_ERR_FILE" ]; then
		echo false
	else
		echo null
	fi
}

status_json() {
	local running=false policy=false config_valid=null config_error="" errors=""

	settings_load 2>/dev/null || errors="Invalid MihoWRT settings"
	service_running && running=true
	if [ "$running" = true ]; then
		nft_active && route_active && policy=true
	fi
	config_valid="$(config_valid_json)"
	[ "$config_valid" = false ] && config_error="$(cat "$CONFIG_ERR_FILE" 2>/dev/null)"
	route_state_read 2>/dev/null

	jq -nc \
		--argjson running "$running" \
		--argjson enabled "$(json_bool service_enabled)" \
		--argjson dns_ok "$(health_json)" \
		--arg state "$(service_state)" \
		--arg last_error "$(cat "$LAST_ERROR_FILE" 2>/dev/null)" \
		--argjson policy "$policy" \
		--argjson config_valid "$config_valid" \
		--argjson config_backup "$(json_bool test -f "$CLASH_CONFIG_BACKUP")" \
		--arg config_error "$config_error" \
		--arg dns_mode "${DNS_MODE:-}" \
		--arg version "$PKG_VERSION" \
		--arg core "$(core_version)" \
		--arg mode "${POLICY_MODE:-}" \
		--arg url "${SUBSCRIPTION_URL:-}" \
		--arg custom "$(dns_global_custom_servers | tr '\n' ' ')" \
		--arg table "${ROUTE_TABLE:-}" \
		--arg priority "${ROUTE_PRIORITY:-}" \
		--arg interfaces "${SOURCE_INTERFACES:-}" \
		--arg dst "$(lists_count dst)" --arg src "$(lists_count src)" --arg direct "$(lists_count direct)" \
		--arg direct_src "$(lists_count direct_src)" \
		--arg errors "$errors" '
		def words: split(" ") | map(select(length > 0));
		{running: $running, enabled: $enabled, state: $state, last_error: $last_error, version: $version, core: $core,
		 core_installed: ($core != ""), subscription_configured: ($url != ""),
		 config_valid: $config_valid, config_backup: $config_backup, config_error: $config_error, dns_mode: $dns_mode, dns_ok: $dns_ok, policy_active: $policy,
		 mode: $mode, interfaces: ($interfaces | words),
		 custom_dns_servers: ($custom | words),
		 lists: {dst: ($dst | tonumber), src: ($src | tonumber), direct: ($direct | tonumber), direct_src: ($direct_src | tonumber)},
		 route: {table: $table, priority: $priority},
		 errors: ([$errors] | map(select(length > 0)))}'
}

# Provider profile for the Traffic page: mode, DNS, provider settings,
# the user's overrides and provider list state.
profile_json() {
	settings_load || return 1
	jq -nc \
		--arg mode "$POLICY_MODE" --arg dns "$DNS_MODE" \
		--arg provider "$(profile_entries set)" \
		--arg overrides "$PROVIDER_OVERRIDES" \
		--argjson dst_provided "$(json_bool lists_provided dst)" \
		--arg dst_provider "$(lists_provider_entries dst | wc -l | tr -d ' ')" \
		--arg dst_own "$(lists_own_count dst)" --arg dst_source "$DST_LIST_SOURCE" \
		--argjson direct_provided "$(json_bool lists_provided direct)" \
		--arg direct_provider "$(lists_provider_entries direct | wc -l | tr -d ' ')" \
		--arg direct_own "$(lists_own_count direct)" --arg direct_source "$DIRECT_LIST_SOURCE" '
		def words: split(" ") | map(select(length > 0));
		def list($p; $n; $o; $s): {provided: $p, provider_count: ($n | tonumber), own_count: ($o | tonumber), source: $s};
		{mode: $mode, dns: $dns,
		 provider: ($provider | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add // {}),
		 overrides: ($overrides | words),
		 lists: {dst: list($dst_provided; $dst_provider; $dst_own; $dst_source),
		         direct: list($direct_provided; $direct_provider; $direct_own; $direct_source)}}'
}

diagnostics_json() {
	local package="" conflicts="" flash="" ram="" rss="" pid="" ports=""

	for package in $CONFLICT_PACKAGES; do
		if apk info -e "$package" >/dev/null 2>&1; then
			conflicts="${conflicts}${package}
"
		fi
	done
	flash="$(df -kP /opt/clash 2>/dev/null | awk 'END { if (NR > 1 && $4 ~ /^[0-9]+$/) print $4 }')"
	ram="$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	if pid="$(service_pid)"; then
		rss="$(awk '$1 == "VmRSS:" && $2 ~ /^[0-9]+$/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)"
	fi
	ports="$(awk '
		/^[[:space:]]*(#.*)?$/ { next }
		/^[^[:space:]]/ { auth_block = 0 }
		/^([\042\047]?authentication[\042\047]?)[[:space:]]*:/ {
			value = $0
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			sub(/[[:space:]]+$/, "", value)
			if (value == "" || value == "null" || value == "~")
				auth_block = 1
			else if (value !~ /^\[[[:space:]]*\]$/)
				auth = 1
		}
		auth_block && /^[[:space:]]+-[[:space:]]/ { auth = 1 }
		/^(mixed-port|port|socks-port|redir-port)[[:space:]]*:/ {
			value = $0
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			gsub(/^[[:space:]\042\047]+|[[:space:]\042\047]+$/, "", value)
			if (value ~ /^[0-9]+$/ && value + 0 > 0 && !seen[value + 0]++)
				ports = ports sprintf("%.0f\n", value + 0)
		}
		END { if (!auth) printf "%s", ports }
	' "$RUNTIME_CONFIG" 2>/dev/null)"
	jq -nc --arg conflicts "$conflicts" --arg flash "$flash" --arg ram "$ram" \
		--arg rss "$rss" --arg ports "$ports" '
		def lines: split("\n") | map(select(length > 0));
		{conflicts: ($conflicts | lines), flash_free_kb: ($flash | tonumber? // null),
		 ram_available_kb: ($ram | tonumber? // null), mihomo_rss_kb: ($rss | tonumber? // null),
		 open_proxy_ports: ($ports | lines | map(tonumber))}'
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
