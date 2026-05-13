#!/bin/ash

MIHOMO_API_REASON=""
MIHOMO_API_HTTP_CODE=""

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

mihomo_hot_reload_config() {
	local config_json="$1"
	local config_path="${2:-${CLASH_CONFIG:-/opt/clash/config.yaml}}"
	local controller="" secret="" base_url="" payload="" body_file="" http_code="" curl_rc=0
	local timeout="${MIHOMO_API_TIMEOUT:-6}"

	MIHOMO_API_REASON=""
	MIHOMO_API_HTTP_CODE=""

	case "$timeout" in
	'' | *[!0-9]*)
		timeout=6
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
	secret="$(printf '%s\n' "$config_json" | jq -r '.secret // ""')" || {
		mihomo_api_set_reason "Failed to read Mihomo controller secret from active config"
		return 2
	}
	base_url="$(mihomo_api_url_from_controller "$controller")" || return 2

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

	if [ -n "$secret" ]; then
		http_code="$(curl -sS --connect-timeout 2 --max-time "$timeout" \
			-o "$body_file" -w '%{http_code}' \
			-X PUT "$base_url/configs?force=true" \
			-H "Authorization: Bearer $secret" \
			-H 'Content-Type: application/json' \
			--data "$payload" 2>/dev/null)" || curl_rc=$?
	else
		http_code="$(curl -sS --connect-timeout 2 --max-time "$timeout" \
			-o "$body_file" -w '%{http_code}' \
			-X PUT "$base_url/configs?force=true" \
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
