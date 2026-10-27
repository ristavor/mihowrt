#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh
setup_runtime_paths "$tmpdir"
# Source the real CLI functions without dispatching a command.
sed '/^cmd=/,$d' "$ROOT_DIR/rootfs/usr/bin/mihowrt" >"$tmpdir/cli-functions.sh"
source "$tmpdir/cli-functions.sh"
settings_load() { DASHBOARD_ENABLED="$(uci_get dashboard 0)"; API_SECRET=secret; }
lan_ip_detect() { echo 192.0.2.1; }
service_running() { return 1; }
fake_uci_set mihowrt.settings.dashboard 0
json="$(dashboard_json)"
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
