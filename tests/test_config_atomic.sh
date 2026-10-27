#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh mihomo-config.sh config.sh subscription.sh

setup_install() {
 setup_runtime_paths "$tmpdir/$1"
 CLASH_CONFIG_BACKUP="$CLASH_CONFIG.bak"
 RUNTIME_CONFIG="$PKG_TMP_DIR/config.yaml"
 printf 'proxies: []\nx-mihowrt:\n  disable-quic: true\n' >"$CLASH_CONFIG"
 printf 'older backup\n' >"$CLASH_CONFIG_BACKUP"
 printf 'proxies: []\nlog-level: debug\nx-mihowrt:\n  disable-quic: false\n' >"$PKG_TMP_DIR/candidate"
 settings_load
 mihomo_config_generate "$CLASH_CONFIG" "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 cp "$CLASH_CONFIG" "$PKG_TMP_DIR/source.before"
 cp "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
 cp "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
 : >"$PKG_TMP_DIR/events"
}
mihomo_config_test() { return 0; }
service_running() { return 0; }
service_ready() { return 0; }
api_alive() { return 0; }
api_reload() { echo reload >>"$PKG_TMP_DIR/events"; }
cron_update() { echo cron >>"$PKG_TMP_DIR/events"; }
policy_apply() {
 echo "policy $(profile_get "set disable_quic")" >>"$PKG_TMP_DIR/events"
 if [ "$(profile_get "set disable_quic")" = 0 ]; then
  err 'new policy failed'
  return 1
 fi
}

for backup in hardlink fallback; do
 (
  setup_install "runtime-backup-$backup"
  config_profile_apply() { :; }
  ln() {
   if [ "${2:-}" = "$RUNTIME_CONFIG" ]; then
    assert_eq -f "$1" 'runtime backup forces the hard link'
    echo link >>"$PKG_TMP_DIR/events"
    [ "$backup" != fallback ] || return 1
   fi
   command ln "$@"
  }
  cp() {
   if [ "${2:-}" = "$PKG_TMP_DIR/runtime.old" ] || [ "${3:-}" = "$PKG_TMP_DIR/runtime.old" ]; then
    assert_eq fallback "$backup" 'runtime backup does not copy when hard links work'
    assert_eq -p "$1" 'runtime backup fallback preserves attributes'
    echo copy >>"$PKG_TMP_DIR/events"
   fi
   if [ "$1" = "$PKG_TMP_DIR/candidate" ] && [ "$2" = "$CLASH_CONFIG.tmp" ]; then
    if [ "$backup" = hardlink ]; then
     assert_true 'runtime backup shares the old inode' test "$RUNTIME_CONFIG" -ef "$PKG_TMP_DIR/runtime.old"
    else
     assert_false 'runtime backup falls back to a separate inode' test "$RUNTIME_CONFIG" -ef "$PKG_TMP_DIR/runtime.old"
     assert_true 'runtime backup fallback keeps the contents' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.old"
    fi
   fi
   command cp "$@"
  }
  config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out"
  assert_file_contains "$PKG_TMP_DIR/events" link 'runtime backup tries a hard link first'
  if [ "$backup" = fallback ]; then
   assert_file_contains "$PKG_TMP_DIR/events" copy 'runtime backup copies only after link failure'
  fi
 )
 pass "config_install runtime backup uses $backup"
done

setup_install rollback
rc=0
config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'profile apply failure fails install'
assert_eq 'Error: Failed to apply the new subscription settings: new policy failed; the previous config is restored' "$(cat "$tmpdir/err")" 'profile failure reports successful rollback'
assert_eq '' "$(cat "$tmpdir/out")" 'failed install emits no success action'
assert_true 'previous YAML restored' cmp -s "$CLASH_CONFIG" "$PKG_TMP_DIR/source.before"
assert_true 'previous runtime restored' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
assert_true 'previous profile restored' cmp -s "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
assert_eq 'older backup' "$(cat "$CLASH_CONFIG_BACKUP")" 'failed install keeps older backup'
assert_eq $'reload\ncron\npolicy 0\nreload\ncron\npolicy 1' "$(cat "$PKG_TMP_DIR/events")" 'rollback reloads and reapplies previous policy'
pass 'config_install rolls back a rejected profile without rotating backup'

