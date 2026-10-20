#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${ROUTER_CONTAINER:-mihowrt-openwrt-test}"
CMD="${*:-}"

if [ -z "${CMD}" ]; then
  # Interactive mode via socat/nc
  exec docker exec -it "${CONTAINER_NAME}" nc 127.0.0.1 4444
else
  # Non-interactive command execution
  # Send carriage return, command, and read response
  docker exec -i "${CONTAINER_NAME}" python3 -c "
import socket, time, sys

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3.0)
try:
    s.connect(('127.0.0.1', 4444))
except Exception as e:
    sys.stderr.write(f'Connection failed: {e}\n')
    sys.exit(1)

# Wake up console
s.sendall(b'\n\n')
time.sleep(0.3)
cmd = sys.argv[1] + '\n'
s.sendall(cmd.encode('utf-8'))
time.sleep(1.0)

s.settimeout(1.5)
out = b''
while True:
    try:
        data = s.recv(4096)
        if not data:
            break
        out += data
    except socket.timeout:
        break

sys.stdout.write(out.decode('utf-8', errors='replace'))
" "${CMD}" 2>/dev/null || docker exec -i "${CONTAINER_NAME}" sh -c "(printf '\n\n'; echo '${CMD}'; sleep 1) | nc -w 2 127.0.0.1 4444"
fi
