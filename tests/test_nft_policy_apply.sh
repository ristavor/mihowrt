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

cat > "$tmpbin/nft" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "list" && "${2:-}" == "table" ]]; then
	exit 1
fi

if [[ "${1:-}" == "-f" ]]; then
	cp "$2" "${NFT_CAPTURE_FILE:?}"
	exit 0
fi

exit 0
EOF

chmod +x "$tmpbin/logger" "$tmpbin/nft"
export PATH="$tmpbin:$PATH"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/nft.sh"

PKG_TMP_DIR="$tmpdir/runtime"
NFT_CAPTURE_FILE="$tmpdir/nft.batch"
export NFT_CAPTURE_FILE
DST_LIST_FILE="$tmpdir/always_proxy_dst.txt"
SRC_LIST_FILE="$tmpdir/always_proxy_src.txt"
SOURCE_INTERFACES="br-lan"
DNS_HIJACK=1
MIHOMO_DNS_LISTEN="127.0.0.1#7874"
MIHOMO_TPROXY_PORT="7894"
MIHOMO_ROUTING_MARK="2"
DISABLE_QUIC=1
CATCH_FAKEIP=1
FAKEIP_RANGE="198.18.0.0/15"

cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
2.2.2.0/24
EOF

cat > "$SRC_LIST_FILE" <<'EOF'
3.3.3.3
EOF

nft_apply_policy
assert_eq "2" "$NFT_PROXY_DST_COUNT" "nft_apply_policy should count destination entries before deletion"
assert_eq "1" "$NFT_PROXY_SRC_COUNT" "nft_apply_policy should count source entries before deletion"
assert_file_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET { 1.1.1.1,2.2.2.0/24 }" "nft_apply_policy should emit destination set before deletion"
assert_file_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET { 3.3.3.3 }" "nft_apply_policy should emit source set before deletion"

rm -f "$DST_LIST_FILE" "$SRC_LIST_FILE"
NFT_CAPTURE_FILE="$tmpdir/nft-deleted.batch"

nft_apply_policy
assert_eq "0" "$NFT_PROXY_DST_COUNT" "nft_apply_policy should treat deleted destination list as empty"
assert_eq "0" "$NFT_PROXY_SRC_COUNT" "nft_apply_policy should treat deleted source list as empty"
assert_file_not_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET {" "nft_apply_policy should not emit destination set elements after deletion"
assert_file_not_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET {" "nft_apply_policy should not emit source set elements after deletion"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should still keep fake-ip interception after list deletion"

pass "nft policy apply handles deleted lists"
