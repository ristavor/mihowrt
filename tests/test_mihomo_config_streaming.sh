#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

assert_false 'streaming renderer has no whole-document output/candidate arrays' \
 grep -Eq '(output|candidate)\[' "$MIHOWRT_LIB_DIR/mihomo-config.awk"
pass 'renderer streams without whole-document arrays'

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/collisions.yaml" <<'YAML'
listeners:
 # before first item
 - type: mixed
   name: mihowrt-direct
   users:
     - username: nested
       name: not-the-listener
 # trailing collision comment

 - name: retained
   type: http
   port: 7900
 - name: 'mihowrt-direct'
   type: tproxy
 # trailing last collision comment
rules: [] # normalised header
dns:
  enhanced-mode: fake-ip
YAML
# Invalid forms discovered at the end must not leak even one rendered line.
printf 'rules:\n  - MATCH,DIRECT\ndns: {enable: true}\n' >"$tmpdir/invalid.yaml"
for dialect in gawk busybox; do
 (
 awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
 for source in collisions invalid; do
  for renderer in legacy current; do
   args=(-f "$ROOT_DIR/tests/fixtures/generator/legacy-renderer.awk")
   if [ "$renderer" = current ]; then
    args=()
    if [ -f "$MIHOWRT_LIB_DIR/yaml-lex.awk" ]; then args+=(-f "$MIHOWRT_LIB_DIR/yaml-lex.awk"); fi
    args+=(-f "$MIHOWRT_LIB_DIR/mihomo-config.awk")
   fi
   : >"$tmpdir/$renderer.profile"
   : >"$tmpdir/$renderer.warn"
   rc=0
   awk "${args[@]}" -v direct_tproxy=7895 \
    -v profile="$tmpdir/$renderer.profile" -v warnfile="$tmpdir/$renderer.warn" \
    "$tmpdir/$source.yaml" >"$tmpdir/$renderer.yaml" || rc=$?
   printf '%s\n' "$rc" >"$tmpdir/$renderer.rc"
  done
  for output in yaml profile warn rc; do
   assert_true "$dialect/$source byte-identical $output" \
    cmp -s "$tmpdir/legacy.$output" "$tmpdir/current.$output"
  done
  if [ "$source" = invalid ]; then
   assert_eq 1 "$(cat "$tmpdir/current.rc")" "$dialect late invalid DNS rejected"
   assert_false "$dialect first pass rejects before streaming output" test -s "$tmpdir/current.yaml"
  fi
 done
 pass "$dialect streaming collision ranges and pre-output validation"
 )
done
