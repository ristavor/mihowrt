#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh mihomo-api.sh
setup_runtime_paths "$tmpdir"

API_SECRET="secret-0001"

cat >"$tmpdir/bin/curl" <<'C'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
printf '%s\n' "$@" >>"$CURL_ARGV_LOG"
[ "${CURL_EXIT:-0}" = 0 ] || exit "$CURL_EXIT"
if [ -n "${CURL_BODY_FILE:-}" ]; then
	cat "$CURL_BODY_FILE"
else
	printf '%s' "$CURL_BODY"
fi
case " $* " in *" -w "*) printf '\n%s' "${CURL_CODE:-200}" ;; esac
C
chmod +x "$tmpdir/bin/curl"
export CURL_LOG="$tmpdir/curl.log"
export CURL_ARGV_LOG="$tmpdir/curl-argv.log"

secret_in_argv=0
for request in get put group-delay; do
	: >"$CURL_ARGV_LOG"
	case "$request" in
	get) CURL_BODY='{}' api_request GET /version >/dev/null ;;
	put) CURL_BODY='{}' api_request PUT /configs '{"path":"/tmp/config.yaml"}' 60 >/dev/null ;;
	group-delay) CURL_BODY='{}' api_group_delay 'My Group' >/dev/null ;;
	esac
	if grep -qF -e Authorization -e "$API_SECRET" "$CURL_ARGV_LOG"; then
		printf 'FAIL: %s exposes authorization or controller secret in curl argv\n' "$request" >&2
		secret_in_argv=1
	fi
done
[[ "$secret_in_argv" = 0 ]] || fail 'unix-socket curl argv must not contain authorization or controller secret'
pass 'unix-socket requests omit authorization and controller secret from curl argv'

CURL_BODY='{"Status":0,"Answer":[]}' api_dns_probe || fail "NOERROR must pass"
CURL_BODY='{"Status":3}' api_dns_probe || fail "NXDOMAIN must pass"
if CURL_EXIT=7 CURL_BODY='' api_dns_probe; then fail "socket failure must fail"; fi
if CURL_BODY='garbage' api_dns_probe; then fail "non-JSON must fail"; fi
assert_file_contains "$CURL_LOG" "/dns/query?name=openwrt.org&type=A" "probe path"
pass "dns probe"

body='{"proxies":{"GLOBAL":{"type":"Selector","now":"A","all":["Proxy","Auto","FB","A"]},"Proxy":{"type":"Selector","now":"B","all":["A","B"]},"Auto":{"type":"URLTest","now":"A","all":["A"]},"FB":{"type":"Fallback","now":"A","all":["A"]},"Hid":{"type":"Selector","hidden":true,"now":"A","all":["A"]},"A":{"type":"Vless"}}}'
result="$(CURL_BODY="$body" api_proxies_json)"
assert_eq '[{"name":"Proxy","type":"Selector","now":"B","all":["A","B"],"fixed":"","delays":{}},{"name":"Auto","type":"URLTest","now":"A","all":["A"],"fixed":"","delays":{}},{"name":"FB","type":"Fallback","now":"A","all":["A"],"fixed":"","delays":{}}]' "$result" "group type and fixed fields"
pass "proxies filtered"

: >"$CURL_LOG"
CURL_BODY='' api_select 'My Group' 'Node 1'
assert_file_contains "$CURL_LOG" "/proxies/My%20Group" "group name encoded"
assert_file_contains "$CURL_LOG" '{"name":"Node 1"}' "selection body"
pass "select proxy"

: >"$CURL_LOG"
CURL_BODY='' api_select 'My Group' ''
assert_file_contains "$CURL_LOG" 'DELETE' "unfix method"
assert_file_contains "$CURL_LOG" '/proxies/My%20Group' "unfix encoded path"

CURL_BODY='{"proxies":{"G":{"type":"URLTest","now":"B","fixed":"A","all":["A","B"]}}}' api_proxies_json | jq -e '.[0].type == "URLTest" and .[0].fixed == "A" and (.[0] | has("auto") | not)' >/dev/null || fail "pinned URLTest API fields"

body='{"proxies":{"GLOBAL":{"all":["FB","Auto","A"]},"Proxy":{"type":"Selector","all":["A"]},"Auto":{"type":"URLTest","all":["A"]},"FB":{"type":"Fallback","all":["A"]},"A":{"type":"Direct"}}}'
assert_eq 'FB,Auto,Proxy' "$(CURL_BODY="$body" api_proxies_json | jq -r 'map(.name)|join(",")')" 'GLOBAL order then missing groups'
CURL_BODY='{"proxies":{"G":{"type":"Selector","now":"A","all":["A","B","C"],"history":[]},"A":{"type":"Http","history":[{"delay":5},{"delay":42}]},"B":{"type":"Http","history":[{"delay":0}]},"C":{"type":"Http","history":[]}}}' api_proxies_json | jq -e '.[0].delays == {"A":42,"B":0}' >/dev/null || fail "last Mihomo history delay per server, none when unchecked"
assert_eq '{"A":12}' "$(CURL_BODY='{"A":12}' api_group_delay G)" "group delay result"
assert_eq '{}' "$(CURL_CODE=504 CURL_BODY='{"message":"get delay: all proxies timeout"}' api_group_delay G)" "no server answered: empty result, not an error"
if CURL_CODE=401 CURL_BODY='{"message":"Unauthorized"}' api_group_delay G >/dev/null 2>&1; then fail "other HTTP errors must fail"; fi
if CURL_EXIT=7 CURL_BODY='' api_group_delay G >/dev/null 2>&1; then fail "socket failure must fail"; fi
pass 'GLOBAL group ordering'

jq -nc '
	[range(3000) | "Node-\(.)"] as $nodes
	| {proxies: (
		(reduce $nodes[] as $n ({}; .[$n] = {type: "Direct"}))
		+ {GLOBAL: {type: "Selector", all: ($nodes + ["Zulu", "Middle", "Alpha", "Zulu", "missing", "GLOBAL", "Alpha"])},
		   Alpha: {type: "LoadBalance", now: "Node-0", all: ["Node-0"]},
		   Middle: {type: "Fallback", now: "Node-0", all: ["Node-0"]},
		   Zulu: {type: "URLTest", now: "Node-0", all: ["Node-0"]}}
	)}' >"$tmpdir/large-proxies.json"
result="$(CURL_BODY_FILE="$tmpdir/large-proxies.json" api_proxies_json)"
assert_eq '[{"name":"Zulu","type":"URLTest","now":"Node-0","all":["Node-0"],"fixed":"","delays":{}},{"name":"Middle","type":"Fallback","now":"Node-0","all":["Node-0"],"fixed":"","delays":{}},{"name":"Alpha","type":"LoadBalance","now":"Node-0","all":["Node-0"],"fixed":"","delays":{}}]' "$result" '3000 proxies: three groups once in GLOBAL order'
pass 'large proxy answer'

: >"$CURL_LOG"
CURL_BODY='{}' api_group_delay G >/dev/null
assert_file_contains "$CURL_LOG" '-m 15 ' 'group-delay stays below browser timeout'
pass 'group-delay timeout'
