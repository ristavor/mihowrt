#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backend="$tmpdir/backend"
cat >"$backend" <<'B'
#!/bin/sh
echo "backend $*"
B
chmod +x "$backend"
read_cli="$ROOT_DIR/rootfs/usr/bin/mihowrt-read"

assert_eq "backend status-json" "$(MIHOWRT_BACKEND="$backend" sh "$read_cli" status-json)" "read command passes"
assert_eq "backend read-config /tmp/mihowrt-config.abc" "$(MIHOWRT_BACKEND="$backend" sh "$read_cli" read-config /tmp/mihowrt-config.abc)" "temp config read"
for bad in "select-proxy a b" "save-config /tmp/x" "read-config /etc/hosts" "status-json extra" "core-update"; do
	# shellcheck disable=SC2086
	if MIHOWRT_BACKEND="$backend" sh "$read_cli" $bad >/dev/null 2>&1; then
		fail "read wrapper must reject: $bad"
	fi
done
pass "read wrapper rejects writes"

out="$(sh "$ROOT_DIR/rootfs/usr/bin/mihowrt" bogus 2>&1 || true)"
[[ "$out" == *"Usage: mihowrt"* ]] || fail "usage on unknown command: $out"
pass "cli usage"
