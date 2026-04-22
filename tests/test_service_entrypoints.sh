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
	return "${TEST_CLEANUP_RUNTIME_RC:-0}"
}

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=0
run_service
assert_file_contains "$cli_log" "load_runtime_config" "run_service should load runtime config"
assert_file_contains "$cli_log" "validate_runtime_config" "run_service should validate runtime config"
assert_file_contains "$cli_log" "init_runtime_layout" "run_service should initialize runtime layout"
assert_file_contains "$cli_log" "wait_for_mihomo_ready:7874:7894:" "run_service should wait for Mihomo ports"
assert_file_contains "$cli_log" "apply_runtime_state" "run_service should apply runtime state after Mihomo is ready"
assert_file_contains "$cli_log" "log:MihoWRT service ready" "run_service should log service readiness only after Mihomo and policy state are ready"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean up runtime state on exit"
[[ ! -e "$SERVICE_PID_FILE" ]] || fail "run_service should remove PID file on clean exit"

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=1
assert_false "run_service should fail when runtime cleanup fails on exit" run_service
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should still attempt runtime cleanup before failing"
[[ ! -e "$SERVICE_PID_FILE" ]] || fail "run_service should remove PID file even when cleanup fails"

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=1
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=0
assert_false "run_service should fail when Mihomo readiness probe fails" run_service
assert_file_contains "$cli_log" "err:Mihomo failed to become ready on DNS port 7874 and TPROXY port 7894" "run_service should report readiness failure"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean runtime state after readiness failure"
assert_file_not_contains "$cli_log" "apply_runtime_state" "run_service should not apply runtime state before readiness succeeds"

: > "$cli_log"
TEST_ENABLED=1
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=1
TEST_CLEANUP_RUNTIME_RC=0
assert_false "run_service should fail when runtime policy apply fails" run_service
assert_file_contains "$cli_log" "err:Failed to apply runtime policy after Mihomo became ready" "run_service should report runtime apply failure"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean runtime state after policy apply failure"

config_override_output="$(
	set -- read-config "$tmpdir/alt-config.yaml"
	CLASH_CONFIG="/opt/clash/config.yaml"
	read_config_json() {
		printf '%s\n' "$CLASH_CONFIG"
	}
	# shellcheck disable=SC1090
	source <(
		sed '/^check_required_file \/lib\/functions\.sh$/,/^\. \/usr\/lib\/mihowrt\/runtime\.sh$/d' \
			"$ROOT_DIR/rootfs/usr/bin/mihowrt"
	)
)"
assert_eq "$tmpdir/alt-config.yaml" "$config_override_output" "read-config command should accept config path override"

apply_config_output="$(
	set -- apply-config "$tmpdir/candidate.yaml"
	apply_config_file() {
		printf '%s\n' "$1"
	}
	# shellcheck disable=SC1090
	source <(
		sed '/^check_required_file \/lib\/functions\.sh$/,/^\. \/usr\/lib\/mihowrt\/runtime\.sh$/d' \
			"$ROOT_DIR/rootfs/usr/bin/mihowrt"
	)
)"
assert_eq "$tmpdir/candidate.yaml" "$apply_config_output" "apply-config command should forward temp config path"

service_ready_output="$(
	set -- service-ready
	service_ready_runtime_state() {
		printf 'ready\n'
	}
	# shellcheck disable=SC1090
	source <(
		sed '/^check_required_file \/lib\/functions\.sh$/,/^\. \/usr\/lib\/mihowrt\/runtime\.sh$/d' \
			"$ROOT_DIR/rootfs/usr/bin/mihowrt"
	)
)"
assert_eq "ready" "$service_ready_output" "service-ready command should dispatch to runtime readiness helper"

source_init_mihowrt_lib

ORCHESTRATOR="$tmpdir/orchestrator.sh"
CLASH_DIR="$tmpdir/init-clash"
CLASH_BIN="$tmpdir/init-clash-bin"
CLASH_CONFIG="$tmpdir/config.yaml"
SKIP_START_FILE="$tmpdir/skip-start"
SERVICE_PID_FILE="$tmpdir/init.pid"

export TEST_ORCH_LOG="$orch_log"
export TEST_ORCH_VALIDATE_RC=0
export TEST_ORCH_CLEANUP_RC=0
export TEST_ORCH_READY_RC=0
export TEST_CLASH_TEST_RC=0
export TEST_SERVICE_PID_FILE="$SERVICE_PID_FILE"

cat > "$ORCHESTRATOR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ORCH_LOG"
case "${1:-}" in
	service-running)
		[ -f "${TEST_SERVICE_PID_FILE:-}" ] && exit 0
		exit 1
		;;
	validate)
		exit "${TEST_ORCH_VALIDATE_RC:-0}"
		;;
	cleanup)
			exit "${TEST_ORCH_CLEANUP_RC:-0}"
			;;
		service-ready)
			exit "${TEST_ORCH_READY_RC:-0}"
			;;
		recover|run-service)
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

stop() {
	printf 'stop\n' >>"$msg_log"
}

sleep() {
	:
}

SERVICE_READY_TIMEOUT=2

