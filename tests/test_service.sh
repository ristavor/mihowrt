#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh nft.sh route.sh dns.sh mihomo-api.sh subscription.sh service.sh
setup_runtime_paths "$tmpdir"

# Full recovery removes the include; removing it before reload avoids re-entry.
(
 mkdir -p "${FW4_INPUT_INCLUDE%/*}"
 printf 'guest input rules\n' >"$FW4_INPUT_INCLUDE"
 nft() { :; }
 fw4() {
  assert_false 'stop removes include before fw4 reload' test -e "$FW4_INPUT_INCLUDE"
  printf '%s\n' "$*" >>"$tmpdir/stop-fw4.calls"
  nft_fw4_input_cleanup
 }
 dns_cleanup() { :; }
 route_cleanup() { :; }
 pgrep() { return 1; }
 service_pid() { return 1; }
 service_recover
 assert_false 'full recovery removes fw4 input include' test -e "$FW4_INPUT_INCLUDE"
 assert_eq reload "$(cat "$tmpdir/stop-fw4.calls")" 'full recovery reloads once without recursion'
 service_recover
 assert_eq reload "$(cat "$tmpdir/stop-fw4.calls")" 'repeated stop does not reload'
)
pass 'full recovery removes fw4 input include without recursive reload'

# Default provider directories follow the existing tmpfs-link migration.
(
 root="$tmpdir/layout"
 sed -e 's|/opt/clash|@ROOT@/opt/clash|g' \
  -e 's|/tmp/|@ROOT@/tmp/|g' -e 's|/var/run/|@ROOT@/run/|g' \
  -e 's|/etc/|@ROOT@/etc/|g' -e "s|@ROOT@|$root|g" \
  "$MIHOWRT_LIB_DIR/constants.sh" >"$tmpdir/layout-constants.sh"
 # shellcheck disable=SC1090
 source "$tmpdir/layout-constants.sh"
 for name in proxies rules; do
  mkdir -p "$root/opt/clash/$name"
  printf 'provider cache\n' >"$root/opt/clash/$name/0123456789abcdef0123456789abcdef"
 done
 layout_init
 for name in proxies rules; do
  assert_symlink_target "$root/opt/clash/$name" "$root/tmp/clash/$name" "$name provider directory uses tmpfs"
  assert_file_contains "$root/tmp/clash/$name/0123456789abcdef0123456789abcdef" 'provider cache' "$name existing provider cache migrated"
 done
 rm -rf "$root/tmp/clash/proxies" "$root/tmp/clash/rules"
 layout_init
 for name in proxies rules; do
  assert_true "$name tmpfs directory recreated after reboot" test -d "$root/tmp/clash/$name"
 done
)
pass 'default provider caches migrate to tmpfs links and recover after reboot'

# R11 keeps user files: only empty or Mihomo hash-named dirs move to tmpfs.
(
 root="$tmpdir/layout-user"
 sed -e 's|/opt/clash|@ROOT@/opt/clash|g' \
  -e 's|/tmp/|@ROOT@/tmp/|g' -e 's|/var/run/|@ROOT@/run/|g' \
  -e 's|/etc/|@ROOT@/etc/|g' -e "s|@ROOT@|$root|g" \
  "$MIHOWRT_LIB_DIR/constants.sh" >"$tmpdir/layout-user-constants.sh"
 # shellcheck disable=SC1090
 source "$tmpdir/layout-user-constants.sh"
 hash=0123456789abcdef0123456789abcdef
 logger() { printf '%s\n' "$*" >>"$tmpdir/layout-user.warnings"; }
 mkdir -p "$root/opt/clash/proxies" "$root/opt/clash/rules"
 printf 'cache\n' >"$root/opt/clash/proxies/$hash"
 printf 'mine\n' >"$root/opt/clash/rules/my.yaml"
 printf 'cache\n' >"$root/opt/clash/rules/$hash"
 layout_init
 assert_symlink_target "$root/opt/clash/proxies" "$root/tmp/clash/proxies" 'hash-only dir migrates to tmpfs'
 assert_file_contains "$root/tmp/clash/proxies/$hash" cache 'hash-named cache file migrated'
 assert_false 'mixed dir is not linked' test -L "$root/opt/clash/rules"
 assert_file_contains "$root/opt/clash/rules/my.yaml" mine 'user file stays on flash'
 assert_file_contains "$root/opt/clash/rules/$hash" cache 'cache file next to user file stays on flash'
 assert_eq 1 "$(wc -l <"$tmpdir/layout-user.warnings" | tr -d ' ')" 'one warning for the kept directory'
 assert_file_contains "$tmpdir/layout-user.warnings" "$root/opt/clash/rules" 'warning names the directory'
 for name in short UPPERCASE0123456789ABCDEF01234567 "${hash}0"; do
  rm -rf "$root/opt/clash/rules"; mkdir -p "$root/opt/clash/rules"
  : >"$root/opt/clash/rules/$name"
  layout_init
  assert_false "$name is not a Mihomo cache name" test -L "$root/opt/clash/rules"
 done
 rm -rf "$root/opt/clash/rules"; mkdir -p "$root/opt/clash/rules/$hash" "$root/opt/clash/rules"
 layout_init
 assert_false 'directory named like a hash is user data' test -L "$root/opt/clash/rules"
 rm -rf "$root/opt/clash/rules"; mkdir -p "$root/opt/clash/rules"; : >"$root/opt/clash/rules/.hidden"
 layout_init
 assert_false 'dotfile is user data' test -L "$root/opt/clash/rules"
 rm -rf "$root/opt/clash/rules"; mkdir -p "$root/opt/clash/rules"
 layout_init
 assert_symlink_target "$root/opt/clash/rules" "$root/tmp/clash/rules" 'empty dir migrates to tmpfs'
)
pass 'provider cache dirs migrate only when they hold nothing but Mihomo cache files'

