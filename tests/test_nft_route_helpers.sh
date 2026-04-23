#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmpbin/logger"
export PATH="$tmpbin:$PATH"

export NFT_TABLE_NAME="mihomo_podkop"
export ROUTE_STATE_FILE="$tmpdir/route.state"
export ROUTE_TABLE_ID_AUTO_MIN="200"
export ROUTE_TABLE_ID_AUTO_MAX="202"
export ROUTE_RULE_PRIORITY_AUTO_MIN="10000"
export ROUTE_RULE_PRIORITY_AUTO_MAX="10002"
export NFT_INTERCEPT_MARK="0x00001000"
export MIHOMO_ROUTE_TABLE_ID=""
export MIHOMO_ROUTE_RULE_PRIORITY=""
net_log="$tmpdir/net.log"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/nft.sh"

log() {
	printf 'log:%s\n' "$*" >>"$net_log"
}

warn() {
	printf 'warn:%s\n' "$*" >>"$net_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$net_log"
}

list_file="$tmpdir/list.txt"
cat > "$list_file" <<'EOF'
# comment
1.1.1.1
bad-entry
2.2.2.0/24
EOF

assert_eq "2" "$(count_valid_list_entries "$list_file")" "count_valid_list_entries should count only valid entries"

NFT_BATCH_FILE="$tmpdir/nft.batch"
nft_emit_ipv4_file_to_set "$list_file" "proxy_dst" NFT_PROXY_DST_COUNT
assert_eq "2" "${NFT_PROXY_DST_COUNT}" "nft_emit_ipv4_file_to_set should return valid entry count"
assert_file_contains "$NFT_BATCH_FILE" "add element inet mihomo_podkop proxy_dst { 1.1.1.1,2.2.2.0/24 }" "nft_emit_ipv4_file_to_set should emit nft batch line"

rm -f "$list_file"
: > "$NFT_BATCH_FILE"
NFT_PROXY_DST_COUNT=99
assert_eq "0" "$(count_valid_list_entries "$list_file")" "count_valid_list_entries should treat missing file as empty list"
nft_emit_ipv4_file_to_set "$list_file" "proxy_dst" NFT_PROXY_DST_COUNT
assert_eq "0" "${NFT_PROXY_DST_COUNT}" "nft_emit_ipv4_file_to_set should treat deleted list file as empty"
[[ ! -s "$NFT_BATCH_FILE" ]] || fail "nft_emit_ipv4_file_to_set should not emit rules for deleted list file"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF

assert_true "policy_route_state_read should parse valid route state" policy_route_state_read
assert_eq "200" "$ROUTE_TABLE_ID_EFFECTIVE" "policy_route_state_read should load table id"
assert_eq "10000" "$ROUTE_RULE_PRIORITY_EFFECTIVE" "policy_route_state_read should load rule priority"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=999
ROUTE_RULE_PRIORITY=bad
EOF

assert_false "policy_route_state_read should reject invalid route state" policy_route_state_read

policy_route_table_id_in_use() {
	[[ "$1" == "200" || "$1" == "201" ]]
}

policy_route_priority_in_use() {
	[[ "$1" == "10000" || "$1" == "10001" ]]
}

assert_eq "202" "$(policy_route_resolve_table_id)" "policy_route_resolve_table_id should pick first free table id"
assert_eq "10002" "$(policy_route_resolve_priority)" "policy_route_resolve_priority should pick first free priority"

policy_route_table_id_in_use() {
	return 0
}

policy_route_priority_in_use() {
	return 0
}

assert_false "policy_route_resolve_table_id should fail when no ids are free" policy_route_resolve_table_id
assert_false "policy_route_resolve_priority should fail when no priorities are free" policy_route_resolve_priority

nft() {
	printf 'nft %s\n' "$*" >>"$net_log"
	case "${1:-}" in
		list)
			if [[ "${TEST_NFT_LIST_RC:-0}" != "0" ]]; then
				return "${TEST_NFT_LIST_RC}"
			fi
			if [[ "${TEST_NFT_TABLE_PRESENT:-0}" = "1" ]]; then
				printf 'table inet %s\n' "$NFT_TABLE_NAME"
			fi
			return 0
			;;
		delete)
			if [[ "${TEST_NFT_DELETE_RC:-0}" != "0" ]]; then
				return "${TEST_NFT_DELETE_RC}"
			fi
			TEST_NFT_TABLE_PRESENT=0
			export TEST_NFT_TABLE_PRESENT
			return 0
			;;
	esac
	return 0
}