policy_apply() { echo policy >>"$PKG_TMP_DIR/events"; }
: >"$PKG_TMP_DIR/events"
assert_eq '{"action":"hot_reloaded"}' "$(config_install "$PKG_TMP_DIR/candidate")" 'same candidate retries after failure'
assert_file_contains "$PKG_TMP_DIR/events" reload 'retry reloads candidate'
assert_file_contains "$PKG_TMP_DIR/events" policy 'retry reapplies candidate policy'
assert_true 'successful retry rotates backup' cmp -s "$CLASH_CONFIG_BACKUP" "$PKG_TMP_DIR/source.before"
pass 'config_install retries the same bytes after rollback'

setup_install restore-failure
policy_apply() { err 'new policy failed'; return 1; }
api_reload() {
 if cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"; then
  err 'previous reload failed'
  return 1
 fi
}
rc=0
config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'failed rollback fails install'
assert_eq "Error: Failed to apply the new subscription settings: new policy failed; restoring the previous config failed: previous reload failed; the previous config is saved in $CLASH_CONFIG.previous.$$" "$(cat "$tmpdir/err")" 'failed rollback names the recovery path'
assert_eq 'older backup' "$(cat "$CLASH_CONFIG_BACKUP")" 'failed rollback keeps older backup'
assert_true 'failed rollback saves previous YAML' cmp -s "$CLASH_CONFIG.previous.$$" "$PKG_TMP_DIR/source.before"
assert_true 'failed rollback saves previous runtime' cmp -s "$PKG_TMP_DIR/runtime.old" "$PKG_TMP_DIR/runtime.before"
assert_true 'failed rollback saves previous profile' cmp -s "$PKG_TMP_DIR/profile.old" "$PKG_TMP_DIR/profile.before"
pass 'config_install reports rollback failure and keeps recovery files'

