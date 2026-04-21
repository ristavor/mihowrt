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
CATCH_FAKEIP="1"
FAKEIP_RANGE="198.18.0.0/15"
SOURCE_INTERFACES="br-lan wg0"

assert_true "validate_runtime_config should accept valid runtime values" validate_runtime_config
[[ -d "$LIST_DIR" ]] || fail "validate_runtime_config should ensure list directory exists"
[[ ! -e "$DST_LIST_FILE" ]] || fail "validate_runtime_config should not auto-create destination list file"
[[ ! -e "$SRC_LIST_FILE" ]] || fail "validate_runtime_config should not auto-create source list file"

SOURCE_INTERFACES="bad/iface"
assert_false "validate_runtime_config should reject invalid interface names" validate_runtime_config

SOURCE_INTERFACES="br-lan"
MIHOMO_ROUTE_TABLE_ID="999"
assert_false "validate_runtime_config should reject out-of-range route table id" validate_runtime_config

MIHOMO_ROUTE_TABLE_ID="200"
MIHOMO_ROUTE_RULE_PRIORITY="10000"
CATCH_FAKEIP="1"
FAKEIP_RANGE="bad-range"
assert_false "validate_runtime_config should reject invalid fake-ip ranges" validate_runtime_config

pass "policy validation helpers"
