#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "/etc/openwrt_release" ]]; then
	printf "%s\n" "${TEST_OPENWRT_RELEASE:-}"
else
	exec /bin/cat "$@"
fi
EOF

cat > "$tmpdir/clash" <<'EOF'
#!/usr/bin/env bash
printf 'Mihomo Meta %s\n' 'v1.18.7'
EOF

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$tmpbin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit "${TEST_PGREP_RC:-1}"
EOF

chmod +x "$tmpbin/cat" "$tmpdir/clash" "$tmpbin/logger" "$tmpbin/pgrep"

export PATH="$tmpbin:$PATH"
export TEST_OPENWRT_RELEASE="DISTRIB_ARCH='aarch64_cortex-a53'"
export CLASH_BIN="$tmpdir/clash"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

assert_eq "1.2.3" "$(normalize_version 'mihomo v1.2.3 build test')" "normalize_version strips prefix"
assert_true "version_ge should accept equal versions" version_ge "1.2.3" "1.2.3"
assert_true "version_ge should accept newer version" version_ge "1.2.4" "1.2.3"
assert_false "version_ge should reject older version" version_ge "1.2.2" "1.2.3"
assert_eq "arm64" "$(detect_mihomo_arch)" "detect_mihomo_arch maps OpenWrt arch"
assert_eq "v1.18.7" "$(current_mihomo_version)" "current_mihomo_version reads Mihomo binary"

export SERVICE_PID_FILE="$tmpdir/mihomo.pid"
export ORCHESTRATOR="/usr/bin/mihowrt"

sleep 30 &
test_pid="$!"
printf '%s\n' "$test_pid" > "$SERVICE_PID_FILE"
assert_true "service_running_state should accept live pid file" service_running_state
kill "$test_pid" 2>/dev/null || true
wait "$test_pid" 2>/dev/null || true

rm -f "$SERVICE_PID_FILE"
export TEST_PGREP_RC=0
assert_true "service_running_state should fall back to pgrep when pid file is missing" service_running_state
export TEST_PGREP_RC=1
assert_false "service_running_state should fail when neither pid nor pgrep match exists" service_running_state

pass "helpers version and arch checks"
