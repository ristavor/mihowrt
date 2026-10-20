# OpenWrt 25.12.6 x86_64 VM Test Harness

Isolated OpenWrt 25.12.6 x86/64 test harness running under native arm64 QEMU TCG in Docker on Apple Silicon (Colima). Provides real OpenWrt Linux kernel 6.12, procd init system, nftables fw4, apk package manager, and dropbear SSH.

## Architecture

- **QEMU TCG**: Containerized `qemu-system-x86_64` running native arm64 binary directly on Apple Silicon to eliminate nested emulation overhead.
- **Kernel & Disk**:
  - Kernel: Official `openwrt-25.12.6-x86-64-generic-kernel.bin` (SHA256: `8f70595f3a6eec3112e007450a1a600153904deffa52ab368712342583cb387c`)
  - Rootfs: Official `openwrt-25.12.6-x86-64-generic-ext4-rootfs.img.gz` (SHA256: `8c243392d09b960a9f0edbfd996153bec213435b0034e6b2db9437115c5178ec`)
  - Disposable ext4 disk resized to 1GiB (`truncate`/`resize2fs`).
  - Preseeded ed25519 root public key in `/etc/dropbear/authorized_keys` via `debugfs` (no host loop mounts or root privileges required).
- **Network**:
  - `eth0` (LAN): Bridge `br-lan` at `192.168.1.1/24`, QEMU host at `192.168.1.2`, port forwarding to guest `192.168.1.1:22`.
  - `eth1` (WAN): DHCP `10.0.2.0/24`, default gateway `10.0.2.2`, DNS `10.0.2.3` with live outbound internet access.
  - SSH mapping: `127.0.0.1:2222` (or `ROUTER_PORT=2223` when port 2222 is held by Colima's SSH mux).
- **Persistence**: All downloads, disposable disks, SSH keys, and logs live in git-ignored `.build/router/`.

## Commands

```bash
# Start VM harness (downloads images, pre-seeds key, boots VM, waits for SSH ready)
./tests/router/start.sh

# Check VM status and connectivity
./tests/router/status.sh

# Interactive SSH shell or command runner
./tests/router/ssh.sh
./tests/router/ssh.sh "uname -a; ubus call system board; apk --version"

# Run smoke tests
./tests/router/run-smoke.sh                 # Baseline proof (kernel, ubus, apk, nftables, procd)
./tests/router/run-smoke.sh --integration   # Install dist/*.apk, Mihomo v1.19.32, test service lifecycle, nft syntax, DNS restore

# Direct serial console diagnostics
./tests/router/serial-cmd.sh "ip -o addr; ps"

# Stop and remove test container
./tests/router/stop.sh

# Automated TAP test harness
MIHOWRT_ROUTER_TESTS=1 ./tests/test_router_harness.sh
```

## Known Limitations

- **No Hardware Offload**: Software QEMU TCG cannot validate hardware flow offloading (NSS, PPE, WED).
- **No Real P2P Traversal**: User-mode NAT (SLIRP) cannot test real STUN/DERP peer-to-peer punching across external carrier NATs.
- **CPU Throughput**: Emulated TCG CPU is meant for configuration, packaging, and policy validation, not raw multi-gigabit throughput benchmarking.
- **Safety**: Test policies avoid contacting real NetBird accounts or modifying host network interfaces.
