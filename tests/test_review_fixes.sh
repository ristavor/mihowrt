#!/usr/bin/env bash
# Behavioral regressions for 196943ef; each named case also runs independently.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

cases=(startup_settings watchdog_settings auto_update_ready lists_refresh_ready dns_comment extension_comment list_comment groups_comment indentless_groups profile_race empty_dns_next empty_dns_comments curl_device curl_plain lists_star lists_brackets single_quote)
if [ "$#" -eq 0 ]; then
	failed=0
	for name in "${cases[@]}"; do
		if bash "$0" "$name"; then :; else failed=1; fi
	done
	exit "$failed"
fi
name="$1"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh fetch.sh lists.sh service.sh config.sh
setup_runtime_paths "$tmpdir"
src="$tmpdir/source.yaml"
out="$tmpdir/runtime.yaml"
events="$tmpdir/events"
: >"$events"
generate() { mihomo_config_generate "$src" "$out" || fail "$name: generation failed"; }
assert_default_dns() {
	assert_eq 1 "$(grep -c '^dns:' "$out")" "$name: exactly one dns key"
	assert_file_contains "$out" 'https://dns.google/dns-query' "$name: managed DNS"
	assert_file_contains "$out" '  enhanced-mode: redir-host' "$name: managed default mode"
	assert_file_contains "$out.profile" 'dns redir-host' "$name: default DNS profile"
	assert_file_contains "$out.profile" 'mode proxy-first' "$name: default policy profile"
}
case "$name" in
startup_settings|watchdog_settings)
	RUNTIME_CONFIG="$out"
	RUNTIME_LOCK_FILE="$tmpdir/lock"
	SERVICE_PID_FILE="$PKG_STATE_DIR/pid"
	RUNNING_MARKER="$PKG_STATE_DIR/running"
	CLASH_BIN="$tmpdir/core"
	printf '#!/bin/sh\nexec sleep 30\n' >"$CLASH_BIN"
	chmod +x "$CLASH_BIN"
	printf 'proxies: []\n' >"$RUNTIME_CONFIG"
	printf 'direct-first\n' >"$tmpdir/mode"
	settings_load() { POLICY_MODE="$(cat "$tmpdir/mode")"; echo load >>"$events"; }
	# Change settings after the initial load, before startup policy is installed.
	wait_for_ready() { [ "$name" != startup_settings ] || echo proxy-first >"$tmpdir/mode"; }
	policy_apply() { echo "apply:$POLICY_MODE" >>"$events"; }
	policy_cleanup() { :; }
	cache_db_persist() { :; }
	WATCHDOG_INTERVAL=0.01
	WATCHDOG_FAILS=1
	probe_count=0
	api_alive() { [ "$probe_count" -le 2 ]; }
	api_dns_probe() {
		probe_count=$((probe_count + 1))
		if [ "$probe_count" = 2 ]; then
			assert_false "$name: marker absent while degraded" test -e "$RUNNING_MARKER"
			echo proxy-first >"$tmpdir/mode"
			return 0
		fi
		return 1
	}
	rc=0
	run_service || rc=$?
	assert_eq 1 "$rc" "$name: hung API exits for respawn"
	if [ "$name" = startup_settings ]; then
		assert_eq proxy-first "$(sed -n 's/^apply://p' "$events" | head -n1)" "$name: startup applies freshly loaded settings"
	else
		assert_eq $'direct-first\nproxy-first' "$(sed -n 's/^apply://p' "$events")" "$name: recovery uses changed profile"
		assert_eq 3 "$(grep -c '^load$' "$events")" "$name: settings reloaded at startup and recovery"
	fi
	;;
auto_update_ready|lists_refresh_ready)
	RUNNING_MARKER="$PKG_STATE_DIR/running"
	service_running() { return 0; }
	settings_load() { LISTS_INTERVAL=1; }
	subscription_due() { return 1; }
	lists_update_remote() { echo changed; }
	with_lock() { "$@"; }
	nft_apply() { echo nft >>"$events"; }
	command_name="${name%_ready}"
	"$command_name" >/dev/null
	assert_eq '' "$(cat "$events")" "$name: no nft while core runs without marker"
	touch "$RUNNING_MARKER"
	"$command_name" >/dev/null
	assert_eq nft "$(cat "$events")" "$name: nft when ready"
	;;
dns_comment)
	printf 'dns:   # provider DNS\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: whitelist\n  nameserver:\n    - 1.2.3.4\nproxies: []\n' >"$src"
	generate
	assert_file_contains "$out" 'dns:   # provider DNS' "$name: provider block kept"
	assert_eq 1 "$(grep -c '^dns:' "$out")" "$name: no second DNS block"
	assert_file_contains "$out" '    - 1.2.3.4' "$name: provider children kept"
	assert_file_not_contains "$out" 'https://dns.google' "$name: no managed nameservers"
	assert_file_contains "$out.profile" 'dns fake-ip' "$name: DNS from children"
	assert_file_contains "$out.profile" 'mode direct-first' "$name: mode from children"
	;;
