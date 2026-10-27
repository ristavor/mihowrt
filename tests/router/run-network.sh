#!/usr/bin/env bash
# Host transport only. All fixture traffic and mutations run inside QEMU.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVIDENCE="${PROJECT_ROOT}/.build/verification-0110/network"
mkdir -p "$EVIDENCE"
RUN="$(mktemp -d "${EVIDENCE}/run.XXXXXX")"
WORK=/tmp/mihowrt-network-test
GUEST_TIMEOUT="${NETWORK_TIMEOUT:-7200}"
case "$GUEST_TIMEOUT" in ''|*[!0-9]*) echo "NETWORK_TIMEOUT must be whole seconds." >&2; exit 1 ;; esac
owned=0
result=1

VM() {
  ROUTER_HOST=127.0.0.1 ROUTER_SSH_FORCE_DOCKER=1 ROUTER_CONTAINER=mihowrt-openwrt-test \
    "${SCRIPT_DIR}/ssh.sh" "$@"
}

report() {
  local row state actual
  {
    printf '# VM network acceptance\n\n'
    printf 'Run: `%s`\n\n' "${RUN#"$PROJECT_ROOT/"}"
    printf 'Transport: fixed Docker QEMU container, loopback SSH only. Exit: **%s**.\n\n' "$result"
    printf '| Required synthetic row | Result | Expected / actual / exit evidence |\n|---|---|---|\n'
    for row in 'nft syntax' 'control reachable' 'client IPv6 rejected' 'local and IPv4 retained' \
      'core and other ingress retained' 'NetBird synthetic' 'routes and DNS boundaries' 'local names' 'fake-IP direct devices' 'lifecycle' \
      'port forward and WAN service replies' 'IPv6 disabled'; do
      state='NOT TESTED'; actual='Not reached; see host.log / guest.log.'
      if [[ -f "$RUN/results.tsv" ]]; then
        state="$(awk -F '\t' -v row="$row" '$1 == row {print $2}' "$RUN/results.tsv")"
        actual="$(awk -F '\t' -v row="$row" '$1 == row {print $3}' "$RUN/results.tsv")"
        state="${state:-NOT TESTED}"
      fi
      printf '| %s | %s | %s |\n' "$row" "$state" "$actual"
    done
    printf '\nCleanup: `%s`. Prerequisite/transport failures are blocking, never synthetic PASS.\n' \
      "$(cat "$RUN/cleanup.status" 2>/dev/null || printf 'not reached')"
    printf '\n## Explicit exclusions\n\n'
    printf '| Row | Result | Reason |\n|---|---|---|\n'
    printf '| Real NetBird peers / STUN / DERP / reconnect across NAT | NOT TESTED | No accounts or real peers. Synthetic marks are not a transport proof. |\n'
    printf '| Hardware / previously offloaded flows | NOT TESTED | QEMU; fresh flows only, no global conntrack flush or offloading changes. |\n'
    printf '| Telegram IPv4 fallback | NOT TESTED | Exact IPv6 refusal does not prove application fallback. |\n'
    printf '\nFull commands, expected/actual/exit status, kernel, rule/route snapshots and pcaps: `%s`.\n' "${RUN#"$PROJECT_ROOT/"}"
  } >"$EVIDENCE/REPORT.md"
}

finish() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ "$owned" == 1 ]]; then
    # On interruption, ask only our tracked guest shell to run its restoration trap.
    if ! VM "if test -f '$WORK/guest.pid'; then pid=\$(cat '$WORK/guest.pid'); case \$pid in ''|*[!0-9]*) exit 1;; esac; grep -q '$WORK/network-guest.sh' /proc/\$pid/cmdline || exit 1; kill -TERM \$pid; for attempt in \$(seq 1 120); do test ! -e '$WORK/guest.pid' && exit 0; sleep 1; done; exit 1; fi" >>"$RUN/host.log" 2>&1; then
      result=1
    fi
    # Archive only evidence, not the saved user YAML/UCI (which may contain secrets).
    if ! VM "tar -C '$WORK' -cf - logs results.tsv cleanup.status" >"$RUN/guest-evidence.tar" 2>>"$RUN/host.log"; then
      result=1
    elif ! tar -xf "$RUN/guest-evidence.tar" -C "$RUN"; then
      result=1
    fi
    if [[ -f "$RUN/cleanup.status" && "$(cat "$RUN/cleanup.status")" == PASS ]]; then
      if ! VM "test ! -e '$WORK/guest.pid' && test \"\$(cat '$WORK/.owner')\" = mihowrt-task-22 && rm -rf '$WORK'" >>"$RUN/host.log" 2>&1; then
        result=1
      fi
    else
      echo "Restoration incomplete; preserve $WORK for recovery (or discard the VM)." >>"$RUN/host.log"
      result=1
    fi
  fi
  [[ "$exit_status" == 0 ]] || result=1
  report
  cat "$EVIDENCE/REPORT.md"
  exit "$result"
}
trap finish EXIT
trap 'exit 1' INT TERM

rows="${NETWORK_ROWS:-all}"
case "$rows" in *[!A-Za-z0-9,\ -]*) echo 'NETWORK_ROWS accepts only row names separated by commas.' >>"$RUN/host.log"; exit 1 ;; esac
# Refuse a stopped/misidentified harness; never start a VM or install packages implicitly.
if ! docker exec mihowrt-openwrt-test sh -c 'test "$(readlink /proc/1/exe)" = /usr/bin/qemu-system-x86_64' >"$RUN/host.log" 2>&1; then
  echo 'Disposable QEMU harness prerequisite unavailable.' >>"$RUN/host.log"
  exit 1
fi
VM 'ubus call system board; uname -r; test "$(cat /sys/class/net/eth0/address)" = 52:54:00:12:34:01; ubus call system board | grep -q QEMU' >>"$RUN/host.log" 2>&1
VM "test ! -e '$WORK' && test ! -L '$WORK' && mkdir -m 700 '$WORK' && echo mihowrt-task-22 > '$WORK/.owner'" >>"$RUN/host.log" 2>&1
owned=1
VM "cat > '$WORK/network-guest.sh'" <"$SCRIPT_DIR/network-guest.sh"
# Run the guest detached from the SSH session so a host disconnect cannot skip its restoration trap.
VM "cat > '$WORK/run-guest.sh'" >>"$RUN/host.log" 2>&1 <<EOF
sh '$WORK/network-guest.sh' >'$WORK/guest.log' 2>&1 </dev/null
echo \$? >'$WORK/guest.exit'
EOF
VM "cd '$WORK' && NETWORK_ROWS='$rows' setsid sh '$WORK/run-guest.sh' >/dev/null 2>&1 </dev/null &" >>"$RUN/host.log" 2>&1
guest_exit=''
for ((poll = 0; poll < GUEST_TIMEOUT / 5; poll++)); do
  sleep 5
  guest_exit="$(VM "cat '$WORK/guest.exit' 2>/dev/null" 2>>"$RUN/host.log" || true)"
  [[ -z "$guest_exit" ]] || break
done
VM "cat '$WORK/guest.log'" >"$RUN/guest.log" 2>>"$RUN/host.log" || true
if [[ "$guest_exit" == 0 ]]; then
  result=0
else
  echo "Guest exit status: ${guest_exit:-timeout}" >>"$RUN/host.log"
fi
# A successful SSH alone is insufficient: require all twelve rows and clean restoration.
VM "test \"\$(grep -c 'PASS' '$WORK/results.tsv')\" = 12 && test \"\$(cat '$WORK/cleanup.status')\" = PASS" >>"$RUN/host.log" 2>&1 || result=1
exit "$result"
