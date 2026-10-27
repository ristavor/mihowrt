#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/run" "$tmpdir/clash"
export HOTPLUG_TEST_DIR="$tmpdir" PATH="$tmpdir/bin:$PATH"
sed -e "s|/var/run/mihowrt|$tmpdir/run|g" -e "s|/opt/clash|$tmpdir/clash|g" \
 "$MIHOWRT_LIB_DIR/constants.sh" >"$tmpdir/constants.sh"
sed -e "s|/usr/lib/mihowrt/constants.sh|$tmpdir/constants.sh|g" \
 -e "s|/usr/bin/mihowrt|$tmpdir/cli|g" -e "s|/etc/init.d/mihowrt|$tmpdir/init|g" \
 "$ROOT_DIR/rootfs/etc/hotplug.d/iface/90-mihowrt" >"$tmpdir/hotplug.sh"
cat >"$tmpdir/bin/pgrep" <<'PGREP'
#!/bin/sh
[ -f "$HOTPLUG_TEST_DIR/supervisor" ]
PGREP
cat >"$tmpdir/cli" <<'CLI'
#!/bin/sh
[ ! -e /proc/$$/fd/6 ] && [ ! -e /proc/$$/fd/9 ] || echo leaked >"$HOTPLUG_TEST_DIR/leaked"
echo "$*" >"$HOTPLUG_TEST_DIR/command"
CLI
cat >"$tmpdir/init" <<'INIT'
#!/bin/sh
[ ! -e /proc/$$/fd/6 ] && [ ! -e /proc/$$/fd/9 ] || echo leaked >"$HOTPLUG_TEST_DIR/leaked"
case "$1" in
enabled) [ ! -f "$HOTPLUG_TEST_DIR/disabled" ] ;;
start) echo start >"$HOTPLUG_TEST_DIR/command" ;;
esac
INIT
chmod +x "$tmpdir/bin/pgrep" "$tmpdir/cli" "$tmpdir/init"
cases=(supervisor_ifup supervisor_ifupdate broken fixed not_ready core_exited watchdog stopped disabled marker)
[ $# -eq 0 ] || cases=("$@")
for scenario in "${cases[@]}"; do
 rm -f "$tmpdir/command" "$tmpdir/supervisor" "$tmpdir/disabled" "$tmpdir/run/"*
 touch -d '2020-01-01' "$tmpdir/clash/config.yaml"
 expected=net-refresh
 action=ifup
 case "$scenario" in
 supervisor_ifup) touch "$tmpdir/supervisor" ;;
 supervisor_ifupdate) touch "$tmpdir/supervisor"; action=ifupdate ;;
 broken) touch -d '2021-01-01' "$tmpdir/run/config.invalid"; expected=none ;;
 fixed)
  touch -d '2021-01-01' "$tmpdir/run/config.invalid" "$tmpdir/run/last_error"
  touch -d '2022-01-01' "$tmpdir/clash/config.yaml"
  expected=start
  ;;
 not_ready | core_exited | watchdog)
  case "$scenario" in
  not_ready) error='Mihomo did not become ready; router stays on direct routing' ;;
  core_exited) error='Mihomo exited unexpectedly' ;;
  watchdog) error='Mihomo API is not responding; restarting core' ;;
  esac
  printf '%s\n' "$error" >"$tmpdir/run/last_error"
  touch -d '2021-01-01' "$tmpdir/run/last_error"
  expected=start
  ;;
 stopped) touch "$tmpdir/run/stopped"; expected=none ;;
 disabled) touch "$tmpdir/disabled"; expected=none ;;
 marker) touch "$tmpdir/run/running" ;;
 esac
 exec 6>>"$tmpdir/net.flock"
 exec 9>>"$tmpdir/runtime.flock"
 ACTION="$action" INTERFACE=wan ash "$tmpdir/hotplug.sh"
 exec 6>&-
 exec 9>&-
 if [ "$expected" = none ]; then
  sleep 0.1
  assert_false "$scenario hotplug starts no operation" test -e "$tmpdir/command"
 else
  for _ in {1..100}; do [ ! -e "$tmpdir/command" ] || break; sleep 0.01; done
  assert_true "$scenario hotplug queues operation" test -f "$tmpdir/command"
  assert_eq "$expected" "$(cat "$tmpdir/command")" "$scenario hotplug operation"
 fi
 assert_false 'hotplug children close fd 6 and fd 9' test -e "$tmpdir/leaked"
 pass "service hotplug: $scenario"
done
