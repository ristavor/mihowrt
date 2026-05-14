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

export CLASH_BIN="$tmpdir/opt/clash/bin/clash"
mkdir -p "$(dirname "$CLASH_BIN")"
cat >"$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
sleep "${1:-60}"
EOF

chmod +x "$tmpbin/logger" "$CLASH_BIN"
export PATH="$tmpbin:$PATH"

export LIST_DIR="$tmpdir/opt/clash/lst"
export DST_LIST_FILE="$LIST_DIR/always_proxy_dst.txt"
export SRC_LIST_FILE="$LIST_DIR/always_proxy_src.txt"
export DIRECT_DST_LIST_FILE="$LIST_DIR/direct_dst.txt"
export RULESET_TMPFS="$tmpdir/tmp/clash/ruleset"
export RULESET_LINK="$tmpdir/opt/clash/ruleset"
export PROXY_PROVIDERS_TMPFS="$tmpdir/tmp/clash/proxy_providers"
export PROXY_PROVIDERS_LINK="$tmpdir/opt/clash/proxy_providers"
export CACHE_DB_TMPFS="$tmpdir/tmp/clash/cache.db"
export CACHE_DB_LINK="$tmpdir/opt/clash/cache.db"
export MIHOMO_SOCKET_TMPFS="$tmpdir/tmp/clash/mihomo.sock"
export MIHOMO_SOCKET_LINK="$tmpdir/opt/clash/mihomo.sock"
export SERVICE_PID_FILE="$tmpdir/run/mihomo.pid"

mkdir -p "$tmpdir/opt/clash/ruleset" "$tmpdir/opt/clash/proxy_providers"
mkdir -p "$(dirname "$MIHOMO_SOCKET_TMPFS")"
printf 'ruleset-data\n' >"$tmpdir/opt/clash/ruleset/sample.txt"
printf 'provider-data\n' >"$tmpdir/opt/clash/proxy_providers/provider.txt"
printf 'cache-data\n' >"$tmpdir/opt/clash/cache.db"
printf 'stale-socket\n' >"$MIHOMO_SOCKET_TMPFS"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime.sh"

init_runtime_layout

[[ -d "$LIST_DIR" ]] || fail "policy list directory missing"
[[ ! -e "$DST_LIST_FILE" ]] || fail "destination policy list should not be auto-created"
[[ ! -e "$SRC_LIST_FILE" ]] || fail "source policy list should not be auto-created"
[[ ! -e "$DIRECT_DST_LIST_FILE" ]] || fail "direct destination policy list should not be auto-created"
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "ruleset link target mismatch"
assert_symlink_target "$PROXY_PROVIDERS_LINK" "$PROXY_PROVIDERS_TMPFS" "proxy providers link target mismatch"
assert_symlink_target "$CACHE_DB_LINK" "$CACHE_DB_TMPFS" "cache db link target mismatch"
assert_symlink_target "$MIHOMO_SOCKET_LINK" "$MIHOMO_SOCKET_TMPFS" "Mihomo socket link target mismatch"
assert_file_contains "$RULESET_TMPFS/sample.txt" "ruleset-data" "ruleset content not copied"
assert_file_contains "$PROXY_PROVIDERS_TMPFS/provider.txt" "provider-data" "provider content not copied"
assert_file_contains "$CACHE_DB_TMPFS" "cache-data" "cache db content not copied"
[[ ! -e "$MIHOMO_SOCKET_TMPFS" ]] || fail "runtime layout should remove stale Mihomo socket before start"

init_runtime_layout
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "ruleset link should stay stable after rerun"
assert_symlink_target "$MIHOMO_SOCKET_LINK" "$MIHOMO_SOCKET_TMPFS" "Mihomo socket link should stay stable after rerun"

sleep 60 &
active_pid="$!"
mkdir -p "$(dirname "$SERVICE_PID_FILE")"
printf '%s\n' "$active_pid" >"$SERVICE_PID_FILE"
printf 'stale-active-socket\n' >"$MIHOMO_SOCKET_TMPFS"
setup_mihomo_socket_link
[[ ! -e "$MIHOMO_SOCKET_TMPFS" ]] || fail "runtime layout should remove stale Mihomo socket when pid belongs to another process"
kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
rm -f "$SERVICE_PID_FILE" "$MIHOMO_SOCKET_TMPFS"

"$CLASH_BIN" 60 &
mihomo_pid="$!"
mkdir -p "$(dirname "$SERVICE_PID_FILE")"
printf '%s\n' "$mihomo_pid" >"$SERVICE_PID_FILE"
printf 'active-socket\n' >"$MIHOMO_SOCKET_TMPFS"
setup_mihomo_socket_link
assert_file_contains "$MIHOMO_SOCKET_TMPFS" "active-socket" "runtime layout should not remove active Mihomo socket"
kill "$mihomo_pid" 2>/dev/null || true
wait "$mihomo_pid" 2>/dev/null || true
rm -f "$SERVICE_PID_FILE" "$MIHOMO_SOCKET_TMPFS"

