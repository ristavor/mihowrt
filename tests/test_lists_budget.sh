#!/usr/bin/env bash
set -euo pipefail
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
mkdir -p "$POLICY_CACHE_DIR"
awk 'BEGIN { for (i=0;i<131072;i++) print "9.9.9.9" }' >"$tmpdir/full"
head -c 1048560 "$tmpdir/full" >"$tmpdir/old-eighth"
printf '1.1.1.1\n' >"$tmpdir/old-ninth"
printf '8.8.8.8\n9.9.9.9\n' >"$tmpdir/new-ninth"
for n in {1..9}; do
 url="https://budget.example/$n"
 printf '%s\n' "$url" >>"$DST_LIST_FILE"
 case "$n" in
 8) content=old-eighth ;;
 9) content=old-ninth ;;
 *) content=full ;;
 esac
 cp "$tmpdir/$content" "$(lists_cache_file "$url")"
done
# Start at 8 MiB - 8 bytes. Replacing URL 8 adds 8 bytes, exactly the cap;
# URL 9 then attempts another 8 bytes. Each individual response is <= 1 MiB.
head -c 1048568 "$tmpdir/full" >"$tmpdir/new-eighth"
http_fetch() {
 case "$1" in
 */8) cp "$tmpdir/new-eighth" "$2" ;;
 */9) cp "$tmpdir/new-ninth" "$2" ;;
 *) cp "$tmpdir/full" "$2" ;;
 esac
}
eighth="$(lists_cache_file https://budget.example/8)"
ninth="$(lists_cache_file https://budget.example/9)"
rc=0
lists_update_remote 1 >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'over-total-budget refresh returns failure'
assert_eq changed "$(cat "$tmpdir/out")" 'partial success still reports changed'
assert_true 'replacement up to exact total cap accepted' cmp -s "$tmpdir/new-eighth" "$eighth"
assert_true 'over-cap replacement preserves old cache' cmp -s "$tmpdir/old-ninth" "$ninth"
assert_eq 'Error: Failed to update 1 of 9 remote lists: Remote lists exceed 8 MiB in total' "$(cat "$tmpdir/err")" 'budget rejection participates in partial failure count'
assert_false 'rejected cache has no successful check stamp' test -f "$(lists_stamp_file "$ninth")"
assert_eq 8388608 "$(find "$POLICY_CACHE_DIR" -name '*.txt' -exec wc -c {} + | awk '$2 != "total" {n += $1} END {print n}')" 'cache total never exceeds 8 MiB'
assert_eq 8388608 "$LISTS_CACHE_MAX_TOTAL" 'shared total cache cap'
pass 'total cache cap rejects growth, preserves old cache and counts partial failure'

# A smaller replacement releases its old bytes for later URLs in the same run.
printf '9.9.9.9\n' >"$tmpdir/new-eighth"
lists_update_remote 1 >"$tmpdir/out" 2>"$tmpdir/err"
assert_eq changed "$(cat "$tmpdir/out")" 'under-cap replacements change caches'
assert_eq '' "$(cat "$tmpdir/err")" 'under-cap refresh has no errors'
assert_true 'shrinking cache releases space for next URL' cmp -s "$tmpdir/new-ninth" "$ninth"
pass 'under-cap refresh accounts for replaced cache bytes'

# A failed publication must not consume budget for the next URL.
(
 for n in {1..7}; do cp "$tmpdir/full" "$(lists_cache_file "https://budget.example/$n")"; done
 head -c 1048552 "$tmpdir/full" >"$eighth"
 cp "$tmpdir/old-ninth" "$ninth"
 head -c 1048568 "$tmpdir/full" >"$tmpdir/new-eighth"
 eval "$(declare -f atomic_copy | sed '1s/atomic_copy/original_atomic_copy/')"
 atomic_copy() { [ "$2" != "$eighth" ] && original_atomic_copy "$@"; }
 assert_false 'publication failure returns failure' lists_update_remote 1 >"$tmpdir/out" 2>"$tmpdir/err"
 assert_true 'next URL still fits after failed publication' cmp -s "$tmpdir/new-ninth" "$ninth"
 assert_eq 'Error: Failed to update 1 of 9 remote lists: Remote list cache write failed: budget.example' "$(cat "$tmpdir/err")" 'only publication failed, not budget'
)
pass 'failed publication does not consume total budget'

# Changing URLs must reclaim stale caches before enforcing the budget.
rm -f "$POLICY_CACHE_DIR"/*.txt
for n in {1..8}; do cp "$tmpdir/full" "$POLICY_CACHE_DIR/stale$n.txt"; done
printf 'https://budget.example/new\n' >"$DST_LIST_FILE"
lists_update_remote 1 >"$tmpdir/out" 2>"$tmpdir/err"
assert_eq changed "$(cat "$tmpdir/out")" 'new URL fits after stale cache GC'
assert_false 'stale cache removed' test -e "$POLICY_CACHE_DIR/stale1.txt"
assert_true 'new cache published' cmp -s "$tmpdir/full" "$(lists_cache_file https://budget.example/new)"
pass 'URL change reclaims full stale cache before budget check'
