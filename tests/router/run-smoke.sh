#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build/router"
DIST_DIR="${PROJECT_ROOT}/dist"
LOG_DIR="${BUILD_DIR}/logs"
mkdir -p "${LOG_DIR}"

MODE="${1:-baseline}"
WATCHDOG="${2:-}"

echo "=========================================================="
echo " MihoWRT Real OpenWrt 25.12.6 VM Smoke Test"
echo " Target: x86/64 QEMU TCG | Mode: ${MODE}"
echo "=========================================================="

# 1. Connectivity check
echo -n "[smoke] Testing SSH connectivity..."
if ! "${SCRIPT_DIR}/ssh.sh" true 2>/dev/null; then
  echo " FAILED"
  echo "Error: Cannot connect to OpenWrt VM via ${SCRIPT_DIR}/ssh.sh" >&2
  exit 1
fi
echo " OK"

# 2. Baseline proof
echo "[smoke] Gathering baseline proof..."
"${SCRIPT_DIR}/ssh.sh" "uname -a" | tee "${LOG_DIR}/baseline-uname.txt"
"${SCRIPT_DIR}/ssh.sh" "ubus call system board" | tee "${LOG_DIR}/baseline-board.json"
"${SCRIPT_DIR}/ssh.sh" "apk --version" | tee "${LOG_DIR}/baseline-apk.txt"
"${SCRIPT_DIR}/ssh.sh" "ip -o addr show" | tee "${LOG_DIR}/baseline-ip.txt"
"${SCRIPT_DIR}/ssh.sh" "ps | grep -E 'procd|dropbear' | grep -v grep" | tee "${LOG_DIR}/baseline-procs.txt" || true
"${SCRIPT_DIR}/ssh.sh" "nft list tables" | tee "${LOG_DIR}/baseline-nft.txt"

if [ "${MODE}" != "integration" ] && [ "${MODE}" != "--integration" ]; then
  echo "=========================================================="
  echo " Baseline Proof Complete (OK)"
  echo " Details saved in ${LOG_DIR}/"
  echo " Use './tests/router/run-smoke.sh --integration' for APK & service lifecycle"
  echo "=========================================================="
  exit 0
fi


# 3. Integration verification (MihoWRT 0.8 behaviour)
echo "=========================================================="
echo " Running Integration Smoke Mode"
echo "=========================================================="

VM() { "${SCRIPT_DIR}/ssh.sh" "$@"; }
fail() { echo " FAILED: $*"; exit 10; }

VERSION="$(sed -n 's/^PKG_VERSION:=//p' "${PROJECT_ROOT}/Makefile")"
APP_APK="${DIST_DIR}/luci-app-mihowrt-${VERSION}-r1.apk"
RU_APK="${DIST_DIR}/luci-i18n-mihowrt-ru-${VERSION}-r1.apk"
[ -f "${APP_APK}" ] && [ -f "${RU_APK}" ] || { echo "Error: ${VERSION} APKs not found in ${DIST_DIR}" >&2; exit 2; }

echo "[smoke] Installing ${VERSION} packages..."
VM "cat > /tmp/mw-app.apk" <"${APP_APK}"
VM "cat > /tmp/mw-ru.apk" <"${RU_APK}"
VM "apk add --allow-untrusted /tmp/mw-app.apk /tmp/mw-ru.apk" | tee "${LOG_DIR}/apk-install.log"
VM "test -s /usr/lib/lua/luci/i18n/mihowrt.ru.lmo" || fail "Russian catalog missing"

if VM "test -x /opt/clash/bin/clash"; then
  echo "[smoke] Mihomo core present: $(VM '/opt/clash/bin/clash -v' | sed -n 1p)"
else
  echo "[smoke] Installing Mihomo core through mihowrt core-update..."
  VM "/usr/bin/mihowrt core-update" | tee "${LOG_DIR}/core-update.json"
fi

echo "[smoke] Deploying minimal test config (no router-owned keys)..."
VM "cat > /opt/clash/config.yaml" <<'EOF'
mode: rule
log-level: info
dns:
  enable: true
  nameserver:
    - 77.88.8.8
proxy-groups:
  - name: FALLBACK
    type: select
    proxies: [DIRECT]
rules:
  - MATCH,FALLBACK
EOF

wait_ready() {
  local i
  for i in $(seq 1 30); do
    VM "/usr/bin/mihowrt status-json | jq -e '.running and .policy_active and .dns_ok' >/dev/null" && return 0
    sleep 2
  done
  return 1
}

echo -n "[smoke] start..."
VM "/etc/init.d/mihowrt enable; /etc/init.d/mihowrt start"
wait_ready || fail "service not ready"
echo " OK"

echo -n "[smoke] dnsmasq conf-dir redirect..."
VM "grep -qx 'server=127.0.0.1#7874' /tmp/dnsmasq.*.d/mihowrt.conf" || fail "conf file missing"
VM "uci show dhcp | grep -q 7874" && fail "UCI must not be modified"
echo " OK"

echo -n "[smoke] DNS answers through dnsmasq..."
VM "nslookup openwrt.org 127.0.0.1 | grep -q Address" || fail "no DNS answer"
echo " OK"

echo -n "[smoke] nft and policy routing (IPv4 + IPv6)..."
VM "nft list table inet mihowrt" >"${LOG_DIR}/nft-mihowrt.txt"
grep -q 'tproxy ip6 to \[::1\]:7894' "${LOG_DIR}/nft-mihowrt.txt" || fail "no IPv6 TPROXY"
VM "ip -4 rule | grep -q 0x8000000" || fail "no IPv4 rule"
VM "[ ! -e /proc/net/if_inet6 ] || ip -6 rule | grep -q 0x8000000" || fail "no IPv6 rule"
echo " OK"

echo "[smoke] reload..."
VM "/etc/init.d/mihowrt reload"
wait_ready || fail "not ready after reload"

echo -n "[smoke] stop is synchronous..."
VM "/etc/init.d/mihowrt stop"
VM "ls /tmp/dnsmasq.*.d/mihowrt.conf >/dev/null 2>&1" && fail "conf file left after stop"
VM "nft list table inet mihowrt >/dev/null 2>&1" && fail "nft table left after stop"
VM "ip rule | grep -q 0x8000000" && fail "ip rule left after stop"
echo " OK"

if [ "${WATCHDOG}" = "--watchdog" ]; then
  echo -n "[smoke] watchdog fail-open with frozen Mihomo..."
  VM "/etc/init.d/mihowrt start"
  wait_ready || fail "not ready before watchdog test"
  OLD_PID="$(VM 'cat /var/run/mihowrt/mihomo.pid' | tr -d '\r\n')"
  VM "kill -STOP ${OLD_PID}"
  opened=0
  for i in $(seq 1 30); do
    sleep 3
    VM "ls /tmp/dnsmasq.*.d/mihowrt.conf >/dev/null 2>&1" || { opened=1; break; }
  done
  [ "${opened}" = 1 ] || fail "DNS still points at frozen Mihomo after 90 s"
  wait_ready || fail "procd did not bring MihoWRT back"
  NEW_PID="$(VM 'cat /var/run/mihowrt/mihomo.pid' | tr -d '\r\n')"
  [ "${NEW_PID}" != "${OLD_PID}" ] || fail "Mihomo was not restarted"
  VM "/etc/init.d/mihowrt stop"
  echo " OK"
fi

echo "=========================================================="
echo " All Integration Tests PASSED successfully!"
echo "=========================================================="
