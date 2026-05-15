#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat >"$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmpbin/uci" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_UCI_LOG"

if [[ "${1:-}" == "-q" ]]; then
	shift
fi

case "${1:-}" in
	get)
		case "${2:-}" in
			mihowrt.settings.subscription_url) printf '%s\n' "${TEST_UCI_SUBSCRIPTION_URL:-}" ;;
			mihowrt.settings.subscription_interval_override) printf '%s\n' "${TEST_UCI_INTERVAL_OVERRIDE:-0}" ;;
			mihowrt.settings.subscription_update_interval) printf '%s\n' "${TEST_UCI_UPDATE_INTERVAL:-}" ;;
			mihowrt.settings.subscription_header_interval) printf '%s\n' "${TEST_UCI_HEADER_INTERVAL:-}" ;;
			mihowrt.settings.subscription_auto_update_enabled) printf '%s\n' "${TEST_UCI_AUTO_ENABLED:-0}" ;;
			mihowrt.settings.subscription_last_update) printf '%s\n' "${TEST_UCI_LAST_UPDATE:-}" ;;
			mihowrt.settings.subscription_next_update) printf '%s\n' "${TEST_UCI_NEXT_UPDATE:-}" ;;
			mihowrt.settings.subscription_auto_update_reason) printf '%s\n' "${TEST_UCI_AUTO_REASON:-}" ;;
			*) exit 1 ;;
		esac
		;;
	set|delete)
		exit 0
		;;
	commit)
		exit "${TEST_UCI_COMMIT_RC:-0}"
		;;
	*)
		exit 1
		;;
esac
EOF

cat >"$tmpbin/wget" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_WGET_LOG"

output=""
while [[ "$#" -gt 0 ]]; do
	case "$1" in
		-O)
			output="$2"
			shift 2
			;;
		-U|-T)
			shift 2
			;;
		--header)
			shift 2
			;;
		-q)
			shift
			;;
		*)
			shift
			;;
	esac
done

[[ -n "$output" ]] || exit 1
[ -z "${TEST_WGET_PROFILE_UPDATE_INTERVAL:-}" ] || printf '  profile-update-interval: %s\n' "$TEST_WGET_PROFILE_UPDATE_INTERVAL" >&2

case "${TEST_WGET_MODE:-ok}" in
	fail)
		exit 1
		;;
	http404)
		printf '%s\n' '  HTTP/1.1 404 Not Found' >&2
		exit 1
		;;
	empty)
		[ "$output" = "-" ] || : >"$output"
		;;
	large)
		if [ "$output" = "-" ]; then
			printf '1234567890'
		else
			printf '1234567890' >"$output"
		fi
		;;
	*)
		if [ "$output" = "-" ]; then
			printf 'mode: rule\n'
		else
			printf 'mode: rule\n' >"$output"
		fi
		;;
esac
EOF

chmod +x "$tmpbin/logger" "$tmpbin/uci" "$tmpbin/wget"
export PATH="$tmpbin:$PATH"
export TEST_UCI_LOG="$tmpdir/uci.log"
export TEST_WGET_LOG="$tmpdir/wget.log"
SUBSCRIPTION_AUTO_UPDATE_STATE_FILE="$tmpdir/subscription-auto.state"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

mkdir -p "$tmpdir/net/eth0" "$tmpdir/net/eth1"
printf 'router-serial-001\n' >"$tmpdir/serial"
printf 'aa:bb:cc:00:00:01\n' >"$tmpdir/net/eth0/address"
printf 'aa:bb:cc:00:00:02\n' >"$tmpdir/net/eth1/address"
printf "DISTRIB_RELEASE='25.12.3'\n" >"$tmpdir/openwrt_release"
printf 'Test Router AX\n' >"$tmpdir/model"
export MIHOWRT_DEVICE_SERIAL_FILES="$tmpdir/serial"
export MIHOWRT_NET_CLASS_DIR="$tmpdir/net"
export MIHOWRT_OPENWRT_RELEASE_FILE="$tmpdir/openwrt_release"
export MIHOWRT_DEVICE_MODEL_FILES="$tmpdir/model"
export MIHOWRT_HWID_FILE="$tmpdir/hwid"
expected_hwid="$(printf 'mihowrt-hwid-v1\nserial:router-serial-001\n' | sha256sum | awk '{ print $1; exit }')"

