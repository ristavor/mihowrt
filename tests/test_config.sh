#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh config.sh
setup_runtime_paths "$tmpdir"

PKG_TMP_DIR="$tmpdir/tmp"
CLASH_DIR="$tmpdir/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
CLASH_CONFIG_BACKUP="$CLASH_DIR/config.yaml.bak"
RUNTIME_CONFIG="$tmpdir/runtime.yaml"
mkdir -p "$CLASH_DIR"
CLASH_BIN="$tmpdir/clash-bin"
cat >"$CLASH_BIN" <<'C'
#!/bin/sh
if grep -q BROKEN "$4"; then echo "level=error msg=\"proxy 0: missing type\""; exit 1; fi
exit 0
C
chmod +x "$CLASH_BIN"
echo "mode: rule" >"$CLASH_CONFIG"
running=0
service_running() { [ "$running" = 1 ]; }
service_ready() { [ "$running" = 1 ]; }
runtime_config_build() { mihomo_config_generate "$CLASH_CONFIG" "$1"; }
cron_update() { :; }
policy_apply() { :; }
api_alive() { [ "$running" = 1 ]; }
reload_ok=1
api_reload() { [ "$reload_ok" = 1 ]; }

echo BROKEN >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>"$tmpdir/err"; then fail "invalid config must be rejected"; fi
assert_eq "mode: rule" "$(cat "$CLASH_CONFIG")" "source unchanged"
assert_file_contains "$tmpdir/err" "missing type" "Mihomo error passed to the user"
pass "save rejects invalid"

echo "mode: global" >"$tmpdir/cand"
assert_eq '{"action":"saved"}' "$(config_install "$tmpdir/cand")" "saved while stopped"
assert_eq "mode: global" "$(cat "$CLASH_CONFIG")" "installed"
assert_eq "mode: rule" "$(cat "$CLASH_CONFIG_BACKUP")" "backup kept"
pass "save while stopped"

running=1
echo "mode: direct" >"$tmpdir/cand"
assert_eq '{"action":"hot_reloaded"}' "$(config_install "$tmpdir/cand")" "hot reload while running"
pass "hot reload"

reload_ok=0
echo "log-level: debug" >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>/dev/null; then fail "failed reload must fail"; fi
assert_eq "mode: direct" "$(cat "$CLASH_CONFIG")" "previous config restored"
pass "apply rollback"

assert_false "path outside tmp" config_temp_path_allowed /etc/hosts
assert_false "nested path" config_temp_path_allowed /tmp/mihowrt-config.x/y
link="/tmp/mihowrt-config.testlink.$$"
ln -s /etc/hosts "$link"
assert_false "symlink" config_temp_path_allowed "$link"
rm -f "$link"
assert_eq "mode: direct" "$(config_read_json | jq -r .content | head -n1)" "read config"
pass "config paths"


running=1
service_running() { [ "$running" = 1 ]; }
service_ready() { [ "$running" = 1 ]; }
api_reload() { echo reload >>"$tmpdir/events"; }
policy_apply() { echo policy >>"$tmpdir/events"; }
cron_update() { echo cron >>"$tmpdir/events"; }
dns_restart_dnsmasq() { echo dns-restart >>"$tmpdir/events"; }
printf 'proxies: []\nx-mihowrt:\n  disable-quic: true\n' >"$CLASH_CONFIG"
mihomo_config_generate "$CLASH_CONFIG" "$RUNTIME_CONFIG"
cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
cp "$CLASH_CONFIG" "$tmpdir/cand"
touch -d '2000-01-01' "$CLASH_CONFIG" "$CLASH_CONFIG_BACKUP"
: >"$tmpdir/events"
assert_eq '{"action":"unchanged"}' "$(config_install "$tmpdir/cand")" "unchanged action"
assert_eq 946684800 "$(stat -c %Y "$CLASH_CONFIG")" "unchanged preserves source mtime"
assert_eq 946684800 "$(stat -c %Y "$CLASH_CONFIG_BACKUP")" "unchanged preserves backup mtime"
assert_eq '' "$(cat "$tmpdir/events")" "unchanged no reload"
sed -i 's/disable-quic: true/disable-quic: false/' "$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'cron\npolicy' "$(cat "$tmpdir/events")" "extension-only change applies profile without reload"
# Whitelist -> blacklist updates mode and policy in place; DNS switch flushes once.
printf 'dns:\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: whitelist\nproxies: []\n' >"$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
: >"$tmpdir/events"
sed -i 's/whitelist/blacklist/' "$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'reload\ncron\npolicy' "$(cat "$tmpdir/events")" "mode flip applies policy without DNS restart"
assert_eq proxy-first "$(profile_get mode)" "blacklist flips mode"
: >"$tmpdir/events"
sed -i 's/fake-ip$/redir-host/' "$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'reload\ncron\npolicy\ndns-restart' "$(cat "$tmpdir/events")" "DNS mode flushes cache exactly once"
: >"$tmpdir/events"
printf 'log-level: warning\n' >>"$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq reload "$(cat "$tmpdir/events")" "same profile no policy or DNS restart"
RUNTIME_LOCK_FILE="$tmpdir/lock"
start_runtime_lock_holder "$RUNTIME_LOCK_FILE" "$tmpdir/holder.ready"
api_checks=0
api_alive() { api_checks=$((api_checks + 1)); [ "$api_checks" -ge 3 ]; }
sleep() { assert_true "readiness wait retains other owner's lock" lock_busy; }
config_api_wait
unset -f sleep
assert_eq 3 "$api_checks" "readiness retries until API responds"
assert_true "API wait does not acquire held lock" lock_busy
kill -9 "$LOCK_HOLDER_PID"
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
load_modules service.sh
printf 'BROKEN\n' >"$CLASH_CONFIG"
assert_false "prepare failure" runtime_config_build "$RUNTIME_CONFIG"
assert_file_contains "$CONFIG_ERR_FILE" 'missing type' "prepare records error"
printf 'proxies: []\n' >"$CLASH_CONFIG"
runtime_config_build "$RUNTIME_CONFIG"
assert_true "prepare records success" test -f "$CONFIG_OK_FILE"
assert_false "prepare clears error" test -f "$CONFIG_ERR_FILE"
pass "no-op install, reload/profile/DNS transitions, lock-free wait and prepare check records"

