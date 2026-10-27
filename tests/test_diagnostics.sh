#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/proc/123"
export DIAG_FIXTURE="$tmpdir"
cat >"$tmpdir/bin/apk" <<'APK'
#!/bin/ash
echo "$*" >>"$DIAG_FIXTURE/apk.calls"
case "$*" in
info) cat "$DIAG_FIXTURE/installed" ;;
'info -e '*) grep -qxF "$3" "$DIAG_FIXTURE/installed" ;;
*) exit 99 ;;
esac
APK
cat >"$tmpdir/bin/df" <<'DF'
#!/bin/ash
case "$1 $2" in
'-kP /opt/clash') cat "$DIAG_FIXTURE/df" ;;
'-kP /tmp') printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 64000 4000 60000 7%% /tmp\n' ;;
*) exit 99 ;;
esac
DF
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
: >"$tmpdir/installed"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/root 100000 48800 51200 49%% /\n' >"$tmpdir/df"
printf 'MemTotal: 100000 kB\nMemAvailable: 30000 kB\n' >"$tmpdir/proc/meminfo"
printf 'Name: mihomo\nVmRSS: 45000 kB\n' >"$tmpdir/proc/123/status"
echo 123 >"$tmpdir/pid"
printf 'mixed-port: 7890\nsocks-port: 0\nport: 7891\n' >"$tmpdir/runtime.yaml"
# Relocate kernel files and the temporary storage directory; run the real implementation under BusyBox ash/awk.
sed "s|/proc/|$tmpdir/proc/|g; s|/tmp/clash|$tmpdir/clash|g" "$MIHOWRT_LIB_DIR/status.sh" >"$tmpdir/status.sh"
sed "s|/lib/apk/db/installed|$tmpdir/apk-installed|g; s|/usr/lib/opkg/status|$tmpdir/opkg-status|g" "$MIHOWRT_LIB_DIR/pkg.sh" >"$tmpdir/pkg.sh"
cat >"$tmpdir/diagnostics" <<'RUN'
#!/bin/ash
. "$MIHOWRT_LIB_DIR/constants.sh"
. "$MIHOWRT_LIB_DIR/helpers.sh"
. "$DIAG_FIXTURE/status.sh"
. "$DIAG_FIXTURE/pkg.sh"
RUNTIME_CONFIG="$DIAG_FIXTURE/runtime.yaml"
service_pid() { cat "$DIAG_FIXTURE/pid" 2>/dev/null; }
awk() {
 case "$*" in *"$DIAG_FIXTURE/apk-installed"*|*"$DIAG_FIXTURE/opkg-status"*) echo read >>"$DIAG_FIXTURE/db.reads" ;; esac
 busybox awk "$@"
}
diagnostics_json
RUN
chmod +x "$tmpdir/diagnostics"
diag() { ash "$tmpdir/diagnostics"; }

case "${1:-all}" in
all|conflicts)
 printf 'P:podkop\nV:1\n\nP:foo\n\nP:https-dns-proxy\n' >"$tmpdir/apk-installed"
 assert_eq '["podkop","https-dns-proxy"]' "$(diag | jq -c .conflicts)" 'installed conflicts in authoritative order'
 assert_eq 1 "$(wc -l <"$tmpdir/db.reads" | tr -d ' ')" 'one awk reads package database'
 assert_false 'diagnostics does not invoke package manager' test -e "$tmpdir/apk.calls"
 printf 'Package: adguardhome\nStatus: install ok installed\n\nPackage: podkop\nStatus: deinstall ok not-installed\n\nPackage: foo\n' >"$tmpdir/opkg-status"
 assert_eq '["podkop","https-dns-proxy"]' "$(diag | jq -c .conflicts)" 'apk database takes precedence'
 rm "$tmpdir/apk-installed"
 assert_eq '["adguardhome"]' "$(diag | jq -c .conflicts)" 'opkg installed names skip not-installed entries'
 rm "$tmpdir/opkg-status"
 assert_eq '[]' "$(diag | jq -c .conflicts)" 'no installed conflicts'
 pass 'diagnostics conflicts'
 ;;&
