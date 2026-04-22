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

export LIST_DIR="$tmpdir/opt/clash/lst"
export DST_LIST_FILE="$LIST_DIR/always_proxy_dst.txt"
export SRC_LIST_FILE="$LIST_DIR/always_proxy_src.txt"
export RULESET_TMPFS="$tmpdir/tmp/clash/ruleset"
export RULESET_LINK="$tmpdir/opt/clash/ruleset"
export PROXY_PROVIDERS_TMPFS="$tmpdir/tmp/clash/proxy_providers"
export PROXY_PROVIDERS_LINK="$tmpdir/opt/clash/proxy_providers"
export CACHE_DB_TMPFS="$tmpdir/tmp/clash/cache.db"
export CACHE_DB_LINK="$tmpdir/opt/clash/cache.db"

mkdir -p "$tmpdir/opt/clash/ruleset" "$tmpdir/opt/clash/proxy_providers"
printf 'ruleset-data\n' > "$tmpdir/opt/clash/ruleset/sample.txt"
printf 'provider-data\n' > "$tmpdir/opt/clash/proxy_providers/provider.txt"
printf 'cache-data\n' > "$tmpdir/opt/clash/cache.db"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime.sh"

init_runtime_layout

[[ -d "$LIST_DIR" ]] || fail "policy list directory missing"
[[ ! -e "$DST_LIST_FILE" ]] || fail "destination policy list should not be auto-created"
[[ ! -e "$SRC_LIST_FILE" ]] || fail "source policy list should not be auto-created"
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "ruleset link target mismatch"
assert_symlink_target "$PROXY_PROVIDERS_LINK" "$PROXY_PROVIDERS_TMPFS" "proxy providers link target mismatch"
assert_symlink_target "$CACHE_DB_LINK" "$CACHE_DB_TMPFS" "cache db link target mismatch"
assert_file_contains "$RULESET_TMPFS/sample.txt" "ruleset-data" "ruleset content not copied"
assert_file_contains "$PROXY_PROVIDERS_TMPFS/provider.txt" "provider-data" "provider content not copied"
assert_file_contains "$CACHE_DB_TMPFS" "cache-data" "cache db content not copied"

init_runtime_layout
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "ruleset link should stay stable after rerun"

failure_rules_src="$tmpdir/failure/ruleset"
failure_rules_dst="$tmpdir/failure-tmp/ruleset"
failure_cache_src="$tmpdir/failure/cache.db"
failure_cache_dst="$tmpdir/failure-tmp/cache.db"
mkdir -p "$failure_rules_src"
printf 'ruleset-failure\n' > "$failure_rules_src/failure.txt"
printf 'cache-failure\n' > "$failure_cache_src"

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

pass "runtime layout init is idempotent"
