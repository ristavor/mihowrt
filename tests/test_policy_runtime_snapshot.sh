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

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/nft.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-snapshot.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

PKG_STATE_DIR="$tmpdir/state"
ROUTE_STATE_FILE="$PKG_STATE_DIR/route.state"
DST_LIST_FILE="$tmpdir/always_proxy_dst.txt"
SRC_LIST_FILE="$tmpdir/always_proxy_src.txt"
DIRECT_DST_LIST_FILE="$tmpdir/direct_dst.txt"

ensure_dir "$PKG_STATE_DIR"
cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
2.2.2.0/24
EOF

cat > "$SRC_LIST_FILE" <<'EOF'
3.3.3.3
EOF

cat > "$DIRECT_DST_LIST_FILE" <<'EOF'
8.8.8.8
EOF

POLICY_MODE="proxy-first"
DNS_HIJACK=1
MIHOMO_DNS_PORT="7874"
MIHOMO_DNS_LISTEN="127.0.0.1#7874"
MIHOMO_TPROXY_PORT="7894"
MIHOMO_ROUTING_MARK="2"
MIHOMO_ROUTE_TABLE_ID=""
MIHOMO_ROUTE_RULE_PRIORITY=""
DISABLE_QUIC=1
DNS_ENHANCED_MODE="fake-ip"
CATCH_FAKEIP=1
FAKEIP_RANGE="198.18.0.0/15"
SOURCE_INTERFACES="br-lan wg0"

runtime_snapshot_save

snapshot_file="$(runtime_snapshot_file)"
snapshot_dst_file="$(runtime_snapshot_dst_file)"
snapshot_src_file="$(runtime_snapshot_src_file)"
snapshot_direct_file="$(runtime_snapshot_direct_file)"

assert_eq "proxy-first" "$(jq -r '.policy_mode' "$snapshot_file")" "runtime_snapshot_save should persist policy mode"
assert_eq "201" "$(jq -r '.route_table_id_effective' "$snapshot_file")" "runtime_snapshot_save should persist effective route table id"
assert_eq "10001" "$(jq -r '.route_rule_priority_effective' "$snapshot_file")" "runtime_snapshot_save should persist effective route rule priority"
assert_eq "wg0" "$(jq -r '.source_network_interfaces[1]' "$snapshot_file")" "runtime_snapshot_save should persist source interfaces"
assert_file_contains "$snapshot_dst_file" "2.2.2.0/24" "runtime_snapshot_save should snapshot destination list contents"
assert_file_contains "$snapshot_src_file" "3.3.3.3" "runtime_snapshot_save should snapshot source list contents"
assert_file_contains "$snapshot_direct_file" "8.8.8.8" "runtime_snapshot_save should snapshot direct destination list contents"

direct_snapshot_backup="$tmpdir/direct.snapshot.good"
cp "$snapshot_direct_file" "$direct_snapshot_backup"
rm -f "$snapshot_direct_file"
assert_false "runtime_snapshot_exists should require direct destination snapshot" runtime_snapshot_exists
assert_false "runtime_snapshot_valid should reject missing direct destination snapshot" runtime_snapshot_valid
assert_false "runtime_snapshot_load should reject missing direct destination snapshot" runtime_snapshot_load
cp "$direct_snapshot_backup" "$snapshot_direct_file"

snapshot_backup="$tmpdir/runtime.snapshot.good.json"
cp "$snapshot_file" "$snapshot_backup"
jq '.enabled = false' "$snapshot_backup" > "$snapshot_file"
assert_false "runtime_snapshot_valid should reject disabled legacy snapshots" runtime_snapshot_valid
cp "$snapshot_backup" "$snapshot_file"
assert_true "runtime_snapshot_valid should accept mandatory fake-ip policy snapshots" runtime_snapshot_valid
assert_true "runtime_snapshot_mihomo_config_matches_current should accept matching Mihomo config" runtime_snapshot_mihomo_config_matches_current
MIHOMO_TPROXY_PORT="7895"
assert_false "runtime_snapshot_mihomo_config_matches_current should reject changed TPROXY port" runtime_snapshot_mihomo_config_matches_current
MIHOMO_TPROXY_PORT="7894"
FAKEIP_RANGE="198.19.0.0/16"
assert_false "runtime_snapshot_mihomo_config_matches_current should reject changed fake-ip range" runtime_snapshot_mihomo_config_matches_current
FAKEIP_RANGE="198.18.0.0/15"

TEST_FAIL_MV_DEST=""
mv() {
	local dest="${@: -1}"

	if [ -n "$TEST_FAIL_MV_DEST" ] && [ "$dest" = "$TEST_FAIL_MV_DEST" ]; then
		TEST_FAIL_MV_DEST=""
		return 1
	fi

	command mv "$@"
}

cat > "$DST_LIST_FILE" <<'EOF'
9.9.9.9
EOF