all|resources)
 assert_eq '{"conflicts":[],"flash_free_kb":51200,"ram_available_kb":30000,"mihomo_rss_kb":45000,"open_proxy_ports":[7890,7891]}' "$(diag | jq -c 'del(.tmp_clash_kb, .tmp_free_kb)')" 'baseline diagnostics JSON unchanged except temporary storage fields'
 assert_eq '[51200,30000,45000]' "$(diag | jq -c '[.flash_free_kb,.ram_available_kb,.mihomo_rss_kb]')" 'resource snapshot'
 rm "$tmpdir/pid"
 assert_eq null "$(diag | jq .mihomo_rss_kb)" 'stopped Mihomo has no RSS'
 echo 123 >"$tmpdir/pid"
 rm "$tmpdir/proc/123/status" "$tmpdir/proc/meminfo"
 : >"$tmpdir/df"
 assert_eq '[null,null,null]' "$(diag | jq -c '[.flash_free_kb,.ram_available_kb,.mihomo_rss_kb]')" 'missing resources are null'
 mkdir -p "$tmpdir/clash/ruleset" "$tmpdir/clash/proxy_providers"
 printf cache >"$tmpdir/clash/cache.db"
 expected="$(du -sk "$tmpdir/clash" | awk '{print $1}')"
 assert_eq "$expected:60000" "$(diag | jq -r '"\(.tmp_clash_kb):\(.tmp_free_kb)"' 2>/dev/null)" 'temporary storage snapshot'
 rm -rf "$tmpdir/clash"
 assert_eq null "$(diag | jq .tmp_clash_kb)" 'absent temporary files unknown'
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
all|listener-inherit-open|listener-inherit-auth|listener-empty-users|listener-users|listener-types|listener-scope|listener-indentless|listener-dedup)
 check_listener_ports() {
  printf '%b\n' "$2" >"$tmpdir/runtime.yaml"
  assert_eq "$3" "$(diag | jq -c .open_proxy_ports)" "$1"
 }
 if [ "${1:-all}" = all ]; then
  cases='listener-inherit-open listener-inherit-auth listener-empty-users listener-users listener-types listener-scope listener-indentless listener-dedup'
 else
  cases="$1"
 fi
 for scenario in $cases; do
  case "$scenario" in
  listener-inherit-open)
   check_listener_ports 'listeners without users inherit absent authentication' 'listeners:
  - name: socks-in
    type: socks
    port: 7900
  - port: "07901" # quoted decimal
    name: http-in
    type: "http"' '[7900,7901]'
   ;;
  listener-inherit-auth)
   check_listener_ports 'listeners without users inherit global authentication declared later' 'listeners:
  - type: mixed
    port: 7900
authentication: ["u:p"]' '[]'
   ;;
  listener-empty-users)
   check_listener_ports 'empty users overrides global authentication, including a shared top-level port' 'mixed-port: 7900
listeners:
  - type: mixed
    port: 7900
    users: [] # explicitly open
  - type: http
    port: 7901
authentication: ["u:p"]' '[7900]'
   ;;
  listener-users)
   check_listener_ports 'inline and block users protect listeners without global authentication' 'listeners:
  - type: socks
    port: 7900
    users: [{username: u, password: p}]
  - type: http
    port: 7901
    users:
      - username: u
        password: p' '[]'
   ;;
  listener-types)
   check_listener_ports 'only socks, http and mixed listener types are reported' 'listeners:
    - type: socks
      port: 7900
    - type: http
      port: 7901
    - type: mixed
      port: 7902
    - type: tproxy
      port: 7903
    - port: 7904' '[7900,7901,7902]'
   ;;
  listener-scope)
   check_listener_ports 'nested list items and later sections do not become listener fields' 'listeners:
  - type: socks
    port: 7900
    users:
      - username: u
        password: p
        type: mixed
        port: 7999
  # comments and blank lines do not end listeners

  - name: public
    type: http
    port: 7901
proxy-providers:
  nested:
    listeners:
      - type: mixed
        port: 7998
other-list:
  - type: mixed
    port: 7997' '[7901]'
   ;;
  listener-indentless)
   check_listener_ports 'block listeners support unindented sequence items' 'listeners:
- type: socks
  port: 7900
- type: mixed
  port: 7901
authentication: []' '[7900,7901]'
   ;;
  listener-dedup)
   check_listener_ports 'listener ports are nonzero decimals deduplicated with top-level ports' 'mixed-port: 7890
listeners:
  - type: socks
    port: "07890"
  - type: http
    port: 7900
  - type: mixed
    port: 7900
  - type: mixed
    port: 0
  - type: http
    port: invalid' '[7890,7900]'
   ;;
  esac
 done
 pass 'diagnostics listener authentication and unique ports'
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