for failed_file in config runtime profile; do
 (
  setup_install "restore-$failed_file-failure"
  api_reload() { :; }
  case "$failed_file" in
  config) restore_src="$CLASH_CONFIG.previous.$$"; restore_dst="$CLASH_CONFIG" ;;
  runtime) restore_src="$PKG_TMP_DIR/runtime.old"; restore_dst="$RUNTIME_CONFIG" ;;
  profile) restore_src="$PKG_TMP_DIR/profile.old"; restore_dst="$PROFILE_FILE" ;;
  esac
  mv() {
   if [ "${3:-}" = "$restore_dst" ] && { [ "${2:-}" = "$restore_src" ] || [ "${2:-}" = "$restore_dst.restore.$$" ]; }; then
    err "previous $failed_file restore failed"
    return 1
   fi
   command mv "$@"
  }
  rc=0
  config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
  assert_eq 1 "$rc" "failed $failed_file restore fails install"
  assert_eq "Error: Failed to apply the new subscription settings: new policy failed; restoring the previous config failed: previous $failed_file restore failed; the previous config is saved in $CLASH_CONFIG.previous.$$" "$(cat "$tmpdir/err")" "failed $failed_file restore names the recovery path"
  assert_true "failed $failed_file restore saves previous YAML" cmp -s "$CLASH_CONFIG.previous.$$" "$PKG_TMP_DIR/source.before"
  assert_true "failed $failed_file restore saves previous runtime" cmp -s "$PKG_TMP_DIR/runtime.old" "$PKG_TMP_DIR/runtime.before"
  assert_true "failed $failed_file restore saves previous profile" cmp -s "$PKG_TMP_DIR/profile.old" "$PKG_TMP_DIR/profile.before"
  assert_eq 'older backup' "$(cat "$CLASH_CONFIG_BACKUP")" "failed $failed_file restore keeps older backup"
  assert_eq '' "$(find "${CLASH_CONFIG%/*}" -name '*.restore.*' -print)" "failed $failed_file restore removes staging"
 )
 pass "config_install keeps recovery files after $failed_file restore failure"
done

(
 setup_install profile-only
 printf 'proxies: []\nx-mihowrt:\n  disable-quic: false\n' >"$PKG_TMP_DIR/candidate"
 api_reload() { echo reload >>"$PKG_TMP_DIR/events"; }
 policy_apply() {
  echo "policy $(profile_get "set disable_quic")" >>"$PKG_TMP_DIR/events"
  [ "$(profile_get "set disable_quic")" = 1 ] && return 0
  err 'new policy failed'
  return 1
 }
 rc=0
 config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
 assert_eq 1 "$rc" 'profile-only apply failure fails install'
 assert_eq 'Error: Failed to apply the new subscription settings: new policy failed; the previous config is restored' "$(cat "$tmpdir/err")" 'profile-only failure reports successful rollback'
 assert_true 'profile-only failure restores YAML' cmp -s "$CLASH_CONFIG" "$PKG_TMP_DIR/source.before"
 assert_true 'profile-only failure restores runtime' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
 assert_true 'profile-only failure restores profile' cmp -s "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
 assert_eq $'cron\npolicy 0\ncron\npolicy 1' "$(cat "$PKG_TMP_DIR/events")" 'profile-only rollback reapplies policy without reloading identical runtime'
 assert_eq 'older backup' "$(cat "$CLASH_CONFIG_BACKUP")" 'profile-only failure keeps older backup'
 assert_false 'successful rollback cleans saved YAML' test -e "$CLASH_CONFIG.previous.$$"
 assert_false 'successful rollback cleans saved runtime' test -e "$PKG_TMP_DIR/runtime.old"
 assert_false 'successful rollback cleans saved profile' test -e "$PKG_TMP_DIR/profile.old"
)
pass 'config_install profile-only rollback skips Mihomo reload'

setup_install reload-failure
api_reload() { err 'reload failed'; return 1; }
rc=0
config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'rejected reload fails install'
assert_true 'rejected reload restores YAML' cmp -s "$CLASH_CONFIG" "$PKG_TMP_DIR/source.before"
assert_true 'rejected reload restores runtime' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
assert_true 'rejected reload restores profile' cmp -s "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
assert_eq 'older backup' "$(cat "$CLASH_CONFIG_BACKUP")" 'rejected reload keeps older backup'
pass 'config_install rejected reload keeps older backup'

setup_install subscription
SUBSCRIPTION_META_FILE="$PKG_PERSIST_DIR/subscription.json"
printf '{"profile_title":"old"}\n' >"$SUBSCRIPTION_META_FILE"
SUBSCRIPTION_URL=https://provider.example/config
http_fetch() { cp "$PKG_TMP_DIR/candidate" "$2"; : >"$6"; }
subscription_metadata_from_headers() { echo '{"profile_title":"new"}'; }
with_lock() { "$@"; }
config_api_wait() { :; }
api_reload() { :; }
policy_apply() {
 [ "$(profile_get "set disable_quic")" = 1 ] && return 0
 err 'new policy failed'
 return 1
}
rc=0
subscription_update https://new.example/config >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'subscription propagates apply failure'
assert_eq '{"profile_title":"old"}' "$(cat "$SUBSCRIPTION_META_FILE")" 'failed subscription keeps metadata'
assert_eq '' "$(uci_get subscription_url)" 'failed subscription does not save new URL'
assert_false 'failed subscription does not advance update stamp' test -f "$PKG_STATE_DIR/subscription.stamp"
pass 'subscription_update leaves metadata URL and stamp unchanged after apply failure'
