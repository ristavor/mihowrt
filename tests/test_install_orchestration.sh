#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

event_log="$tmpdir/events.log"
init_log="$tmpdir/init.log"
orch_log="$tmpdir/orch.log"
tmpbin="$tmpdir/bin"

mkdir -p "$tmpbin"

export TEST_INIT_LOG="$init_log"
export TEST_ORCH_LOG="$orch_log"
export TEST_INIT_ENABLED_RC=1
export TEST_INIT_RESTART_RC=0
export TEST_INIT_START_RC=0
export TEST_INIT_STOP_RC=0
export TEST_WAIT_RUNNING_RC=0
export TEST_PGREP_RC=1
export PATH="$tmpbin:$PATH"

source_install_lib
REAL_QUIESCE_POSTINSTALL_SERVICE="$(declare -f quiesce_postinstall_service)"
REAL_INSTALL_SERVICE_RUNNING="$(declare -f service_running)"
REAL_MIGRATE_RESTORED_POLICY_LISTS="$(declare -f migrate_restored_policy_lists)"

INIT_SCRIPT="$tmpdir/init.sh"
ORCHESTRATOR="$tmpdir/orchestrator.sh"

cat > "$INIT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_INIT_LOG"
case "${1:-}" in
	enabled)
		exit "${TEST_INIT_ENABLED_RC:-1}"
		;;
	restart)
		exit "${TEST_INIT_RESTART_RC:-0}"
		;;
	start)
		exit "${TEST_INIT_START_RC:-0}"
		;;
	stop)
		exit "${TEST_INIT_STOP_RC:-0}"
		;;
	enable|disable)
		exit 0
		;;
esac
exit 0
EOF

cat > "$ORCHESTRATOR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ORCH_LOG"
exit 0
EOF

cat > "$tmpbin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit "${TEST_PGREP_RC:-1}"
EOF

chmod +x "$INIT_SCRIPT" "$ORCHESTRATOR" "$tmpbin/pgrep"

log() {
	printf 'log:%s\n' "$*" >>"$event_log"
}

warn() {
	printf 'warn:%s\n' "$*" >>"$event_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$event_log"
}

backup_user_state() {
	printf 'backup_user_state\n' >>"$event_log"
}

cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
}

restore_system_dns_defaults() {
	printf 'restore_system_dns_defaults:%s\n' "$1" >>"$event_log"
	return 0
}

service_enabled() {
	return 0
}

service_running() {
	return "${TEST_SERVICE_RUNNING_RC:-0}"
}

apk_supports_virtual() {
	return "${TEST_APK_SUPPORTS_VIRTUAL_RC:-0}"
}

hold_reinstall_dependencies() {
	printf 'hold_reinstall_dependencies\n' >>"$event_log"
	return "${TEST_HOLD_DEPS_RC:-0}"
}

release_reinstall_dependencies() {
	printf 'release_reinstall_dependencies\n' >>"$event_log"
}

clear_skip_start() {
	printf 'clear_skip_start\n' >>"$event_log"
}

quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
}

restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 0
}

migrate_restored_policy_lists() {
	printf 'migrate_restored_policy_lists\n' >>"$event_log"
	return 0
}

preserve_backup_dir() {
	printf 'preserve_backup_dir\n' >>"$event_log"
}

wait_for_service_stop() {
	printf 'wait_for_service_stop\n' >>"$event_log"
	return 0
}

wait_for_service_running() {
	printf 'wait_for_service_running\n' >>"$event_log"
	return "${TEST_WAIT_RUNNING_RC:-0}"
}

kernel_remove() {
	printf 'kernel_remove\n' >>"$event_log"
}

remove_user_state() {
	printf 'remove_user_state\n' >>"$event_log"
}

apk() {
	printf 'apk:%s\n' "$*" >>"$event_log"
}

cat > "$tmpdir/foreign-service" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$tmpdir/foreign-service"

CLASH_DIR="$tmpdir/clash-dir"
CLASH_BIN="$tmpdir/mihomo-child"
mkdir -p "$CLASH_DIR"
cat > "$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$CLASH_BIN"

: > "$event_log"
: > "$init_log"
: > "$orch_log"
SERVICE_PID_FILE="$tmpdir/install-service.pid"
ORCHESTRATOR="$tmpdir/missing-orchestrator"
TEST_PGREP_RC=1
"$tmpdir/foreign-service" &
foreign_pid="$!"
printf '%s\n' "$foreign_pid" > "$SERVICE_PID_FILE"
eval "$REAL_INSTALL_SERVICE_RUNNING"
assert_false "installer service_running should reject stale pid file when cmdline does not match" service_running
kill "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true

: > "$event_log"
: > "$init_log"
: > "$orch_log"
TEST_PGREP_RC=1
"$CLASH_BIN" -d "$CLASH_DIR" &
mihomo_child_pid="$!"
printf '%s\n' "$mihomo_child_pid" > "$SERVICE_PID_FILE"
assert_true "installer service_running should accept live Mihomo child pid file without pgrep" service_running
kill "$mihomo_child_pid" 2>/dev/null || true
wait "$mihomo_child_pid" 2>/dev/null || true

