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
for bad in "select-proxy a b" "save-config /tmp/x" "read-config /etc/hosts" "status-json extra" "core-update" "profile-json x"; do
	# shellcheck disable=SC2086
	if MIHOWRT_BACKEND="$backend" sh "$read_cli" $bad >/dev/null 2>&1; then
		fail "read wrapper must reject: $bad"
	fi
done
pass "read wrapper rejects writes"

out="$(sh "$ROOT_DIR/rootfs/usr/bin/mihowrt" bogus 2>&1 || true)"
[[ "$out" == *"Usage: mihowrt"* ]] || fail "usage on unknown command: $out"
pass "cli usage"

assert_eq 'backend profile-json' "$(MIHOWRT_BACKEND="$backend" sh "$read_cli" profile-json)" "profile-json read wrapper"
# Execute dispatch with the normal module bootstrap removed, not a duplicated case.
strip_mihowrt_cli_bootstrap >"$tmpdir/cli.sh"
export MIHOWRT_LIB_DIR
for n in 1 2 3 4; do printf '%s\n' "$n" >"$tmpdir/list$n"; done
# The real CLI argument boundary is exercised with a harmless apply stub.
sed -i '/^case "$cmd" in/i lists_apply() { printf "lists:%s:%s:%s:%s\\n" "$1" "$2" "$3" "$4"; }' "$tmpdir/cli.sh"
assert_eq "lists:$tmpdir/list1:$tmpdir/list2:$tmpdir/list3:$tmpdir/list4" "$(sh "$tmpdir/cli.sh" apply-lists "$tmpdir/list1" "$tmpdir/list2" "$tmpdir/list3" "$tmpdir/list4")" "four list CLI args"
assert_false "three lists rejected" sh "$tmpdir/cli.sh" apply-lists a b c >/dev/null 2>&1
