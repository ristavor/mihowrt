#!/bin/ash

# Mihomo REST API over the unix socket. Mihomo requires no auth on this socket,
# which lives in a mode-700 directory.

API_DELAY_URL="${API_DELAY_URL:-https://www.gstatic.com/generate_204}"

# api_request <method> <path> [json-body] [timeout]
api_request() {
	local method="$1" path="$2" body="${3:-}" timeout="${4:-5}"

	set -- -fsS -m "$timeout" --unix-socket "$MIHOMO_SOCKET_TMPFS" -X "$method"
	[ -z "$body" ] || set -- "$@" -H 'Content-Type: application/json' -d "$body"
	curl "$@" "http://localhost$path"
}

uri_encode() {
	printf '%s' "$1" | mihowrt-json uri
}

# Mihomo answers DNS (any rcode, NXDOMAIN included) => alive.
api_dns_probe() {
	api_request GET "/dns/query?name=$WATCHDOG_PROBE_DOMAIN&type=A" "" 5 2>/dev/null |
		mihowrt-json has Status >/dev/null 2>&1
}

# The controller answers (Mihomo is up, whatever its DNS does).
api_alive() {
	api_request GET /version "" 2 >/dev/null 2>&1
}

api_reload() {
	api_request PUT "/configs?force=true" "$(mihowrt-json build object --arg path "$1")" 60 >/dev/null
}

# Proxy groups: [{name, type, now, all, fixed, delays}] in config order (GLOBAL
# lists them so; the proxies map is sorted by name). URLTest/Fallback can be
# pinned to a server ("fixed"); LoadBalance cannot be switched. delays: last
# Mihomo check per server (0 = no response); unchecked servers are absent.
api_proxies_json() {
	api_request GET /proxies | mihowrt-json proxies
}

# An empty name unpins a URLTest/Fallback group (automatic choice again).
api_select() {
	if [ -z "$2" ]; then
		api_request DELETE "/proxies/$(uri_encode "$1")" >/dev/null
	else
		api_request PUT "/proxies/$(uri_encode "$1")" "$(mihowrt-json build object --arg name "$2")" >/dev/null
	fi
}

# {server: ms} for servers that answered. Mihomo replies 504 when none did:
# that is a result (all "no response"), not an error.
api_group_delay() {
	local out code

	out="$(curl -sS -m 15 --unix-socket "$MIHOMO_SOCKET_TMPFS" -w '\n%{http_code}' \
		"http://localhost/group/$(uri_encode "$1")/delay?url=$(uri_encode "$API_DELAY_URL")&timeout=5000")" || return 1
	code="${out##*
}"
	case "$code" in
	2??) printf '%s\n' "${out%
*}" ;;
	504) printf '{}\n' ;;
	*) printf 'Mihomo API error: HTTP %s\n' "$code" >&2; return 1 ;;
	esac
}
