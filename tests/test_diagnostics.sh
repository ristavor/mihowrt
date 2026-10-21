#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/proc/123"
export DIAG_FIXTURE="$tmpdir"
cat >"$tmpdir/bin/apk" <<'APK'
#!/bin/ash
[ "$1 $2" = 'info -e' ] || exit 99
echo "$3" >>"$DIAG_FIXTURE/apk.calls"
grep -qxF "$3" "$DIAG_FIXTURE/installed"
APK
cat >"$tmpdir/bin/df" <<'DF'
#!/bin/ash
[ "$1 $2" = '-kP /opt/clash' ] || exit 99
cat "$DIAG_FIXTURE/df"
DF
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
: >"$tmpdir/installed"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/root 100000 48800 51200 49%% /\n' >"$tmpdir/df"
printf 'MemTotal: 100000 kB\nMemAvailable: 30000 kB\n' >"$tmpdir/proc/meminfo"
printf 'Name: mihomo\nVmRSS: 45000 kB\n' >"$tmpdir/proc/123/status"
echo 123 >"$tmpdir/pid"
printf 'mixed-port: 7890\nsocks-port: 0\nport: 7891\n' >"$tmpdir/runtime.yaml"
# Relocate kernel files only; run the real implementation under BusyBox ash/awk.
sed "s|/proc/|$tmpdir/proc/|g" "$MIHOWRT_LIB_DIR/status.sh" >"$tmpdir/status.sh"
cat >"$tmpdir/diagnostics" <<'RUN'
#!/bin/ash
. "$MIHOWRT_LIB_DIR/constants.sh"
. "$DIAG_FIXTURE/status.sh"
RUNTIME_CONFIG="$DIAG_FIXTURE/runtime.yaml"
service_pid() { cat "$DIAG_FIXTURE/pid" 2>/dev/null; }
awk() { busybox awk "$@"; }
diagnostics_json
RUN
chmod +x "$tmpdir/diagnostics"
diag() { ash "$tmpdir/diagnostics"; }

case "${1:-all}" in
all|conflicts)
 printf 'https-dns-proxy\npodkop\n' >"$tmpdir/installed"
 assert_eq '["podkop","https-dns-proxy"]' "$(diag | jq -c .conflicts)" 'installed conflicts in authoritative order'
 assert_eq 'podkop luci-app-podkop luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy luci-app-nikki nikki luci-app-ssclash luci-app-v2raya luci-app-mihomo https-dns-proxy adguardhome' "$(paste -sd ' ' "$tmpdir/apk.calls")" 'each exact conflict checked once'
 : >"$tmpdir/installed"
 assert_eq '[]' "$(diag | jq -c .conflicts)" 'no installed conflicts'
 pass 'diagnostics conflicts'
 ;;&
all|resources)
 assert_eq '[51200,30000,45000]' "$(diag | jq -c '[.flash_free_kb,.ram_available_kb,.mihomo_rss_kb]')" 'resource snapshot'
 rm "$tmpdir/pid"
 assert_eq null "$(diag | jq .mihomo_rss_kb)" 'stopped Mihomo has no RSS'
 echo 123 >"$tmpdir/pid"
 rm "$tmpdir/proc/123/status" "$tmpdir/proc/meminfo"
 : >"$tmpdir/df"
 assert_eq '[null,null,null]' "$(diag | jq -c '[.flash_free_kb,.ram_available_kb,.mihomo_rss_kb]')" 'missing resources are null'
 pass 'diagnostics resources'
 ;;&
all|ports)
 assert_eq '[7890,7891]' "$(diag | jq -c .open_proxy_ports)" 'nonzero ports in config order'
 printf 'authentication:\n  - "u:p"\n' >>"$tmpdir/runtime.yaml"
 assert_eq '[]' "$(diag | jq -c .open_proxy_ports)" 'authentication hides open ports'
 cat >"$tmpdir/runtime.yaml" <<'YAML'
proxy-providers:
  example:
    authentication:
      - "nested:only"
    mixed-port: 7777
mixed-port: "07890" # quoted decimal
port: '7891'
socks-port: "0"
redir-port: 7892
skip-auth-prefixes:
  - 127.0.0.1/8
YAML
 assert_eq '[7890,7891,7892]' "$(diag | jq -c .open_proxy_ports)" 'quoted ports, column-zero keys and skip-auth-prefixes'
 printf 'authentication: ["u:p"]\n' >>"$tmpdir/runtime.yaml"
 assert_eq '[]' "$(diag | jq -c .open_proxy_ports)" 'inline authentication list'
 rm "$tmpdir/runtime.yaml"
 assert_eq '[]' "$(diag | jq -c .open_proxy_ports)" 'missing runtime config'
 pass 'diagnostics open proxy ports'
 ;;&
all|auth-empty-list|auth-empty|auth-null|auth-tilde|auth-quoted-empty|auth-quoted-block|auth-quoted-inline|dedup)
 check_ports() {
  printf 'mixed-port: 7890\nport: 7891\n' >"$tmpdir/runtime.yaml"
  printf '%b\n' "$2" >>"$tmpdir/runtime.yaml"
  assert_eq "$3" "$(diag | jq -c .open_proxy_ports)" "$1"
 }
 if [ "${1:-all}" = all ]; then
  cases='auth-empty-list auth-empty auth-null auth-tilde auth-quoted-empty auth-quoted-block auth-quoted-inline dedup'
 else
  cases="$1"
 fi
 for scenario in $cases; do
  case "$scenario" in
  auth-empty-list) check_ports "$scenario" 'authentication: []' '[7890,7891]' ;;
  auth-empty) check_ports "$scenario" 'authentication:\n# comment\nother: true\n  - unrelated' '[7890,7891]' ;;
  auth-null) check_ports "$scenario" 'authentication: null' '[7890,7891]' ;;
  auth-tilde) check_ports "$scenario" 'authentication: ~' '[7890,7891]' ;;
  auth-quoted-empty) check_ports "$scenario" '"authentication": []' '[7890,7891]' ;;
  auth-quoted-block) check_ports "$scenario" '"authentication":\n  # comment\n\n  - "u:p"' '[]' ;;
  auth-quoted-inline) check_ports "$scenario" '"authentication": ["u:p"]' '[]' ;;
  dedup) check_ports "$scenario" 'socks-port: 7890\nredir-port: "07891"\nport: 7892' '[7890,7891,7892]' ;;
  esac
 done
 pass 'diagnostics authentication values and unique ports'
 ;;&
all|wrapper)
 assert_eq diagnostics-json "$(MIHOWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/mihowrt-read" diagnostics-json)" 'read wrapper allows diagnostics'
 assert_false 'read wrapper rejects extra argument' env MIHOWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/mihowrt-read" diagnostics-json extra
 assert_false 'read wrapper rejects empty argument' env MIHOWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/mihowrt-read" diagnostics-json ''
 strip_mihowrt_cli_bootstrap >"$tmpdir/cli"
 sed -i '/^case "$cmd" in/i diagnostics_json() { echo diagnostics-dispatched; }' "$tmpdir/cli"
 assert_eq diagnostics-dispatched "$(ash "$tmpdir/cli" diagnostics-json)" 'CLI dispatches diagnostics'
 assert_false 'CLI rejects arguments' ash "$tmpdir/cli" diagnostics-json extra >/dev/null 2>&1
 pass 'diagnostics read boundary'
 ;;
esac
