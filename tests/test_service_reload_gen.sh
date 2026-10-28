#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
export RELOAD_TEST_DIR="$tmpdir"

# Unchanged inputs must not rebuild the runtime config; each generator input
# must. Scenarios run in BusyBox ash, the shell of the router.
failed=0
for scenario in same yaml lan_ip secret dashboard awk_file dns_port fakeip tproxy direct_tproxy mark api_port socket \
	runtime_missing profile_missing no_key api_reload_failure test_rejected build_failed_test \
	install_ok install_restore; do
	if ash -s "$scenario" <<'ASH'
set -e
. "$MIHOWRT_LIB_DIR/constants.sh"
. "$MIHOWRT_LIB_DIR/helpers.sh"
mihowrt_load_modules
scenario="$1"
test_root="$RELOAD_TEST_DIR/$scenario"
mkdir -p "$test_root/lib"
cp "$MIHOWRT_LIB_DIR"/*.awk "$test_root/lib/"
MIHOWRT_LIB_DIR_REAL="$MIHOWRT_LIB_DIR"
# Generator files come from a private copy so a scenario can edit them.
MIHOWRT_LIB_DIR="$test_root/lib"
PKG_TMP_DIR="$test_root/tmp"
PKG_STATE_DIR="$test_root/run"
PKG_PERSIST_DIR="$test_root/persist"
CLASH_BIN="$test_root/core"
printf '#!/bin/sh\nexit 0\n' >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
CLASH_CONFIG="$test_root/source.yaml"
CLASH_CONFIG_BACKUP="$test_root/source.yaml.bak"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.yaml"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
CONFIG_INVALID_FILE="$PKG_STATE_DIR/config.invalid"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR"
printf 'mode: rule\nproxies: []\n' >"$CLASH_CONFIG"
uci set network.lan.ipaddr=192.168.8.1/24
API_SECRET=secret-one
DASHBOARD_ENABLED=0
inputs="$RUNTIME_CONFIG.inputs"

# The real generator with a counter; key computation is not a generation.
eval "$(sed -n '/^mihomo_config_generate() {/,/^}/p' "$MIHOWRT_LIB_DIR_REAL/mihomo-config.sh" |
	sed '1s/mihomo_config_generate/mihomo_config_generate_real/')"
mihomo_config_generate() {
	[ "${3:-}" = key ] || echo gen >>"$test_root/generations"
	mihomo_config_generate_real "$@"
}
settings_load() { :; }
cron_update() { :; }
service_ready() { return 0; }
service_running() { return 0; }
api_alive() { return 0; }
policy_apply() { echo apply >>"$test_root/events"; }
config_profile_apply() { echo profile_apply >>"$test_root/events"; }
mihomo_config_test() { echo test >>"$test_root/events"; [ ! -e "$test_root/reject" ]; }
api_reload() { echo reload >>"$test_root/events"; [ ! -e "$test_root/reload_fail" ]; }
count() { [ -f "$test_root/$1" ] && wc -l <"$test_root/$1" | tr -d ' ' || echo 0; }
require() { [ "$(count generations)" -eq "$1" ] || { echo "$scenario: expected $1 generations, got $(count generations)" >&2; exit 1; }; }

case "$scenario" in
build_failed_test | install_ok | install_restore) ;;
*)
	service_reload
	require 1
	[ -s "$inputs" ] || { echo 'successful reload stored no key' >&2; exit 1; }
	[ "$(wc -c <"$inputs" | tr -d ' ')" -eq 65 ] || { echo 'key is not one sha256 line' >&2; exit 1; }
	;;
esac

expect=2
case "$scenario" in
same) expect=1 ;;
yaml) printf 'mode: global\n' >>"$CLASH_CONFIG" ;;
lan_ip) uci set network.lan.ipaddr=192.168.9.1/24 ;;
secret) API_SECRET=secret-two ;;
dashboard) DASHBOARD_ENABLED=1 ;;
awk_file)
	printf '\n# changed\n' >>"$MIHOWRT_LIB_DIR/mihomo-config.awk"
	;;
dns_port) MIHOMO_DNS_PORT=7000 ;;
fakeip) FAKEIP_RANGE=198.19.0.0/16 ;;
tproxy) MIHOMO_TPROXY_PORT=7001 ;;
direct_tproxy) MIHOMO_DIRECT_TPROXY_PORT=7002 ;;
mark) MIHOMO_ROUTING_MARK=3 ;;
api_port) MIHOMO_API_PORT=9091 ;;
socket) MIHOMO_SOCKET_TMPFS="$test_root/other.sock" ;;
runtime_missing) rm -f "$RUNTIME_CONFIG" ;;
profile_missing) rm -f "$PROFILE_FILE" ;;
no_key) sha256sum() { return 1; } ;;
api_reload_failure)
	# A failed hot reload rolls back: the key must not claim the rolled-back config.
	printf 'mode: global\n' >>"$CLASH_CONFIG"
	touch "$test_root/reload_fail"
	rc=0
	service_reload 2>/dev/null || rc=$?
	[ "$rc" -eq 1 ] || { echo 'failed reload was not reported' >&2; exit 1; }
	[ ! -e "$inputs" ] || { echo 'rollback left a stale key' >&2; exit 1; }
	rm -f "$test_root/reload_fail"
	require 2
	service_reload
	require 3
	[ -s "$inputs" ]
	service_reload
	require 3
	exit 0
	;;
test_rejected)
	# A rejected candidate leaves the live config and its key; the old inputs still skip.
	printf 'mode: global\n' >>"$CLASH_CONFIG"
	touch "$test_root/reject"
	rc=0
	service_reload 2>/dev/null || rc=$?
	[ "$rc" -eq 1 ]
	require 2
	service_reload 2>/dev/null || :
	require 3
	exit 0
	;;
build_failed_test)
	# Start path: runtime_config_build stores the key only after the core test passed.
	touch "$test_root/reject"
	rc=0
	runtime_config_build "$RUNTIME_CONFIG" 2>/dev/null || rc=$?
	[ "$rc" -eq 1 ]
	[ ! -e "$inputs" ] || { echo 'rejected config kept a key' >&2; exit 1; }
	rm "$test_root/reject"
	runtime_config_build "$RUNTIME_CONFIG"
	[ -s "$inputs" ] || { echo 'start stored no key' >&2; exit 1; }
	: >"$test_root/events"
	service_reload
	require 2
	[ "$(cat "$test_root/events")" = apply ] || { echo 'reload after start was not policy-only' >&2; exit 1; }
	exit 0
	;;
install_ok | install_restore)
	CLASH_CONFIG_BACKUP="$test_root/backup"
	printf 'mode: rule\nproxies: []\n' >"$CLASH_CONFIG"
	service_reload
	[ -s "$inputs" ] || { echo 'reload stored no key' >&2; exit 1; }
	printf 'mode: global\n' >"$test_root/upload.yaml"
	[ "$scenario" = install_ok ] || touch "$test_root/reload_fail"
	rc=0
	config_install "$test_root/upload.yaml" >/dev/null 2>&1 || rc=$?
	if [ "$scenario" = install_restore ]; then
		[ "$rc" -eq 1 ]
		[ ! -e "$inputs" ] || { echo 'restore left a stale key' >&2; exit 1; }
		[ "$(cat "$CLASH_CONFIG")" = "$(printf 'mode: rule\nproxies: []')" ]
		rm "$test_root/reload_fail"
		service_reload
		[ "$(count generations)" -eq 3 ] || { echo 'restored config was not regenerated' >&2; exit 1; }
	else
		[ "$rc" -eq 0 ]
		[ -s "$inputs" ] || { echo 'install stored no key' >&2; exit 1; }
		service_reload
		[ "$(count generations)" -eq 2 ] || { echo 'reload after install regenerated' >&2; exit 1; }
	fi
	exit 0
	;;
esac

: >"$test_root/events"
rc=0
service_reload || rc=$?
[ "$rc" -eq 0 ]
require "$expect"
if [ "$scenario" = same ]; then
	[ "$(cat "$test_root/events")" = apply ] || { echo 'unchanged reload did more than apply policy' >&2; exit 1; }
else
	# Identical output needs only the policy apply; changed output is tested and reloaded first.
	[ "$(tail -n 1 "$test_root/events")" = apply ] || { echo "$scenario did not apply policy" >&2; exit 1; }
fi
ASH
	then pass "service reload generation skip: $scenario"; else failed=1; fi
done

# Every awk input of the generator must be in the hashed list; the output
# paths are per-build and stay outside it.
gen_sh="$ROOT_DIR/rootfs/usr/lib/mihowrt/mihomo-config.sh"
body="$(sed -n '/^mihomo_config_generate() {/,/^}/p' "$gen_sh")"
list="$(printf '%s\n' "$body" | sed -n '/^\tset -- /,/^\t[^ \t-]/p')"
missing=""
for name in $(printf '%s\n' "$body" | grep -oE -- '-v [a-z_]+=' | sed 's/^-v //; s/=$//' | sort -u); do
	case "$name" in profile | warnfile) continue ;; esac
	printf '%s\n' "$list" | grep -q -- "-v $name=" || missing="$missing $name"
done
if [ -z "$missing" ]; then pass 'generator key covers every awk -v input'; else
	echo "FAIL: mihomo_config_generate -v inputs outside the hashed list:$missing" >&2
	failed=1
fi
exit "$failed"
