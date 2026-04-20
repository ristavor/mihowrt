#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

cli_log="$tmpdir/cli.log"
msg_log="$tmpdir/msg.log"
procd_log="$tmpdir/procd.log"
orch_log="$tmpdir/orch.log"

source_mihowrt_cli_lib

CLASH_DIR="$tmpdir/clash"
CLASH_BIN="$tmpdir/clash-bin"
PKG_STATE_DIR="$tmpdir/run"
SERVICE_PID_FILE="$PKG_STATE_DIR/mihomo.pid"
mkdir -p "$CLASH_DIR"

cat > "$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
sleep "${TEST_CLASH_SLEEP:-0}"
exit "${TEST_CLASH_RC:-0}"
EOF
chmod +x "$CLASH_BIN"

log() {
	printf 'log:%s\n' "$*" >>"$cli_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$cli_log"
}

load_runtime_config() {
	printf 'load_runtime_config\n' >>"$cli_log"
	ENABLED="${TEST_ENABLED:-1}"
	MIHOMO_DNS_LISTEN="127.0.0.1#7874"
	MIHOMO_TPROXY_PORT="7894"
	return 0
}

validate_runtime_config() {
	printf 'validate_runtime_config\n' >>"$cli_log"
	return 0
}

ensure_dir() {
	printf 'ensure_dir:%s\n' "$1" >>"$cli_log"
	mkdir -p "$1"
}

init_runtime_layout() {
	printf 'init_runtime_layout\n' >>"$cli_log"
	return 0
}

dns_listen_port() {
	printf '7874\n'
}

wait_for_mihomo_ready() {
	printf 'wait_for_mihomo_ready:%s:%s:%s\n' "$1" "$2" "$3" >>"$cli_log"
	return "${TEST_WAIT_READY_RC:-0}"
}

apply_runtime_state() {
	printf 'apply_runtime_state\n' >>"$cli_log"
	return "${TEST_APPLY_RUNTIME_RC:-0}"
}

cleanup_runtime_state() {
	printf 'cleanup_runtime_state\n' >>"$cli_log"
	return 0
}

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=0
run_service
assert_file_contains "$cli_log" "load_runtime_config" "run_service should load runtime config"
assert_file_contains "$cli_log" "validate_runtime_config" "run_service should validate runtime config"
assert_file_contains "$cli_log" "init_runtime_layout" "run_service should initialize runtime layout"
assert_file_contains "$cli_log" "wait_for_mihomo_ready:7874:7894:" "run_service should wait for Mihomo ports"
assert_file_contains "$cli_log" "apply_runtime_state" "run_service should apply runtime state after Mihomo is ready"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean up runtime state on exit"
[[ ! -e "$SERVICE_PID_FILE" ]] || fail "run_service should remove PID file on clean exit"

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=1
TEST_APPLY_RUNTIME_RC=0
assert_false "run_service should fail when Mihomo readiness probe fails" run_service
assert_file_contains "$cli_log" "err:Mihomo failed to become ready on DNS port 7874 and TPROXY port 7894" "run_service should report readiness failure"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean runtime state after readiness failure"
assert_file_not_contains "$cli_log" "apply_runtime_state" "run_service should not apply runtime state before readiness succeeds"

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=1
assert_false "run_service should fail when runtime policy apply fails" run_service
assert_file_contains "$cli_log" "err:Failed to apply runtime policy after Mihomo became ready" "run_service should report runtime apply failure"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean runtime state after policy apply failure"

source_init_mihowrt_lib

ORCHESTRATOR="$tmpdir/orchestrator.sh"
CLASH_DIR="$tmpdir/init-clash"
CLASH_BIN="$tmpdir/init-clash-bin"
CLASH_CONFIG="$tmpdir/config.yaml"
SKIP_START_FILE="$tmpdir/skip-start"
SERVICE_PID_FILE="$tmpdir/init.pid"

export TEST_ORCH_LOG="$orch_log"

cat > "$ORCHESTRATOR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ORCH_LOG"
case "${1:-}" in
	validate)
		exit "${TEST_ORCH_VALIDATE_RC:-0}"
		;;
	recover|cleanup|run-service)
		exit 0
		;;
esac
exit 0
EOF

cat > "$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
case " $* " in
	*" -t "*)
		exit "${TEST_CLASH_TEST_RC:-0}"
		;;
esac
exit 0
EOF

chmod +x "$ORCHESTRATOR" "$CLASH_BIN"
mkdir -p "$CLASH_DIR"
printf 'mode: rule\n' > "$CLASH_CONFIG"

msg() {
	printf '%s\n' "$*" >>"$msg_log"
}

procd_open_instance() {
	printf 'open\n' >>"$procd_log"
}

procd_set_param() {
	printf 'set:%s\n' "$*" >>"$procd_log"
}

procd_close_instance() {
	printf 'close\n' >>"$procd_log"
}

: > "$msg_log"
: > "$procd_log"
: > "$orch_log"
TEST_ORCH_VALIDATE_RC=0
TEST_CLASH_TEST_RC=0
rm -f "$SKIP_START_FILE"
start_service
assert_file_contains "$msg_log" "Starting MihoWRT service..." "start_service should log service start"
assert_file_contains "$orch_log" "recover" "start_service should run crash recovery before start"
assert_file_contains "$orch_log" "validate" "start_service should validate policy state"
assert_file_contains "$orch_log" "cleanup" "start_service should clean stale runtime state before procd start"
assert_file_contains "$procd_log" "set:command $ORCHESTRATOR run-service" "start_service should register run-service command with procd"
assert_file_contains "$procd_log" "set:file $CLASH_CONFIG /etc/config/mihowrt /opt/clash/lst/always_proxy_dst.txt /opt/clash/lst/always_proxy_src.txt" "start_service should register config and list file triggers"

: > "$msg_log"
: > "$procd_log"
: > "$orch_log"
: > "$SKIP_START_FILE"
start_service
assert_file_contains "$msg_log" "Skipping MihoWRT service auto-start during installer transaction" "start_service should honor skip-start marker"
[[ ! -s "$orch_log" ]] || fail "start_service should not call orchestrator when skip-start marker exists"
[[ ! -s "$procd_log" ]] || fail "start_service should not open procd instance when skip-start marker exists"
rm -f "$SKIP_START_FILE"

stop() {
	printf 'stop\n' >>"$msg_log"
}

start() {
	printf 'start\n' >>"$msg_log"
}

wait_for_stop_complete() {
	printf 'wait_for_stop_complete\n' >>"$msg_log"
	return 1
}

: > "$msg_log"
reload_service
assert_file_contains "$msg_log" "Reloading MihoWRT service..." "reload_service should log reload"
assert_file_contains "$msg_log" "stop" "reload_service should stop existing service before start"
assert_file_contains "$msg_log" "wait_for_stop_complete" "reload_service should wait for stop completion"
assert_file_contains "$msg_log" "WARNING: previous MihoWRT stop still draining during reload" "reload_service should warn when stop drain takes too long"
assert_file_contains "$msg_log" "start" "reload_service should start service after stop"

(
	source_init_recover_lib
	ORCHESTRATOR="$tmpdir/orchestrator.sh"
	start
)
assert_file_contains "$orch_log" "recover" "recover init script should invoke orchestrator recover action"

pass "service entrypoints"
