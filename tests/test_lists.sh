#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh lists.sh

LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
PKG_TMP_DIR="$tmpdir/tmp"
lists_ensure_files

assert_eq 4 "$(list_entry_family 10.0.0.0/8)" "IPv4 CIDR"
assert_eq 6 "$(list_entry_family '2001:db8::/32;443')" "IPv6 with port"
assert_eq any "$(list_entry_family ';53')" "port-only entry"
assert_false "invalid v4" list_entry_family 999.1.1.1
assert_false "invalid v6" list_entry_family 'gggg::'
assert_false "invalid port" list_entry_family '1.1.1.1;70000'
pass "entry families"

cat >"$DST_LIST_FILE" <<'L'
# comment
1.1.1.1
2001:db8::/32;443
;53
999.1.1.1
1.1.1.1
https://lists.example.com/a.txt;80 | 24
L
mkdir -p "$POLICY_CACHE_DIR"
printf '8.8.8.0/24\n2606:4700::1;8443\n' >"$(lists_cache_file https://lists.example.com/a.txt)"

stdout="$(lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null)"
assert_eq "" "$stdout" "resolve writes nothing to stdout (CLI output must stay JSON)"
assert_eq 3 "$(wc -l <"$tmpdir/v4" | tr -d ' ')" "v4 entries deduplicated"
assert_file_contains "$tmpdir/v4" "8.8.8.0/24;80" "remote entry inherits URL ports"
assert_file_contains "$tmpdir/v4" ";53" "port-only entry in v4"
assert_file_contains "$tmpdir/v6" "2001:db8::/32;443" "v6 entry"
assert_file_contains "$tmpdir/v6" "2606:4700::1;8443" "remote v6 keeps own ports"
assert_file_contains "$tmpdir/v6" ";53" "port-only entry in v6"
assert_file_not_contains "$tmpdir/v4" "999.1.1.1" "invalid entry skipped"
pass "mixed families resolved"

http_fetch() {
	FETCH_ERROR=network
	return 1
}
LISTS_INTERVAL=0
assert_eq unchanged "$(lists_update_remote 0)" "cached list not due without interval"
if lists_update_remote 1 >/dev/null 2>&1; then
	fail "forced update with failing fetch must report failure"
fi
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_file_contains "$tmpdir/v4" "8.8.8.0/24;80" "cache used when fetch fails"
pass "remote cache used offline"

http_fetch() {
	printf '9.9.9.9\nnot-an-ip\n' >"$2"
}
assert_eq changed "$(lists_update_remote 1)" "fetched content changes cache"
assert_eq "9.9.9.9" "$(cat "$(lists_cache_file https://lists.example.com/a.txt)")" "cache keeps only valid entries"
assert_eq unchanged "$(lists_update_remote 1)" "same content is unchanged"
pass "remote update"

printf '10.0.0.1\n300.1.1.1\n2001:db8::1;443\n1:2:3:4:5:6::7\nfe80::1/64\n::ffff:1.2.3.4\n;80\nbad\n' >"$DST_LIST_FILE"
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_eq "$(printf ';80\n10.0.0.1\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v4")" "v4 classification"
assert_eq "$(printf '1:2:3:4:5:6::7\n2001:db8::1;443\n;80\nfe80::1/64\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v6")" "v6 classification"
pass "bulk classification"

seq 1 20000 | awk '{ printf "10.%d.%d.0/24\n", int($1/256)%256, $1%256 }' >"$DST_LIST_FILE"
start=$(date +%s)
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ] || fail "20000 entries took ${elapsed}s (one fork per entry?)"
pass "large list resolves fast"
