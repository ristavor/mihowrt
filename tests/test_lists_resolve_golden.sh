#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh lists.sh
setup_runtime_paths "$tmpdir"
POLICY_CACHE_DIR="$tmpdir/cache"
mkdir -p "$POLICY_CACHE_DIR"
fixtures="$ROOT_DIR/tests/fixtures/lists"
legacy="$fixtures/legacy-resolver.sh"
assert_true 'frozen pre-L7 resolver exists' test -s "$legacy"
cp "$fixtures/remote.txt" "$(lists_cache_file https://lists.example.com/a.txt)"
awk 'BEGIN {
 for (i=0;i<10000;i++) {
  if (i%5 == 0) printf "10.%d.%d.1/32;443\n", int(i/256)%256, i%256
  if (i%5 == 1) printf "2001:db8::%x/128;53,8000-8080\n", i
  if (i%5 == 2) printf "AA:BB:CC:DD:%02X:%02X\n", int(i/256)%256, i%256
  if (i%5 == 3) printf ";%d\n", i+1
  if (i%5 == 4) printf "invalid-%d\n", i
 }
}' >"$tmpdir/10000.txt"

# All list fixtures (including shipped defaults) in every family context;
# every existing provider-profile fixture in each selectable source mode.
for dialect in gawk busybox; do
 (
  awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
  warn() { :; } # Diagnostics deliberately bounded by L7, not part of file parity.
  compare_resolvers() {
   local kind="$1" implementation output
   for implementation in legacy current; do
    (
     if [ "$implementation" = legacy ]; then
      # shellcheck source=tests/fixtures/lists/legacy-resolver.sh
      source "$legacy"
     fi
     lists_resolve "$kind" "$tmpdir/$implementation.4" "$tmpdir/$implementation.6" "$tmpdir/$implementation.mac" >"$tmpdir/$implementation.stdout"
    )
   done
   for output in 4 6 mac stdout; do
    assert_true "$dialect/$label/$kind byte-identical $output" cmp -s "$tmpdir/legacy.$output" "$tmpdir/current.$output"
   done
  }
  for src in "$fixtures"/*.txt "$ROOT_DIR"/rootfs/opt/clash/lst/*.txt "$tmpdir/10000.txt"; do
   lists_source() { lists_clean_lines "$src"; }
   label="${src##*/}"
   for kind in dst src direct direct_src; do compare_resolvers "$kind"; done
  done
  # Restore the real source selector for provider/merge/own coverage.
  load_modules lists.sh
  DST_LIST_FILE="$fixtures/mixed.txt"
  DIRECT_DST_LIST_FILE="$fixtures/edges.txt"
  for PROFILE_FILE in "$ROOT_DIR"/tests/fixtures/generator/*.profile; do
   for DST_LIST_SOURCE in provider merge own; do
    DIRECT_LIST_SOURCE="$DST_LIST_SOURCE"
    label="${PROFILE_FILE##*/}/$DST_LIST_SOURCE"
    for kind in dst direct; do compare_resolvers "$kind"; done
   done
  done
  pass "$dialect resolver matches frozen baseline on all list and provider fixtures plus 10000 mixed lines"

  # Container wall/user/sys time of exactly the same generated 10000 lines.
  lists_source() { lists_clean_lines "$tmpdir/10000.txt"; }
  for implementation in legacy current; do
   (
    if [ "$implementation" = legacy ]; then
     # shellcheck source=tests/fixtures/lists/legacy-resolver.sh
     source "$legacy"
    fi
    TIMEFORMAT="$dialect/$implementation 10000 lines: %3R real %3U user %3S sys"
    time lists_resolve src "$tmpdir/timing.4" "$tmpdir/timing.6" "$tmpdir/timing.mac"
   )
  done
 )
done
