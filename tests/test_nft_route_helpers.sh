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
export MIHOMO_ROUTE_TABLE_ID=""
export MIHOMO_ROUTE_RULE_PRIORITY=""

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/nft.sh"

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

pass "nft and route helper logic"