assert_eq "mihowrt/0.7.5" "$(subscription_user_agent)" "subscription_user_agent should include package version"
assert_eq "$expected_hwid" "$(device_hwid)" "device_hwid should hash stable hardware material"
assert_eq "$expected_hwid" "$(cat "$MIHOWRT_HWID_FILE")" "device_hwid should cache deterministic hardware ID"
printf '1111111111111111111111111111111111111111111111111111111111111111\n' >"$MIHOWRT_HWID_FILE"
assert_eq "1111111111111111111111111111111111111111111111111111111111111111" "$(device_hwid)" "device_hwid should reuse stored hardware ID"
rm -f "$MIHOWRT_HWID_FILE"
MIHOWRT_DEVICE_SERIAL_FILES="$tmpdir/missing-serial"
expected_mac_hwid="$(printf 'mihowrt-hwid-v1\nmacs:aa:bb:cc:00:00:01,aa:bb:cc:00:00:02\n' | sha256sum | awk '{ print $1; exit }')"
assert_eq "$expected_mac_hwid" "$(device_hwid)" "device_hwid should fall back to sorted MAC material"
rm -f "$MIHOWRT_HWID_FILE"
MIHOWRT_DEVICE_SERIAL_FILES="$tmpdir/missing-serial"
MIHOWRT_NET_CLASS_DIR="$tmpdir/missing-net"
blocked_hwid_parent="$tmpdir/blocked-hwid-parent"
: >"$blocked_hwid_parent"
MIHOWRT_HWID_FILE="$blocked_hwid_parent/hwid"
if device_hwid >/dev/null 2>&1; then
	fail "device_hwid should fail random fallback when hardware ID cache cannot be written"
fi
assert_eq "unknown" "$(device_hwid_header_value)" "device_hwid_header_value should not send unstable random IDs when cache writes fail"
MIHOWRT_HWID_FILE="$tmpdir/hwid"
MIHOWRT_NET_CLASS_DIR="$tmpdir/net"
MIHOWRT_DEVICE_SERIAL_FILES="$tmpdir/serial"
assert_eq "OpenWrt" "$(device_os_name)" "device_os_name should report OpenWrt"
assert_eq "25.12.3" "$(device_os_version)" "device_os_version should read OpenWrt release"
assert_eq "Test Router AX" "$(device_model)" "device_model should read sysinfo model"
assert_true "is_subscription_url should accept https URLs" is_subscription_url "https://example.com/sub.yaml"
assert_true "is_subscription_url should accept http URLs" is_subscription_url "http://example.com/sub.yaml"
assert_false "is_subscription_url should reject local paths" is_subscription_url "/tmp/sub.yaml"
assert_false "is_subscription_url should reject whitespace" is_subscription_url "https://example.com/sub yaml"
assert_false "is_subscription_url should reject empty hosts" is_subscription_url "https://"
assert_false "is_subscription_url should reject missing hosts" is_subscription_url "https:///sub.yaml"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="1"
export TEST_UCI_UPDATE_INTERVAL="12"
export TEST_UCI_HEADER_INTERVAL="24"
export TEST_UCI_AUTO_ENABLED="1"
assert_eq "https://example.com/current.yaml" "$(subscription_url_json | jq -r '.subscription_url')" "subscription_url_json should expose saved UCI URL"
assert_eq "true" "$(subscription_url_json | jq -r '.subscription_interval_override')" "subscription_url_json should expose interval override flag"
assert_eq "12" "$(subscription_url_json | jq -r '.subscription_update_interval')" "subscription_url_json should expose override interval"
assert_eq "24" "$(subscription_url_json | jq -r '.subscription_header_interval')" "subscription_url_json should expose header interval"
assert_eq "12" "$(subscription_url_json | jq -r '.subscription_effective_interval')" "subscription_url_json should prefer override interval"
assert_eq "true" "$(subscription_url_json | jq -r '.subscription_auto_update_enabled')" "subscription_url_json should expose auto-update state"
assert_file_contains "$TEST_UCI_LOG" "-q get mihowrt.settings.subscription_url" "subscription_url_json should read UCI option"
export TEST_UCI_INTERVAL_OVERRIDE="0"
assert_eq "24" "$(subscription_url_json | jq -r '.subscription_effective_interval')" "subscription_url_json should use header interval without override"
assert_eq "" "$(subscription_effective_update_interval 0 "" "")" "subscription_effective_update_interval should disable auto-update without header interval"
assert_eq "0" "$(subscription_effective_update_interval 0 "" 0)" "subscription_effective_update_interval should preserve zero header interval as disabled"
assert_eq "" "$(subscription_effective_update_interval 1 "" 24)" "subscription_effective_update_interval should disable auto-update when override is on but empty"

