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
DIRECT_DST_LIST_FILE="$tmpdir/direct_dst.txt"
SOURCE_INTERFACES="br-lan"
POLICY_MODE="direct-first"
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
4.4.4.4:443
5.5.5.0/24:15-2000
6.6.6.6:15,443
:8443
9.9.9.9:0
EOF

cat > "$SRC_LIST_FILE" <<'EOF'
3.3.3.3
7.7.7.0/24:53
:853
EOF

nft_apply_policy
assert_eq "6" "$NFT_PROXY_DST_COUNT" "nft_apply_policy should count destination entries before deletion"
assert_eq "3" "$NFT_PROXY_SRC_COUNT" "nft_apply_policy should count source entries before deletion"
assert_eq "2" "$NFT_PROXY_DST_SET_COUNT" "nft_apply_policy should keep only unscoped destination entries in set"
assert_eq "1" "$NFT_PROXY_SRC_SET_COUNT" "nft_apply_policy should keep only unscoped source entries in set"
assert_file_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET { 1.1.1.1,2.2.2.0/24 }" "nft_apply_policy should emit destination set before deletion"
assert_file_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET { 3.3.3.3 }" "nft_apply_policy should emit source set before deletion"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr 4.4.4.4 udp dport 443 reject" "nft_apply_policy should reject QUIC for single-port destination entry"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr 5.5.5.0/24 udp dport 443 reject" "nft_apply_policy should reject QUIC when range contains 443"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr 6.6.6.6 udp dport 443 reject" "nft_apply_policy should reject QUIC when list contains 443"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr 4.4.4.4 tcp dport 443 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark TCP for single-port destination entry"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr 5.5.5.0/24 udp dport 15-2000 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark UDP for destination port range"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr 6.6.6.6 tcp dport { 15, 443 } meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark TCP for destination port list"
assert_file_contains "$NFT_CAPTURE_FILE" "ip saddr 7.7.7.0/24 tcp dport 53 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark source policy by destination port"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_OUTPUT ip daddr 4.4.4.4 tcp dport 443 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should apply port-scoped destination rules to output chain"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING_POLICY meta nfproto ipv4 tcp dport 8443 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark any IPv4 destination by port"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_OUTPUT meta nfproto ipv4 tcp dport 8443 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should apply any-port destination rules to output chain"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING_POLICY meta nfproto ipv4 udp dport 853 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark any IPv4 client by destination port"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip daddr 9.9.9.9" "nft_apply_policy should skip invalid port-scoped entries"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip saddr 7.7.7.0/24 udp dport 443 reject" "nft_apply_policy should not reject QUIC for source port filters without 443"

cat > "$DST_LIST_FILE" <<'EOF'
:443
EOF
: > "$SRC_LIST_FILE"
NFT_CAPTURE_FILE="$tmpdir/nft-port-only.batch"

nft_apply_policy
assert_eq "1" "$NFT_PROXY_DST_COUNT" "nft_apply_policy should count port-only destination entries"
assert_eq "0" "$NFT_PROXY_DST_SET_COUNT" "nft_apply_policy should keep destination set empty for port-only entries"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip daddr @$NFT_PROXY_DST_SET udp dport 443 reject" "nft_apply_policy should not emit empty destination set QUIC rule"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip daddr @$NFT_PROXY_DST_SET meta l4proto" "nft_apply_policy should not emit empty destination set mark rule"
assert_file_contains "$NFT_CAPTURE_FILE" "meta nfproto ipv4 udp dport 443 reject" "nft_apply_policy should reject QUIC for any IPv4 destination by port"
assert_file_contains "$NFT_CAPTURE_FILE" "meta nfproto ipv4 tcp dport 443 meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should mark any IPv4 destination by port"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip daddr  tcp" "nft_apply_policy should not emit empty destination address match"

rm -f "$DST_LIST_FILE" "$SRC_LIST_FILE"
NFT_CAPTURE_FILE="$tmpdir/nft-deleted.batch"

nft_apply_policy
assert_eq "0" "$NFT_PROXY_DST_COUNT" "nft_apply_policy should treat deleted destination list as empty"
assert_eq "0" "$NFT_PROXY_SRC_COUNT" "nft_apply_policy should treat deleted source list as empty"
assert_eq "0" "$NFT_PROXY_DST_SET_COUNT" "nft_apply_policy should treat deleted destination set as empty"
assert_eq "0" "$NFT_PROXY_SRC_SET_COUNT" "nft_apply_policy should treat deleted source set as empty"
assert_file_not_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET {" "nft_apply_policy should not emit destination set elements after deletion"
assert_file_not_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET {" "nft_apply_policy should not emit source set elements after deletion"
assert_file_contains "$NFT_CAPTURE_FILE" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK" "nft_apply_policy should still keep fake-ip interception after list deletion"

POLICY_MODE="proxy-first"
cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
EOF
cat > "$SRC_LIST_FILE" <<'EOF'
3.3.3.3
EOF
cat > "$DIRECT_DST_LIST_FILE" <<'EOF'
8.8.8.8
9.9.9.0/24:443
EOF
NFT_CAPTURE_FILE="$tmpdir/nft-proxy-first.batch"

nft_apply_policy
assert_eq "0" "$NFT_PROXY_DST_COUNT" "proxy-first should ignore always-proxy destination entries"
assert_eq "0" "$NFT_PROXY_SRC_COUNT" "proxy-first should ignore always-proxy source entries"
assert_eq "2" "$NFT_DIRECT_DST_COUNT" "proxy-first should count direct destination entries"
assert_eq "1" "$NFT_DIRECT_DST_SET_COUNT" "proxy-first should keep unscoped direct destinations in set"
assert_file_contains "$NFT_CAPTURE_FILE" "add element inet $NFT_TABLE_NAME $NFT_DIRECT_DST_SET { 8.8.8.8 }" "proxy-first should emit direct destination set"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING_POLICY ip daddr @$NFT_DIRECT_DST_SET return" "proxy-first should bypass direct destinations before marking prerouting"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING_POLICY ip daddr 9.9.9.0/24 tcp dport 443 return" "proxy-first should bypass port-scoped direct destinations"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING_POLICY meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK" "proxy-first should mark all non-direct prerouting TCP/UDP"
assert_file_contains "$NFT_CAPTURE_FILE" "add rule inet $NFT_TABLE_NAME $NFT_CHAIN_OUTPUT meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK" "proxy-first should mark all non-direct output TCP/UDP"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip daddr @$NFT_PROXY_DST_SET meta l4proto" "proxy-first should not use always-proxy destination set"
assert_file_not_contains "$NFT_CAPTURE_FILE" "ip saddr @$NFT_PROXY_SRC_SET meta l4proto" "proxy-first should not use always-proxy source set"

pass "nft policy apply handles deleted lists"
