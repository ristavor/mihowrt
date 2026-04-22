#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

event_log="$tmpdir/events.log"
init_log="$tmpdir/init.log"
orch_log="$tmpdir/orch.log"

export TEST_INIT_LOG="$init_log"
export TEST_ORCH_LOG="$orch_log"
export TEST_INIT_ENABLED_RC=1
export TEST_INIT_RESTART_RC=0
export TEST_INIT_START_RC=0

source_install_lib

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
	stop|enable|disable)
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

chmod +x "$INIT_SCRIPT" "$ORCHESTRATOR"

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

preserve_backup_dir() {
	printf 'preserve_backup_dir\n' >>"$event_log"
}

wait_for_service_stop() {
	printf 'wait_for_service_stop\n' >>"$event_log"
	return 0
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
: > "$init_log"
TEST_SERVICE_RUNNING_RC=0
TEST_INIT_RESTART_RC=0
TEST_INIT_START_RC=0
WAS_ENABLED=1
WAS_RUNNING=1
restore_runtime_state
assert_file_contains "$init_log" "enable" "restore_runtime_state should re-enable service when previously enabled"
assert_file_contains "$init_log" "restart" "restore_runtime_state should restart running service"
assert_eq "0" "$(grep -c '^start$' "$init_log" || true)" "restore_runtime_state should not start when restart succeeds"
assert_file_not_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should not tear down state after successful restart"

: > "$event_log"
: > "$init_log"
TEST_SERVICE_RUNNING_RC=1
TEST_INIT_START_RC=0
WAS_ENABLED=0
WAS_RUNNING=1
restore_runtime_state
assert_file_contains "$init_log" "disable" "restore_runtime_state should disable service when it was previously disabled"
assert_file_contains "$init_log" "start" "restore_runtime_state should start stopped service"
assert_file_not_contains "$init_log" "restart" "restore_runtime_state should skip restart when service is no longer running"

: > "$event_log"
: > "$init_log"
TEST_SERVICE_RUNNING_RC=1
TEST_INIT_START_RC=1
WAS_ENABLED=1
WAS_RUNNING=1
assert_false "restore_runtime_state should fail when restart fails" restore_runtime_state
assert_file_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should clean runtime fallback after failed restart"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "restore_runtime_state should restore DNS defaults after failed restart"

: > "$event_log"
: > "$init_log"
WAS_ENABLED=0
WAS_RUNNING=0
restore_runtime_state
assert_file_contains "$init_log" "disable" "restore_runtime_state should preserve disabled state"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "restore_runtime_state should clean runtime fallback when service was not running"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "restore_runtime_state should restore DNS defaults when service was not running"

: > "$event_log"
: > "$init_log"
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
restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 1
}
assert_false "handle_install_failure should still fail when restore_user_state fails" handle_install_failure 1 "restore broke"
assert_file_contains "$event_log" "restore_user_state" "handle_install_failure should try restoring saved state on reinstall"
assert_file_contains "$event_log" "preserve_backup_dir" "handle_install_failure should preserve backup dir when restore fails"
assert_file_contains "$event_log" "err:failed to restore saved config and policy files" "handle_install_failure should report restore failure"

: > "$event_log"
: > "$init_log"
TEST_INIT_START_RC=0
start_fresh_install_service
assert_file_contains "$init_log" "enable" "start_fresh_install_service should enable service"
assert_file_contains "$init_log" "start" "start_fresh_install_service should start service"

: > "$event_log"
: > "$init_log"
TEST_INIT_START_RC=1
assert_false "start_fresh_install_service should fail when init start fails" start_fresh_install_service
assert_file_contains "$init_log" "enable" "failed fresh start should still try enable"
assert_file_contains "$init_log" "start" "failed fresh start should still try start"
assert_file_contains "$init_log" "disable" "failed fresh start should disable service afterwards"
assert_file_contains "$event_log" "cleanup_runtime_fallback" "failed fresh start should clean runtime fallback"
assert_file_contains "$event_log" "restore_system_dns_defaults:1" "failed fresh start should restore DNS defaults"

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

