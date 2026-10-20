#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build/router"

CONTAINER_NAME="${ROUTER_CONTAINER:-mihowrt-openwrt-test}"
IMAGE_NAME="${ROUTER_IMAGE:-mihowrt-openwrt-test:latest}"
TIMEOUT="${ROUTER_BOOT_TIMEOUT:-120}"

KERNEL_NAME="openwrt-25.12.6-x86-64-generic-kernel.bin"
KERNEL_SHA256="8f70595f3a6eec3112e007450a1a600153904deffa52ab368712342583cb387c"
ROOTFS_NAME="openwrt-25.12.6-x86-64-generic-ext4-rootfs.img.gz"
ROOTFS_SHA256="8c243392d09b960a9f0edbfd996153bec213435b0034e6b2db9437115c5178ec"
BASE_URL="https://downloads.openwrt.org/releases/25.12.6/targets/x86/64"

mkdir -p "${BUILD_DIR}"

# 1. SSH Key generation
KEY_FILE="${BUILD_DIR}/id_ed25519"
PUB_FILE="${KEY_FILE}.pub"
if [ ! -f "${KEY_FILE}" ] || [ ! -f "${PUB_FILE}" ]; then
  echo "[start] Generating new ed25519 SSH keypair..."
  rm -f "${KEY_FILE}" "${PUB_FILE}"
  ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "openwrt-test-harness" -q
  chmod 600 "${KEY_FILE}"
fi

# 2. Download and verify official OpenWrt 25.12.6 artifacts
check_sha256() {
  local file="$1"
  local expected="$2"
  if [ ! -f "${file}" ]; then
    return 1
  fi
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "${file}" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "${file}" | awk '{print $1}')
  fi
  [ "${actual}" = "${expected}" ]
}

if ! check_sha256 "${BUILD_DIR}/${KERNEL_NAME}" "${KERNEL_SHA256}"; then
  echo "[start] Downloading ${KERNEL_NAME}..."
  curl -fL -o "${BUILD_DIR}/${KERNEL_NAME}.tmp" "${BASE_URL}/${KERNEL_NAME}"
  mv "${BUILD_DIR}/${KERNEL_NAME}.tmp" "${BUILD_DIR}/${KERNEL_NAME}"
  if ! check_sha256 "${BUILD_DIR}/${KERNEL_NAME}" "${KERNEL_SHA256}"; then
    echo "Error: SHA256 mismatch for ${KERNEL_NAME}" >&2
    exit 1
  fi
fi

if ! check_sha256 "${BUILD_DIR}/${ROOTFS_NAME}" "${ROOTFS_SHA256}"; then
  echo "[start] Downloading ${ROOTFS_NAME}..."
  curl -fL -o "${BUILD_DIR}/${ROOTFS_NAME}.tmp" "${BASE_URL}/${ROOTFS_NAME}"
  mv "${BUILD_DIR}/${ROOTFS_NAME}.tmp" "${BUILD_DIR}/${ROOTFS_NAME}"
  if ! check_sha256 "${BUILD_DIR}/${ROOTFS_NAME}" "${ROOTFS_SHA256}"; then
    echo "Error: SHA256 mismatch for ${ROOTFS_NAME}" >&2
    exit 1
  fi
fi

# 3. Check port 2222 (override if busy)
is_port_in_use() {
  local p="$1"
  nc -z 127.0.0.1 "${p}" 2>/dev/null && return 0
  return 1
}

# Stop old container if already running
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "[start] Cleaning up existing container ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
fi

if [ -n "${ROUTER_PORT:-}" ]; then
  PORT="${ROUTER_PORT}"
else
  if is_port_in_use 2222; then
    echo "[start] Port 2222 is busy on host (Colima/SSH). Overriding to 2223."
    PORT=2223
  else
    PORT=2222
  fi
fi

if is_port_in_use "${PORT}"; then
  echo "Error: Port 127.0.0.1:${PORT} is currently in use." >&2
  echo "You can override the port by setting ROUTER_PORT=<free_port>." >&2
  exit 1
fi

# 4. Ensure docker image is built
if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "[start] Building native arm64 Docker image ${IMAGE_NAME}..."
  docker build --platform linux/arm64 -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
fi

# 5. Run container
echo "[start] Starting OpenWrt VM container ${CONTAINER_NAME} on 127.0.0.1:${PORT}..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  -v "${BUILD_DIR}:/router" \
  -p "127.0.0.1:${PORT}:2222" \
  "${IMAGE_NAME}"

# Save active port for helper scripts
echo "${PORT}" > "${BUILD_DIR}/active_port"

# 6. Wait for SSH readiness
echo -n "[start] Waiting for OpenWrt VM SSH to become ready (timeout ${TIMEOUT}s)..."
START_TIME=$(date +%s)
READY=0
while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    break
  fi

  if ROUTER_PORT="${PORT}" "${SCRIPT_DIR}/ssh.sh" true 2>/dev/null; then
    READY=1
    break
  fi

  # Check if container died prematurely
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo ""
    echo "Error: Container ${CONTAINER_NAME} exited unexpectedly." >&2
    echo "--- Docker Logs ---" >&2
    docker logs "${CONTAINER_NAME}" 2>/dev/null | tail -n 30 >&2 || true
    echo "--- Console Log ---" >&2
    tail -n 30 "${BUILD_DIR}/console.log" 2>/dev/null >&2 || true
    exit 1
  fi

  echo -n "."
  sleep 2
done

echo ""
if [ "${READY}" -ne 1 ]; then
  echo "Error: Timed out waiting for OpenWrt VM after ${TIMEOUT}s." >&2
  echo "--- Last 30 lines of console.log ---" >&2
  tail -n 30 "${BUILD_DIR}/console.log" 2>/dev/null >&2 || true
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  exit 1
fi

echo "[start] OpenWrt 25.12.6 VM is READY!"
echo "SSH access: ${SCRIPT_DIR}/ssh.sh"
echo "Direct SSH: ssh -i ${KEY_FILE} -p ${PORT} root@127.0.0.1"
echo "Serial log: ${BUILD_DIR}/console.log"