# Uninstall removes only our links to tmpfs, never a real directory with user files.
(
 root="$tmpdir/uninstall-user"
 sed -e 's|/opt/clash|@ROOT@/opt/clash|g' \
  -e 's|/tmp/|@ROOT@/tmp/|g' -e 's|/var/run/|@ROOT@/run/|g' \
  -e 's|/etc/|@ROOT@/etc/|g' -e "s|@ROOT@|$root|g" \
  "$MIHOWRT_LIB_DIR/constants.sh" >"$tmpdir/uninstall-user-constants.sh"
 # shellcheck disable=SC1090
 source "$tmpdir/uninstall-user-constants.sh"
 service_recover() { :; }
 policy_cleanup() { :; }
 nft_fw4_input_cleanup() { :; }
 cron_sync() { :; }
 mkdir -p "$root/opt/clash/proxies" "$root/tmp/clash/rules"
 printf 'mine\n' >"$root/opt/clash/proxies/my.yaml"
 ln -s "$root/tmp/clash/rules" "$root/opt/clash/rules"
 printf 'cache\n' >"$root/tmp/clash/rules/0123456789abcdef0123456789abcdef"
 uninstall_cleanup
 assert_file_contains "$root/opt/clash/proxies/my.yaml" mine 'uninstall keeps a real directory with user files'
 assert_false 'uninstall removes our symlink' test -e "$root/opt/clash/rules"
 assert_false 'uninstall removes our symlink itself' test -L "$root/opt/clash/rules"
 assert_false 'uninstall removes the tmpfs target' test -e "$root/tmp/clash/rules"
 ln -s "$root/elsewhere" "$root/opt/clash/rules"
 uninstall_cleanup
 assert_true 'uninstall keeps a symlink that is not ours' test -L "$root/opt/clash/rules"
)
pass 'uninstall removes only the provider cache links it created'


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
printf '#!/bin/sh\n[ ! -e /proc/$$/fd/9 ] || touch "%s"\nexec sleep 30\n' "$tmpdir/core-lock-leaked" >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
echo "mode: rule" >"$RUNTIME_CONFIG"

# Watchdog flaps keep the include; only final stop removes it, after the core.
for stop_lock in available busy; do
 (
  cycle="$tmpdir/fw4-cycle-$stop_lock"
  setup_runtime_paths "$cycle"
  WATCHDOG_FAILS=1
  WATCHDOG_INTERVAL=0.01
  SOURCE_INTERFACES=br-guest
  POLICY_MODE=direct-first
  probe_count=0
  before=''
  settings_load() { :; }
  settings_require() { :; }
  wait_for_ready() { :; }
  with_lock() { "$@"; }
  lock_busy() { return 1; }
  lock_acquire() { [ "$stop_lock" = available ]; }
  lock_release() { :; }
  route_setup() { :; }
  route_cleanup() { :; }
  dns_apply() { :; }
  dns_cleanup() { :; }
  cache_db_persist() { :; }
  nft_input_hash() { printf 'fixed inputs\n'; }
  nft_render() { printf 'fixed transaction\n' >"$1"; }
  nft_active() { test -e "$cycle/table"; }
  nft() {
   case "$1" in
    -f) touch "$cycle/table" ;;
    delete) rm -f "$cycle/table" ;;
    *) fail "unexpected nft call: $*" ;;
   esac
  }
  eval "$(declare -f atomic_write | sed '1s/atomic_write/cycle_atomic_write/')"
  atomic_write() {
   [ "$1" != "$FW4_INPUT_INCLUDE" ] || printf 'write\n' >>"$cycle/include.writes"
   cycle_atomic_write "$@"
  }
  fw4() {
   printf '%s\n' "$*" >>"$cycle/fw4.calls"
   if [ ! -e "$FW4_INPUT_INCLUDE" ]; then
    assert_true 'stop reload happens after stop_child' test -e "$cycle/child-stopped"
    assert_false 'stop reload happens after table deletion' test -e "$cycle/table"
   fi
  }
  eval "$(declare -f stop_child | sed '1s/stop_child/cycle_stop_child/')"
  stop_child() {
   assert_false 'stop deletes table before stopping core' test -e "$cycle/table"
   assert_true 'stop retains include until core is stopped' test -f "$FW4_INPUT_INCLUDE"
   cycle_stop_child "$@"
   touch "$cycle/child-stopped"
  }
  api_alive() { return 0; }
  api_dns_probe() {
   probe_count=$((probe_count + 1))
   if [ "$probe_count" -eq 1 ]; then
    before="$(stat -c '%i:%Y' "$FW4_INPUT_INCLUDE")"
    return 1
   fi
   assert_true 'watchdog keeps include through degradation and recovery' test -f "$FW4_INPUT_INCLUDE"
   assert_eq "$before" "$(stat -c '%i:%Y' "$FW4_INPUT_INCLUDE")" 'watchdog does not rewrite include'
   assert_eq write "$(cat "$cycle/include.writes")" 'watchdog performs no extra include write'
   assert_eq reload "$(cat "$cycle/fw4.calls")" 'watchdog performs no extra fw4 reload'
   # Recovery needs three good probes (2-4); probe 5 sees the recovered state.
   if [ "$probe_count" -le 4 ]; then
    assert_true 'watchdog degraded before recovery' test -f "$DEGRADED_FILE"
    assert_false 'degradation deletes our table' test -e "$cycle/table"
   else
    assert_false 'watchdog recovered' test -e "$DEGRADED_FILE"
    assert_true 'recovery restores our table' test -e "$cycle/table"
    stop=1
   fi
   return 0
  }
  run_service || fail 'watchdog cycle must stop normally'
  assert_eq 5 "$probe_count" 'test runs both degradation and recovery'
  assert_false 'final stop removes include' test -e "$FW4_INPUT_INCLUDE"
  assert_eq $'reload\nreload' "$(cat "$cycle/fw4.calls")" 'only startup and final stop reload fw4'
 )
done
pass 'watchdog keeps include and stop removes it after core with either lock outcome'

# polish: auto_update stamp once
(
 set -e
 settings_load() { LISTS_INTERVAL=0; }
 subscription_due() { return 0; }
 : >"$tmpdir/auto.touch"; : >"$tmpdir/auto.updates"
 subscription_update() { command touch "$PKG_STATE_DIR/subscription.stamp"; echo update >>"$tmpdir/auto.updates"; }
 touch() { printf '%s\n' "$*" >>"$tmpdir/auto.touch"; command touch "$@"; }
 auto_update
 assert_true 'subscription update leaves stamp' test -f "$PKG_STATE_DIR/subscription.stamp"
 assert_eq update "$(cat "$tmpdir/auto.updates")" 'subscription updated once'
 assert_eq '' "$(cat "$tmpdir/auto.touch")" 'auto_update stamp once: no redundant touch'
)
pass 'auto_update stamp once'

# polish: auto_update owns no subscription stamp write
(
 set -e
 assert_false 'auto_update has no own stamp touch' grep -F 'touch "$PKG_STATE_DIR/subscription.stamp"' <<<"$(declare -f auto_update)"
)
pass 'auto_update owns no subscription stamp write'

