#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="${SCRIPT_DIR}/router"

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