service_running() {
	return "${TEST_SERVICE_RUNNING_RC:-0}"
}
ORCHESTRATOR="$tmpdir/orchestrator.sh"

: > "$orch_log"
eval "$REAL_MIGRATE_RESTORED_POLICY_LISTS"
assert_true "migrate_restored_policy_lists should invoke installed orchestrator when present" migrate_restored_policy_lists
assert_file_contains "$orch_log" "migrate-policy-lists" "migrate_restored_policy_lists should run policy list migration command"
migrate_restored_policy_lists() {
	printf 'migrate_restored_policy_lists\n' >>"$event_log"
	return 0
}

: > "$event_log"
: > "$init_log"
: > "$orch_log"
TEST_SERVICE_RUNNING_RC=0
TEST_INIT_STOP_RC=1
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
eval "$REAL_QUIESCE_POSTINSTALL_SERVICE"
assert_false "quiesce_postinstall_service should fail when fallback cleanup fails" quiesce_postinstall_service
assert_file_contains "$init_log" "stop" "quiesce_postinstall_service should try stopping auto-started service first"
assert_file_contains "$orch_log" "cleanup" "quiesce_postinstall_service should ask orchestrator to clean runtime state after stop failure"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "quiesce_postinstall_service should attempt runtime fallback cleanup after stop failure"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "quiesce_postinstall_service should still attempt DNS restore after stop failure"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state after stopping auto-started service" "quiesce_postinstall_service should report runtime cleanup failure after stop failure"

: > "$event_log"
: > "$init_log"
: > "$orch_log"
TEST_INIT_STOP_RC=0
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
assert_false "quiesce_postinstall_service should still verify cleanup after successful stop" quiesce_postinstall_service
assert_file_contains "$init_log" "stop" "quiesce_postinstall_service should stop service before verification"
assert_file_contains "$event_log" "wait_for_service_stop" "quiesce_postinstall_service should wait for service stop before verification"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "quiesce_postinstall_service should verify runtime cleanup even after stop succeeds"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "quiesce_postinstall_service should still attempt DNS restore after successful stop"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state after stopping auto-started service" "quiesce_postinstall_service should report cleanup verification failure after successful stop"
assert_file_not_contains "$orch_log" "cleanup" "quiesce_postinstall_service should skip orchestrator cleanup when init stop already succeeded"

: > "$event_log"
: > "$init_log"
: > "$orch_log"
TEST_SERVICE_RUNNING_RC=1
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
assert_false "quiesce_postinstall_service should verify cleanup even when service already exited" quiesce_postinstall_service
assert_file_not_contains "$init_log" "stop" "quiesce_postinstall_service should not stop init service when it is already down"
assert_file_not_contains "$orch_log" "cleanup" "quiesce_postinstall_service should skip orchestrator cleanup when service is already down"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "quiesce_postinstall_service should still verify runtime cleanup when service is already down"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "quiesce_postinstall_service should still attempt DNS restore when service is already down"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state after stopping auto-started service" "quiesce_postinstall_service should report cleanup verification failure when service is already down"

TEST_INIT_STOP_RC=0
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
}
quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
}

: > "$event_log"
TEST_SERVICE_RUNNING_RC=0
TEST_APK_SUPPORTS_VIRTUAL_RC=0
TEST_HOLD_DEPS_RC=0
WAS_ENABLED=0
WAS_RUNNING=0
prepare_update
assert_eq "1" "$WAS_ENABLED" "prepare_update should remember enabled service"
assert_eq "1" "$WAS_RUNNING" "prepare_update should remember running service"
assert_file_contains "$event_log" "backup_user_state" "prepare_update should back up user state"
assert_file_contains "$event_log" "hold_reinstall_dependencies" "prepare_update should hold reinstall dependencies"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "prepare_update should clean runtime fallback state"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "prepare_update should restore DNS defaults with fallback"

: > "$event_log"
WAS_ENABLED=0
WAS_RUNNING=0
backup_user_state() {
	printf 'backup_user_state\n' >>"$event_log"
	return 1
}
assert_false "prepare_update should fail when backup_user_state fails" prepare_update
assert_eq "1" "$WAS_ENABLED" "prepare_update should snapshot enabled state before backup"
assert_eq "1" "$WAS_RUNNING" "prepare_update should snapshot running state before backup"
assert_file_contains "$event_log" "backup_user_state" "prepare_update should attempt backup before failing"
assert_file_not_contains "$event_log" "cleanup_runtime_fallback" "prepare_update should not tear down runtime when backup fails"

backup_user_state() {
	printf 'backup_user_state\n' >>"$event_log"
}

: > "$event_log"
WAS_ENABLED=0
WAS_RUNNING=0
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
assert_false "prepare_update should fail when runtime cleanup fails" prepare_update
assert_file_contains "$event_log" "cleanup_runtime_fallback" "prepare_update should attempt runtime cleanup before update"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "prepare_update should still attempt DNS restore when runtime cleanup fails"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state before update" "prepare_update should report runtime cleanup failure"

cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
}

: > "$event_log"
: > "$init_log"
TEST_SERVICE_RUNNING_RC=0
TEST_INIT_RESTART_RC=0
TEST_INIT_START_RC=0
TEST_WAIT_RUNNING_RC=0
WAS_ENABLED=1
WAS_RUNNING=1
restore_runtime_state
assert_file_contains "$init_log" "enable" "restore_runtime_state should re-enable service when previously enabled"
assert_file_contains "$init_log" "restart" "restore_runtime_state should restart running service"
assert_eq "0" "$(grep -c '^start$' "$init_log" || true)" "restore_runtime_state should not start when restart succeeds"
assert_file_contains "$event_log" "wait_for_service_running" "restore_runtime_state should confirm liveness after restart"
assert_file_not_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should not tear down state after successful restart"

: > "$event_log"
: > "$init_log"
TEST_SERVICE_RUNNING_RC=1
TEST_INIT_START_RC=0
TEST_WAIT_RUNNING_RC=0
WAS_ENABLED=0
WAS_RUNNING=1
restore_runtime_state
assert_file_contains "$init_log" "disable" "restore_runtime_state should disable service when it was previously disabled"
assert_file_contains "$init_log" "start" "restore_runtime_state should start stopped service"
assert_file_not_contains "$init_log" "restart" "restore_runtime_state should skip restart when service is no longer running"
assert_file_contains "$event_log" "wait_for_service_running" "restore_runtime_state should confirm liveness after fresh start"

: > "$event_log"
: > "$init_log"
TEST_SERVICE_RUNNING_RC=1
TEST_INIT_START_RC=1
TEST_WAIT_RUNNING_RC=0
WAS_ENABLED=1
WAS_RUNNING=1
assert_false "restore_runtime_state should fail when restart fails" restore_runtime_state
assert_file_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should clean runtime fallback after failed restart"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "restore_runtime_state should restore DNS defaults after failed restart"
assert_file_not_contains "$event_log" "wait_for_service_running" "restore_runtime_state should not wait for liveness when start itself fails"

: > "$event_log"
: > "$init_log"
TEST_SERVICE_RUNNING_RC=1
TEST_INIT_START_RC=0
TEST_WAIT_RUNNING_RC=1
WAS_ENABLED=1
WAS_RUNNING=1
restore_runtime_state
assert_file_contains "$event_log" "wait_for_service_running" "restore_runtime_state should wait for liveness before declaring success"
assert_file_contains "$event_log" "warn:MihoWRT start returned success; service start is asynchronous and was not observed within timeout" "restore_runtime_state should warn instead of failing on async startup"
assert_file_not_contains "$init_log" "stop" "restore_runtime_state should not tear down async startup after timeout"
assert_file_not_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should not clean runtime fallback when init start already succeeded"
assert_file_not_contains "$event_log" "restore_system_dns_defaults:1" "restore_runtime_state should not restore DNS defaults when init start already succeeded"

: > "$event_log"
: > "$init_log"
TEST_WAIT_RUNNING_RC=0
WAS_ENABLED=0
WAS_RUNNING=0
restore_runtime_state
assert_file_contains "$init_log" "disable" "restore_runtime_state should preserve disabled state"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should clean runtime fallback when service was not running"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "restore_runtime_state should restore DNS defaults when service was not running"

: > "$event_log"
: > "$init_log"
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
TEST_WAIT_RUNNING_RC=0
WAS_ENABLED=0
WAS_RUNNING=0
assert_false "restore_runtime_state should fail when cleanup after update fails" restore_runtime_state
assert_file_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should attempt runtime cleanup before succeeding"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "restore_runtime_state should still attempt DNS restore when cleanup fails"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state after update" "restore_runtime_state should report cleanup failure after update"

cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
}

: > "$event_log"
: > "$init_log"
restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
	return 0
}
stage_kernel_backup() {
	printf 'stage_kernel_backup\n' >>"$event_log"
	return 0
}
preserve_kernel_backup_dir() {
	printf 'preserve_kernel_backup_dir\n' >>"$event_log"
}
preserve_backup_dir() {
	printf 'preserve_backup_dir\n' >>"$event_log"
}
clear_kernel_backup() {
	printf 'clear_kernel_backup\n' >>"$event_log"
}
release_reinstall_dependencies() {
	printf 'release_reinstall_dependencies\n' >>"$event_log"
}
kernel_backup_available() {
	return 0
}
restore_runtime_state() {
	printf 'restore_runtime_state\n' >>"$event_log"
	return 1
}
assert_false "rollback_reinstall_state should fail when runtime restore fails" rollback_reinstall_state 1
assert_file_contains "$event_log" "restore_kernel_backup" "rollback_reinstall_state should restore previous kernel before runtime rollback"
assert_file_contains "$event_log" "restore_runtime_state" "rollback_reinstall_state should attempt runtime rollback"
assert_file_contains "$event_log" "stage_kernel_backup" "rollback_reinstall_state should restage tmpfs kernel backup when runtime rollback fails"
assert_file_contains "$event_log" "preserve_backup_dir" "rollback_reinstall_state should preserve backup dir when runtime rollback fails"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "rollback_reinstall_state should preserve kernel rollback dir when runtime rollback fails"
assert_file_contains "$event_log" "err:failed to restore runtime state during rollback" "rollback_reinstall_state should report runtime rollback failure"
assert_file_not_contains "$event_log" "release_reinstall_dependencies" "rollback_reinstall_state should not clear dependency hold on runtime rollback failure"
assert_file_not_contains "$event_log" "clear_kernel_backup" "rollback_reinstall_state should not drop kernel rollback state on runtime rollback failure"