# polish: prepare records error
(
 set -e
 service_prepare() { echo 'Error: Invalid lists_interval: x' >&2; return 1; }
 rc=0
 declare -F service_prepare_cmd >/dev/null || fail 'service_prepare_cmd helper missing'
 service_prepare_cmd 2>"$tmpdir/helper-prepare.err" || rc=$?
 assert_eq 1 "$rc" 'prepare records error status'
 assert_eq 'Invalid lists_interval: x' "$(cat "$LAST_ERROR_FILE")" 'prepare records error'
 assert_file_contains "$tmpdir/helper-prepare.err" 'Error: Invalid lists_interval: x' 'prepare stderr passes through'
 assert_eq '' "$(find "$PKG_TMP_DIR" "$PKG_STATE_DIR" -name '*.tmp.*')" 'prepare leaves no temporary files'
)
pass 'prepare records error'

# polish: empty error fallback
(
 set -e
 service_prepare() { return 1; }
 rc=0
 declare -F service_prepare_cmd >/dev/null || fail 'service_prepare_cmd helper missing'
 service_prepare_cmd 2>"$tmpdir/helper-empty.err" || rc=$?
 assert_eq 1 "$rc" 'empty error fallback status'
 assert_eq 'MihoWRT could not start. See the system log.' "$(cat "$LAST_ERROR_FILE")" 'empty error fallback'
)
pass 'empty error fallback'

# polish: one last-error prefix stripping site
(
 set -e
 count="$(grep -hcF 'error_text "$1"' "$ROOT_DIR/rootfs/etc/init.d/mihowrt" "$MIHOWRT_LIB_DIR/service.sh" | awk '{ n += $1 } END { print n + 0 }')"
 assert_eq 1 "$count" 'last error prefix stripped in one helper only'
)
pass 'one last-error prefix stripping site'

# polish: orphan killed after grace
(
 set -e
 rm -f "$RUNNING_MARKER"
 : >"$tmpdir/stop.sleeps"; : >"$tmpdir/stop.kills"
 pgrep() { return 1; }
 kill() { printf '%s\n' "$*" >>"$tmpdir/stop.kills"; return 0; }
 sleep() { echo sleep >>"$tmpdir/stop.sleeps"; }
 service_running() { return 0; }
 service_pid() { echo 4242; }
 policy_cleanup() { :; }
 with_lock() { echo recover >>"$tmpdir/stop.recover"; "$@"; }
 service_wait_stopped || fail 'orphan stop failed'
 sleeps="$(wc -l <"$tmpdir/stop.sleeps")"
 [ "$sleeps" -le 5 ] || fail "orphan killed after grace: slept $sleeps times (max 5)"
 assert_file_contains "$tmpdir/stop.recover" recover 'orphan recovery runs'
 assert_file_contains "$tmpdir/stop.kills" '-9 4242' 'orphan killed with SIGKILL'
)
pass 'orphan killed after grace'

# polish: supervisor alive no kill
(
 set -e
 rm -f "$RUNNING_MARKER"
 : >"$tmpdir/supervisor.sleeps"; : >"$tmpdir/supervisor.kills"
 iterations() { wc -l <"$tmpdir/supervisor.sleeps"; }
 pgrep() { [ "$(iterations)" -lt 3 ]; }
 sleep() { echo sleep >>"$tmpdir/supervisor.sleeps"; }
 kill() { printf '%s\n' "$*" >>"$tmpdir/supervisor.kills"; return 0; }
 service_running() { [ "$(iterations)" -lt 4 ]; }
 service_pid() { service_running && echo 4242; }
 policy_cleanup() { :; }
 with_lock() { "$@"; }
 service_wait_stopped || fail 'supervisor stop failed'
 [ "$(iterations)" -ge 3 ] || fail 'stop must wait for supervisor cleanup'
 assert_file_not_contains "$tmpdir/supervisor.kills" '-9' 'supervisor alive no kill'
)
pass 'supervisor alive no kill'

# polish: orphan without pid file
(
 set -e
 rm -f "$SERVICE_PID_FILE" "$RUNNING_MARKER"
 : >"$tmpdir/no-pid.kills"
 # shellcheck disable=SC2153 # CLASH_DIR comes from constants.sh
 pgrep() { [ "$*" != "-f ^$CLASH_BIN -d $CLASH_DIR -f [^ ]+\$" ] || { echo 4242; return 0; }; return 1; }
 kill() { printf '%s\n' "$*" >>"$tmpdir/no-pid.kills"; return 0; }
 policy_cleanup() { :; }
 service_recover || fail 'orphan recovery failed'
 assert_file_contains "$tmpdir/no-pid.kills" '-9 4242' 'orphan without pid file killed'
)
pass 'orphan without pid file'

# A healthy run-service owner must keep its core and policy.
(
 set -e
 pgrep() { return 0; }
 kill() { fail 'live run-service must not kill Mihomo'; }
 policy_cleanup() { fail 'live run-service must not clean policy'; }
 service_recover
)
pass 'live run-service recovery returns early'

# Readers holding an old inode must never observe a truncated/replaced error.
(
 set -e
 declare -F last_error_record >/dev/null || fail 'last_error_record helper missing'
 printf 'previous error\n' >"$LAST_ERROR_FILE"
 exec 8<"$LAST_ERROR_FILE"
 printf 'Error: replacement error\n' >"$tmpdir/last-error.stderr"
 last_error_record "$tmpdir/last-error.stderr"
 assert_eq 'replacement error' "$(cat "$LAST_ERROR_FILE")" 'last_error_record strips prefix'
 assert_eq 'previous error' "$(cat <&8)" 'error publication replaces inode'
 exec 8<&-
)
pass 'last error published atomically'

(
 settings_load() { return 1; }
 if run_service 2>"$tmpdir/settings.err"; then fail 'empty settings failure must fail'; fi
 assert_eq 'MihoWRT could not start. See the system log.' "$(cat "$LAST_ERROR_FILE")" 'empty settings error has fallback'
)
pass 'empty settings failure has message'

# A supervisor entered with an inherited lock must drop both fd and depth.
env PKG_STATE_DIR="$PKG_STATE_DIR" HEALTH_FILE="$HEALTH_FILE" DEGRADED_FILE="$DEGRADED_FILE" LAST_ERROR_FILE="$LAST_ERROR_FILE" \
CHECK_FILE="$tmpdir/supervisor-closed" RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock" ash -c '
 . "$MIHOWRT_LIB_DIR/helpers.sh"
 . "$MIHOWRT_LIB_DIR/validate.sh"
 . "$MIHOWRT_LIB_DIR/service.sh"
 lock_acquire || exit 1
 settings_load() { [ ! -e /proc/$$/fd/9 ] && [ "$LOCK_DEPTH" = 0 ] && touch "$CHECK_FILE"; return 1; }
 run_service