detect_log="$tmpdir/detect.log"
read_config_json() {
	printf 'read_config_json\n' >>"$detect_log"
	printf '%s\n' '{"external_controller_unix":"mihomo.sock"}'
}

mihomo_api_live_state_read() {
	printf 'mihomo_api_live_state_read\n' >>"$detect_log"
	printf '%s\n' '{"external_controller_unix":"mihomo.sock"}'
}

config_requires_service_restart() {
	return 1
}

SUBSCRIPTION_CRON_FILE="$tmpdir/detect.cron"
SUBSCRIPTION_AUTO_UPDATE_STATE_FILE="$tmpdir/detect.state"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="1"
export TEST_UCI_UPDATE_INTERVAL="0"
export TEST_UCI_HEADER_INTERVAL="24"
: >"$detect_log"
subscription_refresh_auto_update_state
[[ ! -s "$detect_log" ]] || fail "subscription refresh should skip config/live API reads when auto-update is disabled"
subscription_refresh_auto_update_state 1 "Manual restart required"
assert_file_contains "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE" "manual_restart_required=1" "disabled subscription refresh should keep explicit manual restart state"
assert_file_contains "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE" "manual_restart_reason=Manual restart required" "disabled subscription refresh should keep explicit manual restart reason"
[[ ! -s "$detect_log" ]] || fail "subscription refresh should not detect API drift when disabled state is explicit"

export TEST_UCI_UPDATE_INTERVAL="12"
subscription_refresh_auto_update_state
assert_file_contains "$detect_log" "read_config_json" "subscription refresh should detect API drift only when auto-update is enabled"

read_config_json() {
	return 1
}

mihomo_api_live_state_read() {
	return 1
}

SUBSCRIPTION_AUTO_UPDATE_STATE_FILE="$tmpdir/subscription-auto.state"

SUBSCRIPTION_CRON_FILE="$tmpdir/root.cron"
rm -f "$SUBSCRIPTION_CRON_FILE"
subscription_sync_auto_update_cron 0
[[ ! -e "$SUBSCRIPTION_CRON_FILE" ]] || fail "subscription cron sync should not create crontab when disabled and marker is absent"
printf '0 0 * * * echo keep\n17 * * * * /usr/bin/mihowrt auto-update-subscription >/dev/null 2>&1 # mihowrt subscription auto-update\n' >"$SUBSCRIPTION_CRON_FILE"
subscription_sync_auto_update_cron 0
assert_file_contains "$SUBSCRIPTION_CRON_FILE" "echo keep" "subscription cron sync should preserve unrelated entries when disabled"
assert_file_not_contains "$SUBSCRIPTION_CRON_FILE" "auto-update-subscription" "subscription cron sync should remove auto-update task when disabled"
subscription_sync_auto_update_cron 1
assert_file_contains "$SUBSCRIPTION_CRON_FILE" "auto-update-subscription" "subscription cron sync should create auto-update task only when enabled"
subscription_cron_inode="$(stat -c %i "$SUBSCRIPTION_CRON_FILE")"
subscription_sync_auto_update_cron 1
assert_eq "$subscription_cron_inode" "$(stat -c %i "$SUBSCRIPTION_CRON_FILE")" "subscription cron sync should not rewrite unchanged enabled task"
subscription_sync_auto_update_cron 0
assert_file_not_contains "$SUBSCRIPTION_CRON_FILE" "auto-update-subscription" "subscription cron sync should remove auto-update task after interval becomes disabled"