restore_runtime_state() {
	printf 'restore_runtime_state\n' >>"$event_log"
	return 0
}

: > "$event_log"
begin_install_transaction 1
rollback_active_transaction
assert_file_contains "$event_log" "restore_runtime_state" "rollback_active_transaction should use runtime rollback before package mutation"
assert_file_not_contains "$event_log" "err:installer interrupted" "rollback_active_transaction should not use incomplete-install handler before package mutation"
assert_eq "0" "$INSTALL_TRANSACTION_ACTIVE" "rollback_active_transaction should clear active flag after rollback"

: > "$event_log"
: > "$init_log"
begin_install_transaction 1
INSTALL_TRANSACTION_PACKAGE_STARTED=1
rollback_active_transaction
assert_file_contains "$event_log" "err:installer interrupted" "rollback_active_transaction should use incomplete-install handler after package mutation starts"
assert_file_contains "$event_log" "restore_user_state" "rollback_active_transaction should restore saved user state after interrupted reinstall mutation"
assert_eq "0" "$INSTALL_TRANSACTION_ACTIVE" "rollback_active_transaction should clear active flag after incomplete reinstall cleanup"

: > "$event_log"
: > "$init_log"
begin_install_transaction 0
INSTALL_TRANSACTION_PACKAGE_STARTED=1
rollback_active_transaction
assert_file_contains "$event_log" "err:installer interrupted" "rollback_active_transaction should clean interrupted fresh install"
assert_file_not_contains "$event_log" "restore_user_state" "rollback_active_transaction should not restore reinstall-only user state for fresh install"
assert_eq "0" "$INSTALL_TRANSACTION_ACTIVE" "rollback_active_transaction should clear active flag after interrupted fresh install cleanup"

: > "$event_log"
: > "$init_log"
release_reinstall_dependencies() {
	printf 'release_reinstall_dependencies\n' >>"$event_log"
}
restore_runtime_state() {
	printf 'restore_runtime_state\n' >>"$event_log"
	return 0
}
assert_false "handle_install_failure should return failure" handle_install_failure 1 "package broke"
assert_file_contains "$event_log" "err:package broke" "handle_install_failure should log install error"
assert_file_contains "$event_log" "clear_skip_start" "handle_install_failure should clear skip-start marker"
assert_file_contains "$event_log" "release_reinstall_dependencies" "handle_install_failure should release held dependencies"
assert_file_contains "$init_log" "disable" "handle_install_failure should disable service"
assert_file_contains "$event_log" "quiesce_postinstall_service" "handle_install_failure should quiesce auto-started service"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "handle_install_failure should clean runtime fallback"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "handle_install_failure should restore DNS defaults"
assert_file_contains "$event_log" "restore_user_state" "handle_install_failure should restore saved state on reinstall"

: > "$event_log"
quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
	return 1
}
assert_false "handle_install_failure should fail fast when quiesce fails" handle_install_failure 1 "quiesce broke"
assert_file_contains "$event_log" "quiesce_postinstall_service" "handle_install_failure should attempt quiesce before aborting"
assert_file_contains "$event_log" "preserve_backup_dir" "handle_install_failure should preserve backup dir when quiesce fails"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "handle_install_failure should preserve kernel rollback dir when quiesce fails"
assert_file_not_contains "$event_log" "restore_user_state" "handle_install_failure should not restore user state after quiesce failure"

: > "$event_log"
quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
}
restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 1
}
: > "$init_log"
assert_false "handle_install_failure should still fail when restore_user_state fails" handle_install_failure 1 "restore broke"
assert_file_contains "$event_log" "restore_user_state" "handle_install_failure should try restoring saved state on reinstall"
assert_file_contains "$event_log" "preserve_backup_dir" "handle_install_failure should preserve backup dir when restore fails"
assert_file_contains "$event_log" "err:failed to restore saved config and policy files" "handle_install_failure should report restore failure"

: > "$event_log"
: > "$init_log"
restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 0
}
preserve_kernel_backup_dir() {
	printf 'preserve_kernel_backup_dir\n' >>"$event_log"
}
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
assert_false "handle_install_failure should stop before restoring user state when cleanup fails" handle_install_failure 1 "cleanup broke"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "handle_install_failure should attempt runtime cleanup"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "handle_install_failure should still attempt DNS restore when cleanup fails"
assert_file_contains "$event_log" "preserve_backup_dir" "handle_install_failure should preserve backup dir when cleanup fails"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "handle_install_failure should preserve kernel rollback dir when cleanup fails"
assert_file_not_contains "$event_log" "restore_user_state" "handle_install_failure should not continue to restore user state after cleanup failure"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state after incomplete package install" "handle_install_failure should report cleanup failure"

