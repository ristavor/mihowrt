#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh lists.sh
setup_runtime_paths "$tmpdir"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
lists_ensure_files
printf '1.1.1.1\n2001:db8::1\nAA:BB:CC:DD:EE:FF\n;53\n' >"$SRC_LIST_FILE"
for n in {1..30}; do printf 'bad-%02d\n' "$n" >>"$SRC_LIST_FILE"; done
failures=0

(
 eval "$(declare -f lists_classify | sed '1s/lists_classify/original_lists_classify/')"
 lists_classify() { echo classify >>"$tmpdir/classify-calls"; original_lists_classify "$@"; }
 lists_resolve src "$tmpdir/v4" "$tmpdir/v6" "$tmpdir/mac"
 assert_eq 1 "$(wc -l <"$tmpdir/classify-calls" | tr -d ' ')" 'resolver classifies local lines once'
 assert_eq $'1.1.1.1\n;53' "$(cat "$tmpdir/v4")" 'one pass writes IPv4 and any entries'
 assert_eq $'2001:db8::1\n;53' "$(cat "$tmpdir/v6")" 'one pass writes IPv6 and any entries'
 assert_eq aa:bb:cc:dd:ee:ff "$(cat "$tmpdir/mac")" 'one pass writes normalized MACs'
 pass 'resolver uses one classifying pass for all family outputs'
) || failures=$((failures + 1))

(
 warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }
 lists_resolve src "$tmpdir/v4" "$tmpdir/v6" "$tmpdir/mac"
 assert_file_contains "$tmpdir/warnings" bad-20 'diagnostics include first 20 bad lines'
 assert_file_not_contains "$tmpdir/warnings" bad-21 'diagnostics exclude bad lines after first 20'
 assert_file_contains "$tmpdir/warnings" '30 total' 'diagnostics report the full invalid count'
 assert_eq '' "$(find "$PKG_TMP_DIR" -name 'list.*')" 'resolver removes source and diagnostics scratch files'
 pass 'resolver warnings are bounded and include total bad count'
) || failures=$((failures + 1))

# The classifying pass itself writes only 20 samples plus the count, in both awks.
for dialect in gawk busybox; do
 (
  awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
  lists_classify 0 src "$tmpdir/c4" "$tmpdir/c6" "$tmpdir/cmac" "$tmpdir/bad" <"$SRC_LIST_FILE" >"$tmpdir/stdout"
  assert_true "$dialect classifier writes a diagnostics file" test -f "$tmpdir/bad"
  assert_eq 21 "$(wc -l <"$tmpdir/bad" | tr -d ' ')" "$dialect diagnostics contain only count and 20 samples"
  assert_eq 30 "$(head -n 1 "$tmpdir/bad")" "$dialect diagnostics count all bad lines"
  assert_eq '' "$(cat "$tmpdir/stdout")" "$dialect file-output mode has no stdout"
  pass "$dialect classifier writes bounded diagnostics with per-family output"
 ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures resolver checks failed"
