#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh
setup_runtime_paths "$tmpdir"
# Source the real CLI functions without dispatching a command.
sed '/^cmd=/,$d' "$ROOT_DIR/rootfs/usr/bin/mihowrt" |
 sed "s|/etc/init.d/mihowrt|$tmpdir/init-mihowrt|g" >"$tmpdir/cli-functions.sh"
source "$tmpdir/cli-functions.sh"
settings_load() { DASHBOARD_ENABLED="$(uci_get dashboard 0)"; API_SECRET=secret; }
lan_ip_detect() { echo 192.0.2.1; }
service_running() { return 1; }
fake_uci_set mihowrt.settings.dashboard 0
API_SECRET_FILE="$tmpdir/api_secret"
printf 'secret\n' >"$API_SECRET_FILE"
jq() { printf '%s\n' "$@" >"$tmpdir/jq.argv"; command jq "$@"; }
json="$(dashboard_json)"
assert_eq 1 "$(grep -xcF secret "$tmpdir/jq.argv")" 'only secret argument name, never its value, in jq argv'
assert_eq 'false:false:false:null' "$(jq -r '[.running,.enabled,.installed,.size] | map(tostring) | join(":")' <<<"$json")" 'missing dashboard status'
assert_eq '192.0.2.1:9090:secret' "$(jq -r '[.host,(.port|tostring),.secret]|join(":")' <<<"$json")" 'existing dashboard fields retained'
mkdir -p "$CLASH_DIR/ui"
printf panel >"$CLASH_DIR/ui/index.html"
fake_uci_set mihowrt.settings.dashboard 1
json="$(dashboard_json)"
assert_eq 'true:true' "$(jq -r '[.enabled,.installed]|map(tostring)|join(":")' <<<"$json")" 'enabled and installed status'
assert_eq "$(( $(du -sk "$CLASH_DIR/ui" | cut -f1) * 1024 ))" "$(jq -r .size <<<"$json")" 'installed size in bytes'
rm "$CLASH_DIR/ui/index.html"
assert_eq false "$(dashboard_json | jq -r .installed)" 'directory alone is not installed'
pass 'dashboard-json flag, index and optional byte size'

load_modules job.sh
reloads=0
service_running() { return 0; }
export DOWNLOAD=0 RESTART_FAIL=0
cat >"$tmpdir/init-mihowrt" <<EOF
#!/bin/ash
[ ! -e /proc/self/fd/9 ] || exit 1
printf '%s\n' "\$*" >>"$tmpdir/init-calls"
if [ "\$(uci -q get mihowrt.settings.dashboard)" = 0 ] && [ -d "$CLASH_DIR/ui" ]; then
 printf '%s\n' "\$*" >"$tmpdir/rollback-before-cleanup"
fi
[ "\$RESTART_FAIL" = 0 ] || exit 1
if [ "\$DOWNLOAD" = 1 ]; then
 mkdir -p "$CLASH_DIR/ui"; printf panel >"$CLASH_DIR/ui/index.html"
fi
EOF
chmod +x "$tmpdir/init-mihowrt"
: >"$tmpdir/init-calls"
with_lock() { "$@"; }
service_reload() {
 reloads=$((reloads + 1))
 if [ "${DOWNLOAD:-0}" = 1 ] && [ "$(uci_get dashboard)" = 1 ]; then
  mkdir -p "$CLASH_DIR/ui"; printf panel >"$CLASH_DIR/ui/index.html"
 fi
 [ "${RELOAD_FAIL:-0}" = 0 ]
}
DASHBOARD_WAIT_SECONDS=1
rm -rf "$CLASH_DIR/ui"
fake_uci_set mihowrt.settings.dashboard 0
DOWNLOAD=1
job_validate dashboard-install
job_execute dashboard-install 9>"$tmpdir/runtime.lock" >"$tmpdir/result"
assert_eq 1 "$(uci_get dashboard)" 'install enables panel'
assert_true 'install downloads index' test -f "$CLASH_DIR/ui/index.html"
assert_eq restart "$(cat "$tmpdir/init-calls")" 'running install restarts once'
assert_eq 0 "$reloads" 'running install does not reload'
job_execute dashboard-install >/dev/null
assert_eq 1 "$(wc -l <"$tmpdir/init-calls")" 'installed panel no restart'
assert_eq 0 "$reloads" 'installed panel no reload'
job_execute dashboard-remove >/dev/null
assert_eq 0 "$(uci_get dashboard)" 'remove disables panel'
assert_false 'remove clears files' test -d "$CLASH_DIR/ui"
assert_eq 1 "$reloads" 'remove reloads once'
assert_eq 1 "$(wc -l <"$tmpdir/init-calls")" 'remove never restarts'
job_execute dashboard-remove >/dev/null
assert_eq 1 "$reloads" 'removed panel no-op'
pass 'dashboard jobs install, remove and no-op'
DOWNLOAD=0
mkdir -p "$CLASH_DIR/ui"; echo partial >"$CLASH_DIR/ui/partial"
if job_execute dashboard-install >"$tmpdir/result" 2>"$tmpdir/error"; then fail 'timeout must fail'; fi
assert_eq 0 "$(uci_get dashboard)" 'timeout resets flag'
assert_true 'timeout restarts before deleting partial files' test -f "$tmpdir/rollback-before-cleanup"
assert_eq restart "$(cat "$tmpdir/rollback-before-cleanup")" 'rollback kills in-flight download before cleanup'
assert_false 'timeout deletes partial files' test -d "$CLASH_DIR/ui"
assert_eq 'Error: Could not download the dashboard. Check that GitHub is reachable from the router.' "$(cat "$tmpdir/error")" 'exact timeout error'
assert_eq 1 "$reloads" 'timeout rollback never hot reloads'
assert_eq 3 "$(wc -l <"$tmpdir/init-calls")" 'timeout restarts to install and rollback'
RESTART_FAIL=1
if job_execute dashboard-install >"$tmpdir/result" 2>"$tmpdir/error"; then fail 'restart failure must fail'; fi
assert_eq 0 "$(uci_get dashboard)" 'restart failure resets flag'
assert_file_contains "$tmpdir/error" 'Could not download the dashboard. Check that GitHub is reachable from the router.' 'restart failure exact error'
RESTART_FAIL=0
pass 'dashboard install timeout and restart failure roll back'