: > "$event_log"
: > "$init_log"
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
}
restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 0
}
restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
	return 1
}
preserve_kernel_backup_dir() {
	printf 'preserve_kernel_backup_dir\n' >>"$event_log"
}
assert_false "handle_install_failure should preserve tmpfs kernel backup when kernel restore fails" handle_install_failure 1 "kernel restore broke"
assert_file_contains "$event_log" "restore_kernel_backup" "handle_install_failure should try restoring previous kernel on reinstall failure"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "handle_install_failure should preserve tmpfs kernel backup when restore fails"
assert_file_contains "$event_log" "warn:failed to restore previous Mihomo kernel after install failure" "handle_install_failure should warn when previous kernel restore fails"

rollback_kernel_update() {
	printf 'rollback_kernel_update\n' >>"$event_log"
	return 0
}

: > "$event_log"
: > "$init_log"
assert_false "handle_install_failure should roll back fresh kernel update" handle_install_failure 0 "fresh package broke"
assert_file_contains "$event_log" "rollback_kernel_update" "handle_install_failure should roll back kernel for failed fresh install"
assert_file_not_contains "$event_log" "restore_user_state" "handle_install_failure should not restore reinstall state for failed fresh install"

rollback_kernel_update() {
	printf 'rollback_kernel_update\n' >>"$event_log"
	return 1
}

: > "$event_log"
: > "$init_log"
assert_false "handle_install_failure should preserve backup when fresh kernel rollback fails" handle_install_failure 0 "fresh kernel rollback broke"
assert_file_contains "$event_log" "rollback_kernel_update" "handle_install_failure should try fresh kernel rollback"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "handle_install_failure should preserve tmpfs kernel backup when fresh rollback fails"
assert_file_contains "$event_log" "warn:failed to roll back Mihomo kernel after install failure" "handle_install_failure should warn when fresh kernel rollback fails"

: > "$event_log"
: > "$init_log"
TEST_INIT_START_RC=0
TEST_WAIT_RUNNING_RC=0
start_fresh_install_service
assert_file_contains "$init_log" "enable" "start_fresh_install_service should enable service"
assert_file_contains "$init_log" "start" "start_fresh_install_service should start service"
assert_file_contains "$event_log" "wait_for_service_running" "start_fresh_install_service should confirm liveness before succeeding"

: > "$event_log"
: > "$init_log"
TEST_INIT_START_RC=1
TEST_WAIT_RUNNING_RC=0
assert_false "start_fresh_install_service should fail when init start fails" start_fresh_install_service
assert_file_contains "$init_log" "enable" "failed fresh start should still try enable"
assert_file_contains "$init_log" "start" "failed fresh start should still try start"
assert_file_contains "$init_log" "disable" "failed fresh start should disable service afterwards"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "failed fresh start should clean runtime fallback"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "failed fresh start should restore DNS defaults"
assert_file_not_contains "$event_log" "wait_for_service_running" "failed fresh start should not wait when init start already failed"

: > "$event_log"
: > "$init_log"
TEST_INIT_START_RC=0
TEST_WAIT_RUNNING_RC=1
start_fresh_install_service
assert_file_contains "$event_log" "wait_for_service_running" "fresh start should wait for liveness before succeeding"
assert_file_contains "$event_log" "warn:MihoWRT start returned success; service start is asynchronous and was not observed within timeout" "fresh start should warn instead of failing on async startup"
assert_file_not_contains "$init_log" "stop" "fresh start should not stop async startup after timeout"
assert_file_not_contains "$init_log" "disable" "fresh start should not disable service when init start already succeeded"
assert_file_not_contains "$event_log" "cleanup_runtime_fallback" "fresh start should not clean runtime fallback when init start already succeeded"
assert_file_not_contains "$event_log" "restore_system_dns_defaults:1" "fresh start should not restore DNS defaults when init start already succeeded"

latest_asset_url() {
	printf '%s\n' "https://example.com/luci-app-mihowrt.apk"
}

package_installed() {
	return "${TEST_PACKAGE_INSTALLED_RC:-0}"
}

prepare_update() {
	printf 'prepare_update\n' >>"$event_log"
	return 0
}

kernel_stage_update() {
	printf 'kernel_stage_update\n' >>"$event_log"
	return 0
}

kernel_apply_staged_update() {
	printf 'kernel_apply_staged_update\n' >>"$event_log"
	return 0
}

set_skip_start() {
	printf 'set_skip_start\n' >>"$event_log"
}

create_tmp_apk() {
	TMP_APK="$tmpdir/downloaded.apk"
	printf 'create_tmp_apk\n' >>"$event_log"
}

