#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="${SCRIPT_DIR}/router"

# Safety contracts run without a VM; only the existing live checks are opt-in.
fail() { echo "not ok - $*" >&2; exit 1; }
for script in run-network.sh network-guest.sh; do
  [ -f "${ROUTER_DIR}/${script}" ] || fail "network fixture missing: ${script}"
done
host="${ROUTER_DIR}/run-network.sh"
guest="${ROUTER_DIR}/network-guest.sh"
grep -q 'ROUTER_HOST=127.0.0.1 ROUTER_SSH_FORCE_DOCKER=1' "$host" || fail 'network SSH must force loopback and Docker'
grep -q 'ROUTER_CONTAINER=mihowrt-openwrt-test' "$host" || fail 'network container must be fixed'
grep -q 'readlink /proc/1/exe' "$host" || fail 'QEMU identity must not depend on truncated ps output'
grep -q 'trap .*EXIT' "$host" || fail 'host must collect evidence on failure'
grep -q 'GUEST_TIMEOUT / 5' "$host" || fail 'host guest poll loop must be bounded'
grep -q 'WORK=/tmp/mihowrt-network-test' "$guest" || fail 'guest must own its temporary directory'
grep -q 'trap .*EXIT' "$guest" || fail 'guest must clean up on exit'
grep -q 'refuse existing' "$guest" || fail 'guest must refuse existing fixture objects'
for fixture_contract in \
  'ip -4 rule add priority 50 fwmark 0x220000/0xff0000 lookup 201' \
  'ip -4 rule del priority 50 fwmark 0x220000/0xff0000 lookup 201' \
  'ip -4 rule show | grep -Eq '\''(^50:| lookup (200|201)( |$))' \
  'ip -6 rule show | grep -Eq '\''(^50:| lookup (200|201)( |$))' \
  '[ "$priority" != 50 ]' \
  'ip -4 rule show | grep '\''^50:.*0x220000/0xff0000.*lookup 201'; do
  grep -qF "$fixture_contract" "$guest" || fail "priority collision fixture must use slot 50: $fixture_contract"
done
grep -q 'save-config' "$guest" || fail 'guest must install and restore YAML through the config API'
grep -q 'network.m22c.proto=static' "$guest" || fail 'netifd must retain the selected client fixture addresses'
# The A2 row alone may toggle this guest-only sysctl, with failure-safe restoration.
if grep -vE '^[[:space:]]*sysctl -w net\.ipv6\.conf\.all\.disable_ipv6=[01]$' "$guest" |
  grep -Eq '(killall|pkill|conntrack -F|flush ruleset|sysctl -w)'; then
  fail 'guest must not use broad process, conntrack or network mutations'
fi
for contract in 'sysctl -w net.ipv6.conf.all.disable_ipv6=1' 'sysctl -w net.ipv6.conf.all.disable_ipv6=0'; do
  grep -qF "$contract" "$guest" || fail "IPv6 disabled fixture must toggle and restore only the allowed sysctl: $contract"
done
for script in "$host" "$guest"; do
  grep -q "'local names'" "$script" || fail 'network matrix must include local names'
done
grep -q 'dhcp.m22host.name=m22host.lan' "$guest" || fail 'local names must use a fixture-owned dnsmasq host record'
grep -q 'check_local_names' "$guest" || fail 'local names must have a guest check'
bash -n "$host"
sh -n "$guest"
for script in "$host" "$guest"; do
  grep -q "'port forward and WAN service replies'" "$script" || fail 'network matrix must include port forward and WAN service replies'
done
grep -q 'check_forward_replies' "$guest" || fail 'port forward row must have a guest check'
grep -q 'uci set firewall.m22dnat=redirect' "$guest" || fail 'port forward must use a fixture-owned fw4 redirect'
grep -q 'comment a1-reply' "$guest" || fail 'port forward row must count marked replies'
grep -q 'stop_reply_listeners' "$guest" || fail 'reply listeners must have tracked TERM/KILL teardown'
grep -q 'a1-ports-router.before' "$guest" || fail 'reply probes must refuse occupied ports'
for script in "$host" "$guest"; do
  grep -q "'IPv6 disabled'" "$script" || fail 'network matrix must include IPv6 disabled'
  grep -q "'policy rule precedence'" "$script" || fail 'network matrix must include policy rule precedence'
done
grep -q 'check_ipv6_disabled' "$guest" || fail 'IPv6 disabled row must have a guest check'
grep -q 'restore_ipv6' "$guest" || fail 'IPv6 sysctl and addresses must be restored even on failure'
grep -q 'check_rule_precedence' "$guest" || fail 'policy precedence row must have a guest check'
for contract in 'priority 105' 'priority 110' 'priority 2001' '0x3f00/0x3f00' 'PRIORITY=1000'; do
  grep -qF "$contract" "$guest" || fail "policy precedence fixture missing: $contract"
