#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

apk_log="$tmpdir/apk.log"
net_log="$tmpdir/net.log"

export NET_LOG="$net_log"

source_install_lib

ROUTE_STATE_FILE="$tmpdir/route.state"

log() {
	:
}

apk() {
	printf '%s\n' "$*" >>"$apk_log"
}

have_command() {
	case "$1" in
		nft|ip) return 0 ;;
		*) command -v "$1" >/dev/null 2>&1 ;;
	esac
}

nft() {
	printf 'nft %s\n' "$*" >>"$NET_LOG"
}

ip() {
	printf 'ip %s\n' "$*" >>"$NET_LOG"
	if [[ "${1:-}" == "rule" && "${2:-}" == "del" ]]; then
		if [[ "${TEST_RULE_DEL_DONE:-0}" = "0" ]]; then
			TEST_RULE_DEL_DONE=1
			export TEST_RULE_DEL_DONE
			return 0
		fi
		return 1
	fi
	return 0
}

: > "$apk_log"
apk_supports_virtual() {
	return 1
}
assert_false "hold_reinstall_dependencies should fail without virtual package support" hold_reinstall_dependencies
[[ ! -s "$apk_log" ]] || fail "hold_reinstall_dependencies should not call apk without virtual support"

: > "$apk_log"
apk_supports_virtual() {
	return 0
}
package_present() {
	[[ "$1" == "$REINSTALL_HOLD_VIRTUAL" || "$1" == "kmod-nf-tproxy" ]]
}
hold_reinstall_dependencies
assert_file_contains "$apk_log" "del $REINSTALL_HOLD_VIRTUAL" "hold_reinstall_dependencies should remove stale virtual package"
assert_file_contains "$apk_log" "add --virtual $REINSTALL_HOLD_VIRTUAL $COMMON_REPO_PACKAGES kmod-nf-tproxy" "hold_reinstall_dependencies should install virtual dependency hold with resolved tproxy kmod"
assert_eq "1" "$REINSTALL_HOLD_ACTIVE" "hold_reinstall_dependencies should mark hold active"

: > "$apk_log"
release_reinstall_dependencies
assert_file_contains "$apk_log" "del $REINSTALL_HOLD_VIRTUAL" "release_reinstall_dependencies should remove active virtual hold"
assert_eq "0" "$REINSTALL_HOLD_ACTIVE" "release_reinstall_dependencies should clear hold flag"

: > "$apk_log"
package_present() {
	[[ "$1" == "$REINSTALL_HOLD_VIRTUAL" ]]
}
release_reinstall_dependencies
assert_file_contains "$apk_log" "del $REINSTALL_HOLD_VIRTUAL" "release_reinstall_dependencies should remove stale virtual hold package"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

TEST_RULE_DEL_DONE=0
export TEST_RULE_DEL_DONE
: > "$NET_LOG"
cleanup_runtime_fallback
assert_file_contains "$NET_LOG" "nft delete table inet $NFT_TABLE_NAME" "cleanup_runtime_fallback should drop nft table"
assert_file_contains "$NET_LOG" "ip rule del fwmark $NFT_INTERCEPT_MARK/$NFT_INTERCEPT_MARK table 201 priority 10001" "cleanup_runtime_fallback should delete policy route rule"
assert_file_contains "$NET_LOG" "ip route flush table 201" "cleanup_runtime_fallback should flush policy route table"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "cleanup_runtime_fallback should remove route state file"

pass "installer hold and cleanup helpers"
