#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat >"$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmpbin/nft" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "list" && "${2:-}" == "tables" ]]; then
	printf 'table inet mihowrt\n'
	exit 0
fi

if [[ "${1:-}" == "list" && "${2:-}" == "chain" ]]; then
	exit "${TEST_NFT_CHAIN_EXISTS_RC:-0}"
fi

if [[ "${1:-}" == "-f" ]]; then
	cp "$2" "${NFT_CAPTURE_FILE:?}"
	exit "${TEST_NFT_APPLY_RC:-0}"
fi

exit 0
EOF

chmod +x "$tmpbin/logger" "$tmpbin/nft"
export PATH="$tmpbin:$PATH"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-snapshot.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/nft.sh"

PKG_TMP_DIR="$tmpdir/runtime"
PKG_STATE_DIR="$tmpdir/state"
NFT_CAPTURE_FILE="$tmpdir/nft-fast.batch"
export NFT_CAPTURE_FILE
DST_LIST_FILE="$tmpdir/source-dst.txt"
SRC_LIST_FILE="$tmpdir/source-src.txt"
DIRECT_DST_LIST_FILE="$tmpdir/source-direct.txt"
POLICY_DST_LIST_FILE="$tmpdir/effective-dst.txt"
POLICY_SRC_LIST_FILE="$tmpdir/effective-src.txt"
POLICY_DIRECT_DST_LIST_FILE="$tmpdir/effective-direct.txt"
SOURCE_INTERFACES="br-lan"
POLICY_MODE="direct-first"
DNS_HIJACK=1
MIHOMO_DNS_LISTEN="127.0.0.1#7874"
MIHOMO_TPROXY_PORT="7894"
MIHOMO_ROUTING_MARK="2"
DISABLE_QUIC=1
CATCH_FAKEIP=1
FAKEIP_RANGE="198.18.0.0/15"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR"

cat >"$(runtime_snapshot_dst_file)" <<'EOF'
1.1.1.1
EOF

cat >"$POLICY_DST_LIST_FILE" <<'EOF'
2.2.2.2
3.3.3.0/24
EOF

assert_true "unscoped proxy_dst changes should support fast update" nft_policy_component_fast_update_supported proxy_dst
nft_update_policy_components_fast "proxy_dst"
assert_file_contains "$NFT_CAPTURE_FILE" "flush set inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET" "fast update should flush only changed destination set"
assert_file_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET { 2.2.2.2,3.3.3.0/24 }" "fast update should repopulate destination set"
assert_file_not_contains "$NFT_CAPTURE_FILE" "flush set inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET" "fast proxy_dst update should not touch proxy_src set"
assert_file_not_contains "$NFT_CAPTURE_FILE" "delete table inet $NFT_TABLE_NAME" "fast update should not rebuild nft table"
assert_file_not_contains "$NFT_CAPTURE_FILE" "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_PREROUTING" "unscoped fast update should not touch port chains"

cat >"$(runtime_snapshot_dst_file)" <<'EOF'
1.1.1.1;443
EOF

cat >"$POLICY_DST_LIST_FILE" <<'EOF'
2.2.2.2;8443
3.3.3.0/24
EOF

NFT_CAPTURE_FILE="$tmpdir/nft-fast-ports.batch"
assert_true "existing port-scoped proxy_dst changes should support fast chain update" nft_policy_component_fast_update_supported proxy_dst
nft_update_policy_components_fast "proxy_dst"
assert_file_contains "$NFT_CAPTURE_FILE" "flush set inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET" "port fast update should still refresh unscoped destination set"
assert_file_contains "$NFT_CAPTURE_FILE" "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_PREROUTING" "port fast update should refresh prerouting port chain"
assert_file_contains "$NFT_CAPTURE_FILE" "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_OUTPUT" "port fast update should refresh output port chain"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_PREROUTING ip daddr 2.2.2.2 meta l4proto { tcp, udp } th dport 8443 meta mark set $NFT_INTERCEPT_MARK" "port fast update should repopulate prerouting port rules"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_OUTPUT ip daddr 2.2.2.2 meta l4proto { tcp, udp } th dport 8443 meta mark set $NFT_INTERCEPT_MARK" "port fast update should repopulate output port rules"
assert_file_not_contains "$NFT_CAPTURE_FILE" "flush set inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET" "port fast update should not touch unrelated source set"

cat >"$(runtime_snapshot_dst_file)" <<'EOF'
1.1.1.1
EOF

cat >"$POLICY_DST_LIST_FILE" <<'EOF'
2.2.2.2;443
EOF
assert_false "adding first port-scoped entry should require full reload to add jump" nft_policy_component_fast_update_supported proxy_dst

cat >"$(runtime_snapshot_dst_file)" <<'EOF'
1.1.1.1;443
EOF

cat >"$POLICY_DST_LIST_FILE" <<'EOF'
2.2.2.2
EOF
assert_false "removing last port-scoped entry should require full reload to remove jump" nft_policy_component_fast_update_supported proxy_dst

export TEST_NFT_CHAIN_EXISTS_RC=1
cat >"$(runtime_snapshot_dst_file)" <<'EOF'
1.1.1.1;443
EOF

cat >"$POLICY_DST_LIST_FILE" <<'EOF'
2.2.2.2;443
EOF
assert_false "missing dynamic port chains should require full reload once after upgrade" nft_policy_component_fast_update_supported proxy_dst
unset TEST_NFT_CHAIN_EXISTS_RC

POLICY_MODE="proxy-first"
cat >"$(runtime_snapshot_direct_file)" <<'EOF'
8.8.8.8;443
EOF

cat >"$POLICY_DIRECT_DST_LIST_FILE" <<'EOF'
9.9.9.9;853
EOF
NFT_CAPTURE_FILE="$tmpdir/nft-fast-direct.batch"
assert_true "existing port-scoped direct_dst changes should support fast chain update" nft_policy_component_fast_update_supported direct_dst
nft_update_policy_components_fast "direct_dst"
assert_file_contains "$NFT_CAPTURE_FILE" "flush set inet $NFT_TABLE_NAME $NFT_DIRECT_DST_SET" "direct fast update should refresh only direct set"
assert_file_contains "$NFT_CAPTURE_FILE" "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING" "direct fast update should refresh prerouting direct port chain"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT ip daddr 9.9.9.9 meta l4proto { tcp, udp } th dport 853 return" "direct fast update should repopulate output return rules"
assert_file_not_contains "$NFT_CAPTURE_FILE" "flush set inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET" "direct fast update should not touch proxy destination set"

pass "nft policy fast component update"