done
echo 'ok - network fixture static safety contracts (no VM)'

# Exercise host failure handling with a fake transport; no Docker daemon or VM.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/project/tests/router" "$tmpdir/bin" "$tmpdir/guest/logs"
cp "$host" "$tmpdir/project/tests/router/run-network.sh"
cp "$guest" "$tmpdir/project/tests/router/network-guest.sh"
printf 'FAIL\n' >"$tmpdir/guest/cleanup.status"
printf 'nft syntax\tNOT TESTED\tfixture transport failed\n' >"$tmpdir/guest/results.tsv"
cat >"$tmpdir/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmpdir/project/tests/router/ssh.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$ROUTER_HOST" "$ROUTER_SSH_FORCE_DOCKER" "$ROUTER_CONTAINER" >>"$NETWORK_FAKE_ENV"
case "$*" in
  *"tar -C"*) tar -C "$NETWORK_FAKE_GUEST" -cf - logs results.tsv cleanup.status ;;
  *"rm -rf"*) echo removed >"$NETWORK_FAKE_REMOVED" ;;
  *"sh '/tmp/mihowrt-network-test/network-guest.sh'"*) exit 1 ;;
  *"grep -c"*) exit 1 ;;
  *"cat >"*) cat >/dev/null ;;
  *) : ;;
esac
EOF
chmod +x "$tmpdir/bin/docker" "$tmpdir/project/tests/router/ssh.sh"
export NETWORK_FAKE_ENV="$tmpdir/environment" NETWORK_FAKE_GUEST="$tmpdir/guest" NETWORK_FAKE_REMOVED="$tmpdir/removed"
if PATH="$tmpdir/bin:$PATH" NETWORK_TIMEOUT=5 NETWORK_ROWS='fake-IP direct devices' ROUTER_HOST=example.invalid ROUTER_SSH_FORCE_DOCKER=0 ROUTER_CONTAINER=not-a-vm \
  bash "$tmpdir/project/tests/router/run-network.sh" >"$tmpdir/output" 2>&1; then
  fail 'unavailable network check must return 1'
fi
[ -s "$NETWORK_FAKE_ENV" ] || fail 'fake SSH transport not exercised'
if grep -vxF '127.0.0.1|1|mihowrt-openwrt-test' "$NETWORK_FAKE_ENV"; then
  fail 'caller overrides escaped fixed VM transport'
fi
[ ! -e "$NETWORK_FAKE_REMOVED" ] || fail 'failed restoration must preserve guest recovery snapshots'
grep -q '| nft syntax | NOT TESTED |' "$tmpdir/project/.build/verification-0110/network/REPORT.md" || fail 'failed transport must not claim synthetic PASS'
grep -q '| local names | NOT TESTED |' "$tmpdir/project/.build/verification-0110/network/REPORT.md" || fail 'failed transport must report local names as untested'
echo 'ok - network host pins transport, fails closed and retains failed-restore state'

grep -q -- '-e "VM_MEM=${VM_MEM:-512}"' "${ROUTER_DIR}/start.sh" || fail 'start.sh must pass VM_MEM (default 512) to the VM container'
grep -q -- '-m "${VM_MEM:-512}M"' "${ROUTER_DIR}/entrypoint.sh" || fail 'entrypoint.sh must size guest RAM from VM_MEM (default 512)'
echo 'ok - VM memory override defaults to 512 MiB'

# Boots a QEMU OpenWrt VM via Docker; keep it out of the default unit suite.
if [ "${MIHOWRT_ROUTER_TESTS:-0}" != "1" ]; then
  echo "1..0 # SKIP set MIHOWRT_ROUTER_TESTS=1 to run the OpenWrt VM harness"
  exit 0
fi

echo "1..2"

# Test 1: Router test harness start / status check
if ! "${ROUTER_DIR}/status.sh" >/dev/null 2>&1; then
  echo "# Starting router test harness..."
  "${ROUTER_DIR}/start.sh" >/dev/null
fi

if "${ROUTER_DIR}/status.sh" >/dev/null 2>&1; then
  echo "ok 1 - openwrt router vm running and ssh reachable"
else
  echo "not ok 1 - openwrt router vm not reachable"
  exit 1
fi

# Test 2: Baseline smoke proof
if "${ROUTER_DIR}/run-smoke.sh" baseline >/dev/null 2>&1; then
  echo "ok 2 - openwrt baseline kernel/ubus/apk/procd proof passed"
else
  echo "not ok 2 - openwrt baseline proof failed"
  exit 1
fi
