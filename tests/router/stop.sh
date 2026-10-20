#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${ROUTER_CONTAINER:-mihowrt-openwrt-test}"

echo "[router] Stopping and removing container ${CONTAINER_NAME}..."
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
echo "[router] Stopped."