: > "$msg_log"
: > "$procd_log"
: > "$orch_log"
export TEST_ORCH_VALIDATE_RC=0
export TEST_ORCH_CLEANUP_RC=0
export TEST_ORCH_READY_RC=0
export TEST_CLASH_TEST_RC=0
rm -f "$SKIP_START_FILE"
start_service
assert_file_contains "$msg_log" "Starting MihoWRT service..." "start_service should log service start"
assert_file_contains "$orch_log" "recover" "start_service should run crash recovery before start"
assert_file_contains "$orch_log" "validate" "start_service should validate policy state"
assert_file_contains "$orch_log" "cleanup" "start_service should clean stale runtime state before procd start"
assert_file_contains "$orch_log" "service-ready" "start_service should wait for service readiness before success"
assert_file_contains "$procd_log" "set:command $ORCHESTRATOR run-service" "start_service should register run-service command with procd"
assert_file_not_contains "$procd_log" "set:file " "start_service should avoid procd file triggers that race explicit UI apply/reload"
assert_file_contains "$msg_log" "MihoWRT service registered with procd" "start_service should not claim readiness before runtime start completes"
assert_file_not_contains "$msg_log" "MihoWRT service started" "start_service should avoid premature started log"

: > "$msg_log"
: > "$procd_log"
: > "$orch_log"
export TEST_ORCH_CLEANUP_RC=1
assert_false "start_service should fail when stale runtime cleanup fails" start_service
assert_file_contains "$msg_log" "ERROR: Failed to clean stale runtime state" "start_service should report stale runtime cleanup failure"
[[ ! -s "$procd_log" ]] || fail "start_service should not register procd instance when cleanup fails"
export TEST_ORCH_CLEANUP_RC=0

: > "$msg_log"
: > "$procd_log"
: > "$orch_log"
export TEST_ORCH_READY_RC=1
assert_false "start_service should fail when service never becomes ready" start_service
assert_file_contains "$orch_log" "service-ready" "start_service should wait for readiness before failing"
assert_file_contains "$msg_log" "stop" "start_service should stop procd instance after readiness timeout"
assert_file_contains "$msg_log" "ERROR: MihoWRT service did not become ready after start" "start_service should report readiness timeout"
assert_file_not_contains "$msg_log" "MihoWRT service registered with procd" "start_service should not claim success when readiness never arrives"
export TEST_ORCH_READY_RC=0

: > "$msg_log"
: > "$procd_log"
: > "$orch_log"
: > "$SKIP_START_FILE"
start_service
assert_file_contains "$msg_log" "Skipping MihoWRT service auto-start during installer transaction" "start_service should honor skip-start marker"
[[ ! -s "$orch_log" ]] || fail "start_service should not call orchestrator when skip-start marker exists"
[[ ! -s "$procd_log" ]] || fail "start_service should not open procd instance when skip-start marker exists"
rm -f "$SKIP_START_FILE"

start() {
	printf 'start\n' >>"$msg_log"
}

: > "$msg_log"
reload_service
printf '%s\n' "$$" > "$SERVICE_PID_FILE"
reload_service
assert_file_contains "$msg_log" "Reloading MihoWRT policy..." "reload_service should log policy reload"
assert_file_contains "$msg_log" "MihoWRT policy reloaded" "reload_service should log successful policy reload"
assert_file_contains "$orch_log" "service-running" "reload_service should check service state through orchestrator"
assert_file_contains "$orch_log" "reload-policy" "reload_service should invoke policy-only reload through orchestrator"

: > "$msg_log"
: > "$orch_log"
rm -f "$SERVICE_PID_FILE"
reload_service
assert_file_contains "$msg_log" "MihoWRT service is not running; skipping policy reload" "reload_service should skip policy reload when service is stopped"
assert_file_contains "$orch_log" "service-running" "reload_service should still ask orchestrator for service state when service is stopped"
assert_file_not_contains "$orch_log" "reload-policy" "reload_service should not invoke policy reload when service is stopped"

: > "$msg_log"
: > "$orch_log"
printf '%s\n' "$$" > "$SERVICE_PID_FILE"
apply
assert_file_contains "$msg_log" "Applying MihoWRT on-disk config..." "apply should announce on-disk apply flow"
assert_file_contains "$msg_log" "MihoWRT service is running; restarting to apply on-disk changes" "apply should restart running service after validation"
assert_file_contains "$msg_log" "stop" "apply should stop running service before restart"
assert_file_contains "$msg_log" "start" "apply should start service after stop during apply"
assert_file_contains "$msg_log" "MihoWRT on-disk changes applied" "apply should confirm successful on-disk apply"
assert_file_contains "$orch_log" "validate" "apply should validate policy before restart"
assert_file_contains "$orch_log" "service-running" "apply should check service state before restart"

: > "$msg_log"
: > "$orch_log"
rm -f "$SERVICE_PID_FILE"
apply
assert_file_contains "$msg_log" "MihoWRT service is not running; validated on-disk config only" "apply should avoid starting stopped service implicitly"
assert_file_contains "$orch_log" "validate" "apply should still validate config when service is stopped"
assert_file_contains "$orch_log" "service-running" "apply should still inspect running state when service is stopped"
assert_file_not_contains "$msg_log" "start" "apply should not start stopped service automatically"

: > "$msg_log"
: > "$orch_log"
: > "$SKIP_START_FILE"
printf '%s\n' "$$" > "$SERVICE_PID_FILE"
assert_false "apply should fail while installer skip-start marker is active" apply
assert_file_contains "$msg_log" "ERROR: Cannot apply while installer skip-start marker is active" "apply should explain skip-start conflict"
assert_file_not_contains "$msg_log" "stop" "apply should not stop service when skip-start marker blocks restart"
assert_eq "0" "$(grep -c '^start$' "$msg_log" || true)" "apply should not restart service when skip-start marker blocks apply"
assert_file_not_contains "$orch_log" "validate" "apply should bail before validation when skip-start marker is active"
rm -f "$SKIP_START_FILE"

(
	source_init_recover_lib
	ORCHESTRATOR="$tmpdir/orchestrator.sh"
	start
)
assert_file_contains "$orch_log" "recover" "recover init script should invoke orchestrator recover action"

pass "service entrypoints"
