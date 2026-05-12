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

cat > "$tmpbin/uci" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-q" && "${2:-}" == "get" ]]; then
	case "${3:-}" in
		network.lan.device)
			printf '%s\n' "${TEST_LAN_DEVICE:-}"
			exit 0
			;;
		network.lan.ifname)
			printf '%s\n' "${TEST_LAN_IFNAME:-}"
			exit 0
			;;
	esac
fi
exit 1
EOF

chmod +x "$tmpbin/logger" "$tmpbin/uci"
export PATH="$tmpbin:$PATH"

export CLASH_BIN="$tmpdir/clash"
export CLASH_CONFIG="$tmpdir/config.yaml"
export LIST_DIR="$tmpdir/opt/clash/lst"
export DST_LIST_FILE="$LIST_DIR/always_proxy_dst.txt"
export SRC_LIST_FILE="$LIST_DIR/always_proxy_src.txt"
export DIRECT_DST_LIST_FILE="$LIST_DIR/direct_dst.txt"

cat > "$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CLASH_BIN"
: > "$CLASH_CONFIG"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

export TEST_LAN_DEVICE="br-lan.10"
unset TEST_LAN_IFNAME
assert_eq "br-lan.10" "$(detect_lan_interface)" "detect_lan_interface should prefer network.lan.device"
assert_eq "br-lan.10" "$(default_source_interface)" "default_source_interface should use detected LAN device"

unset TEST_LAN_DEVICE
unset TEST_LAN_IFNAME
assert_eq "br-lan" "$(default_source_interface)" "default_source_interface should fall back to br-lan"

MIHOMO_DNS_LISTEN="127.0.0.1#7874"
MIHOMO_TPROXY_PORT="7894"
MIHOMO_ROUTING_MARK="2"
MIHOMO_ROUTE_TABLE_ID="200"
MIHOMO_ROUTE_RULE_PRIORITY="10000"
POLICY_MODE="direct-first"
DNS_ENHANCED_MODE="fake-ip"
CATCH_FAKEIP="1"
FAKEIP_RANGE="198.18.0.0/15"
SOURCE_INTERFACES="br-lan wg0"

assert_true "validate_runtime_config should accept valid runtime values" validate_runtime_config
[[ -d "$LIST_DIR" ]] || fail "validate_runtime_config should ensure list directory exists"
[[ ! -e "$DST_LIST_FILE" ]] || fail "validate_runtime_config should not auto-create destination list file"
[[ ! -e "$SRC_LIST_FILE" ]] || fail "validate_runtime_config should not auto-create source list file"
[[ ! -e "$DIRECT_DST_LIST_FILE" ]] || fail "validate_runtime_config should not auto-create direct destination list file"

SOURCE_INTERFACES="bad/iface"
assert_false "validate_runtime_config should reject invalid interface names" validate_runtime_config

SOURCE_INTERFACES="br-lan"
MIHOMO_ROUTE_TABLE_ID="999"
assert_false "validate_runtime_config should reject out-of-range route table id" validate_runtime_config

MIHOMO_ROUTE_TABLE_ID="200"
MIHOMO_ROUTE_RULE_PRIORITY="10000"
POLICY_MODE="invalid"
assert_false "validate_runtime_config should reject invalid policy mode" validate_runtime_config

POLICY_MODE="proxy-first"
assert_true "validate_runtime_config should accept proxy-first policy mode" validate_runtime_config

POLICY_MODE="direct-first"
DNS_ENHANCED_MODE="fake-ip"
CATCH_FAKEIP="1"
FAKEIP_RANGE="bad-range"
assert_false "validate_runtime_config should reject invalid fake-ip ranges" validate_runtime_config

FAKEIP_RANGE="198.18.0.0/15"
DNS_ENHANCED_MODE="redir-host"
assert_false "validate_runtime_config should reject non fake-ip enhanced mode" validate_runtime_config

DNS_ENHANCED_MODE="fake-ip"
CATCH_FAKEIP="0"
assert_false "validate_runtime_config should require fake-ip interception" validate_runtime_config

CATCH_FAKEIP="1"
MIHOMO_ROUTING_MARK="0"
assert_false "validate_runtime_config should reject zero routing mark" validate_runtime_config

MIHOMO_ROUTING_MARK="4096"
assert_false "validate_runtime_config should reject intercept mark conflict" validate_runtime_config

MIHOMO_ROUTING_MARK="4294967296"
assert_false "validate_runtime_config should reject routing mark outside uint32" validate_runtime_config

