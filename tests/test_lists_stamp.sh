#!/usr/bin/env bash
# Remote-list check stamps live on tmpfs: a refresh never writes to flash
# unless the list content changed; after reboot the cache mtime decides.

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
POLICY_CACHE_DIR="$tmpdir/flash/policy-cache"
lists_ensure_files
mkdir -p "$POLICY_CACHE_DIR"

url=https://stamp.example/list
printf '%s\n' "$url" >"$DST_LIST_FILE"
cache="$(lists_cache_file "$url")"
stamp="$PKG_STATE_DIR/lists-stamp/$(lists_url_key "$url")"
LISTS_INTERVAL=1
http_fetch() {
 echo fetch >>"$tmpdir/fetches"
 printf '9.9.9.9\n' >"$2"
}
fetches() { wc -l <"$tmpdir/fetches" | tr -d ' '; }
: >"$tmpdir/fetches"
age() { touch -d "@$(($(date +%s) - $2))" "$1"; }

# Unchanged content: no write at all under the flash dir; the stamp records the check.
printf '9.9.9.9\n' >"$cache"
age "$cache" 7200
before="$(stat -c '%Y' "$cache")"
dir_before="$(stat -c '%Y' "$POLICY_CACHE_DIR")"
find "$POLICY_CACHE_DIR" -type f >"$tmpdir/files.before"
assert_eq unchanged "$(lists_update_remote 0)" 'stale cache with same content is unchanged'
assert_eq 1 "$(fetches)" 'stale cache fetched'
assert_eq "$before" "$(stat -c '%Y' "$cache")" 'unchanged refresh does not touch the flash cache'
assert_eq "$dir_before" "$(stat -c '%Y' "$POLICY_CACHE_DIR")" 'unchanged refresh does not modify the flash directory'
find "$POLICY_CACHE_DIR" -type f >"$tmpdir/files.after"
assert_true 'unchanged refresh adds no flash file' cmp -s "$tmpdir/files.before" "$tmpdir/files.after"
assert_true 'check stamp written to runtime state' test -f "$stamp"
pass 'unchanged refresh writes only the tmpfs stamp'

# A fresh stamp keeps an old cache from being fetched again.
assert_eq unchanged "$(lists_update_remote 0)" 'stamped list is not due'
assert_eq 1 "$(fetches)" 'fresh stamp skips the fetch'
pass 'fresh stamp decides'

# An old stamp makes a fresh cache due.
age "$stamp" 7200
touch "$cache"
assert_eq unchanged "$(lists_update_remote 0)" 'old stamp refresh'
assert_eq 2 "$(fetches)" 'old stamp triggers a fetch'
lists_update_remote 0 >/dev/null
assert_eq 2 "$(fetches)" 'a new check renews the existing stamp'
pass 'old stamp decides'

# After reboot the stamp is gone: cache mtime is the fallback.
rm -f "$stamp"
touch "$cache"
lists_update_remote 0 >/dev/null
assert_eq 2 "$(fetches)" 'fresh cache mtime without stamp is not due'
age "$cache" 7200
lists_update_remote 0 >/dev/null
assert_eq 3 "$(fetches)" 'old cache mtime without stamp is due'
pass 'cache mtime fallback after reboot'

# Changed content is published to flash and stamped.
rm -f "$stamp"
printf '1.1.1.1\n' >"$cache"
assert_eq changed "$(lists_update_remote 1)" 'forced refresh with new content'
assert_eq 9.9.9.9 "$(cat "$cache")" 'changed content published'
assert_true 'changed refresh stamped' test -f "$stamp"
pass 'changed refresh publishes and stamps'

# Stamps of URLs that left the lists are removed with their cache.
: >"$DST_LIST_FILE"
assert_eq unchanged "$(lists_update_remote 0)" 'no URLs left'
assert_false 'cache of removed URL deleted' test -e "$cache"
assert_false 'stamp of removed URL deleted' test -e "$stamp"
pass 'gc removes stamps'
