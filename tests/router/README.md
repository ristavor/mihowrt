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

## OpenWrt 24.10 guest (opkg)

`ROUTER_OPENWRT=24.10 ./tests/router/start.sh` boots the official OpenWrt 24.10.8 x86/64 kernel and ext4 rootfs (kernel 6.6, opkg, fw4) with the same harness and image `mihowrt-openwrt-test:24.10`; the default stays 25.12.6 (`ROUTER_OPENWRT=25.12`). Artifact names and SHA256 values live in `tests/router/release.sh`; the VM container name is shared, so only one guest runs at a time.

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

# Synthetic client-IPv6 / coexistence acceptance (guest-only, no real peers)
./tests/router/run-network.sh

# Direct serial console diagnostics
./tests/router/serial-cmd.sh "ip -o addr; ps"

# Stop and remove test container
./tests/router/stop.sh

# Automated TAP test harness
MIHOWRT_ROUTER_TESTS=1 ./tests/test_router_harness.sh
```

## Network acceptance (`run-network.sh`)

`./tests/router/run-network.sh` is the repeatable synthetic network acceptance for the direct-first client IPv6 bypass ban and its coexistence with local IPv6, IPv4, the Mihomo core, NetBird marks, routes and DNS. It exits 0 only when all thirteen required rows (`nft syntax`, `control reachable`, `client IPv6 rejected`, `local and IPv4 retained`, `core and other ingress retained`, `NetBird synthetic`, `routes and DNS boundaries`, `local names`, `fake-IP direct devices`, `lifecycle`, `port forward and WAN service replies`, `IPv6 disabled`, `policy rule precedence`) PASS and guest restoration PASS; a missing prerequisite or transport is exit 1, never PASS.

- **Prerequisites**: the VM from `./tests/router/start.sh` with the development APKs and Mihomo installed (`./tests/router/run-smoke.sh --integration --watchdog`), and guest tools `ip` (netns, veth), `nft`, `tcpdump`, `curl`, `dnsmasq`, `uhttpd`, `odhcp6c`, `odhcpd`, `jq`, `hexdump`, `nc` (BusyBox), `socat` (UDP probes), `netstat`, `kmod-veth`. Nothing is installed implicitly.
- **Isolation**: the host entry pins `ROUTER_HOST=127.0.0.1`, `ROUTER_SSH_FORCE_DOCKER=1` and the `mihowrt-openwrt-test` container; it refuses anything that is not the QEMU guest (MAC `52:54:00:12:34:01`). Clients, local peer, WAN and NetBird endpoints are veth/namespaces (`m22-*`, `m22*`, `wt0`) inside the VM, with a second Mihomo process as the synthetic SOCKS5 node.
- **Guest mutation and cleanup**: `/tmp/mihowrt-network-test` (owner file, refused if it exists) holds the fixtures; UCI (`mihowrt`, `dhcp`, `firewall`, `network`), the YAML/backup, policy lists and service state are snapshotted and restored through the config API; only tracked PIDs, namespaces and links are removed. The cleanup trap ignores SIGINT/SIGTERM/SIGHUP, and the guest runs detached from SSH, so a host disconnect still restores. Offloaded flows are not flushed (no global conntrack flush).
- **Report**: `.build/verification-0110/network/REPORT.md`, with per-run logs, expected/actual/exit status, kernel, rule/route snapshots and pcaps under `.build/verification-0110/network/run.*`.
- **Not tested** (reported as NOT TESTED, never PASS): real NetBird peers/STUN/DERP, hardware/previously offloaded flows, Telegram IPv4 fallback.
- `NETWORK_ROWS="row,row"` selects rows for development; a filtered run cannot exit 0.

The stable-review rows add:

| Row | Proof |
|---|---|
| `port forward and WAN service replies` | fw4 DNAT to a LAN host and a router WAN listener, TCP/UDP in both policy modes; marked-reply counters stay zero and conntrack tuples show real replies. Removing each reply guard breaks a fresh TCP control. Probe ports must be free; tracked, non-forking listeners receive TERM then KILL if needed. |
| `IPv6 disabled` | Guest-only `all.disable_ipv6=1`: service starts, IPv4 reaches TPROXY, IPv6 rules/routes are unchanged and no IPv6 path can set the intercept mark or reach TPROXY. Inert inet ip6 sets/guards may remain. The original sysctls, addresses and routes are restored even after failure; restarting proves IPv6 interception returns. |
| `policy rule precedence` | Synthetic NetBird priorities 105/110 and mwan3 mask `0x3f00/0x3f00` at 2001 exist before start. The allocated priority is 50–99, dual-stack marked flows reach TPROXY with mwan3 bits intact, foreign rules survive, and stored priority-1000 rules/routes disappear. Existing NetBird and route/DNS rows continue covering producer order, reconnect, marks and occupied slots. |

## Known Limitations

- **No Hardware Offload**: Software QEMU TCG cannot validate hardware flow offloading (NSS, PPE, WED).
- **No Real P2P Traversal**: User-mode NAT (SLIRP) cannot test real STUN/DERP peer-to-peer punching across external carrier NATs.
- **CPU Throughput**: Emulated TCG CPU is meant for configuration, packaging, and policy validation, not raw multi-gigabit throughput benchmarking.
- **Safety**: Test policies avoid contacting real NetBird accounts or modifying host network interfaces.