wrong_rules_target="$tmpdir/wrong-tmp/ruleset"
mkdir -p "$wrong_rules_target"
rm -f "$RULESET_LINK"
command ln -s "$wrong_rules_target" "$RULESET_LINK"
init_runtime_layout
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "runtime layout should replace stale ruleset symlink to directory"
compgen -G "$wrong_rules_target/ruleset.tmp.*" >/dev/null && fail "runtime layout should not move replacement symlink inside stale target directory"

wrong_socket_target="$tmpdir/wrong-tmp/mihomo.sock"
mkdir -p "$(dirname "$wrong_socket_target")"
rm -f "$MIHOMO_SOCKET_LINK"
command ln -s "$wrong_socket_target" "$MIHOMO_SOCKET_LINK"
init_runtime_layout
assert_symlink_target "$MIHOMO_SOCKET_LINK" "$MIHOMO_SOCKET_TMPFS" "runtime layout should replace stale Mihomo socket symlink"

failure_rules_src="$tmpdir/failure/ruleset"
failure_rules_dst="$tmpdir/failure-tmp/ruleset"
failure_cache_src="$tmpdir/failure/cache.db"
failure_cache_dst="$tmpdir/failure-tmp/cache.db"
mkdir -p "$failure_rules_src"
printf 'ruleset-failure\n' >"$failure_rules_src/failure.txt"
printf 'cache-failure\n' >"$failure_cache_src"

cp() {
	case "$*" in
	"-a $failure_rules_src/. "*) return 1 ;;
	"-a $failure_cache_src "*) return 1 ;;
	esac
	command cp "$@"
}

assert_false "sync_runtime_dir should fail when tmpfs ruleset copy fails" sync_runtime_dir "$failure_rules_src" "$failure_rules_dst"
assert_true "sync_runtime_dir should keep original ruleset dir on copy failure" test -d "$failure_rules_src"
assert_false "sync_runtime_dir should not replace original ruleset dir with symlink on copy failure" test -L "$failure_rules_src"
assert_file_contains "$failure_rules_src/failure.txt" "ruleset-failure" "sync_runtime_dir should preserve original ruleset data on copy failure"

assert_false "sync_runtime_file should fail when tmpfs cache copy fails" sync_runtime_file "$failure_cache_src" "$failure_cache_dst"
assert_true "sync_runtime_file should keep original cache file on copy failure" test -f "$failure_cache_src"
assert_false "sync_runtime_file should not replace original cache file with symlink on copy failure" test -L "$failure_cache_src"
assert_file_contains "$failure_cache_src" "cache-failure" "sync_runtime_file should preserve original cache data on copy failure"

link_fail_rules_src="$tmpdir/link-failure/ruleset"
link_fail_rules_dst="$tmpdir/link-failure-tmp/ruleset"
link_fail_cache_src="$tmpdir/link-failure/cache.db"
link_fail_cache_dst="$tmpdir/link-failure-tmp/cache.db"
mkdir -p "$link_fail_rules_src"
printf 'ruleset-link-failure\n' >"$link_fail_rules_src/original.txt"
printf 'cache-link-failure\n' >"$link_fail_cache_src"

ln() {
	case "$*" in
	"-s $link_fail_rules_dst $link_fail_rules_src.tmp."* | "-s $link_fail_cache_dst $link_fail_cache_src.tmp."*)
		return 1
		;;
	esac
	command ln "$@"
}

assert_false "sync_runtime_dir should fail when runtime symlink creation fails" sync_runtime_dir "$link_fail_rules_src" "$link_fail_rules_dst"
assert_true "sync_runtime_dir should restore original ruleset dir after symlink failure" test -d "$link_fail_rules_src"
assert_false "sync_runtime_dir should not leave failed ruleset symlink behind" test -L "$link_fail_rules_src"
assert_file_contains "$link_fail_rules_src/original.txt" "ruleset-link-failure" "sync_runtime_dir should restore original ruleset data after symlink failure"

assert_false "sync_runtime_file should fail when cache symlink creation fails" sync_runtime_file "$link_fail_cache_src" "$link_fail_cache_dst"
assert_true "sync_runtime_file should restore original cache file after symlink failure" test -f "$link_fail_cache_src"
assert_false "sync_runtime_file should not leave failed cache symlink behind" test -L "$link_fail_cache_src"
assert_file_contains "$link_fail_cache_src" "cache-link-failure" "sync_runtime_file should restore original cache data after symlink failure"

pass "runtime layout init is idempotent"
