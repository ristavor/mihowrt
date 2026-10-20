#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh nft.sh route.sh dns.sh mihomo-api.sh service.sh

PKG_STATE_DIR="$tmpdir/run"
PKG_TMP_DIR="$tmpdir/tmp"
PKG_PERSIST_DIR="$tmpdir/etc"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/lock"
SERVICE_PID_FILE="$PKG_STATE_DIR/pid"
RUNNING_MARKER="$PKG_STATE_DIR/running"
RUNTIME_CONFIG="$tmpdir/runtime.yaml"
CACHE_DB_TMPFS="$tmpdir/cache.db"
WATCHDOG_INTERVAL=0.1
mkdir -p "$PKG_STATE_DIR"
CLASH_BIN="$tmpdir/clash"
printf '#!/bin/sh\nexec sleep 30\n' >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
echo "mode: rule" >"$RUNTIME_CONFIG"

events="$tmpdir/events"
reset_events() {
	: >"$events"
}
settings_load() { :; }
wait_for_ready() { :; }
policy_apply() { echo apply >>"$events"; }
policy_cleanup() { echo cleanup >>"$events"; }
probe_script=""
probe_count=0
api_dns_probe() {
	probe_count=$((probe_count + 1))
	local verdict
	verdict="$(printf '%s' "$probe_script" | cut -c"$probe_count")"
	[ "${verdict:-1}" = 1 ]
}

reset_events
probe_script="000"
rc=0
run_service || rc=$?
assert_eq 1 "$rc" "watchdog exits 1 so procd respawns"
assert_eq $'apply\ncleanup' "$(cat "$events")" "policy cleaned once after fail-open"
[[ ! -e "$RUNNING_MARKER" ]] || fail "running marker removed"
pass "watchdog fails open"

reset_events
probe_count=0
probe_script="001000"
rc=0
run_service || rc=$?
assert_eq 6 "$probe_count" "two failures reset by a success"
assert_eq 1 "$rc" "third consecutive failure triggers fail-open"
pass "watchdog tolerates transient failures"

reset_events
wait_for_ready() { return 1; }
rc=0
run_service 2>/dev/null || rc=$?
assert_eq 1 "$rc" "start failure"
assert_eq "cleanup" "$(cat "$events")" "no apply when Mihomo is not ready"
pass "not ready cleans up"

load_modules service.sh
nft_apply() { echo nft >>"$events"; }
route_setup() { echo route-fail >>"$events"; return 1; }
dns_apply() { echo dns >>"$events"; }
dns_cleanup() { echo dns-clean >>"$events"; }
nft_cleanup() { echo nft-clean >>"$events"; }
route_cleanup() { echo route-clean >>"$events"; }
reset_events
rc=0
policy_apply || rc=$?
assert_eq 1 "$rc" "apply failure reported"
assert_eq $'nft\nroute-fail\ndns-clean\nnft-clean\nroute-clean' "$(cat "$events")" "partial apply rolled back"
pass "apply failure cleans"

nested() {
	with_lock true
	[ -L "$RUNTIME_LOCK_FILE" ] || fail "outer lock must survive nested release"
}
with_lock nested
[[ ! -e "$RUNTIME_LOCK_FILE" ]] || fail "lock released after outer call"
pass "lock is re-entrant"

# Network fetches must not hold the runtime lock (LuCI saves would time out).
load_modules fetch.sh config.sh
lock_seen=""
http_fetch() {
	lock_seen="$lock_seen $(readlink "$RUNTIME_LOCK_FILE" 2>/dev/null || echo free)"
	mkdir -p "$(dirname "$2")"
	printf 'mode: rule\n' >"$2"
}
config_install() {
	[ "$(readlink "$RUNTIME_LOCK_FILE")" = "$$" ] || fail "config_install must run under the lock"
	echo '{"action":"saved"}'
}
cron_update() { :; }
subscription_metadata_from_headers() { echo '{}'; }
SUBSCRIPTION_META_FILE="$tmpdir/etc/sub.json"
settings_load() { SUBSCRIPTION_URL=https://sub.example/x; SUBSCRIPTION_INTERVAL=1; LISTS_INTERVAL=1; }
subscription_update >/dev/null
assert_eq " free" "$lock_seen" "subscription download runs without the lock"
pass "network fetch outside the lock"

# --- review fixes -----------------------------------------------------------
load_modules service.sh
policy_apply() { echo apply >>"$events"; }
policy_cleanup() { echo "cleanup marker=$([ -e "$RUNNING_MARKER" ] && echo yes || echo no)" >>"$events"; }
wait_for_ready() { :; }
settings_load() { :; }

# B: the running marker is gone before cleanup, so hotplug/reload cannot
# re-point DNS at a dying Mihomo.
reset_events
probe_count=0
probe_script="0"
WATCHDOG_FAILS=1
run_service 2>/dev/null || true
assert_eq "cleanup marker=no" "$(grep cleanup "$events")" "marker removed before cleanup"
WATCHDOG_FAILS=3
pass "marker removed before cleanup"

# A: stop never waits on a busy lock longer than procd allows.
sleep 300 &
holder=$!
ln -s "$holder" "$RUNTIME_LOCK_FILE"
reset_events
start=$(date +%s)
probe_script="1111111111"
probe_count=0
( sleep 1; kill -TERM $$ ) &
run_service 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
rm -f "$RUNTIME_LOCK_FILE"
[ "$elapsed" -lt 25 ] || fail "stop took ${elapsed}s with a busy lock (procd kills at 30s)"
assert_file_contains "$events" "cleanup" "cleanup still happens without the lock"
pass "stop does not wait on a busy lock"

# J: a stop request during startup aborts the wait.
grep -q 'stop:-0}" -eq 0 ] || return 1' "$MIHOWRT_LIB_DIR/service.sh" || fail "wait_for_ready must honour stop requests"
pass "startup honours stop"

# C: WAN ifup restarts an enabled service that procd gave up on.
grep -q '/etc/init.d/mihowrt enabled' "$ROOT_DIR/rootfs/etc/hotplug.d/iface/90-mihowrt" || fail "hotplug must re-arm a stopped enabled service"
pass "hotplug re-arms service"

# M: list upload paths cannot escape /tmp.
mkdir -p /tmp/mihowrt-policy-list.dir
: >/tmp/mihowrt-policy-list.dir/x
if lists_apply /tmp/mihowrt-policy-list.dir/x /tmp/mihowrt-policy-list.dir/x /tmp/mihowrt-policy-list.dir/x 2>/dev/null; then fail "nested list path must be rejected"; fi
rm -rf /tmp/mihowrt-policy-list.dir
pass "list path check"
