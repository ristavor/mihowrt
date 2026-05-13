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

module_dir="$tmpdir/modules"
mkdir -p "$module_dir"
printf '%s\n' "loaded_modules=\"\${loaded_modules:+\$loaded_modules }one\"" >"$module_dir/one.sh"
printf '%s\n' "loaded_modules=\"\${loaded_modules:+\$loaded_modules }two\"" >"$module_dir/two.sh"
saved_mihowrt_lib_dir="$MIHOWRT_LIB_DIR"
MIHOWRT_LIB_DIR="$module_dir"
loaded_modules=""
mihowrt_source_module_list "one.sh two.sh"
MIHOWRT_LIB_DIR="$saved_mihowrt_lib_dir"
assert_eq "one two" "$loaded_modules" "mihowrt_source_module_list should source modules from shared manifest order"

assert_true "uint_lte should accept equal values" uint_lte "4294967295" "4294967295"
assert_true "uint_lte should accept leading zero values below max" uint_lte "00065535" "65535"
assert_false "uint_lte should reject values above max" uint_lte "4294967296" "4294967295"
assert_false "uint_lte should reject non-integers" uint_lte "12x" "65535"
assert_true "is_valid_port should accept max port" is_valid_port "65535"
assert_false "is_valid_port should reject port above max" is_valid_port "65536"
assert_true "is_valid_uint32_mark should accept max mark" is_valid_uint32_mark "4294967295"
assert_false "is_valid_uint32_mark should reject mark above max" is_valid_uint32_mark "4294967296"
assert_true "shell_name_chars_valid should accept DNS host punctuation" shell_name_chars_valid "mihomo.local:9090-test"
assert_false "shell_name_chars_valid should reject shell metacharacters" shell_name_chars_valid "bad^server"

assert_eq "1.2.3" "$(normalize_version 'mihomo v1.2.3 build test')" "normalize_version strips prefix"
assert_true "version_ge should accept equal versions" version_ge "1.2.3" "1.2.3"
assert_true "version_ge should accept newer version" version_ge "1.2.4" "1.2.3"
assert_false "version_ge should reject older version" version_ge "1.2.2" "1.2.3"
assert_eq "arm64" "$(detect_mihomo_arch)" "detect_mihomo_arch maps OpenWrt arch"
assert_eq "v1.18.7" "$(current_mihomo_version)" "current_mihomo_version reads Mihomo binary"

export SERVICE_PID_FILE="$tmpdir/mihomo.pid"
export ORCHESTRATOR="/usr/bin/mihowrt"
export SERVICE_RUN_PATTERN="$tmpdir/mihowrt-service run-service"
export CLASH_DIR="$tmpdir/clash-dir"
mkdir -p "$CLASH_DIR"

cat > "$tmpdir/mihowrt-service" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$tmpdir/mihowrt-service"

"$tmpdir/mihowrt-service" run-service &
test_pid="$!"
printf '%s\n' "$test_pid" > "$SERVICE_PID_FILE"
assert_true "service_running_state should accept live pid file" service_running_state
kill "$test_pid" 2>/dev/null || true
wait "$test_pid" 2>/dev/null || true

cat > "$tmpdir/mihomo-child" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$tmpdir/mihomo-child"
export CLASH_BIN="$tmpdir/mihomo-child"
"$tmpdir/mihomo-child" -d "$CLASH_DIR" &
test_pid="$!"
printf '%s\n' "$test_pid" > "$SERVICE_PID_FILE"
export TEST_PGREP_RC=1
assert_true "service_running_state should accept live Mihomo child pid file without pgrep" service_running_state
kill "$test_pid" 2>/dev/null || true
wait "$test_pid" 2>/dev/null || true

printf '%s\n' "$$" > "$SERVICE_PID_FILE"
export TEST_PGREP_RC=1
assert_false "service_running_state should reject stale pid file when cmdline does not match" service_running_state

rm -f "$SERVICE_PID_FILE"
export TEST_PGREP_RC=0
assert_true "service_running_state should fall back to pgrep when pid file is missing" service_running_state
export TEST_PGREP_RC=1
assert_false "service_running_state should fail when neither pid nor pgrep match exists" service_running_state

service_running_state() {
	return "${TEST_SERVICE_RUNNING_RC:-0}"
}

port_listening_udp() {
	[[ "$1" == "${TEST_DNS_PORT_READY:-}" ]]
}

port_listening_tcp() {
	[[ "$1" == "${TEST_TPROXY_PORT_TCP_READY:-}" ]]
}

TEST_DNS_PORT_READY="7874"
TEST_TPROXY_PORT_TCP_READY="7894"
assert_true "mihomo_ready_state should accept ready UDP+TCP listeners" mihomo_ready_state "7874" "7894"
TEST_TPROXY_PORT_TCP_READY=""
port_listening_udp() {
	[[ "$1" == "7874" || "$1" == "7894" ]]
}
assert_true "mihomo_ready_state should accept ready UDP+UDP listeners" mihomo_ready_state "7874" "7894"
TEST_SERVICE_RUNNING_RC=1
assert_false "mihomo_ready_state should fail when service is not running" mihomo_ready_state "7874" "7894"
TEST_SERVICE_RUNNING_RC=0
assert_false "mihomo_ready_state should reject invalid ports" mihomo_ready_state "bad" "7894"

pass "helpers version and arch checks"