kernel_install_or_update() {
	printf 'kernel_install_or_update\n' >>"$event_log"
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
assert_file_contains "$event_log" "kernel_install_or_update" "perform_package_action should update kernel first"
assert_file_contains "$event_log" "set_skip_start" "perform_package_action should set skip-start before package install"
assert_file_contains "$event_log" "create_tmp_apk" "perform_package_action should allocate temporary APK path"
assert_file_contains "$event_log" "download_file:https://example.com/luci-app-mihowrt.apk:$tmpdir/downloaded.apk" "perform_package_action should download latest package asset"
assert_file_contains "$event_log" "install_package:1:$tmpdir/downloaded.apk" "perform_package_action should reinstall package"
assert_file_contains "$event_log" "verify_required_packages" "perform_package_action should verify required packages"
assert_file_contains "$event_log" "quiesce_postinstall_service" "perform_package_action should quiesce postinstall service on reinstall"
assert_file_contains "$event_log" "restore_user_state" "perform_package_action should restore saved user state on reinstall"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state on reinstall"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after reinstall"
assert_file_not_contains "$event_log" "start_fresh_install_service" "perform_package_action should not use fresh-install branch for reinstall"

prepare_update() {
	printf 'prepare_update\n' >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "perform_package_action should fail when prepare_update fails" perform_package_action
assert_file_contains "$event_log" "prepare_update" "perform_package_action should attempt prepare_update on reinstall"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state after prepare_update failure"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after prepare_update failure"
assert_file_not_contains "$event_log" "kernel_install_or_update" "perform_package_action should not continue after prepare_update failure"

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
assert_file_contains "$event_log" "set_skip_start" "perform_package_action should try setting skip-start marker"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state after skip-start failure"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after skip-start failure"
assert_file_not_contains "$event_log" "create_tmp_apk" "perform_package_action should stop before tmp apk allocation on skip-start failure"

set_skip_start() {
	printf 'set_skip_start\n' >>"$event_log"
}

create_tmp_apk() {
	printf 'create_tmp_apk\n' >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "perform_package_action should fail when tmp apk allocation fails" perform_package_action
assert_file_contains "$event_log" "set_skip_start" "perform_package_action should set skip-start before tmp apk allocation"
assert_file_contains "$event_log" "create_tmp_apk" "perform_package_action should try allocating temporary apk path"
assert_file_contains "$event_log" "clear_skip_start" "perform_package_action should clear skip-start after tmp apk allocation failure"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state after tmp apk allocation failure"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after tmp apk allocation failure"
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
assert_file_contains "$event_log" "prepare_update" "perform_package_action should still prepare reinstall state before download failure"
assert_file_contains "$event_log" "kernel_install_or_update" "perform_package_action should still update kernel before package download failure"
assert_file_contains "$event_log" "set_skip_start" "perform_package_action should set skip-start before package download"
assert_file_contains "$event_log" "clear_skip_start" "perform_package_action should clear skip-start when package download fails"
assert_file_contains "$event_log" "restore_runtime_state" "perform_package_action should restore runtime state after package download failure"
assert_file_contains "$event_log" "release_reinstall_dependencies" "perform_package_action should release held dependencies after package download failure"
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
assert_file_contains "$event_log" "preserve_backup_dir" "perform_package_action should preserve backup dir when restore fails"
assert_file_contains "$event_log" "err:failed to restore saved config and policy state" "perform_package_action should report restore failure"
assert_file_not_contains "$event_log" "restore_runtime_state" "perform_package_action should not restart runtime after restore failure"
assert_file_contains "$init_log" "disable" "perform_package_action should disable service after restore_user_state failure"

restore_user_state() {
	printf 'restore_user_state\n' >>"$event_log"
	return 0
}

: > "$event_log"
kernel_backup_available() {
	return 0
}

restore_kernel_backup() {
	printf 'restore_kernel_backup\n' >>"$event_log"
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

pass "installer orchestration logic"
