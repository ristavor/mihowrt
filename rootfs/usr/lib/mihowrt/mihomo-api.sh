#!/bin/ash

# Mihomo REST API over the unix socket. The socket is root-only, and the
# secret is still sent so the TCP controller and the socket share one contract.

API_DELAY_URL="${API_DELAY_URL:-https://www.gstatic.com/generate_204}"

# api_request <method> <path> [json-body] [timeout]
api_request() {
	local method="$1" path="$2" body="${3:-}" timeout="${4:-5}"

	if [ -n "$body" ]; then
		curl -fsS -m "$timeout" --unix-socket "$MIHOMO_SOCKET_TMPFS" \
			-H "Authorization: Bearer $API_SECRET" -H 'Content-Type: application/json' \
			-X "$method" -d "$body" "http://localhost$path"
	else
		curl -fsS -m "$timeout" --unix-socket "$MIHOMO_SOCKET_TMPFS" \
			-H "Authorization: Bearer $API_SECRET" -X "$method" "http://localhost$path"
	fi
}

uri_encode() {
	printf '%s' "$1" | jq -sRr @uri
}

# Mihomo answers DNS (any rcode, NXDOMAIN included) => alive.
api_dns_probe() {
	api_request GET "/dns/query?name=$WATCHDOG_PROBE_DOMAIN&type=A" "" 5 2>/dev/null |
		jq -e 'has("Status")' >/dev/null 2>&1
}

api_reload() {
	api_request PUT "/configs?force=true" "$(jq -nc --arg p "$1" '{path: $p}')" 60 >/dev/null
}

# Selector groups the user can switch: [{name, now, all}].
api_proxies_json() {
	api_request GET /proxies | jq -c '
		[.proxies | to_entries[]
		 | select(.key != "GLOBAL" and (.value.hidden | not)
		     and (.value.type | IN("Selector", "URLTest", "Fallback", "LoadBalance")))
		 | {name: .key, now: .value.now, all: .value.all, auto: (.value.type != "Selector")}]'
}

api_select() {
	api_request PUT "/proxies/$(uri_encode "$1")" "$(jq -nc --arg n "$2" '{name: $n}')" >/dev/null
}

api_group_delay() {
	api_request GET "/group/$(uri_encode "$1")/delay?url=$(uri_encode "$API_DELAY_URL")&timeout=5000" "" 30
}
