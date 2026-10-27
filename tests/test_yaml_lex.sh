#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
lex="$MIHOWRT_LIB_DIR/yaml-lex.awk"
assert_true 'shared YAML lexer exists' test -s "$lex"
# Extract only the diagnostics program, leaving the shell/module untouched.
sed -n '/^[[:space:]]*function report_port(value)/,/^AWK$/p' \
 "$MIHOWRT_LIB_DIR/status.sh" | sed '$d' >"$tmpdir/ports.awk"

for dialect in gawk busybox; do
 (
 awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
 compare_ports() {
  awk -f "$ROOT_DIR/tests/fixtures/diagnostics/legacy-ports.awk" "$1" >"$tmpdir/old"
  awk -f "$lex" -f "$tmpdir/ports.awk" "$1" >"$tmpdir/new"
  assert_true "$dialect/$1 byte-identical diagnostics ports" cmp -s "$tmpdir/old" "$tmpdir/new"
 }
 for src in "$ROOT_DIR"/tests/fixtures/generator/*.yaml \
            "$ROOT_DIR"/tests/fixtures/yaml-forms/*.yaml \
            "$ROOT_DIR/rootfs/opt/clash/config.yaml"; do
  compare_ports "$src"
 done
 # Diagnostics historically trims quote/space edges more loosely than the
 # renderer, and treats an immediate # differently from a spaced comment.
 for auth in '' 'authentication: []' 'authentication: # comment' \
             'authentication: null # comment' '"authentication": ["u:p"]'; do
  for value in '"07900" # comment' "' 7900 '" '""7900"' '# comment'; do
   {
    printf 'mixed-port: %s\n%s\n' "$value" "$auth"
    printf 'listeners:\n  - type: " mixed "\n    port: %s\n    users: []\n' "$value"
   } >"$tmpdir/edge.yaml"
   compare_ports "$tmpdir/edge.yaml"
  done
 done
 printf 'mixed-port: 7900\nlisteners: # comment\n  - type: http\n    port: 7901\n' >"$tmpdir/edge.yaml"
 compare_ports "$tmpdir/edge.yaml"
 pass "$dialect shared YAML lexer preserves diagnostics fixture and edge-case bytes"
 )
done
