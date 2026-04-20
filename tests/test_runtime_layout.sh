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

[[ -f "$DST_LIST_FILE" ]] || fail "destination policy list missing"
[[ -f "$SRC_LIST_FILE" ]] || fail "source policy list missing"
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "ruleset link target mismatch"
assert_symlink_target "$PROXY_PROVIDERS_LINK" "$PROXY_PROVIDERS_TMPFS" "proxy providers link target mismatch"
assert_symlink_target "$CACHE_DB_LINK" "$CACHE_DB_TMPFS" "cache db link target mismatch"
assert_file_contains "$RULESET_TMPFS/sample.txt" "ruleset-data" "ruleset content not copied"
assert_file_contains "$PROXY_PROVIDERS_TMPFS/provider.txt" "provider-data" "provider content not copied"
assert_file_contains "$CACHE_DB_TMPFS" "cache-data" "cache db content not copied"

init_runtime_layout
assert_symlink_target "$RULESET_LINK" "$RULESET_TMPFS" "ruleset link should stay stable after rerun"

pass "runtime layout init is idempotent"