download_file() {
	printf 'download_file:%s:%s\n' "$1" "$2" >>"$event_log"
	: > "$2"
}

install_package() {
	printf 'install_package:%s:%s\n' "$1" "$2" >>"$event_log"
	return 0
}

clear_skip_start() {
	printf 'clear_skip_start\n' >>"$event_log"
}

verify_required_packages() {
	printf 'verify_required_packages\n' >>"$event_log"
	return 0
}

quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
}

restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 0
}

preserve_backup_dir() {
	printf 'preserve_backup_dir\n' >>"$event_log"
}

restore_runtime_state() {
	printf 'restore_runtime_state\n' >>"$event_log"
	return 0
}

release_reinstall_dependencies() {
	printf 'release_reinstall_dependencies\n' >>"$event_log"
}

start_fresh_install_service() {
	printf 'start_fresh_install_service\n' >>"$event_log"
	return 0
}

: > "$event_log"
TEST_PACKAGE_INSTALLED_RC=0
perform_package_action
assert_file_contains "$event_log" "prepare_update" "perform_package_action should prepare reinstall state"
assert_file_contains "$event_log" "kernel_stage_update" "perform_package_action should prepare kernel before reinstall state changes"
assert_file_contains "$event_log" "kernel_apply_staged_update" "perform_package_action should install prepared kernel inside transaction"
assert_file_contains "$event_log" "set_skip_start" "perform_package_action should set skip-start before package install"
assert_file_contains "$event_log" "create_tmp_apk" "perform_package_action should allocate temporary APK path"
assert_file_contains "$event_log" "download_file:https://example.com/luci-app-mihowrt.apk:$tmpdir/downloaded.apk" "perform_package_action should download latest package asset"
assert_file_contains "$event_log" "install_package:1:$tmpdir/downloaded.apk" "perform_package_action should reinstall package"
assert_file_contains "$event_log" "verify_required_packages" "perform_package_action should verify required packages"
assert_file_contains "$event_log" "quiesce_postinstall_service" "perform_package_action should quiesce postinstall service on reinstall"
assert_file_contains "$event_log" "restore_user_state" "perform_package_action should restore saved user state on reinstall"
assert_file_contains "$event_log" "migrate_restored_policy_lists" "perform_package_action should migrate restored policy lists on reinstall"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state on reinstall"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after reinstall"
assert_file_not_contains "$event_log" "start_fresh_install_service" "perform_package_action should not use fresh-install branch for reinstall"

: > "$event_log"
quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
	return 1
}
assert_false "perform_package_action should fail when quiesce after reinstall fails" perform_package_action
assert_file_contains "$event_log" "quiesce_postinstall_service" "perform_package_action should attempt quiesce after reinstall"
assert_file_contains "$event_log" "preserve_backup_dir" "perform_package_action should preserve backup dir when quiesce fails"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "perform_package_action should preserve kernel rollback dir when quiesce fails"
assert_file_contains "$event_log" "err:failed to quiesce auto-started service after package install" "perform_package_action should report quiesce failure"
assert_file_not_contains "$event_log" "restore_user_state" "perform_package_action should not restore user state after quiesce failure"

quiesce_postinstall_service() {
	printf 'quiesce_postinstall_service\n' >>"$event_log"
}