# Exercise the real save-config dispatch, including its upload path guard.
load_modules subscription.sh
sed '/^LIB=/,/mihowrt_load_modules.*exit 1/d' "$ROOT_DIR/rootfs/usr/bin/mihowrt" >"$tmpdir/cli.sh"
config_cli() { ( set -- "$@"; source "$tmpdir/cli.sh"; ); }
upload="/tmp/mihowrt-config.safety.$$"
trap 'rm -rf "$tmpdir"; rm -f "$upload"' EXIT
for candidate in '' $'\n  \n' $'# only\n# comments\n'; do
 printf '%s' "$candidate" >"$upload"
 cp "$CLASH_CONFIG" "$tmpdir/source.before"
 cp "$CLASH_CONFIG_BACKUP" "$tmpdir/backup.before"
 : >"$tmpdir/events"
 rc=0
 config_cli save-config "$upload" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
 assert_eq 1 "$rc" 'empty yaml rejected'
 assert_eq 'Error: The YAML is empty: nothing was changed.' "$(cat "$tmpdir/err")" 'empty YAML message'
 assert_true 'empty preserves installed YAML' cmp -s "$CLASH_CONFIG" "$tmpdir/source.before"
 assert_true 'empty preserves backup' cmp -s "$CLASH_CONFIG_BACKUP" "$tmpdir/backup.before"
 assert_eq '' "$(cat "$tmpdir/events")" 'empty does not reload'
done
pass 'empty yaml rejected'

printf 'proxies: []\n' >"$upload"
truncate -s 8388609 "$upload"
rc=0
config_cli save-config "$upload" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'oversize rejected'
assert_eq 'Error: The YAML is larger than 8 MiB.' "$(cat "$tmpdir/err")" 'oversize message'
assert_true 'oversize preserves installed YAML' cmp -s "$CLASH_CONFIG" "$tmpdir/source.before"
assert_true 'oversize preserves backup' cmp -s "$CLASH_CONFIG_BACKUP" "$tmpdir/backup.before"
assert_eq '' "$(cat "$tmpdir/events")" 'oversize does not reload'
pass 'oversize rejected'

for key in 'mode:' '"quoted-key" :' "'quoted_key':" 'key9:'; do
 printf '%s value\n' "$key" >"$tmpdir/keys"
 assert_true 'top-level mapping key recognized' config_has_keys "$tmpdir/keys"
done
printf '  nested: value\n- item\n# comment: value\n' >"$tmpdir/keys"
assert_false 'only top-level keys recognized' config_has_keys "$tmpdir/keys"
pass 'config_has_keys contract'

api_alive() { return 0; }
service_running() { return 0; }
service_ready() { return 0; }
printf 'mode: rule\n' >"$CLASH_CONFIG"
printf 'mode: global\n' >"$CLASH_CONFIG_BACKUP"
: >"$tmpdir/events"
assert_eq '{"action":"hot_reloaded"}' "$(config_cli restore-config)" 'restore action'
assert_eq 'mode: global' "$(cat "$CLASH_CONFIG")" 'restore installs B'
assert_eq 'mode: rule' "$(cat "$CLASH_CONFIG_BACKUP")" 'restore backs up A'
assert_file_contains "$tmpdir/events" reload 'restore hot reloads'
config_cli restore-config >/dev/null
assert_eq 'mode: rule' "$(cat "$CLASH_CONFIG")" 'second restore installs A'
assert_eq 'mode: global' "$(cat "$CLASH_CONFIG_BACKUP")" 'second restore backs up B'
rm "$CLASH_CONFIG_BACKUP"
rc=0
config_cli restore-config 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'missing backup rejected'
assert_eq 'Error: There is no previous configuration.' "$(cat "$tmpdir/err")" 'missing backup message'
pass 'restore swaps'

printf 'BROKEN\n' >"$CLASH_CONFIG_BACKUP"
cp "$CLASH_CONFIG" "$tmpdir/source.before"
cp "$CLASH_CONFIG_BACKUP" "$tmpdir/backup.before"
: >"$tmpdir/events"
rc=0
config_cli restore-config >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'broken backup rejected'
assert_true 'broken backup preserves installed YAML' cmp -s "$CLASH_CONFIG" "$tmpdir/source.before"
assert_true 'broken backup stays unchanged' cmp -s "$CLASH_CONFIG_BACKUP" "$tmpdir/backup.before"
assert_eq '' "$(find "$PKG_TMP_DIR" -name 'restore.*' -print)" 'broken restore removes temporary file'
assert_eq '' "$(cat "$tmpdir/events")" 'broken restore does not reload'
pass 'broken backup restore is safe'

for candidate in $'\357\273\277proxies: []\n' $'proxies: []\r\n'; do
 printf '%s' "$candidate" >"$upload"
 (
  awk() { busybox awk "$@"; }
  assert_true 'BusyBox awk accepts BOM or CRLF single key' config_has_keys "$upload"
 )
 assert_true 'save-config accepts BOM or CRLF single key' config_cli save-config "$upload"
done
pass 'BOM and CRLF single key accepted'