cat > "$SRC_LIST_FILE" <<'EOF'
8.8.8.8
EOF

TEST_FAIL_MV_DEST="$snapshot_file"
assert_false "runtime_snapshot_save should fail cleanly when final snapshot move fails" runtime_snapshot_save
assert_eq "201" "$(jq -r '.route_table_id_effective' "$snapshot_file")" "runtime_snapshot_save should preserve previous snapshot json on failure"
assert_file_contains "$snapshot_dst_file" "2.2.2.0/24" "runtime_snapshot_save should preserve previous destination snapshot on failure"
assert_file_contains "$snapshot_src_file" "3.3.3.3" "runtime_snapshot_save should preserve previous source snapshot on failure"

DNS_HIJACK=0
MIHOMO_DNS_PORT=""
MIHOMO_DNS_LISTEN=""
MIHOMO_TPROXY_PORT=""
MIHOMO_ROUTING_MARK=""
MIHOMO_ROUTE_TABLE_ID=""
MIHOMO_ROUTE_RULE_PRIORITY=""
DISABLE_QUIC=0
DNS_ENHANCED_MODE=""
CATCH_FAKEIP=0
FAKEIP_RANGE=""
SOURCE_INTERFACES=""
POLICY_MODE=""
unset POLICY_DST_LIST_FILE POLICY_SRC_LIST_FILE POLICY_DIRECT_DST_LIST_FILE

runtime_snapshot_load
assert_eq "proxy-first" "$POLICY_MODE" "runtime_snapshot_load should restore policy mode"
assert_eq "127.0.0.1#7874" "$MIHOMO_DNS_LISTEN" "runtime_snapshot_load should restore DNS listen"
assert_eq "201" "$MIHOMO_ROUTE_TABLE_ID" "runtime_snapshot_load should restore effective route table id as active override"
assert_eq "10001" "$MIHOMO_ROUTE_RULE_PRIORITY" "runtime_snapshot_load should restore effective route rule priority as active override"
assert_eq "br-lan wg0" "$SOURCE_INTERFACES" "runtime_snapshot_load should restore source interfaces"
assert_eq "$snapshot_dst_file" "$POLICY_DST_LIST_FILE" "runtime_snapshot_load should point destination override to snapshot file"
assert_eq "$snapshot_src_file" "$POLICY_SRC_LIST_FILE" "runtime_snapshot_load should point source override to snapshot file"
assert_eq "$snapshot_direct_file" "$POLICY_DIRECT_DST_LIST_FILE" "runtime_snapshot_load should point direct destination override to snapshot file"

restore_log="$tmpdir/restore.log"
apply_runtime_state_internal() {
	printf '%s|%s|%s|%s|%s|%s\n' \
		"$MIHOMO_DNS_LISTEN" \
		"$POLICY_MODE" \
		"$MIHOMO_ROUTE_TABLE_ID" \
		"$POLICY_DST_LIST_FILE" \
		"$POLICY_SRC_LIST_FILE" \
		"$POLICY_DIRECT_DST_LIST_FILE" > "$restore_log"
	return 0
}

unset POLICY_DST_LIST_FILE POLICY_SRC_LIST_FILE POLICY_DIRECT_DST_LIST_FILE
runtime_snapshot_restore
assert_file_contains "$restore_log" "127.0.0.1#7874|proxy-first|201|$snapshot_dst_file|$snapshot_src_file|$snapshot_direct_file" "runtime_snapshot_restore should reapply saved runtime snapshot with snapshot list overrides"

runtime_snapshot_clear
assert_false "runtime_snapshot_clear should remove runtime snapshot json" test -f "$snapshot_file"
assert_false "runtime_snapshot_clear should remove destination snapshot file" test -f "$snapshot_dst_file"
assert_false "runtime_snapshot_clear should remove source snapshot file" test -f "$snapshot_src_file"
assert_false "runtime_snapshot_clear should remove direct destination snapshot file" test -f "$snapshot_direct_file"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

rm -f "$DST_LIST_FILE" "$SRC_LIST_FILE" "$DIRECT_DST_LIST_FILE"

POLICY_MODE="direct-first"
runtime_snapshot_save
assert_false "runtime_snapshot_save should keep deleted destination list empty in snapshot" test -s "$snapshot_dst_file"
assert_false "runtime_snapshot_save should keep deleted source list empty in snapshot" test -s "$snapshot_src_file"
assert_eq "0" "$(jq -r '.always_proxy_dst_count' <(runtime_snapshot_status_json))" "runtime snapshot status should report zero destination entries after list deletion"
assert_eq "0" "$(jq -r '.always_proxy_src_count' <(runtime_snapshot_status_json))" "runtime snapshot status should report zero source entries after list deletion"
assert_eq "0" "$(jq -r '.direct_dst_count' <(runtime_snapshot_status_json))" "direct-first runtime snapshot status should report inactive direct destination count"

pass "policy runtime snapshot"