' 2>/dev/null || true
assert_true "supervisor drops inherited lock fd and depth" test -f "$tmpdir/supervisor-closed"
pass "supervisor closes inherited fd 9"

# Persist through a sibling temporary file, leaving the old database intact
# until rename and preserving it if the copy fails.
(
	mkdir -p "$PKG_PERSIST_DIR"
	printf old >"$PKG_PERSIST_DIR/cache.db"
	printf selected >"$CACHE_DB_TMPFS"
	cp() {
		assert_eq "$PKG_PERSIST_DIR/cache.db.new.$$" "$2" "copy targets sibling staging file"
		assert_eq old "$(cat "$PKG_PERSIST_DIR/cache.db")" "old database survives copy"
		command cp "$@"
	}
	mv() {
		assert_eq "$PKG_PERSIST_DIR/cache.db.new.$$" "$2" "rename source is staging file"
		assert_eq "$PKG_PERSIST_DIR/cache.db" "$3" "rename replaces database"
		command mv "$@"
	}
	cache_db_persist
	assert_eq selected "$(cat "$PKG_PERSIST_DIR/cache.db")" "selected proxies persisted"
	assert_false "staging file removed by rename" test -e "$PKG_PERSIST_DIR/cache.db.new.$$"
	cp() { fail "unchanged database must not be copied"; }
	cache_db_persist
	printf changed >"$CACHE_DB_TMPFS"
	cp() { printf partial >"$2"; return 1; }
	if cache_db_persist; then fail "failed copy must report failure"; fi
	assert_eq selected "$(cat "$PKG_PERSIST_DIR/cache.db")" "failed copy preserves database"
	assert_false "failed staging file cleaned" test -e "$PKG_PERSIST_DIR/cache.db.new.$$"
)
pass "cache_db_persist atomically replaces changed database"

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

api_alive() { return 1; }
(
 eval "$(declare -f atomic_write | sed '1s/atomic_write/health_atomic_write/')"
 atomic_write() {
  [ "$1" != "$HEALTH_FILE" ] || printf '%s\n' "$2" >>"$tmpdir/health.writes"
  health_atomic_write "$@"
 }
 api_dns_probe() {
  probe_count=$((probe_count + 1))
  if [ "$probe_count" = 3 ]; then
   assert_eq ok "$(cat "$tmpdir/health.writes")" 'two ok probes publish health once'
  fi
  [ "$probe_count" -le 2 ]
 }
 run_service 2>"$tmpdir/health.err" || :
 assert_eq $'ok\nfail' "$(cat "$tmpdir/health.writes")" 'health writes only on ok to fail transition'
) || { cat "$tmpdir/health.err" >&2; exit 1; }
pass 'watchdog publishes health only when changed'

reset_events
probe_script="000"
rc=0
run_service || rc=$?
assert_eq 1 "$rc" "watchdog exits 1 so procd respawns"
assert_eq $'apply\ncleanup' "$(cat "$events")" "policy cleaned once after fail-open"
[[ ! -e "$RUNNING_MARKER" ]] || fail "running marker removed"
assert_false "Mihomo does not inherit fd 9" test -e "$tmpdir/core-lock-leaked"
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
assert_eq "Mihomo did not become ready; router stays on direct routing" "$(cat "$LAST_ERROR_FILE")" "startup error recorded"
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

(
 route_setup() { echo route >>"$events"; }
 dns_apply() { echo dns-fail >>"$events"; return 1; }
 reset_events
 rc=0
 policy_apply || rc=$?
 assert_eq 1 "$rc" 'DNS failure after nft apply reported'
 assert_eq $'nft\nroute\ndns-fail\ndns-clean\nnft-clean\nroute-clean' "$(cat "$events")" 'DNS failure still cleans partial policy'
)
pass 'DNS apply failure still cleans'

# A rejected nft transaction leaves the old live policy alone: no cleanup,
# route/DNS mutation, retry, or compensating delete.
(
 load_modules nft.sh
 settings_require() { return 0; }
 nft_render() { printf 'candidate transaction\n' >"$1"; }
 printf 'old live transaction\n' >"$tmpdir/live-policy"
 nft() {
  printf 'nft:%s\n' "$*" >>"$events"
  case "$1" in
   -f) return 1 ;;
   delete) rm -f "$tmpdir/live-policy" ;;
  esac
 }
 reset_events
 rc=0
 policy_apply 2>"$tmpdir/policy-nft.err" || rc=$?
 assert_eq 1 "$rc" 'failed nft apply reported'
 assert_eq "nft:-f $PKG_TMP_DIR/nft/ruleset.nft" "$(cat "$events")" 'failed nft has no cleanup, partial second apply, route or DNS calls'
 assert_eq 'old live transaction' "$(cat "$tmpdir/live-policy")" 'failed nft leaves previous live policy'
)
pass 'failed nft transaction preserves live policy'

# A policy-only flag apply must reach real policy_apply/nft_apply, without a
# Mihomo config test or API reload when generated runtime YAML is identical.
(
 load_modules settings.sh nft.sh
 fake_uci_reset
 fake_uci_set network.lan.ipaddr 192.168.8.1/24
 service_ready() { return 0; }
 cron_update() { :; }
 mihomo_config_generate() {
  cp "$RUNTIME_CONFIG" "$2"
  printf 'mode direct-first\ndns fake-ip\n' >"$2.profile"
 }
 mihomo_config_key() { return 1; }
 mihomo_config_test() { fail 'policy-only flag must not test the core'; }
 api_reload() { fail 'policy-only flag must not reload the core'; }
 route_setup() { echo route >>"$events"; }
 dns_apply() { echo dns >>"$events"; }
 ip() { return 0; }
 nft() {
  assert_eq -f "$1" 'policy-only apply uses nft transaction'
  cp "$2" "$tmpdir/policy-only.nft"
  echo "nft:$BLOCK_CLIENT_IPV6" >>"$events"
 }
 printf 'mode direct-first\ndns fake-ip\n' >"$PROFILE_FILE"
 rm -f "$NFT_APPLIED_FILE"
 for flag in 1 0; do
  fake_uci_set mihowrt.settings.block_client_ipv6 "$flag"
  reset_events
  service_reload
  assert_eq "$(printf 'nft:%s\nroute\ndns' "$flag")" "$(cat "$events")" 'policy-only flag reaches nft with effective setting'
  if [ "$flag" = 1 ]; then
   assert_file_contains "$tmpdir/policy-only.nft" client_ipv6_egress 'policy-only flag enables boundary'
  else
   assert_file_not_contains "$tmpdir/policy-only.nft" client_ipv6_egress 'policy-only flag disables boundary'
  fi
 done
)
pass 'policy-only flag apply skips core test and reload'