# Stopped: only the running core downloads the panel, so refuse at once.
service_running() { return 1; }
before_restarts="$(wc -l <"$tmpdir/init-calls")"
before_reloads="$reloads"
DASHBOARD_WAIT_SECONDS=30
mkdir -p "$CLASH_DIR/ui"; echo partial >"$CLASH_DIR/ui/partial"
started="$(date +%s)"
if job_execute dashboard-install >"$tmpdir/result" 2>"$tmpdir/error"; then fail 'stopped install must fail'; fi
assert_true 'stopped install fails without waiting' test "$(( $(date +%s) - started ))" -lt 5
assert_eq 'Error: Start MihoWRT before installing the dashboard.' "$(cat "$tmpdir/error")" 'stopped install exact error'
assert_eq 0 "$(uci_get dashboard)" 'stopped install keeps flag off'
assert_true 'stopped install leaves files alone' test -f "$CLASH_DIR/ui/partial"
assert_eq "$before_restarts" "$(wc -l <"$tmpdir/init-calls")" 'stopped install never restarts'
assert_eq "$before_reloads" "$reloads" 'stopped install never reloads'
rm -rf "$CLASH_DIR/ui"
DASHBOARD_WAIT_SECONDS=1
pass 'dashboard install while stopped is refused at once'

# Use the actual stopped-service reload, then generate the next-start config.
load_modules service.sh
service_ready() { return 1; }
cron_update() { return 0; }

fake_uci_set mihowrt.settings.dashboard 1
mkdir -p "$CLASH_DIR/ui"; echo panel >"$CLASH_DIR/ui/index.html"
job_execute dashboard-remove >/dev/null
assert_eq 0 "$(uci_get dashboard)" 'remove while stopped disables panel'
assert_false 'remove while stopped clears files' test -d "$CLASH_DIR/ui"
settings_load
printf 'proxies: []\n' >"$tmpdir/config.yaml"
mihomo_config_generate "$tmpdir/config.yaml" "$tmpdir/runtime.yaml"
assert_file_not_contains "$tmpdir/runtime.yaml" 'external-ui' 'next start after stopped removal omits external-ui'
pass 'dashboard removal while stopped affects next render'

read_cli="$ROOT_DIR/rootfs/usr/bin/mihowrt-read"
for op in dashboard-install dashboard-remove; do
 assert_false 'read wrapper rejects dashboard write' sh "$read_cli" "$op" >/dev/null 2>&1
 assert_false 'read wrapper rejects dashboard job' sh "$read_cli" job-start "$op" >/dev/null 2>&1
 assert_false 'dashboard job rejects args' job_validate "$op" extra >/dev/null 2>&1
done
acl="$ROOT_DIR/rootfs/usr/share/rpcd/acl.d/luci-app-mihowrt.json"
assert_eq true "$(jq '."luci-app-mihowrt".write.file."/usr/bin/mihowrt" | index("exec") != null' "$acl")" 'backend write exec granted'
assert_eq null "$(jq '."luci-app-mihowrt".read.file."/usr/bin/mihowrt"' "$acl")" 'backend not granted in read ACL'
cat >"$tmpdir/read-backend" <<'BACKEND'
#!/bin/sh
printf '%s\n' "$*"
BACKEND
chmod +x "$tmpdir/read-backend"
assert_false 'dashboard secret not exposed through read wrapper' env MIHOWRT_BACKEND="$tmpdir/read-backend" sh "$read_cli" dashboard-json >/dev/null 2>&1
pass 'dashboard write ACL and read wrapper boundary'