: >"$TEST_UCI_LOG"
: >"$SUBSCRIPTION_CRON_FILE"
rm -f "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="1"
export TEST_UCI_UPDATE_INTERVAL="12"
export TEST_UCI_HEADER_INTERVAL="24"
subscription_refresh_auto_update_state
assert_file_contains "$SUBSCRIPTION_CRON_FILE" "auto-update-subscription" "subscription refresh should create cron for positive interval"
assert_file_contains "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE" "interval=12" "subscription refresh should write tmpfs schedule state"
assert_file_not_contains "$TEST_UCI_LOG" "-q set" "subscription refresh should not write runtime schedule state to UCI"

printf 'interval=12\nlast_update=1\nnext_update=123\nlast_result=scheduled\nreason=\n' >"$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE"
subscription_refresh_auto_update_state
assert_eq "123" "$(subscription_state_value next_update)" "subscription refresh should preserve next update when interval is unchanged"

: >"$TEST_UCI_LOG"
subscription_mark_update_success
assert_file_contains "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE" "last_result=success" "subscription success should update tmpfs result"
assert_file_not_contains "$TEST_UCI_LOG" "-q set" "subscription success should not write schedule state to UCI"
printf '17 * * * * /usr/bin/mihowrt auto-update-subscription >/dev/null 2>&1 # mihowrt subscription auto-update\n' >"$SUBSCRIPTION_CRON_FILE"
subscription_cron_before="$(cat "$SUBSCRIPTION_CRON_FILE")"
subscription_mark_update_success
assert_eq "$subscription_cron_before" "$(cat "$SUBSCRIPTION_CRON_FILE")" "subscription success should not rewrite cron"
subscription_store_auto_update_state 0 "" "api failed"
assert_file_contains "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE" "enabled=0" "subscription disabled state should be kept in tmpfs for UI reason"
assert_eq "false" "$(subscription_url_json | jq -r '.subscription_auto_update_enabled')" "subscription_url_json should expose disabled runtime state"
assert_eq "api failed" "$(subscription_url_json | jq -r '.subscription_auto_update_reason')" "subscription_url_json should expose disabled runtime reason"
subscription_write_auto_update_state 12 "success" "" 1 "Mihomo API/UI settings changed; manual restart is required" 123
assert_eq "true" "$(subscription_url_json | jq -r '.subscription_manual_restart_required')" "subscription_url_json should expose pending manual restart"
assert_eq "Mihomo API/UI settings changed; manual restart is required" "$(subscription_url_json | jq -r '.subscription_manual_restart_reason')" "subscription_url_json should expose pending manual restart reason"
subscription_store_auto_update_state 0 "" "auto-update interval is disabled"
assert_eq "true" "$(subscription_url_json | jq -r '.subscription_manual_restart_required')" "disabled subscription state should preserve pending manual restart"
assert_eq "Mihomo API/UI settings changed; manual restart is required" "$(subscription_url_json | jq -r '.subscription_manual_restart_reason')" "disabled subscription state should preserve pending manual restart reason"
set_subscription_settings "https://example.com/current.yaml" 1 12 24
assert_eq "true" "$(subscription_url_json | jq -r '.subscription_manual_restart_required')" "set_subscription_settings should preserve pending manual restart when drift cannot be detected"
assert_eq "Mihomo API/UI settings changed; manual restart is required" "$(subscription_url_json | jq -r '.subscription_manual_restart_reason')" "set_subscription_settings should preserve pending manual restart reason when drift cannot be detected"
subscription_mark_update_failure "fetch failed"
assert_file_contains "$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE" "last_result=failure" "subscription failure should update tmpfs result"
assert_eq "true" "$(subscription_url_json | jq -r '.subscription_manual_restart_required')" "subscription failure should preserve pending manual restart"
assert_eq "Mihomo API/UI settings changed; manual restart is required" "$(subscription_url_json | jq -r '.subscription_manual_restart_reason')" "subscription failure should preserve pending manual restart reason"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/old.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL="24"
set_subscription_settings "https://example.com/new.yaml" 0 ""
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.subscription_header_interval" "set_subscription_settings should clear stale fetched interval when URL changes without header"

