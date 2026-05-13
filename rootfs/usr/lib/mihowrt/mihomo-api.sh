#!/bin/ash

MIHOMO_API_REASON=""
MIHOMO_API_HTTP_CODE=""

mihomo_api_live_state_file() {
	printf '%s\n' "${MIHOMO_API_LIVE_STATE_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/mihomo-api.live.json}"
}

mihomo_api_set_reason() {
	MIHOMO_API_REASON="$1"
	MIHOMO_API_HTTP_CODE="${2:-}"
}

mihomo_api_reload_host() {
	local host="$1"

	case "$host" in
	0.0.0.0 | 127.0.0.1)
		printf '%s' '127.0.0.1'
		;;
	*)
		mihomo_api_set_reason "Mihomo external-controller host is not safe for hot reload"
		return 1
		;;
	esac
}

mihomo_api_url_from_controller() {
	local controller="$1"
	local host="" port="" safe_host=""

	controller="$(trim "$controller")"
	[ -n "$controller" ] || {
		mihomo_api_set_reason "Mihomo external-controller is not configured"
		return 1
	}

	case "$controller" in
	https://*)
		mihomo_api_set_reason "Mihomo HTTPS controller hot reload is unsupported"
		return 1
		;;
	http://*)
		controller="${controller#http://}"
		;;
	*://*)
		mihomo_api_set_reason "Mihomo controller transport is unsupported"
		return 1
		;;
	esac

	case "$controller" in
	*/* | *[[:space:]]*)
		mihomo_api_set_reason "Mihomo controller address is unsupported"
		return 1
		;;
	esac

	case "$controller" in
	\[*\]:*)
		host="${controller%%\]*}"
		host="${host#\[}"
		port="${controller##*\]:}"
		;;
	*:*)
		host="${controller%:*}"
		port="${controller##*:}"
		;;
	*)
		mihomo_api_set_reason "Mihomo controller port is missing"
		return 1
		;;
	esac

	port="$(trim "$port")"
	is_valid_port "$port" || {
		mihomo_api_set_reason "Mihomo controller port is invalid"
		return 1
	}

	host="$(mihomo_api_reload_host "$(trim "$host")")" || return 1
	case "$host" in
	*:*)
		safe_host="[$host]"
		;;
	*)
		safe_host="$host"
		;;
	esac

	printf 'http://%s:%s' "$safe_host" "$port"
}

mihomo_api_socket_path() {
	local socket="$1"
	local clash_dir="${CLASH_DIR:-/opt/clash}"

	socket="$(trim "$socket")"
	[ -n "$socket" ] || {
		mihomo_api_set_reason "Mihomo Unix controller socket is empty"
		return 1
	}

	case "$socket" in
	*://* | *[[:cntrl:]]*)
		mihomo_api_set_reason "Mihomo Unix controller socket path is unsupported"
		return 1
		;;
	/*)
		printf '%s' "$socket"
		;;
	*)
		printf '%s/%s' "$clash_dir" "$socket"
		;;
	esac
}

mihomo_hot_reload_supported() {
	local config_json="$1"
	local controller="" controller_unix="" socket_path="" base_url=""

	MIHOMO_API_REASON=""
	MIHOMO_API_HTTP_CODE=""

	require_command jq || return 1
	controller="$(printf '%s\n' "$config_json" | jq -r '.external_controller // ""')" || {
		mihomo_api_set_reason "Failed to read Mihomo controller from config"
		return 1
	}
	controller_unix="$(printf '%s\n' "$config_json" | jq -r '.external_controller_unix // ""')" || {
		mihomo_api_set_reason "Failed to read Mihomo Unix controller from config"
		return 1
	}

	if [ -n "$controller_unix" ]; then
		socket_path="$(mihomo_api_socket_path "$controller_unix")" || return 1
		[ -n "$socket_path" ]
		return $?
	fi

	base_url="$(mihomo_api_url_from_controller "$controller")" || return 1
	[ -n "$base_url" ]
}

mihomo_api_live_state_save() {
	local config_json="$1"
	local state_file="" tmp_file=""

	require_command jq || return 1
	state_file="$(mihomo_api_live_state_file)"
	mkdir -p "$(dirname "$state_file")" || return 1
	tmp_file="${state_file}.tmp.$$"

	printf '%s\n' "$config_json" | jq -c '{
		external_controller: (.external_controller // ""),
		external_controller_tls: (.external_controller_tls // ""),
		external_controller_unix: (.external_controller_unix // ""),
		external_controller_pipe: (.external_controller_pipe // ""),
		secret: (.secret // ""),
		external_controller_cors: (.external_controller_cors // ""),
		external_doh_server: (.external_doh_server // ""),
		api_tls: (.api_tls // ""),
		external_ui: (.external_ui // ""),
		external_ui_name: (.external_ui_name // "")
	}' >"$tmp_file" || {
		rm -f "$tmp_file"
		return 1
	}

	mv -f "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
}

mihomo_api_live_state_save_current() {
	local config_json=""

	command -v read_config_json >/dev/null 2>&1 || return 1
	config_json="$(read_config_json 2>/dev/null)" || return 1
	mihomo_api_live_state_save "$config_json"
}

mihomo_api_live_state_read() {
	local state_file=""

	require_command jq || return 1
	state_file="$(mihomo_api_live_state_file)"
	[ -r "$state_file" ] || return 1
	jq -c '{
		external_controller: (.external_controller // ""),
		external_controller_tls: (.external_controller_tls // ""),
		external_controller_unix: (.external_controller_unix // ""),
		external_controller_pipe: (.external_controller_pipe // ""),
		secret: (.secret // ""),
		external_controller_cors: (.external_controller_cors // ""),
		external_doh_server: (.external_doh_server // ""),
		api_tls: (.api_tls // ""),
		external_ui: (.external_ui // ""),
		external_ui_name: (.external_ui_name // "")
	}' "$state_file"
}

mihomo_api_live_or_config_json() {
	local fallback_json="$1"
	local live_json=""

	live_json="$(mihomo_api_live_state_read 2>/dev/null || true)"
	if [ -n "$live_json" ] && mihomo_hot_reload_supported "$live_json"; then
		printf '%s\n' "$live_json"
		return 0
	fi

	printf '%s\n' "$fallback_json"
}

mihomo_api_live_state_clear() {
	rm -f "$(mihomo_api_live_state_file)"
}

mihomo_hot_reload_config() {
	local config_json="$1"
	local config_path="${2:-${CLASH_CONFIG:-/opt/clash/config.yaml}}"
	local force="${3:-0}" force_query="false"
	local controller="" controller_unix="" secret="" base_url="" socket_path=""
	local payload="" body_file="" http_code="" curl_rc=0
	local timeout="${MIHOMO_API_TIMEOUT:-6}"

	MIHOMO_API_REASON=""
	MIHOMO_API_HTTP_CODE=""

	case "$timeout" in
	'' | *[!0-9]*)
		timeout=6
		;;
	esac
	case "$force" in
	1 | true | yes)
		force_query="true"
		;;
	esac

	have_command curl || {
		mihomo_api_set_reason "curl is unavailable for Mihomo API reload"
		return 2
	}
	require_command jq || return 2

	controller="$(printf '%s\n' "$config_json" | jq -r '.external_controller // ""')" || {
		mihomo_api_set_reason "Failed to read Mihomo controller from active config"
		return 2
	}
	controller_unix="$(printf '%s\n' "$config_json" | jq -r '.external_controller_unix // ""')" || {
		mihomo_api_set_reason "Failed to read Mihomo Unix controller from active config"
		return 2
	}
	secret="$(printf '%s\n' "$config_json" | jq -r '.secret // ""')" || {
		mihomo_api_set_reason "Failed to read Mihomo controller secret from active config"
		return 2
	}
	if [ -n "$controller_unix" ]; then
		socket_path="$(mihomo_api_socket_path "$controller_unix")" || return 2
		base_url="http://127.0.0.1"
	else
		base_url="$(mihomo_api_url_from_controller "$controller")" || return 2
	fi

	case "$config_path" in
	/*) ;;
	*)
		mihomo_api_set_reason "Mihomo reload config path must be absolute"
		return 2
		;;
	esac

	payload="$(jq -nc --arg path "$config_path" '{path: $path}')" || {
		mihomo_api_set_reason "Failed to build Mihomo reload payload"
		return 2
	}
	body_file="$(mktemp /tmp/mihowrt-api.XXXXXX)" || {
		mihomo_api_set_reason "Failed to allocate Mihomo API response file"
		return 2
	}

	if [ -n "$socket_path" ]; then
		http_code="$(curl -sS --connect-timeout 2 --max-time "$timeout" \
			--unix-socket "$socket_path" \
			-o "$body_file" -w '%{http_code}' \
			-X PUT "$base_url/configs?force=$force_query" \
			-H 'Content-Type: application/json' \
			--data "$payload" 2>/dev/null)" || curl_rc=$?
	elif [ -n "$secret" ]; then
		http_code="$(curl -sS --connect-timeout 2 --max-time "$timeout" \
			-o "$body_file" -w '%{http_code}' \
			-X PUT "$base_url/configs?force=$force_query" \
			-H "Authorization: Bearer $secret" \
			-H 'Content-Type: application/json' \
			--data "$payload" 2>/dev/null)" || curl_rc=$?
	else
		http_code="$(curl -sS --connect-timeout 2 --max-time "$timeout" \
			-o "$body_file" -w '%{http_code}' \
			-X PUT "$base_url/configs?force=$force_query" \
			-H 'Content-Type: application/json' \
			--data "$payload" 2>/dev/null)" || curl_rc=$?
	fi

	rm -f "$body_file"
	MIHOMO_API_HTTP_CODE="$http_code"

	if [ "$curl_rc" -ne 0 ]; then
		mihomo_api_set_reason "Mihomo API reload request failed" "$http_code"
		return 2
	fi

	case "$http_code" in
	20[0-9])
		return 0
		;;
	esac

	mihomo_api_set_reason "Mihomo API reload returned HTTP $http_code" "$http_code"
	return 2
}
