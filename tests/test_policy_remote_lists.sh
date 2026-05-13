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

cat > "$tmpbin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${TEST_WGET_LOG:?}"

url=""
while [[ "$#" -gt 0 ]]; do
	case "$1" in
		-O|-U|-T)
			shift 2
			;;
		-q)
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done

case "$url" in
	https://example.com/dst-a.txt)
		cat <<'LIST'
# comment
2.2.2.2
3.3.3.0/24:0015-02000
https://example.com/nested.txt
bad-entry
2.2.2.2
LIST
		;;
	https://example.com/src-a.txt)
		cat <<'LIST'
4.4.4.4
:0053
LIST
		;;
	https://example.com/dst-b.txt)
		cat <<'LIST'
5.5.5.5
LIST
		;;
	https://example.com/scoped-url.txt)
		cat <<'LIST'
10.10.10.10
10.10.20.0/24;0080
LIST
		;;
	https://example.com/direct-a.txt)
		cat <<'LIST'
8.8.8.8
9.9.9.0/24:0443,443
LIST
		;;
	https://example.com/fail.txt)
		exit 1
		;;
	https://example.com/large.txt)
		printf '1234567890\n'
		;;
	*)
		printf 'unexpected url: %s\n' "$url" >&2
		exit 1
		;;
esac
EOF

chmod +x "$tmpbin/logger" "$tmpbin/wget"
export PATH="$tmpbin:$PATH"
export TEST_WGET_LOG="$tmpdir/wget.log"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-snapshot.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

assert_unset() {
	local var_name="$1"
	local message="$2"

	[[ -z "${!var_name+x}" ]] || fail "$message"
}

assert_eq_file() {
	local expected="$1"
	local file="$2"
	local message="$3"
	local actual

	actual="$(cat "$file")"
	assert_eq "$expected" "$actual" "$message"
}

PKG_TMP_DIR="$tmpdir/run"
DST_LIST_FILE="$tmpdir/always_proxy_dst.txt"
SRC_LIST_FILE="$tmpdir/always_proxy_src.txt"
DIRECT_DST_LIST_FILE="$tmpdir/direct_dst.txt"

cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
https://example.com/dst-a.txt
1.1.1.1
1.1.1.2:0443,443
EOF

cat > "$SRC_LIST_FILE" <<'EOF'
https://example.com/src-a.txt
:0853
EOF

POLICY_MODE="direct-first"
: >"$TEST_WGET_LOG"
policy_resolve_runtime_lists

assert_eq_file $'1.1.1.1\n2.2.2.2\n3.3.3.0/24:15-2000\n1.1.1.2:443' "$POLICY_DST_LIST_FILE" "policy_resolve_runtime_lists should merge and dedupe destination entries"
assert_eq_file $'4.4.4.4\n:53\n:853' "$POLICY_SRC_LIST_FILE" "policy_resolve_runtime_lists should merge source entries"
assert_file_contains "$DST_LIST_FILE" "https://example.com/dst-a.txt" "policy_resolve_runtime_lists should not rewrite persistent destination list"
assert_file_not_contains "$DST_LIST_FILE" "2.2.2.2" "policy_resolve_runtime_lists should not expand remote destination list into persistent file"
assert_file_contains "$TEST_WGET_LOG" "-U mihowrt/0.5" "policy_resolve_runtime_lists should fetch remote lists with MihoWRT user agent"
assert_file_contains "$TEST_WGET_LOG" "-T 15" "policy_resolve_runtime_lists should use bounded fetch timeout"
assert_file_not_contains "$TEST_WGET_LOG" "https://example.com/nested.txt" "policy_resolve_runtime_lists should not recursively fetch nested URLs"
policy_clear_runtime_list_overrides
assert_unset POLICY_DST_LIST_FILE "policy_clear_runtime_list_overrides should unset destination override"
assert_unset POLICY_SRC_LIST_FILE "policy_clear_runtime_list_overrides should unset source override"

cat > "$DST_LIST_FILE" <<'EOF'
https://example.com/scoped-url.txt;0443,0053
11.11.11.11;00080
EOF
: > "$SRC_LIST_FILE"
POLICY_MODE="direct-first"
: >"$TEST_WGET_LOG"
policy_resolve_runtime_lists
assert_eq_file $'10.10.10.10:53,443\n10.10.20.0/24:80\n11.11.11.11:80' "$POLICY_DST_LIST_FILE" "policy_resolve_runtime_lists should apply semicolon URL ports to unscoped remote entries"
assert_file_contains "$TEST_WGET_LOG" "https://example.com/scoped-url.txt" "URL port suffix should be stripped before fetch"
assert_file_not_contains "$TEST_WGET_LOG" "https://example.com/scoped-url.txt;0443" "URL port suffix should not be passed to wget"
policy_clear_runtime_list_overrides

