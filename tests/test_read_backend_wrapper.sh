#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backend="$tmpdir/mihowrt"
call_log="$tmpdir/backend.log"
wrapper="$ROOT_DIR/rootfs/usr/bin/mihowrt-read"

cat > "$backend" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_BACKEND_LOG"
printf 'ok\n'
EOF
chmod +x "$backend"
export TEST_BACKEND_LOG="$call_log"

MIHOWRT_BACKEND="$backend" sh "$wrapper" status-json >/dev/null
assert_file_contains "$call_log" "status-json" "read wrapper should forward status-json"

: > "$call_log"
MIHOWRT_BACKEND="$backend" sh "$wrapper" live-api-json >/dev/null
assert_file_contains "$call_log" "live-api-json" "read wrapper should forward live-api-json"

: > "$call_log"
MIHOWRT_BACKEND="$backend" sh "$wrapper" read-config /tmp/mihowrt-config.test >/dev/null
assert_file_contains "$call_log" "read-config /tmp/mihowrt-config.test" "read wrapper should allow MihoWRT temp config previews"

: > "$call_log"
if MIHOWRT_BACKEND="$backend" sh "$wrapper" apply-config /tmp/mihowrt-config.test >/dev/null 2>&1; then
	fail "read wrapper should reject mutating backend commands"
fi
[[ ! -s "$call_log" ]] || fail "read wrapper should not call backend for mutating commands"

if MIHOWRT_BACKEND="$backend" sh "$wrapper" read-config /etc/passwd >/dev/null 2>&1; then
	fail "read wrapper should reject arbitrary config paths"
fi

pass "read backend wrapper"