prepare_update() {
	printf 'prepare_update\n' >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "perform_package_action should fail when prepare_update fails" perform_package_action
assert_file_contains "$event_log" "prepare_update" "perform_package_action should attempt prepare_update on reinstall"
assert_file_contains "$event_log" "kernel_stage_update" "perform_package_action should prepare kernel before prepare_update"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state after prepare_update failure"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after prepare_update failure"
assert_file_not_contains "$event_log" "kernel_apply_staged_update" "perform_package_action should not mutate kernel after prepare_update failure"
assert_eq "0" "$INSTALL_TRANSACTION_ACTIVE" "perform_package_action should clear transaction after prepare_update failure"

prepare_update() {
	printf 'prepare_update\n' >>"$event_log"
	return 0
}

: > "$event_log"
set_skip_start() {
	printf 'set_skip_start\n' >>"$event_log"
	return 1
}
assert_false "perform_package_action should fail when skip-start marker setup fails" perform_package_action
assert_file_contains "$event_log" "kernel_apply_staged_update" "perform_package_action should apply prepared kernel before skip-start marker"
assert_file_contains "$event_log" "set_skip_start" "perform_package_action should try setting skip-start marker"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state after skip-start failure"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after skip-start failure"

rollback_kernel_update() {
	printf 'rollback_kernel_update\n' >>"$event_log"
	return 0
}

: > "$event_log"
TEST_PACKAGE_INSTALLED_RC=1
assert_false "perform_package_action should roll back fresh kernel when skip-start marker setup fails" perform_package_action
assert_file_contains "$event_log" "kernel_apply_staged_update" "fresh install skip-start failure should happen after kernel apply"
assert_file_contains "$event_log" "set_skip_start" "fresh install should try setting skip-start marker"
assert_file_contains "$event_log" "rollback_kernel_update" "fresh install should roll back applied kernel after skip-start failure"
assert_file_not_contains "$event_log" "restore_runtime_state" "fresh install skip-start failure should not use reinstall runtime rollback"
TEST_PACKAGE_INSTALLED_RC=0

set_skip_start() {
	printf 'set_skip_start\n' >>"$event_log"
}

create_tmp_apk() {
	printf 'create_tmp_apk\n' >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "perform_package_action should fail when tmp apk allocation fails" perform_package_action
assert_file_contains "$event_log" "create_tmp_apk" "perform_package_action should try allocating temporary apk path"
assert_file_not_contains "$event_log" "kernel_stage_update" "perform_package_action should not prepare kernel before tmp apk allocation succeeds"
assert_file_not_contains "$event_log" "prepare_update" "perform_package_action should not touch runtime before tmp apk allocation succeeds"
assert_file_not_contains "$event_log" "download_file:https://example.com/luci-app-mihowrt.apk:$tmpdir/downloaded.apk" "perform_package_action should stop before download after tmp apk allocation failure"

create_tmp_apk() {
	TMP_APK="$tmpdir/downloaded.apk"
	printf 'create_tmp_apk\n' >>"$event_log"
}

download_file() {
	printf 'download_file:%s:%s\n' "$1" "$2" >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "perform_package_action should fail when package download fails during reinstall" perform_package_action
assert_file_contains "$event_log" "create_tmp_apk" "perform_package_action should allocate temporary APK path before download"
assert_file_contains "$event_log" "download_file:https://example.com/luci-app-mihowrt.apk:$tmpdir/downloaded.apk" "perform_package_action should try downloading package before transaction"
assert_file_not_contains "$event_log" "kernel_stage_update" "perform_package_action should not prepare kernel after package download failure"
assert_file_not_contains "$event_log" "prepare_update" "perform_package_action should not touch runtime after package download failure"
assert_file_not_contains "$event_log" "set_skip_start" "perform_package_action should not enter transaction after package download failure"
assert_file_not_contains "$event_log" "install_package:1:$tmpdir/downloaded.apk" "perform_package_action should not try package install after package download failure"

download_file() {
	printf 'download_file:%s:%s\n' "$1" "$2" >>"$event_log"
	: > "$2"
}

restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 1
}

: > "$event_log"
: > "$init_log"
assert_false "perform_package_action should fail when restore_user_state fails" perform_package_action
assert_file_contains "$event_log" "quiesce_postinstall_service" "perform_package_action should still quiesce service before restore"
assert_file_contains "$event_log" "restore_user_state" "perform_package_action should try restoring saved state"
assert_file_not_contains "$event_log" "migrate_restored_policy_lists" "perform_package_action should not migrate policy lists after restore failure"
assert_file_contains "$event_log" "preserve_backup_dir" "perform_package_action should preserve backup dir when restore fails"
assert_file_contains "$event_log" "err:failed to restore saved config and policy state" "perform_package_action should report restore failure"
assert_file_not_contains "$event_log" "restore_runtime_state" "perform_package_action should not restart runtime after restore failure"
assert_file_contains "$init_log" "disable" "perform_package_action should disable service after restore_user_state failure"

: > "$event_log"
: > "$init_log"
kernel_backup_available() {
	return 0
}
restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
	return 0
}
assert_false "perform_package_action should restore previous kernel when restore_user_state fails after kernel update" perform_package_action
assert_file_contains "$event_log" "restore_kernel_backup" "perform_package_action should restore previous kernel on restore_user_state failure when backup exists"
assert_file_contains "$event_log" "preserve_backup_dir" "perform_package_action should still preserve backup dir after restoring previous kernel"

: > "$event_log"
: > "$init_log"
restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
	return 1
}
preserve_kernel_backup_dir() {
	printf 'preserve_kernel_backup_dir\n' >>"$event_log"
}
assert_false "perform_package_action should preserve tmpfs kernel backup when user-state rollback kernel restore fails" perform_package_action
assert_file_contains "$event_log" "restore_kernel_backup" "perform_package_action should try restoring previous kernel after restore_user_state failure"
assert_file_contains "$event_log" "preserve_kernel_backup_dir" "perform_package_action should preserve tmpfs kernel backup when restore fails"
assert_file_contains "$event_log" "warn:failed to restore previous Mihomo kernel after user-state restore failure" "perform_package_action should warn when previous kernel restore fails"

restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 0
}

: > "$event_log"
: > "$init_log"
kernel_backup_available() {
	return 0
}
restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
	return 0
}
migrate_restored_policy_lists() {
	printf 'migrate_restored_policy_lists\n' >>"$event_log"
	return 1
}
assert_false "perform_package_action should fail when restored policy list migration fails" perform_package_action
assert_file_contains "$event_log" "migrate_restored_policy_lists" "perform_package_action should attempt policy list migration after restore"
assert_file_contains "$event_log" "restore_kernel_backup" "perform_package_action should restore previous kernel after migration failure"
assert_file_contains "$event_log" "preserve_backup_dir" "perform_package_action should preserve backup dir when migration fails"
assert_file_contains "$event_log" "err:failed to migrate restored policy list syntax" "perform_package_action should report policy list migration failure"
assert_file_not_contains "$event_log" "restore_runtime_state" "perform_package_action should not restart runtime after migration failure"
assert_file_contains "$init_log" "disable" "perform_package_action should disable service after migration failure"

