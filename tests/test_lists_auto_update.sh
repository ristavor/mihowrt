#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh lists.sh service.sh
setup_runtime_paths "$tmpdir"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
lists_ensure_files
settings_load() { :; }
subscription_due() { return 1; }
LISTS_INTERVAL=1

# Even the refresh stub must not run on a URL-free cron tick.
(
 lists_update_remote() { echo refresh >>"$tmpdir/unexpected"; echo unchanged; }
 lists_cache_gc() { echo gc >>"$tmpdir/unexpected"; }
 http_fetch() { echo fetch >>"$tmpdir/unexpected"; }
 auto_update
 assert_false 'idle auto-update never refreshes, fetches or runs GC' test -e "$tmpdir/unexpected"
 assert_false 'idle auto-update creates no cache directory' test -d "$POLICY_CACHE_DIR"
)
pass 'auto-update skips remote lists entirely without URLs'

# Count across command substitutions and pipelines, using the real refresh/GC.
eval "$(declare -f lists_urls | sed '1s/lists_urls/original_lists_urls/')"
lists_urls() { echo call >>"$tmpdir/url-calls"; original_lists_urls; }
http_fetch() { echo fetch >>"$tmpdir/fetches"; printf '9.9.9.9\n' >"$2"; }
with_lock() { "$@"; }
auto_update_policy() { echo apply >>"$tmpdir/applied"; }
printf 'https://one.example/list\nhttps://one.example/list;443\n' >"$DST_LIST_FILE"
printf 'https://two.example/list\n' >"$SRC_LIST_FILE"
mkdir -p "$POLICY_CACHE_DIR"
stale="$(lists_cache_file https://removed.example/list)"
printf '1.1.1.1\n' >"$stale"
auto_update
assert_eq 1 "$(wc -l <"$tmpdir/url-calls" | tr -d ' ')" 'auto-update computes URL set once, including GC'
assert_eq 2 "$(wc -l <"$tmpdir/fetches" | tr -d ' ')" 'each distinct configured URL fetched once'
assert_eq apply "$(cat "$tmpdir/applied")" 'changed cache applies policy'
assert_false 'GC uses the same URL set' test -e "$stale"
pass 'auto-update reuses one URL set for fetch and GC'

# Standalone refresh also computes once; explicit empty input must not recompute.
: >"$tmpdir/url-calls"
lists_update_remote 1 >/dev/null
assert_eq 1 "$(wc -l <"$tmpdir/url-calls" | tr -d ' ')" 'standalone refresh computes URL set once'
: >"$tmpdir/url-calls"
lists_update_remote 0 '' >/dev/null
assert_false 'explicit empty URL set is reused' test -s "$tmpdir/url-calls"
pass 'standalone refresh reuses its URL set'

: >"$tmpdir/url-calls"
LISTS_INTERVAL=0
auto_update
assert_false 'disabled list interval does not compute URLs' test -s "$tmpdir/url-calls"
pass 'disabled interval skips URL collection'