ip() {
	printf 'ip %s\n' "$*" >>"$net_log"
	case "${1:-}:${2:-}" in
		rule:show)
			if [[ "${TEST_RULE_SHOW_RC:-0}" != "0" ]]; then
				return "${TEST_RULE_SHOW_RC}"
			fi
			if [[ "${TEST_RULE_PRESENT:-0}" = "1" ]]; then
				printf '%s: from all fwmark %s/%s lookup %s\n' \
					"${TEST_ROUTE_RULE_PRIORITY:-10000}" \
					"$NFT_INTERCEPT_MARK" \
					"$NFT_INTERCEPT_MARK" \
					"${TEST_ROUTE_TABLE_ID:-200}"
			fi
			return 0
			;;
		rule:del)
			if [[ "${TEST_RULE_DEL_RC:-0}" != "0" ]]; then
				return "${TEST_RULE_DEL_RC}"
			fi
			if [[ "${TEST_RULE_PRESENT:-0}" = "1" ]]; then
				TEST_RULE_PRESENT=0
				export TEST_RULE_PRESENT
				return 0
			fi
			return 2
			;;
		route:show)
			if [[ "${TEST_ROUTE_SHOW_RC:-0}" != "0" ]]; then
				return "${TEST_ROUTE_SHOW_RC}"
			fi
			if [[ "${3:-}" == "table" && "${TEST_ROUTE_PRESENT:-0}" = "1" ]]; then
				printf 'local 0.0.0.0/0 dev lo scope host\n'
			fi
			return 0
			;;
		route:flush)
			if [[ "${TEST_ROUTE_FLUSH_RC:-0}" != "0" ]]; then
				return "${TEST_ROUTE_FLUSH_RC}"
			fi
			TEST_ROUTE_PRESENT=0
			export TEST_ROUTE_PRESENT
			return 0
			;;
	esac
	return 0
}

: > "$net_log"
TEST_NFT_TABLE_PRESENT=0
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
assert_true "nft_remove_policy should treat missing nft table as already clean" nft_remove_policy
assert_file_contains "$net_log" "nft list tables inet" "nft_remove_policy should probe nft table presence before cleanup"
assert_file_not_contains "$net_log" "nft delete table inet $NFT_TABLE_NAME" "nft_remove_policy should not delete absent nft table"
assert_file_contains "$net_log" "log:nft policy table $NFT_TABLE_NAME already clean" "nft_remove_policy should log already-clean nft state"

: > "$net_log"
TEST_NFT_TABLE_PRESENT=1
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
assert_true "nft_remove_policy should delete present nft table" nft_remove_policy
assert_file_contains "$net_log" "nft delete table inet $NFT_TABLE_NAME" "nft_remove_policy should delete present nft table"
assert_file_contains "$net_log" "log:Removed nft policy table $NFT_TABLE_NAME" "nft_remove_policy should log actual nft deletion"

: > "$net_log"
TEST_NFT_TABLE_PRESENT=1
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=1
assert_false "nft_remove_policy should fail when nft delete leaves table behind" nft_remove_policy

: > "$net_log"
TEST_NFT_TABLE_PRESENT=1
TEST_NFT_LIST_RC=2
TEST_NFT_DELETE_RC=0
assert_false "nft_remove_policy should fail when nft probe command breaks" nft_remove_policy

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF
: > "$net_log"
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=0
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
TEST_ROUTE_TABLE_ID=200
TEST_ROUTE_RULE_PRIORITY=10000
assert_true "policy_route_cleanup should treat absent live route state as already clean" policy_route_cleanup
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "policy_route_cleanup should remove route state file after already-clean teardown"
assert_file_contains "$net_log" "log:Policy routing for mark $NFT_INTERCEPT_MARK already clean" "policy_route_cleanup should log already-clean route state"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF
: > "$net_log"
TEST_RULE_PRESENT=1
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
assert_true "policy_route_cleanup should remove active route rule and table entries" policy_route_cleanup
assert_file_contains "$net_log" "ip rule del fwmark $NFT_INTERCEPT_MARK/$NFT_INTERCEPT_MARK table 200 priority 10000" "policy_route_cleanup should delete policy rule"
assert_file_contains "$net_log" "ip route flush table 200" "policy_route_cleanup should flush policy route table"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "policy_route_cleanup should remove route state file after successful teardown"
assert_file_contains "$net_log" "log:Removed policy routing for mark $NFT_INTERCEPT_MARK" "policy_route_cleanup should log actual route teardown"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF
: > "$net_log"
TEST_RULE_PRESENT=1
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=1
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
assert_false "policy_route_cleanup should fail when rule delete does not remove live rule" policy_route_cleanup
[[ -e "$ROUTE_STATE_FILE" ]] || fail "policy_route_cleanup should preserve route state file after rule delete failure"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF
: > "$net_log"
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=1
assert_false "policy_route_cleanup should fail when route flush leaves table entries behind" policy_route_cleanup
[[ -e "$ROUTE_STATE_FILE" ]] || fail "policy_route_cleanup should preserve route state file after route flush failure"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF
: > "$net_log"
TEST_RULE_PRESENT=1
TEST_RULE_SHOW_RC=2
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
assert_false "policy_route_cleanup should fail when ip rule probe command breaks" policy_route_cleanup
[[ -e "$ROUTE_STATE_FILE" ]] || fail "policy_route_cleanup should preserve route state file after rule probe failure"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=200
ROUTE_RULE_PRIORITY=10000
EOF
: > "$net_log"
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=2
TEST_ROUTE_FLUSH_RC=0
assert_false "policy_route_cleanup should fail when ip route probe command breaks" policy_route_cleanup
[[ -e "$ROUTE_STATE_FILE" ]] || fail "policy_route_cleanup should preserve route state file after route probe failure"

pass "nft and route helper logic"