extension_comment)
	printf 'x-mihowrt: # c\n  disable-quic: false\n  lists-interval: 24\nproxies: []\n' >"$src"
	generate
	assert_file_contains "$out.profile" 'set disable_quic 0' "$name: settings parsed"
	assert_file_contains "$out.profile" 'set lists_interval 24' "$name: interval parsed"
	;;
list_comment)
	printf 'x-mihowrt:\n  proxy-ips: # c\n    - 1.2.3.4\n    - https://example.com/list\n' >"$src"
	generate
	assert_file_contains "$out.profile" 'proxy-ip 1.2.3.4' "$name: address parsed"
	assert_file_contains "$out.profile" 'proxy-ip https://example.com/list' "$name: URL parsed"
	;;
groups_comment|indentless_groups|single_quote)
	case "$name" in
	groups_comment) printf 'proxy-groups: # c\n  - name: G\n' >"$src"; group=G ;;
	indentless_groups) printf 'proxy-groups:\n- name: G\n  type: select\n  proxies:\n  - DIRECT\n' >"$src"; group=G ;;
	single_quote) printf "proxy-groups:\n  - name: 'it''s'\n" >"$src"; group="it's" ;;
	esac
	generate
	assert_file_contains "$out" "https://dns.google/dns-query#$group\"" "$name: first group DNS suffix"
	if [ "$name" = indentless_groups ]; then
		sed -n '/^proxy-groups:/,/^# ---/p' "$out" | head -n5 >"$tmpdir/groups"
		cmp -s "$src" "$tmpdir/groups" || fail "$name: group items changed"
	fi
	;;
profile_race)
	CLASH_CONFIG_BACKUP="$tmpdir/backup.yaml"
	RUNTIME_CONFIG="$out"
	printf 'x-mihowrt:\n  disable-quic: true\nproxies: []\n' >"$src"
	generate
	cp "$out.profile" "$PROFILE_FILE"
	printf 'x-mihowrt:\n  disable-quic: false\nproxies: []\n' >"$tmpdir/candidate"
	mihomo_config_test() { :; }
	service_running() { return 0; }
	service_ready() { return 0; }
	api_alive() { return 0; }
	api_reload() { fail "$name: extension-only change must not reload"; }
	cron_update() { :; }
	policy_apply() { echo policy >>"$events"; }
	# Interleave an unlocked status reader immediately after the YAML rename.
	mv() {
		command mv "$@"
		if [ "${*: -1}" = "$CLASH_CONFIG" ]; then
			touch -d '2000-01-01' "$PROFILE_FILE"
			profile_ensure
			assert_file_contains "$PROFILE_FILE" 'set disable_quic 0' "$name: reader regenerated new profile"
			echo reader >>"$events"
		fi
	}
	config_install "$tmpdir/candidate" >/dev/null
	assert_eq $'reader\npolicy' "$(cat "$events")" "$name: policy change survives concurrent profile regeneration"
	;;
empty_dns_next|empty_dns_comments)
	if [ "$name" = empty_dns_next ]; then
		printf 'dns:\nproxies: []\n' >"$src"
	else
		printf 'proxies: []\ndns:\n  # no children\n  # still empty\n' >"$src"
	fi
	generate
	assert_default_dns
	;;
curl_device|curl_plain)
	cat >"$tmpdir/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CURL_LOG"
while [ "$#" -gt 0 ]; do
 case "$1" in
 -D) printf 'HTTP/1.1 200 OK\r\n' >"$2"; shift ;;
 -o) printf data >"$2"; shift ;;
 esac
 shift
done
CURL
	chmod +x "$tmpdir/bin/curl"
	export CURL_LOG="$tmpdir/curl.argv"
	device_hwid() { echo test-hwid; }
	device_os_version() { echo test-os; }
	device_model() { echo test-model; }
	device=0
	[ "$name" != curl_device ] || device=1
	http_fetch 'https://example.com/[1-3]' "$tmpdir/body" 100 10 "$device"
	grep -Eq '^-[^-]*g' "$CURL_LOG" || fail "$name: curl argv missing globoff (-g)"
	if [ "$device" = 1 ]; then assert_file_contains "$CURL_LOG" 'x-hwid: test-hwid' "$name: device branch exercised"; fi
	;;
lists_star|lists_brackets)
	cd "$tmpdir"
	mkdir -p 'https:/example.com'
	if [ "$name" = lists_star ]; then fixture_url='https://example.com/list*'; else fixture_url='https://example.com/list[1-3]'; fi
	touch 'https:/example.com/list1'
	# Verify this cwd really would expand the provider URL without set -f.
	compgen -G "$fixture_url" >/dev/null || fail "$name: missing matching glob fixture"
	POLICY_CACHE_DIR="$tmpdir/cache"
	lists_urls() { printf '%s\n' "$fixture_url"; }
	http_fetch() { printf '%s\n' "$1" >>"$events"; printf '1.2.3.4\n' >"$2"; }
	assert_eq changed "$(lists_update_remote 1)" "$name: cache updated"
	assert_eq "$fixture_url" "$(cat "$events")" "$name: URL passed literally, not cwd-expanded"
	assert_file_contains "$(lists_cache_file "$fixture_url")" '1.2.3.4' "$name: literal URL cache populated"
	;;
*) fail "unknown review regression: $name" ;;
esac
pass "review regression: $name"
