#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${ROUTER_CONTAINER:-mihowrt-openwrt-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build/router"
KEY_FILE="${BUILD_DIR}/id_ed25519"

if [ -n "${ROUTER_PORT:-}" ]; then
  PORT="${ROUTER_PORT}"
elif [ -f "${BUILD_DIR}/active_port" ]; then
  PORT=$(cat "${BUILD_DIR}/active_port")
else
  PORT=$(docker port "${CONTAINER_NAME}" 2222/tcp 2>/dev/null | awk -F: '{print $NF}' | head -n 1 || true)
  PORT="${PORT:-2222}"
fi

echo "=== Container Status ==="
if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}} ({{.Status}})' | grep -q "${CONTAINER_NAME}"; then
  echo "Container: RUNNING"
  docker ps --filter "name=^/${CONTAINER_NAME}$" --format 'ID: {{.ID}}\nImage: {{.Image}}\nPorts: {{.Ports}}\nStatus: {{.Status}}'
else
  echo "Container: NOT RUNNING"
  exit 1
fi

echo "=== SSH Connectivity ==="
if [ -f "${KEY_FILE}" ]; then
  if "${SCRIPT_DIR}/ssh.sh" true 2>/dev/null; then
    echo "SSH: OK (Port ${PORT})"
    "${SCRIPT_DIR}/ssh.sh" "uname -a" 2>/dev/null || true
  else
    echo "SSH: UNREACHABLE (Port ${PORT})"
    exit 2
  fi
else
  echo "SSH Key not found: ${KEY_FILE}"
  exit 3
fi