assert_true "is_policy_entry should accept IPv4" is_policy_entry "1.2.3.4"
assert_true "is_policy_entry should accept IPv4 CIDR" is_policy_entry "1.2.3.0/24"
assert_true "is_policy_entry should accept one port" is_policy_entry "1.2.3.4:443"
assert_true "is_policy_entry should accept CIDR with port range" is_policy_entry "100.100.100.100/20:15-2000"
assert_true "is_policy_entry should accept comma-separated ports" is_policy_entry "1.2.3.4:15,443"
assert_true "is_policy_entry should accept port without IP" is_policy_entry ":443"
assert_true "is_policy_entry should accept port range without IP" is_policy_entry ":15-2000"
assert_true "is_policy_entry should accept port list without IP" is_policy_entry ":15,443"
assert_true "is_policy_entry should accept semicolon port syntax" is_policy_entry "1.2.3.4;443"
assert_true "is_policy_entry should accept semicolon CIDR port ranges" is_policy_entry "100.100.100.100/20;15-2000"
assert_true "is_policy_entry should accept semicolon port-only entries" is_policy_entry ";15,443"
assert_false "is_policy_entry should reject empty addr and empty port" is_policy_entry ":"
assert_false "is_policy_entry should reject empty addr and empty semicolon port" is_policy_entry ";"
assert_false "is_policy_entry should reject zero port without IP" is_policy_entry ":0"
assert_false "is_policy_entry should reject zero semicolon port without IP" is_policy_entry ";0"
assert_false "is_policy_entry should reject double colon" is_policy_entry "::443"
assert_false "is_policy_entry should reject empty port" is_policy_entry "1.2.3.4:"
assert_false "is_policy_entry should reject empty semicolon port" is_policy_entry "1.2.3.4;"
assert_false "is_policy_entry should reject zero port" is_policy_entry "1.2.3.4:0"
assert_false "is_policy_entry should reject zero semicolon port" is_policy_entry "1.2.3.4;0"
assert_false "is_policy_entry should reject out-of-range port" is_policy_entry "1.2.3.4:65536"
assert_false "is_policy_entry should reject out-of-range semicolon port" is_policy_entry "1.2.3.4;65536"
assert_false "is_policy_entry should reject reversed port range" is_policy_entry "1.2.3.4:2000-15"
assert_false "is_policy_entry should reject reversed semicolon port range" is_policy_entry "1.2.3.4;2000-15"
assert_false "is_policy_entry should reject mixed range/list ports" is_policy_entry "1.2.3.4:15-20,443"
assert_false "is_policy_entry should reject mixed semicolon range/list ports" is_policy_entry "1.2.3.4;15-20,443"
assert_false "is_policy_entry should reject blank port list item" is_policy_entry "1.2.3.4:15,,443"
assert_false "is_policy_entry should reject blank semicolon port list item" is_policy_entry "1.2.3.4;15,,443"
assert_false "is_policy_entry should reject huge port without shell overflow" is_policy_entry "1.2.3.4:999999999999999999999999"

assert_eq "443" "$(policy_ports_nft_expr "0443")" "policy_ports_nft_expr should normalize single port"
assert_eq "15-2000" "$(policy_ports_nft_expr "0015-02000")" "policy_ports_nft_expr should normalize port range"
assert_eq "443" "$(policy_ports_nft_expr "0443-443")" "policy_ports_nft_expr should collapse single-value range"
assert_eq "{ 15, 443 }" "$(policy_ports_nft_expr "0015,0443")" "policy_ports_nft_expr should format port set"
assert_eq "443" "$(policy_ports_nft_expr "0443,443")" "policy_ports_nft_expr should dedupe port set"
assert_eq "15,443" "$(policy_ports_normalized_spec "0015,0443,443")" "policy_ports_normalized_spec should normalize and dedupe port lists"
assert_eq "15,443" "$(policy_ports_normalized_spec "0443,0015,443")" "policy_ports_normalized_spec should sort port lists"
assert_eq "1.2.3.4:15,443" "$(policy_entry_normalized "1.2.3.4:0443,15")" "policy_entry_normalized should normalize port-scoped entries"
assert_eq "1.2.3.4:15,443" "$(policy_entry_normalized "1.2.3.4;0443,15")" "policy_entry_normalized should normalize semicolon port-scoped entries"
assert_eq ":15-2000" "$(policy_entry_normalized ":0015-02000")" "policy_entry_normalized should normalize port-only entries"
assert_eq ":15-2000" "$(policy_entry_normalized ";0015-02000")" "policy_entry_normalized should normalize semicolon port-only entries"
assert_eq "https://example.com/list.txt" "$(policy_remote_list_url "https://example.com/list.txt;0443,53")" "policy_remote_list_url should strip semicolon port suffix"
assert_eq "53,443" "$(policy_remote_list_ports "https://example.com/list.txt;0443,53")" "policy_remote_list_ports should normalize semicolon URL ports"
assert_true "is_policy_remote_list_url should accept URL with semicolon ports" is_policy_remote_list_url "https://example.com/list.txt;443"
assert_false "is_policy_remote_list_url should reject URL with invalid semicolon ports" is_policy_remote_list_url "https://example.com/list.txt;0"
assert_true "policy_ports_include_port should find port inside range" policy_ports_include_port "15-2000" 443
assert_true "policy_ports_include_port should find port inside list" policy_ports_include_port "15,443" 443
assert_false "policy_ports_include_port should reject missing port" policy_ports_include_port "15,80" 443

mkdir -p "$LIST_DIR"
cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
1.1.1.0/24:443
1.1.2.2:15,443
:8443
1.1.4.4;443
;53
1.1.3.3:0
EOF
assert_eq "6" "$(count_valid_list_entries "$DST_LIST_FILE")" "count_valid_list_entries should count port-scoped policy entries"

cat > "$DST_LIST_FILE" <<'EOF'
# keep comment
1.1.1.1:443
:53
100.100.100.0/24:15-2000
https://example.com/list.txt
https://example.com/list.txt;443
bad:value
2.2.2.2;8443
EOF
migrate_policy_list_file "$DST_LIST_FILE"
assert_eq $'# keep comment\n1.1.1.1;443\n;53\n100.100.100.0/24;15-2000\nhttps://example.com/list.txt\nhttps://example.com/list.txt;443\nbad:value\n2.2.2.2;8443' "$(cat "$DST_LIST_FILE")" "migrate_policy_list_file should convert legacy colon policy ports only"
touch -d '2024-01-01 00:00:00' "$DST_LIST_FILE"
before_migration_mtime="$(stat -c %Y "$DST_LIST_FILE")"
migrate_policy_list_file "$DST_LIST_FILE"
after_migration_mtime="$(stat -c %Y "$DST_LIST_FILE")"
assert_eq "$before_migration_mtime" "$after_migration_mtime" "migrate_policy_list_file should skip rewrites when no legacy entries remain"

pass "policy validation helpers"