nested() {
	with_lock true
	[ "$LOCK_DEPTH" = 1 ] || fail "outer lock must survive nested release"
}
with_lock nested
assert_false "lock released after outer call" lock_busy
pass "lock is re-entrant"

# Network fetches must not hold the runtime lock (LuCI saves would time out).
load_modules fetch.sh subscription.sh config.sh
lock_seen=""
http_fetch() {
	lock_seen="$lock_seen ${LOCK_DEPTH:-0}"
	assert_false "network download leaves lock free" lock_busy
	mkdir -p "$(dirname "$2")"
	printf 'proxies: []\n' >"$2"
}
config_install() {
	[ "${LOCK_DEPTH:-0}" -gt 0 ] || fail "config_install must run under the lock"
	echo '{"action":"saved"}'
}
cron_update() { :; }
subscription_metadata_from_headers() { echo '{}'; }
FETCH_HDR="$tmpdir/headers"
lists_urls() { :; }
SUBSCRIPTION_META_FILE="$tmpdir/etc/sub.json"
settings_load() { SUBSCRIPTION_URL=https://sub.example/x; SUBSCRIPTION_INTERVAL=1; LISTS_INTERVAL=1; }
subscription_update >/dev/null
assert_eq " 0" "$lock_seen" "subscription download runs without the lock"
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
start_runtime_lock_holder "$RUNTIME_LOCK_FILE" "$tmpdir/holder.ready"
holder=$LOCK_HOLDER_PID
reset_events
start=$(date +%s)
probe_script="1111111111"
probe_count=0
( sleep 1; kill -TERM $$ ) &
run_service 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
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
if lists_apply /tmp/mihowrt-policy-list.dir/x /tmp/mihowrt-policy-list.dir/x /tmp/mihowrt-policy-list.dir/x /tmp/mihowrt-policy-list.dir/x 2>/dev/null; then fail "nested list path must be rejected"; fi
rm -rf /tmp/mihowrt-policy-list.dir
pass "list path check"

# Lists saved from LuCI rebuild nft with the full settings (interfaces etc.).
(
	load_modules settings.sh
	NETBIRD_INTERFACE=""
	fake_uci_set mihowrt.settings.netbird_interface wt9
	service_ready() { return 0; }
	lists_install() { echo 1; }
	lists_update_remote() { :; }
	nft_apply() { echo "nft:$NETBIRD_INTERFACE" >>"$events"; }
	reset_events
	lists_apply /tmp/mihowrt-policy-list.a /tmp/mihowrt-policy-list.b /tmp/mihowrt-policy-list.c /tmp/mihowrt-policy-list.d >/dev/null
	assert_file_contains "$events" "nft:wt9" "apply-lists must load settings before nft_apply"
)
pass "apply-lists loads settings"

# A partial list upload must reach the real nft_apply once, without rebuilding
# unchanged lists or making a separate nft delete/apply call.
(
 load_modules settings.sh lists.sh nft.sh
 setup_runtime_paths "$tmpdir/partial-lists"
 LIST_DIR="$tmpdir/partial-lists/lists"
 DST_LIST_FILE="$LIST_DIR/dst.txt"
 SRC_LIST_FILE="$LIST_DIR/src.txt"
 DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
 POLICY_CACHE_DIR="$tmpdir/partial-lists/cache"
 lists_ensure_files
 fake_uci_reset
 printf 'mode direct-first\n' >"$PROFILE_FILE"
 service_ready() { return 0; }
 cron_update() { :; }
 ip() { return 0; }
 nft_active() { return 0; }
 nft() {
  printf '%s\n' "$*" >>"$tmpdir/partial-lists/nft.calls"
  assert_eq -f "$1" 'partial list apply uses one nft transaction'
  cp "$2" "$tmpdir/partial-lists/applied.nft"
 }
 settings_load
 nft_apply
 : >"$tmpdir/partial-lists/nft.calls"
 for kind in dst direct direct_src; do
  cp "$(lists_file "$kind")" "$tmpdir/partial-lists/$kind.before"
 done
 partial_upload="/tmp/mihowrt-policy-list.partial.$$"
 trap 'rm -f "$partial_upload"' EXIT
 printf '192.168.1.99\n' >"$partial_upload"
 lists_apply - "$partial_upload" - - >"$tmpdir/partial-lists/result.json"
 assert_eq true "$(jq -r .changed "$tmpdir/partial-lists/result.json")" 'partial list upload reports a change'
 assert_eq "-f $PKG_TMP_DIR/nft/ruleset.nft" "$(cat "$tmpdir/partial-lists/nft.calls")" 'partial list apply calls nft -f exactly once'
 assert_file_contains "$tmpdir/partial-lists/applied.nft" 'proxy_src { 192.168.1.99 }' 'single transaction includes updated device list'
 for kind in dst direct direct_src; do
  assert_true "partial apply leaves $kind unchanged" cmp -s "$(lists_file "$kind")" "$tmpdir/partial-lists/$kind.before"
 done
 assert_false 'partial upload removed' test -e "$partial_upload"
)
pass 'partial list apply runs nft -f once'

# Keep the core alive through degradation and recovery, then end via hung API.
load_modules service.sh
WATCHDOG_FAILS=3
WATCHDOG_INTERVAL=0.01
probe_count=0
probe_script=00010111000
api_alive() { [ "$probe_count" -le 8 ]; }
wait_for_ready() { :; }
settings_load() { :; }
policy_cleanup() {
 if [ "$probe_count" = 3 ]; then
  assert_true 'degraded visible before policy cleanup' test -f "$DEGRADED_FILE"
 fi
 echo "cleanup:$([ -e "$RUNNING_MARKER" ] && echo yes || echo no)" >>"$events"
}
policy_apply() { echo apply >>"$events"; }
api_dns_probe() {
 probe_count=$((probe_count + 1))
 if [ "$probe_count" = 2 ]; then
  assert_eq fail "$(cat "$HEALTH_FILE")" "failed probe written"
 fi
 if [ "$probe_count" = 4 ]; then
  exec 8<"$HEALTH_FILE"
  assert_true "degraded file created" test -f "$DEGRADED_FILE"
  assert_false "degraded marker absent before recovery" test -e "$RUNNING_MARKER"
 fi
 if [ "$probe_count" = 5 ]; then
  assert_eq fail "$(cat <&8)" 'health publication replaces inode'
  exec 8<&-
  assert_eq ok "$(cat "$HEALTH_FILE")" "successful probe written"
  assert_true 'one good probe leaves degraded policy' test -f "$DEGRADED_FILE"
  assert_eq $'apply\ncleanup:no' "$(cat "$events")" 'f,f,f,ok,f does not reapply'
 fi
 if [ "$probe_count" = 8 ]; then
  assert_true 'two consecutive good probes leave degraded policy' test -f "$DEGRADED_FILE"
  assert_eq $'apply\ncleanup:no' "$(cat "$events")" 'failure resets recovery counter'
 fi
 if [ "$probe_count" = 9 ]; then
  assert_false "recovery clears degraded file" test -e "$DEGRADED_FILE"
  assert_false "ready clears last error" test -e "$LAST_ERROR_FILE"
  assert_true "recovery restores marker" test -e "$RUNNING_MARKER"
 fi
 [ "$(printf '%s' "$probe_script" | cut -c"$probe_count")" = 1 ]
}
reset_events
rc=0
run_service 2>"$tmpdir/watchdog.err" || rc=$?
assert_eq 1 "$rc" "hung core still exits for respawn"
assert_eq 11 "$probe_count" "loop continues after three consecutive good probes"
assert_false "exit removes health" test -e "$HEALTH_FILE"
assert_false "exit removes degraded" test -e "$DEGRADED_FILE"
assert_eq "watchdog: Mihomo does not answer; restarting" "$(cat "$LAST_ERROR_FILE")" "watchdog error recorded"
assert_eq $'apply\ncleanup:no\napply\ncleanup:no' "$(cat "$events")" "degrade cleans and recovery reapplies"
pass "watchdog degrades in place and restores policy and marker"

exec 9>>"$tmpdir/init-inherited.flock"
source_init_mihowrt_lib
assert_false "init script closes inherited fd 9 before procd" test -e "/proc/$$/fd/9"
PKG_STATE_DIR="$tmpdir/run"
LAST_ERROR_FILE="$tmpdir/last_error"
USER_STOP_FILE="$tmpdir/stopped"
SKIP_START_FILE="$tmpdir/skip-start"
MIHOWRT="$tmpdir/cli"
printf '#!/bin/sh\nexit 0\n' >"$MIHOWRT"
chmod +x "$MIHOWRT"
procd_open_instance() { :; }
procd_set_param() { :; }
procd_close_instance() { :; }
stop_service
assert_true "Stop creates sticky flag" test -f "$USER_STOP_FILE"
start_service
assert_false "Start clears sticky flag" test -f "$USER_STOP_FILE"
printf '#!/bin/sh\necho "Error: Invalid lists_interval: x" >&2\necho "Invalid lists_interval: x" >"%s"\nexit 1\n' "$LAST_ERROR_FILE" >"$MIHOWRT"
logger() { printf '%s\n' "$*" >>"$tmpdir/prepare.log"; }
if start_service 2>"$tmpdir/prepare.err"; then fail 'invalid prepare must fail'; fi
assert_file_contains "$tmpdir/prepare.err" 'Invalid lists_interval: x' 'prepare reason visible on stderr'
assert_file_contains "$tmpdir/prepare.log" 'Invalid lists_interval: x' 'prepare reason logged'
assert_eq 'Invalid lists_interval: x' "$(cat "$LAST_ERROR_FILE")" 'prepare error strips prefix'
assert_false 'failed prepare removes temporary file' test -e "$LAST_ERROR_FILE.tmp.$$"
printf '#!/bin/sh\necho "MihoWRT could not start. See the system log." >"%s"\nexit 1\n' "$LAST_ERROR_FILE" >"$MIHOWRT"
if start_service 2>"$tmpdir/prepare.err"; then fail 'empty prepare failure must fail'; fi
assert_eq 'MihoWRT could not start. See the system log.' "$(cat "$LAST_ERROR_FILE")" 'empty prepare error has fallback'
assert_file_contains "$tmpdir/prepare.err" 'MihoWRT could not start. See the system log.' 'fallback visible on stderr'
printf '#!/bin/sh\nexit 0\n' >"$MIHOWRT"
start_service
assert_false 'successful prepare clears error' test -e "$LAST_ERROR_FILE"
assert_false 'successful prepare clears temporary file' test -e "$LAST_ERROR_FILE.tmp.$$"
pass 'prepare last error'
# Rewrite constants and absolute device paths, then execute real hotplug logic.
mkdir -p "$tmpdir/lib"
sed -e "s|/var/run/mihowrt|$tmpdir/hotplug|g" -e "s|/usr/bin/mihowrt|$tmpdir/cli|g" \
 "$MIHOWRT_LIB_DIR/constants.sh" >"$tmpdir/lib/constants.sh"
sed -e "s|/usr/lib/mihowrt/constants.sh|$tmpdir/lib/constants.sh|g" -e "s|/etc/init.d/mihowrt|$tmpdir/init-hotplug|g" \
 -e "s|/usr/bin/mihowrt|$tmpdir/cli|g" "$ROOT_DIR/rootfs/etc/hotplug.d/iface/90-mihowrt" >"$tmpdir/hotplug.sh"
printf '#!/bin/sh\n[ ! -e /proc/$$/fd/6 ] && [ ! -e /proc/$$/fd/9 ] || touch "%s"\n[ "$1" != start ] || touch "%s"\n' "$tmpdir/hotplug-init-lock-leaked" "$tmpdir/hotplug.started" >"$tmpdir/init-hotplug"
chmod +x "$tmpdir/init-hotplug"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/bin/pgrep"
chmod +x "$tmpdir/bin/pgrep"
mkdir -p "$tmpdir/hotplug"
touch "$tmpdir/hotplug/stopped"
ACTION=ifup sh "$tmpdir/hotplug.sh"
sleep 0.1
assert_false "hotplug respects Stop" test -f "$tmpdir/hotplug.started"
rm "$tmpdir/hotplug/stopped"
exec 6>>"$tmpdir/hotplug-start-net.flock"
exec 9>>"$tmpdir/hotplug-start-runtime.flock"
ACTION=ifup sh "$tmpdir/hotplug.sh"
exec 6>&-
exec 9>&-
for i in {1..50}; do [ ! -e "$tmpdir/hotplug.started" ] || break; sleep 0.02; done
assert_true "hotplug starts when not stopped" test -f "$tmpdir/hotplug.started"
assert_false 'hotplug init calls close fd 6 and fd 9' test -f "$tmpdir/hotplug-init-lock-leaked"
pass "sticky Stop and hotplug"

printf '#!/bin/sh\n[ ! -e /proc/$$/fd/6 ] && [ ! -e /proc/$$/fd/9 ] || exit 1\nprintf "%%s\\n" "$*" >"%s"\n' "$tmpdir/hotplug.calls" >"$tmpdir/cli"
touch "$tmpdir/hotplug/running"
INTERFACE=loopback ACTION=ifupdate sh "$tmpdir/hotplug.sh"
sleep 0.1
assert_false 'loopback ifupdate runs no command' test -e "$tmpdir/hotplug.calls"
exec 6>>"$tmpdir/hotplug-net.flock"
exec 9>>"$tmpdir/hotplug.flock"
INTERFACE=wan ACTION=ifupdate sh "$tmpdir/hotplug.sh"
exec 6>&-
exec 9>&-
for i in {1..50}; do [ ! -e "$tmpdir/hotplug.calls" ] || break; sleep 0.02; done
assert_eq net-refresh "$(cat "$tmpdir/hotplug.calls")" 'wan ifupdate refreshes without inherited fd 6 or fd 9'
assert_false 'old refresh command removed from runtime' grep -R -E 'dns[-_]refresh' "$ROOT_DIR/rootfs"
pass 'hotplug'

# Execute the actual renamed CLI dispatch with the real DNS/nft apply functions.
(
 load_modules settings.sh lists.sh nft.sh dns.sh
 setup_runtime_paths "$tmpdir/refresh"
 RUNNING_MARKER="$PKG_STATE_DIR/running"
 RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
 LIST_DIR="$tmpdir/refresh/lists"
 DST_LIST_FILE="$LIST_DIR/dst.txt"
 SRC_LIST_FILE="$LIST_DIR/src.txt"
 DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
 POLICY_CACHE_DIR="$tmpdir/refresh/cache"
 lists_ensure_files
 fake_uci_reset
 fake_uci_set dhcp.cfg01 dnsmasq
 fake_uci_set dhcp.cfg01.confdir "$tmpdir/refresh/dnsmasq.d"
 DNS_AUTO_RESOLVFILE="$tmpdir/refresh/resolv"
 printf 'nameserver 10.0.0.1\n' >"$DNS_AUTO_RESOLVFILE"
 touch "$RUNNING_MARKER"
 service_running() { return 0; }
 routes="$tmpdir/refresh/routes"
 printf '2001:db8:1::/64 dev br-lan\n' >"$routes"
 ip() { [ "$*" != '-6 route show table main' ] || cat "$routes"; return 0; }
 nft_active() { return 0; }
 nft() { echo "$*" >>"$tmpdir/refresh/nft.calls"; }
 dns_restart_dnsmasq() { echo restart >>"$tmpdir/refresh/restarts"; }
 route_setup() { :; }
 # Observe settings reload under the runtime lock, without replacing apply.
 eval "$(declare -f settings_load | sed '1s/settings_load/refresh_settings_load/')"
 settings_load() {
  [ "${LOCK_DEPTH:-0}" = 1 ] || fail 'net-refresh must load settings under lock'
  refresh_settings_load
 }
 sed '/^LIB=/,/mihowrt_load_modules.*exit 1/d' "$ROOT_DIR/rootfs/usr/bin/mihowrt" >"$tmpdir/refresh/cli.sh"
 NET_REFRESH_DELAY=0
 declare -F net_refresh_coalesced >/dev/null || fail 'CLI coalescer missing'
 eval "$(declare -f net_refresh_coalesced | sed '1s/net_refresh_coalesced/refresh_coalesced_real/')"
 net_refresh_coalesced() {
  echo coalesced >>"$tmpdir/refresh/coalesced.calls"
  refresh_coalesced_real
 }
 refresh_cli() { ( set -- net-refresh; source "$tmpdir/refresh/cli.sh"; ); }
 refresh_cli
 refresh_cli
 assert_eq 1 "$(wc -l <"$tmpdir/refresh/nft.calls" | tr -d ' ')" 'unchanged refresh skips nft -f'
 assert_eq 1 "$(wc -l <"$tmpdir/refresh/restarts" | tr -d ' ')" 'unchanged refresh skips dnsmasq restart'
 printf '2001:db8:2::/64 dev br-guest\n' >>"$routes"
 refresh_cli
 assert_eq 3 "$(wc -l <"$tmpdir/refresh/coalesced.calls" | tr -d ' ')" 'CLI dispatches through coalescer'
 assert_eq 2 "$(wc -l <"$tmpdir/refresh/nft.calls" | tr -d ' ')" 'new route calls nft -f once'
 assert_eq 1 "$(wc -l <"$tmpdir/refresh/restarts" | tr -d ' ')" 'new route does not restart dnsmasq'
)
pass 'refresh is idempotent'

for candidate_kind in same changed rejected; do
 (
  PKG_TMP_DIR="$tmpdir/tmp"
  RUNTIME_CONFIG="$tmpdir/reload.yaml"
  PROFILE_FILE="$tmpdir/reload.profile"
  CONFIG_OK_FILE="$tmpdir/reload.config.ok"
  CONFIG_ERR_FILE="$tmpdir/reload.config.err"
  service_ready() { return 0; }
  settings_load() { :; }
  cron_update() { :; }
  mihomo_config_generate() {
   assert_eq "$CLASH_CONFIG" "$1" 'reload generates from installed YAML'
   printf '%s runtime\n' "$candidate_kind" >"$2"
   printf 'candidate profile\n' >"$2.profile"
  }
  mihomo_config_key() { return 1; }
  mihomo_config_test() {
   echo test >>"$events"
   CONFIG_TEST_OUTPUT='candidate rejected'
   [ "$candidate_kind" != rejected ]
  }
  api_reload() { echo reload >>"$events"; }
  policy_apply() { echo apply >>"$events"; }
  printf 'same runtime\n' >"$RUNTIME_CONFIG"
  printf 'previous profile\n' >"$PROFILE_FILE"
  printf 'previous check\n' >"$CONFIG_ERR_FILE"
  rm -f "$CONFIG_OK_FILE"
  reset_events
  rc=0
  service_reload || rc=$?
  if [ "$candidate_kind" = rejected ]; then
   assert_eq 1 "$rc" 'rejected candidate fails reload'
   assert_eq test "$(cat "$events")" 'rejected candidate tested without reload or policy apply'
   assert_eq 'same runtime' "$(cat "$RUNTIME_CONFIG")" 'rejected candidate preserves runtime'
   assert_eq 'previous profile' "$(cat "$PROFILE_FILE")" 'rejected candidate preserves profile'
   assert_eq 'candidate rejected' "$(cat "$CONFIG_ERR_FILE")" 'rejected candidate records failed check'
   assert_false 'rejected candidate does not record success' test -e "$CONFIG_OK_FILE"
  else
   assert_eq 0 "$rc" 'candidate reload succeeds'
   assert_eq 'candidate profile' "$(cat "$PROFILE_FILE")" 'candidate profile installed'
   if [ "$candidate_kind" = same ]; then
    assert_eq apply "$(cat "$events")" 'same candidate no test or reload, policy applied once'
    assert_eq 'previous check' "$(cat "$CONFIG_ERR_FILE")" 'same candidate preserves last check'
    assert_false 'same candidate does not record a new check' test -e "$CONFIG_OK_FILE"
   else
    assert_eq $'test\nreload\napply' "$(cat "$events")" 'changed candidate tested and reloaded once'
    assert_eq 'changed runtime' "$(cat "$RUNTIME_CONFIG")" 'changed candidate installed'
    assert_true 'changed candidate records successful check' test -f "$CONFIG_OK_FILE"
    assert_false 'successful check clears old error' test -e "$CONFIG_ERR_FILE"
   fi
  fi
  assert_false 'reload removes candidate config' test -e "$PKG_TMP_DIR/config.candidate.yaml"
  assert_false 'reload removes candidate profile' test -e "$PKG_TMP_DIR/config.candidate.yaml.profile"
 )
 pass "$candidate_kind candidate reload"
done

(
 PKG_TMP_DIR="$tmpdir/tmp"
 RUNTIME_CONFIG="$tmpdir/reload.yaml"
 PROFILE_FILE="$tmpdir/reload.profile"
 CONFIG_OK_FILE="$tmpdir/reload.config.ok"
 CONFIG_ERR_FILE="$tmpdir/reload.config.err"
 service_ready() { return 0; }
 settings_load() { :; }
 cron_update() { :; }
 mihomo_config_generate() {
  printf 'new runtime\n' >"$2"
  printf 'new profile\n' >"$2.profile"
 }
 mihomo_config_key() { return 1; }
 mihomo_config_test() { return 0; }
 printf 'previous runtime\n' >"$RUNTIME_CONFIG"
 printf 'previous profile\n' >"$PROFILE_FILE"
 cp "$RUNTIME_CONFIG" "$tmpdir/runtime.before"
 cp "$PROFILE_FILE" "$tmpdir/profile.before"
 previous_kept=0
 api_reload() {
  cmp -s "$RUNTIME_CONFIG.prev" "$tmpdir/runtime.before" && previous_kept=1
  return 1
 }
 rc=0
 service_reload 2>"$tmpdir/reload.err" || rc=$?
 assert_eq 1 "$rc" 'reload failure reported'
 assert_eq 1 "$previous_kept" 'previous runtime kept until API reload'
 assert_true 'runtime rolled back' cmp -s "$RUNTIME_CONFIG" "$tmpdir/runtime.before"
 assert_true 'profile rolled back' cmp -s "$PROFILE_FILE" "$tmpdir/profile.before"
 assert_file_contains "$tmpdir/reload.err" 'Mihomo hot reload failed' 'reload failure logged'
 api_reload() { return 0; }
 service_reload
 assert_eq 'new runtime' "$(cat "$RUNTIME_CONFIG")" 'successful reload installs runtime'
 assert_eq 'new profile' "$(cat "$PROFILE_FILE")" 'successful reload installs profile'
 assert_false 'success removes previous runtime' test -e "$RUNTIME_CONFIG.prev"
 assert_false 'success removes previous profile' test -e "$PROFILE_FILE.prev"

 for missing in profile both; do
  rm -f "$PROFILE_FILE"
  [ "$missing" != both ] || rm -f "$RUNTIME_CONFIG"
  api_reload() { return 0; }
  rc=0
  service_reload 2>"$tmpdir/reload.err" || rc=$?
  assert_eq 0 "$rc" "reload succeeds with missing $missing"
  assert_eq 'new profile' "$(cat "$PROFILE_FILE")" 'reload installs missing profile'
  assert_eq 'new runtime' "$(cat "$RUNTIME_CONFIG")" 'reload installs runtime'

  printf 'previous runtime\n' >"$RUNTIME_CONFIG"
  rm -f "$PROFILE_FILE"
  [ "$missing" != both ] || rm -f "$RUNTIME_CONFIG"
  api_reload() { return 1; }
  rc=0
  service_reload 2>"$tmpdir/reload.err" || rc=$?
  assert_eq 1 "$rc" "reload failure with missing $missing reported"
  assert_false 'rollback leaves no stray profile' test -e "$PROFILE_FILE"
  if [ "$missing" = both ]; then
   assert_false 'rollback leaves no stray runtime' test -e "$RUNTIME_CONFIG"
  else
   assert_eq 'previous runtime' "$(cat "$RUNTIME_CONFIG")" 'rollback restores existing runtime'
  fi
 done
)
pass 'reload rollback'

(
 settings_load() { LISTS_INTERVAL=0; }
 subscription_due() { return 0; }
 subscription_update() { err 'subscription failed'; return 1; }
 assert_false 'auto-update reports subscription failure' auto_update 2>"$tmpdir/auto.err"
 subscription_due() { return 1; }
 settings_load() { LISTS_INTERVAL=1; }
 lists_urls() { echo https://list.example/x; }
 lists_update_remote() { echo changed; return 1; }
 service_ready() { return 0; }
 nft_apply() { echo applied >"$tmpdir/auto-applied"; }
 assert_false 'auto-update reports partial list failure' auto_update
 assert_true 'partial changed lists still applied' test -f "$tmpdir/auto-applied"
 lists_update_remote() { echo changed; }
 nft_apply() { return 1; }
 assert_false 'auto-update reports policy failure' auto_update
 service_ready() { return 1; }
 auto_update || fail 'stopped service is not an automatic update failure'
)
pass 'auto-update accumulates update and apply failures'
