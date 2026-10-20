#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh route.sh

ROUTE_STATE_FILE="$tmpdir/route.state"
calls="$tmpdir/calls"
: >"$calls"
ip() {
	echo "ip $*" >>"$calls"
	case "$*" in
	"-4 route show table all") echo "local 1.2.3.4 dev lo table 200 proto kernel" ;;
	"-4 rule show") printf '0:\tfrom all lookup local\n10000:\tfrom all lookup 201\n' ;;
	"-4 rule del"*) return 1 ;;
	"-6 rule del"*) return 1 ;;
	esac
	return 0
}
route_families() {
	echo 4
	[ "${WITH_V6:-0}" = 1 ] && echo 6
	return 0
}

route_setup || fail "setup must succeed"
assert_file_contains "$ROUTE_STATE_FILE" "TABLE=202" "first free table skips used ids"
assert_file_contains "$ROUTE_STATE_FILE" "PRIORITY=10001" "first free priority"
assert_file_contains "$calls" "ip -4 rule add fwmark 0x08000000/0x08000000 lookup 202 priority 10001" "v4 rule added"
assert_file_not_contains "$calls" "ip -6" "no IPv6 calls without IPv6"
pass "route v6 skipped without IPv6"

: >"$calls"
WITH_V6=1 route_setup
assert_file_contains "$calls" "ip -6 route replace local default dev lo table 202" "v6 local route"
assert_file_contains "$calls" "ip -6 rule add fwmark 0x08000000/0x08000000 lookup 202 priority 10001" "v6 rule"
pass "route v6 added with IPv6"

: >"$calls"
WITH_V6=1 route_cleanup
assert_file_contains "$calls" "ip -4 rule del fwmark 0x00001000/0x00001000 lookup 202 priority 10001" "old mark rule removed"
assert_file_contains "$calls" "ip -6 route flush table 202" "v6 table flushed"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "state removed"
pass "route cleanup"

printf 'ROUTE_TABLE_ID=210\nROUTE_RULE_PRIORITY=10500\n' >"$ROUTE_STATE_FILE"
route_state_read || fail "0.7 state must be readable"
assert_eq "210:10500" "$ROUTE_TABLE:$ROUTE_PRIORITY" "0.7 state keys"
pass "old state format"
