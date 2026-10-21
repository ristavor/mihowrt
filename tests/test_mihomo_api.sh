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
[ "${CURL_EXIT:-0}" = 0 ] || exit "$CURL_EXIT"
printf '%s' "$CURL_BODY"
C
chmod +x "$tmpdir/bin/curl"
export CURL_LOG="$tmpdir/curl.log"

CURL_BODY='{"Status":0,"Answer":[]}' api_dns_probe || fail "NOERROR must pass"
CURL_BODY='{"Status":3}' api_dns_probe || fail "NXDOMAIN must pass"
if CURL_EXIT=7 CURL_BODY='' api_dns_probe; then fail "socket failure must fail"; fi
if CURL_BODY='garbage' api_dns_probe; then fail "non-JSON must fail"; fi
assert_file_contains "$CURL_LOG" "Authorization: Bearer secret-0001" "secret sent"
assert_file_contains "$CURL_LOG" "/dns/query?name=openwrt.org&type=A" "probe path"
pass "dns probe"

body='{"proxies":{"GLOBAL":{"type":"Selector","now":"A","all":["A"]},"Proxy":{"type":"Selector","now":"B","all":["A","B"]},"Auto":{"type":"URLTest","now":"A","all":["A"]},"FB":{"type":"Fallback","now":"A","all":["A"]},"Hid":{"type":"Selector","hidden":true,"now":"A","all":["A"]},"A":{"type":"Vless"}}}'
result="$(CURL_BODY="$body" api_proxies_json)"
assert_eq '[{"name":"Proxy","type":"Selector","now":"B","all":["A","B"],"fixed":""},{"name":"Auto","type":"URLTest","now":"A","all":["A"],"fixed":""},{"name":"FB","type":"Fallback","now":"A","all":["A"],"fixed":""}]' "$result" "group type and fixed fields"
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
