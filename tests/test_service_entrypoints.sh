#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

cli_log="$tmpdir/cli.log"
msg_log="$tmpdir/msg.log"
procd_log="$tmpdir/procd.log"
orch_log="$tmpdir/orch.log"
clash_log="$tmpdir/clash.log"

source_mihowrt_cli_lib

CLASH_DIR="$tmpdir/clash"
CLASH_BIN="$tmpdir/clash-bin"
CLASH_CONFIG="$tmpdir/config.yaml"
PKG_STATE_DIR="$tmpdir/run"
SERVICE_PID_FILE="$PKG_STATE_DIR/mihomo.pid"
RUNTIME_LOCK_FILE="$tmpdir/runtime.lock"
mkdir -p "$CLASH_DIR"

cat >"$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CLASH_LOG"
sleep "${TEST_CLASH_SLEEP:-0}"
exit "${TEST_CLASH_RC:-0}"
EOF
chmod +x "$CLASH_BIN"
export TEST_CLASH_LOG="$clash_log"

log() {
	printf 'log:%s\n' "$*" >>"$cli_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$cli_log"
}

warn() {
	printf 'warn:%s\n' "$*" >>"$cli_log"
}

load_runtime_config() {
	printf 'load_runtime_config\n' >>"$cli_log"
	[ "${TEST_LOAD_RUNTIME_CONFIG_RC:-0}" -eq 0 ] || return "${TEST_LOAD_RUNTIME_CONFIG_RC:-1}"
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

: >"$cli_log"
lock_body() {
	[ -L "$RUNTIME_LOCK_FILE" ] || fail "with_runtime_lock should hold symlink lock while command runs"
	printf 'lock_body\n' >>"$cli_log"
}
with_runtime_lock lock_body
assert_file_contains "$cli_log" "lock_body" "with_runtime_lock should execute locked command"
[[ ! -e "$RUNTIME_LOCK_FILE" ]] || fail "with_runtime_lock should remove lock after command success"
ln -s 999999 "$RUNTIME_LOCK_FILE"
with_runtime_lock lock_body
[[ ! -e "$RUNTIME_LOCK_FILE" ]] || fail "with_runtime_lock should replace and release stale lock"

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

mihomo_api_live_state_save_current() {
	printf 'mihomo_api_live_state_save_current\n' >>"$cli_log"
	return "${TEST_LIVE_API_SAVE_RC:-0}"
}

subscription_refresh_auto_update_state() {
	printf 'subscription_refresh_auto_update_state\n' >>"$cli_log"
	return "${TEST_SUBSCRIPTION_REFRESH_RC:-0}"
}

mihomo_api_live_state_clear() {
	printf 'mihomo_api_live_state_clear\n' >>"$cli_log"
}

service_running_state() {
	printf 'service_running_state\n' >>"$cli_log"
	return "${TEST_SERVICE_RUNNING_STATE_RC:-0}"
}

mihomo_ports_ready_state() {
	printf 'mihomo_ports_ready_state:%s:%s\n' "$1" "$2" >>"$cli_log"
	return "${TEST_SERVICE_READY_STATE_RC:-0}"
}

runtime_snapshot_valid() {
	printf 'runtime_snapshot_valid\n' >>"$cli_log"
	return "${TEST_RUNTIME_SNAPSHOT_VALID_RC:-1}"
}

policy_route_state_read() {
	printf 'policy_route_state_read\n' >>"$cli_log"
	return "${TEST_POLICY_ROUTE_STATE_READ_RC:-1}"
}

nft_table_exists() {
	printf 'nft_table_exists\n' >>"$cli_log"
	return "${TEST_NFT_TABLE_EXISTS_RC:-1}"
}

dns_backup_valid() {
	printf 'dns_backup_valid\n' >>"$cli_log"
	return "${TEST_DNS_BACKUP_VALID_RC:-1}"
}

runtime_snapshot_status_json() {
	[ -n "${TEST_RUNTIME_SNAPSHOT_JSON:-}" ] || return 1
	printf '%s\n' "$TEST_RUNTIME_SNAPSHOT_JSON"
}

runtime_snapshot_readiness_json() {
	[ "${TEST_RUNTIME_SNAPSHOT_READINESS_RC:-0}" -eq 0 ] || return "${TEST_RUNTIME_SNAPSHOT_READINESS_RC:-1}"
	[ -n "${TEST_RUNTIME_SNAPSHOT_JSON:-}" ] || return 1
	printf '%s\n' "$TEST_RUNTIME_SNAPSHOT_JSON"
}

eval "$(sed -n '/^runtime_policy_ready_state()/,/^}/p;/^load_snapshot_readiness_ports()/,/^}/p;/^load_config_readiness_ports()/,/^}/p;/^service_ready_runtime_state()/,/^}/p;/^service_ready_runtime_state_for_running_service()/,/^}/p' "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-status.sh")"

: >"$cli_log"
: >"$clash_log"
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=0
run_service
assert_file_contains "$cli_log" "load_runtime_config" "run_service should load runtime config"
assert_file_contains "$cli_log" "validate_runtime_config" "run_service should validate runtime config"
assert_file_contains "$cli_log" "init_runtime_layout" "run_service should initialize runtime layout"
assert_file_contains "$cli_log" "wait_for_mihomo_ready:7874:7894:" "run_service should wait for Mihomo ports"
assert_file_contains "$clash_log" "-d $CLASH_DIR -f $CLASH_CONFIG" "run_service should start Mihomo with explicit config path"
assert_file_contains "$cli_log" "mihomo_api_live_state_save_current" "run_service should save live API state after Mihomo is ready"
assert_file_contains "$cli_log" "subscription_refresh_auto_update_state" "run_service should refresh subscription auto-update state after live API state is saved"
assert_file_contains "$cli_log" "apply_runtime_state" "run_service should apply runtime state after Mihomo is ready"
assert_file_contains "$cli_log" "log:MihoWRT service ready" "run_service should log service readiness only after Mihomo and policy state are ready"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean up runtime state on exit"
assert_file_contains "$cli_log" "mihomo_api_live_state_clear" "run_service should clear live API state on exit"
[[ ! -e "$SERVICE_PID_FILE" ]] || fail "run_service should remove PID file on clean exit"

: >"$cli_log"
TEST_LIVE_API_SAVE_RC=1
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=0
run_service
assert_file_contains "$cli_log" "warn:Failed to persist live Mihomo API state" "run_service should warn when live API state cannot be saved"
assert_file_not_contains "$cli_log" "subscription_refresh_auto_update_state" "run_service should not refresh subscription state without saved live API metadata"
TEST_LIVE_API_SAVE_RC=0

: >"$cli_log"
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=1
assert_false "run_service should fail when runtime cleanup fails on exit" run_service
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should still attempt runtime cleanup before failing"
[[ ! -e "$SERVICE_PID_FILE" ]] || fail "run_service should remove PID file even when cleanup fails"

: >"$cli_log"
TEST_WAIT_READY_RC=1
TEST_APPLY_RUNTIME_RC=0
TEST_CLEANUP_RUNTIME_RC=0
assert_false "run_service should fail when Mihomo readiness probe fails" run_service
assert_file_contains "$cli_log" "err:Mihomo failed to become ready on DNS port 7874 and TPROXY port 7894" "run_service should report readiness failure"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean runtime state after readiness failure"
assert_file_not_contains "$cli_log" "apply_runtime_state" "run_service should not apply runtime state before readiness succeeds"

: >"$cli_log"
TEST_WAIT_READY_RC=0
TEST_APPLY_RUNTIME_RC=1
TEST_CLEANUP_RUNTIME_RC=0
assert_false "run_service should fail when runtime policy apply fails" run_service
assert_file_contains "$cli_log" "err:Failed to apply runtime policy after Mihomo became ready" "run_service should report runtime apply failure"
assert_file_contains "$cli_log" "cleanup_runtime_state" "run_service should clean runtime state after policy apply failure"

: >"$cli_log"
TEST_SERVICE_RUNNING_STATE_RC=0
TEST_SERVICE_READY_STATE_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=0
TEST_RUNTIME_SNAPSHOT_READINESS_RC=0
TEST_RUNTIME_SNAPSHOT_JSON='{"present":true,"enabled":true,"mihomo_dns_port":"7874","mihomo_tproxy_port":"7894"}'
assert_true "service_ready_runtime_state should report ready when runtime snapshot is valid" service_ready_runtime_state
assert_file_contains "$cli_log" "mihomo_ports_ready_state:7874:7894" "service_ready_runtime_state should verify listeners before success"
assert_file_not_contains "$cli_log" "runtime_snapshot_valid" "service_ready_runtime_state should avoid full snapshot status checks on active readiness snapshot"
assert_file_not_contains "$cli_log" "policy_route_state_read" "service_ready_runtime_state should not block on route probe after valid snapshot"
assert_file_not_contains "$cli_log" "nft_table_exists" "service_ready_runtime_state should not block on nft probe after valid snapshot"
assert_file_not_contains "$cli_log" "dns_backup_valid" "service_ready_runtime_state should not block on dns backup probe after valid snapshot"
assert_file_not_contains "$cli_log" "load_runtime_config" "service_ready_runtime_state should use runtime snapshot before config reload"

: >"$cli_log"
TEST_SERVICE_RUNNING_STATE_RC=0
TEST_SERVICE_READY_STATE_RC=0
TEST_RUNTIME_SNAPSHOT_READINESS_RC=1
TEST_RUNTIME_SNAPSHOT_JSON='{"present":true,"enabled":true,"mihomo_dns_port":"7874","mihomo_tproxy_port":"7894"}'
TEST_RUNTIME_SNAPSHOT_VALID_RC=1
assert_false "service_ready_runtime_state should stay false until runtime snapshot validates" service_ready_runtime_state
assert_file_contains "$cli_log" "mihomo_ports_ready_state:7874:7894" "service_ready_runtime_state should still probe listeners before failing on invalid snapshot"

: >"$cli_log"
TEST_SERVICE_RUNNING_STATE_RC=0
TEST_SERVICE_READY_STATE_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=1
TEST_RUNTIME_SNAPSHOT_READINESS_RC=0
TEST_RUNTIME_SNAPSHOT_JSON=''
TEST_LOAD_RUNTIME_CONFIG_RC=0
assert_false "service_ready_runtime_state should require policy markers without a valid runtime snapshot" service_ready_runtime_state
assert_file_contains "$cli_log" "runtime_snapshot_valid" "service_ready_runtime_state should require runtime markers for mandatory policy layer"

: >"$cli_log"
TEST_SERVICE_RUNNING_STATE_RC=0
TEST_SERVICE_READY_STATE_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=0
TEST_RUNTIME_SNAPSHOT_READINESS_RC=0
TEST_RUNTIME_SNAPSHOT_JSON='{"present":true,"enabled":true,"mihomo_dns_port":"7874","mihomo_tproxy_port":"7894"}'
TEST_LOAD_RUNTIME_CONFIG_RC=1
assert_true "service_ready_runtime_state should use active runtime snapshot even when config reload fails" service_ready_runtime_state
assert_file_not_contains "$cli_log" "load_runtime_config" "service_ready_runtime_state should not depend on config reload when active snapshot exists"
TEST_LOAD_RUNTIME_CONFIG_RC=0

config_override_output="$(
	set -- read-config "$tmpdir/alt-config.yaml"
	CLASH_CONFIG="/opt/clash/config.yaml"
	read_config_json() {
		printf '%s\n' "$CLASH_CONFIG"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "$tmpdir/alt-config.yaml" "$config_override_output" "read-config command should accept config path override"

live_api_output="$(
	set -- live-api-json
	mihomo_api_live_state_read() {
		printf 'live-api\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "live-api" "$live_api_output" "live-api-json command should dispatch to live API state helper"

apply_config_output="$(
	set -- apply-config "$tmpdir/candidate.yaml"
	apply_config_runtime() {
		printf 'runtime:%s\n' "$1"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "runtime:$tmpdir/candidate.yaml" "$apply_config_output" "apply-config command should forward temp config path to runtime apply helper"

apply_config_contents_output="$(
	set -- apply-config-contents 'mode: direct
dns:
  listen: 0.0.0.0:7874
'
	apply_config_contents() {
		printf '%s\n' "$1"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "mode: direct
dns:
  listen: 0.0.0.0:7874" "$apply_config_contents_output" "apply-config-contents command should forward raw config contents"

subscription_json_output="$(
	set -- subscription-json
	subscription_url_json() {
		printf 'subscription-json\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "subscription-json" "$subscription_json_output" "subscription-json command should dispatch to subscription JSON helper"

set_subscription_settings_output="$(
	set -- set-subscription-settings "https://example.com/sub.yaml" 1 12 24
	set_subscription_settings() {
		printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "https://example.com/sub.yaml|1|12|24" "$set_subscription_settings_output" "set-subscription-settings command should forward auto-update settings"

set_subscription_settings_minimal_output="$(
	set -- set-subscription-settings "https://example.com/sub.yaml" 0 ""
	set_subscription_settings() {
		printf '%s|%s|%s|argc=%s|header=%s\n' "$1" "$2" "$3" "$#" "${4+x}"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "https://example.com/sub.yaml|0||argc=3|header=" "$set_subscription_settings_minimal_output" "set-subscription-settings command should not synthesize absent header interval"

fetch_subscription_output="$(
	set -- fetch-subscription "https://example.com/sub.yaml"
	fetch_subscription_config() {
		printf '%s\n' "$1"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "https://example.com/sub.yaml" "$fetch_subscription_output" "fetch-subscription command should forward URL"

fetch_subscription_json_output="$(
	set -- fetch-subscription-json "https://example.com/sub.yaml"
	fetch_subscription_json() {
		printf 'json:%s\n' "$1"
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "json:https://example.com/sub.yaml" "$fetch_subscription_json_output" "fetch-subscription-json command should forward URL"

update_policy_lists_output="$(
	set -- update-policy-lists
	update_runtime_policy_lists() {
		printf 'updated=0\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "updated=0" "$update_policy_lists_output" "update-policy-lists command should dispatch to remote list updater"

auto_update_policy_lists_output="$(
	set -- auto-update-policy-lists
	auto_update_policy_remote_lists() {
		printf 'policy-auto-updated\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "policy-auto-updated" "$auto_update_policy_lists_output" "auto-update-policy-lists command should dispatch to policy remote auto updater"

sync_policy_remote_output="$(
	set -- sync-policy-remote-auto-update
	policy_remote_refresh_auto_update_state() {
		printf 'policy-cron-synced\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "policy-cron-synced" "$sync_policy_remote_output" "sync-policy-remote-auto-update command should dispatch to policy cron sync helper"

sync_subscription_output="$(
	set -- sync-subscription-auto-update
	subscription_refresh_auto_update_state() {
		printf 'subscription-cron-synced\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "subscription-cron-synced" "$sync_subscription_output" "sync-subscription-auto-update command should dispatch to subscription cron sync helper"

update_subscription_output="$(
	set -- update-subscription
	update_subscription_config() {
		printf 'subscription-updated\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "subscription-updated" "$update_subscription_output" "update-subscription command should dispatch to subscription updater"

auto_update_subscription_output="$(
	set -- auto-update-subscription
	auto_update_subscription_config() {
		printf 'subscription-auto-updated\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "subscription-auto-updated" "$auto_update_subscription_output" "auto-update-subscription command should dispatch to subscription auto updater"

migrate_policy_lists_output="$(
	set -- migrate-policy-lists
	migrate_policy_list_files() {
		printf 'migrated\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "migrated" "$migrate_policy_lists_output" "migrate-policy-lists command should dispatch to policy list migration helper"

migrate_legacy_settings_output="$(
	set -- migrate-legacy-settings
	migrate_legacy_uci_settings() {
		printf 'legacy-migrated\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "legacy-migrated" "$migrate_legacy_settings_output" "migrate-legacy-settings command should dispatch to legacy UCI migration helper"

ensure_api_defaults_output="$(
	set -- ensure-api-defaults
	with_runtime_lock() {
		"$@"
	}
	ensure_active_config_api_defaults() {
		printf 'api-defaults\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "api-defaults" "$ensure_api_defaults_output" "ensure-api-defaults command should dispatch active config API default patch"

service_ready_output="$(
	set -- service-ready
	service_ready_runtime_state() {
		printf 'ready\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "ready" "$service_ready_output" "service-ready command should dispatch to runtime readiness helper"

service_state_output="$(
	set -- service-state-json
	service_state_json() {
		printf 'state\n'
	}
	# shellcheck disable=SC1090
	source <(strip_mihowrt_cli_bootstrap)
)"
assert_eq "state" "$service_state_output" "service-state-json command should dispatch to service state JSON helper"

restart_validated_output="$(
	set -- restart-validated-service
	PKG_NAME="mihowrt"
	current_config_has_validated_stamp() {
		return 0
	}
	init_path="$tmpdir/restart-validated-init"
	cat >"$init_path" <<'EOF'
#!/usr/bin/env bash
printf 'skip=%s args=%s\n' "${MIHOWRT_SKIP_CLASH_TEST:-0}" "$*"
EOF
	chmod +x "$init_path"
	# shellcheck disable=SC1090
	source <(
		strip_mihowrt_cli_bootstrap |
			sed "s|\"/etc/init.d/\\\${PKG_NAME:-mihowrt}\"|\"$init_path\"|g"
	)
)"
assert_eq "skip=1 args=restart" "$restart_validated_output" "restart-validated-service command should skip duplicate Mihomo config test on init restart"

restart_unvalidated_output="$(
	set -- restart-validated-service
	PKG_NAME="mihowrt"
	current_config_has_validated_stamp() {
		return 1
	}
	init_path="$tmpdir/restart-unvalidated-init"
	cat >"$init_path" <<'EOF'
#!/usr/bin/env bash
printf 'skip=%s args=%s\n' "${MIHOWRT_SKIP_CLASH_TEST:-0}" "$*"
EOF
	chmod +x "$init_path"
	# shellcheck disable=SC1090
	source <(
		strip_mihowrt_cli_bootstrap |
			sed "s|\"/etc/init.d/\\\${PKG_NAME:-mihowrt}\"|\"$init_path\"|g"
	)
)"
assert_eq "skip=0 args=restart" "$restart_unvalidated_output" "restart-validated-service command should keep full init validation when active config marker is stale"

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
export TEST_ORCH_RUNNING_RC=0
export TEST_CLASH_TEST_RC=0
export TEST_SERVICE_PID_FILE="$SERVICE_PID_FILE"

cat >"$ORCHESTRATOR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ORCH_LOG"
case "${1:-}" in
	service-running)
		if [ -n "${TEST_ORCH_RUNNING_RC:-}" ]; then
			exit "$TEST_ORCH_RUNNING_RC"
		fi
		[ -f "${TEST_SERVICE_PID_FILE:-}" ] && exit 0
		exit 1
		;;
	validate)
		exit "${TEST_ORCH_VALIDATE_RC:-0}"
		;;
	cleanup)
			exit "${TEST_ORCH_CLEANUP_RC:-0}"
			;;
		recover|run-service|update-policy-lists|sync-policy-remote-auto-update|sync-subscription-auto-update)
			exit 0
			;;
esac
exit 0
EOF

cat >"$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CLASH_LOG"
case " $* " in
	*" -t "*)
		exit "${TEST_CLASH_TEST_RC:-0}"
		;;
esac
exit 0
EOF

chmod +x "$ORCHESTRATOR" "$CLASH_BIN"
mkdir -p "$CLASH_DIR"
printf 'mode: rule\n' >"$CLASH_CONFIG"

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

: >"$msg_log"
: >"$procd_log"
: >"$orch_log"
export TEST_ORCH_VALIDATE_RC=0
export TEST_ORCH_CLEANUP_RC=0
export TEST_CLASH_TEST_RC=0
rm -f "$SKIP_START_FILE"
start_service
assert_file_contains "$msg_log" "Starting MihoWRT service..." "start_service should log service start"
assert_file_contains "$orch_log" "recover" "start_service should run crash recovery before start"
assert_file_contains "$orch_log" "ensure-api-defaults" "start_service should patch missing API defaults before validation"
assert_file_contains "$orch_log" "validate" "start_service should validate policy state"
assert_file_contains "$orch_log" "sync-policy-remote-auto-update" "start_service should sync remote policy auto-update schedule"
assert_file_contains "$orch_log" "sync-subscription-auto-update" "start_service should sync subscription auto-update schedule"
assert_file_contains "$orch_log" "cleanup" "start_service should clean stale runtime state before procd start"
assert_file_contains "$procd_log" "set:command $ORCHESTRATOR run-service" "start_service should register run-service command with procd"
assert_file_not_contains "$procd_log" "set:file " "start_service should avoid procd file triggers that race explicit UI apply/reload"
assert_file_contains "$msg_log" "MihoWRT service registered with procd" "start_service should return after procd registration"
assert_file_not_contains "$msg_log" "MihoWRT service started" "start_service should avoid premature started log"

: >"$msg_log"
: >"$orch_log"
: >"$clash_log"
MIHOWRT_SKIP_CLASH_TEST=1 validate_service_inputs
assert_file_not_contains "$clash_log" "-d $CLASH_DIR -f $CLASH_CONFIG -t" "validate_service_inputs should skip duplicate Mihomo syntax test when backend already validated config"
assert_file_contains "$orch_log" "ensure-api-defaults" "validate_service_inputs should still ensure API defaults when duplicate syntax test is skipped"
assert_file_contains "$orch_log" "validate" "validate_service_inputs should still run MihoWRT policy validation when syntax test is skipped"
assert_file_contains "$msg_log" "Skipping duplicate Mihomo configuration test" "validate_service_inputs should log skipped duplicate syntax validation"
unset MIHOWRT_SKIP_CLASH_TEST

: >"$msg_log"
: >"$procd_log"
: >"$orch_log"
export TEST_ORCH_CLEANUP_RC=1
assert_false "start_service should fail when stale runtime cleanup fails" start_service
assert_file_contains "$msg_log" "ERROR: Failed to clean stale runtime state" "start_service should report stale runtime cleanup failure"
[[ ! -s "$procd_log" ]] || fail "start_service should not register procd instance when cleanup fails"
export TEST_ORCH_CLEANUP_RC=0

: >"$msg_log"
: >"$procd_log"
: >"$orch_log"
: >"$SKIP_START_FILE"
start_service
assert_file_contains "$msg_log" "Skipping MihoWRT service auto-start during installer transaction" "start_service should honor skip-start marker"
[[ ! -s "$orch_log" ]] || fail "start_service should not call orchestrator when skip-start marker exists"
[[ ! -s "$procd_log" ]] || fail "start_service should not open procd instance when skip-start marker exists"
rm -f "$SKIP_START_FILE"
unset TEST_ORCH_RUNNING_RC

start() {
	printf 'start\n' >>"$msg_log"
}

: >"$msg_log"
reload_service
printf '%s\n' "$$" >"$SERVICE_PID_FILE"
reload_service
assert_file_contains "$msg_log" "Reloading MihoWRT policy..." "reload_service should log policy reload"
assert_file_contains "$msg_log" "MihoWRT policy reloaded" "reload_service should log successful policy reload"
assert_file_contains "$orch_log" "sync-policy-remote-auto-update" "reload_service should sync remote policy auto-update schedule"
assert_file_contains "$orch_log" "sync-subscription-auto-update" "reload_service should sync subscription auto-update schedule"
assert_file_contains "$orch_log" "service-running" "reload_service should check service state through orchestrator"
assert_file_contains "$orch_log" "reload-policy" "reload_service should invoke policy-only reload through orchestrator"

: >"$msg_log"
: >"$orch_log"
rm -f "$SERVICE_PID_FILE"
reload_service
assert_file_contains "$msg_log" "MihoWRT service is not running; skipping policy reload" "reload_service should skip policy reload when service is stopped"
assert_file_contains "$orch_log" "sync-policy-remote-auto-update" "reload_service should sync remote policy auto-update even when stopped"
assert_file_contains "$orch_log" "sync-subscription-auto-update" "reload_service should sync subscription auto-update even when stopped"
assert_file_contains "$orch_log" "service-running" "reload_service should still ask orchestrator for service state when service is stopped"
assert_file_not_contains "$orch_log" "reload-policy" "reload_service should not invoke policy reload when service is stopped"

: >"$msg_log"
: >"$orch_log"
printf '%s\n' "$$" >"$SERVICE_PID_FILE"
update_lists
assert_file_contains "$msg_log" "Updating MihoWRT remote policy lists..." "update_lists should log remote list update"
assert_file_contains "$orch_log" "service-running" "update_lists should check service state through orchestrator"
assert_file_contains "$orch_log" "update-policy-lists" "update_lists should invoke backend remote list update"
assert_file_contains "$msg_log" "MihoWRT remote policy list update finished" "update_lists should confirm remote list update"

: >"$msg_log"
: >"$orch_log"
rm -f "$SERVICE_PID_FILE"
update_lists
assert_file_contains "$msg_log" "MihoWRT service is not running; skipping remote list update" "update_lists should skip when service is stopped"
assert_file_contains "$orch_log" "service-running" "update_lists should still ask orchestrator for service state"
assert_file_not_contains "$orch_log" "update-policy-lists" "update_lists should not update remote lists when service is stopped"

: >"$msg_log"
: >"$orch_log"
update_subscription
assert_file_contains "$msg_log" "Updating MihoWRT subscription..." "update_subscription should log subscription update"
assert_file_contains "$orch_log" "update-subscription" "update_subscription should invoke backend subscription updater"
assert_file_contains "$msg_log" "MihoWRT subscription update finished" "update_subscription should confirm subscription update"

: >"$msg_log"
: >"$orch_log"
printf '%s\n' "$$" >"$SERVICE_PID_FILE"
apply
assert_file_contains "$msg_log" "Applying MihoWRT on-disk config..." "apply should announce on-disk apply flow"
assert_file_contains "$msg_log" "MihoWRT service is running; restarting to apply on-disk changes" "apply should restart running service after validation"
assert_file_contains "$msg_log" "stop" "apply should stop running service before restart"
assert_file_contains "$msg_log" "start" "apply should start service after stop during apply"
assert_file_contains "$msg_log" "MihoWRT on-disk changes applied" "apply should confirm successful on-disk apply"
assert_file_contains "$orch_log" "validate" "apply should validate policy before restart"
assert_file_contains "$orch_log" "sync-policy-remote-auto-update" "apply should sync remote policy auto-update schedule"
assert_file_contains "$orch_log" "sync-subscription-auto-update" "apply should sync subscription auto-update schedule"
assert_file_contains "$orch_log" "service-running" "apply should check service state before restart"

: >"$msg_log"
: >"$orch_log"
rm -f "$SERVICE_PID_FILE"
apply
assert_file_contains "$msg_log" "MihoWRT service is not running; validated on-disk config only" "apply should avoid starting stopped service implicitly"
assert_file_contains "$orch_log" "validate" "apply should still validate config when service is stopped"
assert_file_contains "$orch_log" "sync-policy-remote-auto-update" "apply should sync remote policy auto-update when service is stopped"
assert_file_contains "$orch_log" "sync-subscription-auto-update" "apply should sync subscription auto-update when service is stopped"
assert_file_contains "$orch_log" "service-running" "apply should still inspect running state when service is stopped"
assert_file_not_contains "$msg_log" "start" "apply should not start stopped service automatically"

: >"$msg_log"
: >"$orch_log"
: >"$SKIP_START_FILE"
printf '%s\n' "$$" >"$SERVICE_PID_FILE"
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
