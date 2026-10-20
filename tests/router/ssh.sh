#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build/router"
KEY_FILE="${BUILD_DIR}/id_ed25519"
CONTAINER_NAME="${ROUTER_CONTAINER:-mihowrt-openwrt-test}"
HOST="${ROUTER_HOST:-127.0.0.1}"

if [ -n "${ROUTER_PORT:-}" ]; then
  PORT="${ROUTER_PORT}"
elif [ -f "${BUILD_DIR}/active_port" ]; then
  PORT=$(cat "${BUILD_DIR}/active_port")
else
  PORT=2222
fi

if [ ! -f "${KEY_FILE}" ]; then
  echo "Error: SSH private key not found at ${KEY_FILE}" >&2
  exit 1
fi
chmod 600 "${KEY_FILE}" 2>/dev/null || true

# Check if direct port forward is working without hanging
if [ "${ROUTER_SSH_FORCE_DOCKER:-0}" != "1" ] && nc -z -w 1 "${HOST}" "${PORT}" 2>/dev/null; then
  # Try direct SSH with tight timeout
  if ssh \
    -i "${KEY_FILE}" \
    -p "${PORT}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=2 \
    "root@${HOST}" "$@" 2>/dev/null; then
    exit 0
  fi
fi

# In-container SSH bridge (handles Colima Lima host port-mux conflicts on macOS)
if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${CONTAINER_NAME}"; then
  if [ -t 0 ] && [ -t 1 ]; then
    exec docker exec -it "${CONTAINER_NAME}" ssh \
      -i /router/id_ed25519 \
      -p 2222 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      root@127.0.0.1 "$@"
  else
    exec docker exec -i "${CONTAINER_NAME}" ssh \
      -i /router/id_ed25519 \
      -p 2222 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      root@127.0.0.1 "$@"
  fi
fi

echo "Error: Container ${CONTAINER_NAME} is not running or VM SSH is unreachable." >&2
exit 1
