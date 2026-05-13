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
	set|delete|commit)
		exit 0
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

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

assert_eq "mihowrt/0.6" "$(subscription_user_agent)" "subscription_user_agent should include package version"
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

: >"$TEST_UCI_LOG"
set_subscription_url " https://example.com/new.yaml "
assert_file_contains "$TEST_UCI_LOG" "-q get mihowrt.settings.subscription_url" "set_subscription_url should read current URL before writing"
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings=settings" "set_subscription_url should ensure named UCI section"
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.subscription_url=https://example.com/new.yaml" "set_subscription_url should store trimmed URL"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "set_subscription_url should commit UCI config"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/same.yaml"
set_subscription_url "https://example.com/same.yaml"
assert_file_contains "$TEST_UCI_LOG" "-q get mihowrt.settings.subscription_url" "set_subscription_url should still read current URL for no-op saves"
assert_file_not_contains "$TEST_UCI_LOG" "-q commit mihowrt" "set_subscription_url should avoid NAND writes when URL is unchanged"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
set_subscription_url ""
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.subscription_url" "set_subscription_url should delete empty URL"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "set_subscription_url should commit URL deletion"

: >"$TEST_UCI_LOG"
assert_false "set_subscription_url should reject unsupported schemes" set_subscription_url "file:///tmp/config.yaml"
[[ ! -s "$TEST_UCI_LOG" ]] || fail "set_subscription_url should not touch UCI for invalid URL"

: >"$TEST_WGET_LOG"
SUBSCRIPTION_FETCH_TIMEOUT=7
SUBSCRIPTION_MAX_BYTES=128
assert_eq "128" "$(subscription_max_bytes)" "subscription_max_bytes should honor valid override"
assert_eq "mode: rule" "$(fetch_subscription_config "https://example.com/sub.yaml")" "fetch_subscription_config should print downloaded config"
assert_file_contains "$TEST_WGET_LOG" "-T 7" "fetch_subscription_config should bound wget timeout"
assert_file_contains "$TEST_WGET_LOG" "-U mihowrt/0.6" "fetch_subscription_config should send MihoWRT user agent"
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
auto_update_disabled_json="$(update_subscription_config)"
assert_eq "auto_update_disabled" "$(printf '%s\n' "$auto_update_disabled_json" | jq -r '.action')" "update_subscription_config should return disabled action from apply"
assert_file_not_contains "$TEST_UCI_LOG" "mark_update_success" "failed auto-update apply should not re-enable auto-update state"

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
export TEST_UCI_HEADER_INTERVAL="0"
export TEST_WGET_MODE=ok
export TEST_WGET_PROFILE_UPDATE_INTERVAL="0"
auto_update_zero_header_json="$(update_subscription_config)"
assert_eq "hot_reloaded" "$(printf '%s\n' "$auto_update_zero_header_json" | jq -r '.action')" "update_subscription_config should still apply when subscription interval header is zero"
assert_file_contains "$TEST_UCI_LOG" "store_auto_update_state:0::auto-update interval is disabled" "update_subscription_config should disable scheduling when header interval is zero"
assert_file_not_contains "$TEST_UCI_LOG" "mark_update_success" "update_subscription_config should not schedule next update for zero header interval"

pass "subscription helpers"