: > "$event_log"
kernel_backup_available() {
	return 0
}

restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
	return 0
}

migrate_restored_policy_lists() {
	printf 'migrate_restored_policy_lists\n' >>"$event_log"
	return 0
}

restore_runtime_state() {
	printf 'restore_runtime_state\n' >>"$event_log"
	if [ "${TEST_RESTORE_RUNTIME_FAIL_ONCE:-0}" = "1" ]; then
		TEST_RESTORE_RUNTIME_FAIL_ONCE=0
		return 1
	fi
	return 0
}

TEST_RESTORE_RUNTIME_FAIL_ONCE=1
perform_package_action
assert_eq "2" "$(grep -c '^restore_runtime_state$' "$event_log" || true)" "perform_package_action should retry runtime restore after kernel rollback"
assert_file_contains "$event_log" "restore_kernel_backup" "perform_package_action should restore previous kernel before retrying runtime restore"
assert_file_contains "$event_log" "warn:runtime restore failed after kernel update; retrying with previous Mihomo kernel" "perform_package_action should warn before retrying with previous kernel"

restore_runtime_state() {
	printf 'restore_runtime_state\n' >>"$event_log"
	return 0
}

verify_required_packages() {
	MISSING_PACKAGES="jq nftables"
	printf 'verify_required_packages\n' >>"$event_log"
	return 1
}

handle_install_failure() {
	printf 'handle_install_failure:%s:%s\n' "$1" "$2" >>"$event_log"
	return 0
}

: > "$event_log"
assert_false "perform_package_action should fail when required packages are missing" perform_package_action
assert_file_contains "$event_log" "handle_install_failure:1:package install incomplete; missing packages: jq nftables" "perform_package_action should delegate incomplete reinstall cleanup"

release_reinstall_dependencies() {
	printf 'release_reinstall_dependencies\n' >>"$event_log"
}

clear_skip_start() {
	printf 'clear_skip_start\n' >>"$event_log"
}

wait_for_service_stop() {
	printf 'wait_for_service_stop\n' >>"$event_log"
	return 0
}

cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
}

restore_system_dns_defaults() {
	printf 'restore_system_dns_defaults:%s\n' "$1" >>"$event_log"
	return 0
}

kernel_remove() {
	printf 'kernel_remove\n' >>"$event_log"
}

package_installed() {
	return 0
}

remove_user_state() {
	printf 'remove_user_state\n' >>"$event_log"
}

: > "$event_log"
: > "$init_log"
: > "$orch_log"
remove_package_and_kernel
assert_file_contains "$event_log" "release_reinstall_dependencies" "remove_package_and_kernel should release held dependencies"
assert_file_contains "$event_log" "clear_skip_start" "remove_package_and_kernel should clear skip-start marker"
assert_file_contains "$init_log" "disable" "remove_package_and_kernel should disable service before removal"
assert_file_contains "$init_log" "stop" "remove_package_and_kernel should stop service before removal"
assert_file_contains "$event_log" "wait_for_service_stop" "remove_package_and_kernel should wait for stop completion"
assert_file_contains "$orch_log" "cleanup" "remove_package_and_kernel should ask orchestrator to clean runtime state"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "remove_package_and_kernel should clean runtime fallback state"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "remove_package_and_kernel should restore DNS defaults before removal"
assert_file_contains "$event_log" "kernel_remove" "remove_package_and_kernel should remove Mihomo kernel"
assert_file_contains "$event_log" "apk:del $PKG_NAME" "remove_package_and_kernel should remove installed package"
assert_file_contains "$event_log" "remove_user_state" "remove_package_and_kernel should remove user state files"

: > "$event_log"
: > "$init_log"
: > "$orch_log"
cleanup_runtime_fallback() {
	printf 'cleanup_runtime_fallback\n' >>"$event_log"
	return 1
}
assert_false "remove_package_and_kernel should fail when runtime cleanup before removal fails" remove_package_and_kernel
assert_file_contains "$event_log" "cleanup_runtime_fallback" "remove_package_and_kernel should attempt runtime cleanup before removal"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "remove_package_and_kernel should still attempt DNS restore when cleanup fails"
assert_file_contains "$event_log" "err:failed to clean runtime fallback state before removal" "remove_package_and_kernel should report cleanup failure before removal"
assert_file_not_contains "$event_log" "kernel_remove" "remove_package_and_kernel should not remove kernel after cleanup failure"
assert_file_not_contains "$event_log" "apk:del $PKG_NAME" "remove_package_and_kernel should not remove package after cleanup failure"
assert_file_not_contains "$event_log" "remove_user_state" "remove_package_and_kernel should not wipe user state after cleanup failure"

pass "installer orchestration logic"
