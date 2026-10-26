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
grep -q 'save-config' "$guest" || fail 'guest must install and restore YAML through the config API'
grep -q 'network.m22c.proto=static' "$guest" || fail 'netifd must retain the selected client fixture addresses'
if grep -Eq '(killall|pkill|conntrack -F|flush ruleset|sysctl -w)' "$guest"; then
  fail 'guest must not use broad process, conntrack or network mutations'
fi
bash -n "$host"
sh -n "$guest"
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
if PATH="$tmpdir/bin:$PATH" NETWORK_TIMEOUT=5 ROUTER_HOST=example.invalid ROUTER_SSH_FORCE_DOCKER=0 ROUTER_CONTAINER=not-a-vm \
  bash "$tmpdir/project/tests/router/run-network.sh" >"$tmpdir/output" 2>&1; then
  fail 'unavailable network check must return 1'
fi
[ -s "$NETWORK_FAKE_ENV" ] || fail 'fake SSH transport not exercised'
if grep -vxF '127.0.0.1|1|mihowrt-openwrt-test' "$NETWORK_FAKE_ENV"; then
  fail 'caller overrides escaped fixed VM transport'
fi
[ ! -e "$NETWORK_FAKE_REMOVED" ] || fail 'failed restoration must preserve guest recovery snapshots'
grep -q '| nft syntax | NOT TESTED |' "$tmpdir/project/.build/verification-0110/network/REPORT.md" || fail 'failed transport must not claim synthetic PASS'
echo 'ok - network host pins transport, fails closed and retains failed-restore state'

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
