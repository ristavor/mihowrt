#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
legacy="$ROOT_DIR/tests/fixtures/generator/legacy-renderer.awk"
assert_true 'frozen pre-streaming renderer exists' test -s "$legacy"

# Render every existing YAML fixture, including already-rendered runtimes.
# Compare all observable awk outputs, not only the generated YAML.
for dialect in gawk busybox; do
 (
 awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
 for src in "$ROOT_DIR"/tests/fixtures/generator/*.yaml \
            "$ROOT_DIR"/tests/fixtures/yaml-forms/*.yaml \
            "$ROOT_DIR/rootfs/opt/clash/config.yaml"; do
  for renderer in legacy current current-off; do
   args=(-f "$legacy")
   ui_url=https://example.com/ui.zip
   if [ "$renderer" != legacy ]; then
    args=()
    if [ -f "$MIHOWRT_LIB_DIR/yaml-lex.awk" ]; then args+=(-f "$MIHOWRT_LIB_DIR/yaml-lex.awk"); fi
    args+=(-f "$MIHOWRT_LIB_DIR/mihomo-config.awk")
   fi
   # Dashboard flag 0: the shell passes an empty URL.
   [ "$renderer" != current-off ] || ui_url=
   : >"$tmpdir/$renderer.profile"
   : >"$tmpdir/$renderer.warn"
   rc=0
   MIHOWRT_SECRET=golden-secret awk "${args[@]}" \
    -v drop=' log-level tproxy-port routing-mark allow-lan bind-address tun profile external-controller external-controller-unix external-controller-tls external-controller-pipe external-doh-server external-controller-cors secret external-ui external-ui-url external-ui-name x-mihowrt ' \
    -v dnsdrop=' enable listen fake-ip-range fake-ip-range6 ' \
    -v dns_port=7874 -v fakeip=198.18.0.0/16 -v tproxy=7894 -v direct_tproxy=7895 \
    -v mark=255 -v api=192.0.2.1:9090 -v sock=/tmp/mihomo.sock \
    -v ui_url="$ui_url" \
    -v profile="$tmpdir/$renderer.profile" -v warnfile="$tmpdir/$renderer.warn" \
    "$src" >"$tmpdir/$renderer.yaml" || rc=$?
   printf '%s\n' "$rc" >"$tmpdir/$renderer.rc"
  done
  for output in yaml profile warn rc; do
   assert_true "$dialect/${src#"$ROOT_DIR/"} byte-identical $output" \
    cmp -s "$tmpdir/legacy.$output" "$tmpdir/current.$output"
  done
  grep -v '^external-ui' "$tmpdir/legacy.yaml" >"$tmpdir/legacy-off.yaml" || true
  cp "$tmpdir/legacy.rc" "$tmpdir/legacy-off.rc"
  cp "$tmpdir/legacy.profile" "$tmpdir/legacy-off.profile"
  cp "$tmpdir/legacy.warn" "$tmpdir/legacy-off.warn"
  for output in yaml profile warn rc; do
   assert_true "$dialect/${src#"$ROOT_DIR/"} dashboard off = baseline without external-ui $output" \
    cmp -s "$tmpdir/legacy-off.$output" "$tmpdir/current-off.$output"
  done
 done
 pass "$dialect renderer matches frozen baseline on all 45 YAML fixtures (dashboard on and off)"
 )
done
