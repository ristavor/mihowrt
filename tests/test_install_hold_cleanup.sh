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

warn() {
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
}

ip() {
	printf 'ip %s\n' "$*" >>"$NET_LOG"
	case "${1:-}:${2:-}" in
		rule:show)
			if [[ "${TEST_RULE_SHOW_RC:-0}" != "0" ]]; then
				return "${TEST_RULE_SHOW_RC}"
			fi
			if [[ "${TEST_RULE_PRESENT:-0}" = "1" ]]; then
				printf '%s: from all fwmark %s/%s lookup %s\n' \
					"${TEST_ROUTE_RULE_PRIORITY:-201}" \
					"$NFT_INTERCEPT_MARK" \
					"$NFT_INTERCEPT_MARK" \
					"${TEST_ROUTE_TABLE_ID:-201}"
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
	[[ "$1" == "$REINSTALL_HOLD_VIRTUAL" ]]
}
hold_reinstall_dependencies
assert_file_contains "$apk_log" "del $REINSTALL_HOLD_VIRTUAL" "hold_reinstall_dependencies should remove stale virtual package"
assert_file_contains "$apk_log" "add --virtual $REINSTALL_HOLD_VIRTUAL $REQUIRED_REPO_PACKAGES" "hold_reinstall_dependencies should install virtual dependency hold"
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

TEST_NFT_TABLE_PRESENT=1
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
TEST_RULE_PRESENT=1
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
TEST_ROUTE_TABLE_ID=201
TEST_ROUTE_RULE_PRIORITY=10001
: > "$NET_LOG"
cleanup_runtime_fallback
assert_file_contains "$NET_LOG" "nft delete table inet $NFT_TABLE_NAME" "cleanup_runtime_fallback should drop nft table"
assert_file_contains "$NET_LOG" "ip rule del fwmark $NFT_INTERCEPT_MARK/$NFT_INTERCEPT_MARK table 201 priority 10001" "cleanup_runtime_fallback should delete policy route rule"
assert_file_contains "$NET_LOG" "ip route flush table 201" "cleanup_runtime_fallback should flush policy route table"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "cleanup_runtime_fallback should remove route state file"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

TEST_NFT_TABLE_PRESENT=0
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=0
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
: > "$NET_LOG"
assert_true "cleanup_runtime_fallback should treat already-absent live state as clean" cleanup_runtime_fallback
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "cleanup_runtime_fallback should remove route state file when live state is already absent"

: > "$NET_LOG"
TEST_NFT_TABLE_PRESENT=1
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=1
assert_false "cleanup_runtime_fallback should fail when nft delete leaves table behind" cleanup_runtime_fallback

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

: > "$NET_LOG"
TEST_NFT_TABLE_PRESENT=1
TEST_NFT_LIST_RC=2
TEST_NFT_DELETE_RC=0
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=0
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
TEST_ROUTE_TABLE_ID=201
TEST_ROUTE_RULE_PRIORITY=10001
assert_false "cleanup_runtime_fallback should fail when nft probe command breaks" cleanup_runtime_fallback

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

TEST_NFT_TABLE_PRESENT=0
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=1
TEST_ROUTE_TABLE_ID=201
TEST_ROUTE_RULE_PRIORITY=10001
: > "$NET_LOG"
assert_false "cleanup_runtime_fallback should fail when route flush leaves table entries behind" cleanup_runtime_fallback
[[ -e "$ROUTE_STATE_FILE" ]] || fail "cleanup_runtime_fallback should preserve route state file after route flush failure"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

TEST_NFT_TABLE_PRESENT=0
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
TEST_RULE_PRESENT=1
TEST_RULE_SHOW_RC=2
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=0
TEST_ROUTE_FLUSH_RC=0
TEST_ROUTE_TABLE_ID=201
TEST_ROUTE_RULE_PRIORITY=10001
: > "$NET_LOG"
assert_false "cleanup_runtime_fallback should fail when ip rule probe command breaks" cleanup_runtime_fallback
[[ -e "$ROUTE_STATE_FILE" ]] || fail "cleanup_runtime_fallback should preserve route state file after rule probe failure"

cat > "$ROUTE_STATE_FILE" <<'EOF'
ROUTE_TABLE_ID=201
ROUTE_RULE_PRIORITY=10001
EOF

TEST_NFT_TABLE_PRESENT=0
TEST_NFT_LIST_RC=0
TEST_NFT_DELETE_RC=0
TEST_RULE_PRESENT=0
TEST_RULE_SHOW_RC=0
TEST_RULE_DEL_RC=0
TEST_ROUTE_PRESENT=1
TEST_ROUTE_SHOW_RC=2
TEST_ROUTE_FLUSH_RC=0
TEST_ROUTE_TABLE_ID=201
TEST_ROUTE_RULE_PRIORITY=10001
: > "$NET_LOG"
assert_false "cleanup_runtime_fallback should fail when ip route probe command breaks" cleanup_runtime_fallback
[[ -e "$ROUTE_STATE_FILE" ]] || fail "cleanup_runtime_fallback should preserve route state file after route probe failure"

pass "installer hold and cleanup helpers"