: >"$TEST_WGET_LOG"
SUBSCRIPTION_FETCH_TIMEOUT=7
SUBSCRIPTION_MAX_BYTES=128
assert_eq "128" "$(subscription_max_bytes)" "subscription_max_bytes should honor valid override"
assert_eq "mode: rule" "$(fetch_subscription_config "https://example.com/sub.yaml")" "fetch_subscription_config should print downloaded config"
assert_file_contains "$TEST_WGET_LOG" "-T 7" "fetch_subscription_config should bound wget timeout"
assert_file_contains "$TEST_WGET_LOG" "-U mihowrt/0.7.5" "fetch_subscription_config should send MihoWRT user agent"
assert_file_contains "$TEST_WGET_LOG" "x-hwid: $expected_hwid" "fetch_subscription_config should send deterministic hardware ID header"
assert_file_contains "$TEST_WGET_LOG" "x-device-os: OpenWrt" "fetch_subscription_config should send device OS header"
assert_file_contains "$TEST_WGET_LOG" "x-ver-os: 25.12.3" "fetch_subscription_config should send OS version header"
assert_file_contains "$TEST_WGET_LOG" "x-device-model: Test Router AX" "fetch_subscription_config should send device model header"
assert_file_contains "$TEST_WGET_LOG" "-O -" "fetch_subscription_config should stream wget output through size cap"
assert_file_contains "$TEST_WGET_LOG" "https://example.com/sub.yaml" "fetch_subscription_config should pass URL to wget"

SUBSCRIPTION_MAX_BYTES=bad
assert_eq "1048576" "$(subscription_max_bytes)" "subscription_max_bytes should default to 1 MiB on invalid override"
SUBSCRIPTION_MAX_BYTES=0
assert_eq "1048576" "$(subscription_max_bytes)" "subscription_max_bytes should default to 1 MiB on zero override"
SUBSCRIPTION_MAX_BYTES=999999999999999999999
assert_eq "2147483646" "$(subscription_max_bytes)" "subscription_max_bytes should cap huge overrides before shell arithmetic"

export TEST_WGET_MODE=empty
assert_false "fetch_subscription_config should reject empty downloads" fetch_subscription_config "https://example.com/empty.yaml" >/dev/null

export TEST_WGET_MODE=large
SUBSCRIPTION_MAX_BYTES=4
assert_false "fetch_subscription_config should reject oversized downloads" fetch_subscription_config "https://example.com/large.yaml" >/dev/null

export TEST_WGET_MODE=fail
SUBSCRIPTION_MAX_BYTES=128
assert_false "fetch_subscription_config should fail when wget fails" fetch_subscription_config "https://example.com/fail.yaml" >/dev/null
subscription_error_json="$(fetch_subscription_json "https://example.com/fail.yaml")"
assert_eq "false" "$(printf '%s\n' "$subscription_error_json" | jq -r '.ok')" "fetch_subscription_json should return ok=false on fetch failure"
assert_eq "wget_failed" "$(printf '%s\n' "$subscription_error_json" | jq -r '.error.kind')" "fetch_subscription_json should expose wget failure kind"
subscription_secret_error_json="$(fetch_subscription_json "https://example.com/secret-token.yaml?token=abc")"
assert_file_not_contains <(printf '%s\n' "$subscription_secret_error_json") "secret-token" "fetch errors should not expose subscription URL path"
assert_file_not_contains <(printf '%s\n' "$subscription_secret_error_json") "token=abc" "fetch errors should not expose subscription URL query"
assert_file_contains <(printf '%s\n' "$subscription_secret_error_json") "https://example.com/<redacted>" "fetch errors should keep only redacted subscription URL origin"

