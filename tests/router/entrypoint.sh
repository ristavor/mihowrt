#!/usr/bin/env bash
set -euo pipefail

ROUTER_DIR="/router"
ROOTFS_GZ="${ROUTER_DIR}/openwrt-25.12.6-x86-64-generic-ext4-rootfs.img.gz"
ROOTFS_IMG="${ROUTER_DIR}/rootfs.img"
KERNEL_BIN="${ROUTER_DIR}/openwrt-25.12.6-x86-64-generic-kernel.bin"
PUBKEY_FILE="${ROUTER_DIR}/id_ed25519.pub"
CONSOLE_LOG="${ROUTER_DIR}/console.log"

if [ ! -f "${ROOTFS_GZ}" ]; then
  echo "Error: Rootfs archive not found: ${ROOTFS_GZ}" >&2
  exit 1
fi

if [ ! -f "${KERNEL_BIN}" ]; then
  echo "Error: Kernel binary not found: ${KERNEL_BIN}" >&2
  exit 1
fi

if [ ! -f "${PUBKEY_FILE}" ]; then
  echo "Error: SSH public key not found: ${PUBKEY_FILE}" >&2
  exit 1
fi

echo "[entrypoint] Preparing disposable ext4 disk (1GiB)..."
rm -f "${ROOTFS_IMG}"
gzip -dc "${ROOTFS_GZ}" > "${ROOTFS_IMG}"
truncate -s 1024M "${ROOTFS_IMG}"
resize2fs "${ROOTFS_IMG}" >/dev/null

echo "[entrypoint] Pre-seeding SSH public key with debugfs..."
debugfs -w -R "mkdir /etc/dropbear" "${ROOTFS_IMG}" 2>/dev/null || true
debugfs -w -R "write ${PUBKEY_FILE} /etc/dropbear/authorized_keys" "${ROOTFS_IMG}" >/dev/null
debugfs -w -R "sif /etc/dropbear/authorized_keys mode 0100600" "${ROOTFS_IMG}" >/dev/null

echo "[entrypoint] Initializing serial log..."
rm -f "${CONSOLE_LOG}"
touch "${CONSOLE_LOG}"

# Tail console log in background so docker logs shows serial output
tail -n 0 -F "${CONSOLE_LOG}" &
TAIL_PID=$!

cleanup() {
  echo "[entrypoint] Cleaning up..."
  kill -9 "${TAIL_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[entrypoint] Launching native arm64 QEMU TCG OpenWrt x86_64 VM..."
exec qemu-system-x86_64 \
  -nodefaults \
  -m 512M \
  -smp 2 \
  -kernel "${KERNEL_BIN}" \
  -append "root=/dev/vda rootwait console=ttyS0 tsc=unstable" \
  -drive "file=${ROOTFS_IMG},format=raw,if=virtio" \
  -netdev "user,id=lan,net=192.168.1.0/24,host=192.168.1.2,hostfwd=tcp:0.0.0.0:2222-192.168.1.1:22" \
  -device "virtio-net-pci,netdev=lan,mac=52:54:00:12:34:01" \
  -netdev "user,id=wan,net=10.0.2.0/24,dhcpstart=10.0.2.15" \
  -device "virtio-net-pci,netdev=wan,mac=52:54:00:12:34:02" \
  -chardev "socket,id=ser0,host=127.0.0.1,port=4444,server=on,wait=off,logfile=${CONSOLE_LOG}" \
  -serial "chardev:ser0" \
  -display none