cat > "$DIRECT_DST_LIST_FILE" <<'EOF'
https://example.com/direct-a.txt
8.8.8.8
EOF

POLICY_MODE="proxy-first"
: >"$TEST_WGET_LOG"
policy_resolve_runtime_lists
assert_eq_file $'8.8.8.8\n9.9.9.0/24:443' "$POLICY_DIRECT_DST_LIST_FILE" "policy_resolve_runtime_lists should merge direct destination entries in proxy-first mode"
assert_file_contains "$TEST_WGET_LOG" "https://example.com/direct-a.txt" "proxy-first should fetch direct destination remote lists"
assert_file_not_contains "$TEST_WGET_LOG" "https://example.com/dst-a.txt" "proxy-first should not fetch inactive proxy destination remote lists"
policy_clear_runtime_list_overrides

cat > "$DST_LIST_FILE" <<'EOF'
https://example.com/fail.txt
EOF
POLICY_MODE="direct-first"
assert_false "policy_resolve_runtime_lists should fail when remote list fetch fails" policy_resolve_runtime_lists
assert_unset POLICY_DST_LIST_FILE "failed policy_resolve_runtime_lists should clean destination override"

cat > "$DST_LIST_FILE" <<'EOF'
https://example.com/dst-a.txt
https://example.com/dst-b.txt
EOF
: > "$SRC_LIST_FILE"
POLICY_REMOTE_LIST_MAX_URLS=1
: >"$TEST_WGET_LOG"
assert_false "policy_resolve_runtime_lists should reject too many remote list URLs" policy_resolve_runtime_lists
assert_file_contains "$TEST_WGET_LOG" "https://example.com/dst-a.txt" "policy_resolve_runtime_lists should fetch remote URLs up to the URL limit"
assert_file_not_contains "$TEST_WGET_LOG" "https://example.com/dst-b.txt" "policy_resolve_runtime_lists should stop before fetching URLs beyond the URL limit"
unset POLICY_REMOTE_LIST_MAX_URLS

cat > "$DST_LIST_FILE" <<'EOF'
https://example.com/large.txt
EOF
POLICY_REMOTE_LIST_MAX_BYTES=4
assert_false "policy_resolve_runtime_lists should reject oversized remote lists" policy_resolve_runtime_lists
unset POLICY_REMOTE_LIST_MAX_BYTES

cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
1.1.1.1
1.1.1.1
EOF
: > "$SRC_LIST_FILE"
POLICY_EFFECTIVE_LIST_MAX_BYTES=8
policy_resolve_runtime_lists
assert_eq_file "1.1.1.1" "$POLICY_DST_LIST_FILE" "policy_resolve_runtime_lists should dedupe before enforcing effective size"
policy_clear_runtime_list_overrides
unset POLICY_EFFECTIVE_LIST_MAX_BYTES

cat > "$DST_LIST_FILE" <<'EOF'
1.1.1.1
2.2.2.2
EOF
POLICY_EFFECTIVE_LIST_MAX_BYTES=8
assert_false "policy_resolve_runtime_lists should reject oversized effective lists" policy_resolve_runtime_lists
unset POLICY_EFFECTIVE_LIST_MAX_BYTES

cat > "$DST_LIST_FILE" <<'EOF'
https://example.com/dst-a.txt
EOF
: > "$SRC_LIST_FILE"
POLICY_MODE="direct-first"
apply_seen_dst=""
snapshot_seen_dst=""

apply_runtime_state_internal() {
	apply_seen_dst="$(cat "$POLICY_DST_LIST_FILE")"
	return 0
}

runtime_snapshot_save() {
	snapshot_seen_dst="$(cat "$POLICY_DST_LIST_FILE")"
	return 0
}

apply_runtime_state
assert_eq $'2.2.2.2\n3.3.3.0/24:15-2000' "$apply_seen_dst" "apply_runtime_state should apply resolved destination list"
assert_eq "$apply_seen_dst" "$snapshot_seen_dst" "apply_runtime_state should snapshot resolved destination list"
assert_unset POLICY_DST_LIST_FILE "apply_runtime_state should clear resolved destination override after snapshot"

pass "policy remote lists"