export TEST_WGET_MODE=http404
subscription_http_json="$(fetch_subscription_json "https://example.com/missing.yaml")"
assert_eq "http_error" "$(printf '%s\n' "$subscription_http_json" | jq -r '.error.kind')" "fetch_subscription_json should classify HTTP failures"
assert_eq "404" "$(printf '%s\n' "$subscription_http_json" | jq -r '.error.http_code')" "fetch_subscription_json should expose HTTP status"

export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL=24
subscription_ok_json="$(fetch_subscription_json "https://example.com/sub.yaml")"
assert_eq "true" "$(printf '%s\n' "$subscription_ok_json" | jq -r '.ok')" "fetch_subscription_json should return ok=true on success"
assert_eq "mode: rule" "$(printf '%s\n' "$subscription_ok_json" | jq -r '.content')" "fetch_subscription_json should include downloaded content"
assert_eq "24" "$(printf '%s\n' "$subscription_ok_json" | jq -r '.profile_update_interval')" "fetch_subscription_json should include profile update interval header"

assert_false "fetch_subscription_config should reject invalid URLs before wget" fetch_subscription_config "ftp://example.com/sub.yaml" >/dev/null

read_config_json() {
	printf '%s\n' '{"external_controller_unix":"mihomo.sock"}'
}

read_config_json_for_path() {
	printf '%s\n' '{"external_controller_unix":"mihomo.sock"}'
}

mihomo_hot_reload_supported() {
	return 0
}

subscription_store_auto_update_state() {
	printf 'store_auto_update_state:%s:%s:%s\n' "$1" "$2" "$3" >>"$TEST_UCI_LOG"
}

subscription_mark_update_success() {
	printf 'mark_update_success\n' >>"$TEST_UCI_LOG"
}

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL="24"
set +e
set_subscription_settings "https://example.com/current.yaml" 0 "" 24 0
settings_rc=$?
set -e
assert_eq "0" "$settings_rc" "set_subscription_settings should succeed when loaded hot reload flag is false"
assert_file_contains "$TEST_UCI_LOG" "store_auto_update_state:1:24:" "set_subscription_settings should not disable auto-update because fetched config API fields look unsafe"
assert_file_not_contains "$TEST_UCI_LOG" "loaded subscription config has no safe Mihomo API" "loaded config hot reload flag should not block saved auto-update settings"

apply_config_runtime_auto_update() {
	rm -f "$1"
	printf '%s\n' '{"action":"auto_update_disabled","reason":"missing hot reload API"}'
}

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL="24"
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL=24
set +e
auto_update_disabled_json="$(update_subscription_config)"
auto_update_disabled_rc=$?
set -e
assert_eq "auto_update_disabled" "$(printf '%s\n' "$auto_update_disabled_json" | jq -r '.action')" "update_subscription_config should return disabled action from apply"
assert_eq "1" "$auto_update_disabled_rc" "update_subscription_config should fail when apply disables auto-update"
assert_file_not_contains "$TEST_UCI_LOG" "mark_update_success" "failed auto-update apply should not re-enable auto-update state"

subscription_mark_update_failure() {
	printf 'mark_update_failure:%s\n' "${1:-}" >>"$TEST_UCI_LOG"
}

: >"$TEST_UCI_LOG"
printf 'interval=24\nlast_update=1\nnext_update=0\nlast_result=scheduled\nreason=\n' >"$SUBSCRIPTION_AUTO_UPDATE_STATE_FILE"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL="24"
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL=24
set +e
auto_update_disabled_cron_json="$(auto_update_subscription_config)"
auto_update_disabled_cron_rc=$?
set -e
assert_eq "auto_update_disabled" "$(printf '%s\n' "$auto_update_disabled_cron_json" | jq -r '.action')" "auto_update_subscription_config should expose disabled action"
assert_eq "1" "$auto_update_disabled_cron_rc" "auto_update_subscription_config should fail when apply disables auto-update"
assert_file_not_contains "$TEST_UCI_LOG" "mark_update_failure:" "auto_update_subscription_config should not re-enable disabled state as generic failure"

apply_config_runtime_auto_update() {
	rm -f "$1"
	printf '%s\n' '{"action":"hot_reloaded","saved":true,"restart_required":false,"hot_reloaded":true,"policy_reloaded":false}'
}

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL=""
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL=""
auto_update_no_header_json="$(update_subscription_config)"
assert_eq "hot_reloaded" "$(printf '%s\n' "$auto_update_no_header_json" | jq -r '.action')" "update_subscription_config should still apply when subscription has no interval header"
assert_file_contains "$TEST_UCI_LOG" "store_auto_update_state:0::auto-update interval is disabled" "update_subscription_config should disable scheduling when no header interval exists without override"
assert_file_not_contains "$TEST_UCI_LOG" "mark_update_success" "update_subscription_config should not schedule next update without header interval"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL="24"
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL=""
apply_config_runtime_auto_update() {
	printf 'apply_config_runtime_auto_update:%s\n' "$1" >>"$TEST_UCI_LOG"
	rm -f "$1"
	printf '%s\n' '{"action":"auto_update_disabled","reason":"config validation failed"}'
	return 1
}
set +e
auto_update_apply_fail_json="$(update_subscription_config)"
auto_update_apply_fail_rc=$?
set -e
assert_eq "1" "$auto_update_apply_fail_rc" "update_subscription_config should fail when fetched config cannot be applied"
assert_eq "" "$auto_update_apply_fail_json" "update_subscription_config should not emit stale apply JSON when apply command fails"
assert_file_not_contains "$TEST_UCI_LOG" "delete mihowrt.settings.subscription_header_interval" "failed subscription apply should not clear stored header interval"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL=""
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL="24"
export TEST_UCI_COMMIT_RC=1
apply_config_runtime_auto_update() {
	printf 'apply_config_runtime_auto_update:%s\n' "$1" >>"$TEST_UCI_LOG"
	rm -f "$1"
	printf '%s\n' '{"action":"hot_reloaded","saved":true,"restart_required":false,"hot_reloaded":true,"policy_reloaded":false}'
}
set +e
auto_update_uci_fail_json="$(update_subscription_config)"
auto_update_uci_fail_rc=$?
set -e
assert_eq "1" "$auto_update_uci_fail_rc" "update_subscription_config should fail when header interval cannot be persisted"
assert_eq "uci_failed" "$(printf '%s\n' "$auto_update_uci_fail_json" | jq -r '.error.kind')" "update_subscription_config should expose UCI persistence failure"
assert_file_contains "$TEST_UCI_LOG" "apply_config_runtime_auto_update:" "update_subscription_config should persist header interval only after successful apply"
unset TEST_UCI_COMMIT_RC

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_UCI_INTERVAL_OVERRIDE="0"
export TEST_UCI_UPDATE_INTERVAL=""
export TEST_UCI_HEADER_INTERVAL="0"
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL="0"
auto_update_zero_header_json="$(update_subscription_config)"
assert_eq "hot_reloaded" "$(printf '%s\n' "$auto_update_zero_header_json" | jq -r '.action')" "update_subscription_config should still apply when subscription interval header is zero"
assert_file_contains "$TEST_UCI_LOG" "store_auto_update_state:0::auto-update interval is disabled" "update_subscription_config should disable scheduling when header interval is zero"
assert_file_not_contains "$TEST_UCI_LOG" "mark_update_success" "update_subscription_config should not schedule next update for zero header interval"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/auto.yaml"
export TEST_WGET_MODE=fail
set +e
auto_update_fetch_fail_json="$(update_subscription_config)"
auto_update_fetch_fail_rc=$?
set -e
assert_eq "1" "$auto_update_fetch_fail_rc" "update_subscription_config should return non-zero when subscription fetch fails"
assert_eq "false" "$(printf '%s\n' "$auto_update_fetch_fail_json" | jq -r '.updated')" "update_subscription_config should expose failed update JSON"
assert_eq "wget_failed" "$(printf '%s\n' "$auto_update_fetch_fail_json" | jq -r '.error.kind')" "update_subscription_config should expose fetch failure kind"

pass "subscription helpers"
