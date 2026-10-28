#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh fetch.sh core.sh
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/kernel"
CLASH_BIN="$tmpdir/clash"
core_arch() { echo arm64; }
settings_load() { :; }
core_free_kb() { echo 1000000; }
warn() { printf '%s\n' "$*" >&2; }
printf '#!/bin/sh\necho "Mihomo v1.2.3"\n' >"$tmpdir/new-core"
gzip -c "$tmpdir/new-core" >"$tmpdir/asset.gz"
jq -nc --arg s "$(wc -c <"$tmpdir/asset.gz" | tr -d ' ')" \
 '{tag_name: "v1.2.3", assets: [{name: "mihomo-linux-arm64-v1.2.3.gz", browser_download_url: "https://example.com/core.gz", size: ($s | tonumber)}]}' >"$tmpdir/release.json"
curl() {
 local out='' headers='' url=''
 printf '%s\n' "$*" >>"$tmpdir/curl.log"
 while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -D) headers="$2"; shift ;; esac
  url="$1"
  shift
 done
 case "$url" in
 *api.github.com*)
  [ "$fallback" = 0 ] || return 7
  cp "$tmpdir/release.json" "$out"
  ;;
 */releases/latest) printf 'https://github.com/MetaCubeX/mihomo/releases/tag/v1.2.3'; return ;;
 *) cp "$tmpdir/asset.gz" "$out" ;;
 esac
 printf 'HTTP/1.1 200 OK\r\n' >"$headers"
}
for fallback in 0 1; do
 rm -f "$CLASH_BIN" "$CORE_VERSION_CACHE"
 : >"$tmpdir/curl.log"
 result="$(core_update_json 2>"$tmpdir/warnings")" || fail "asset fetch succeeds: $result"
 assert_eq false "$(jq -r .verified <<<"$result")" "missing digest is unverified (fallback=$fallback)"
 if [ "$fallback" = 1 ]; then
  assert_file_contains "$tmpdir/warnings" 'release has no sha256 digest; size not checked' 'fallback warning never claims a size check'
 else
  assert_file_contains "$tmpdir/warnings" 'release has no sha256 digest; size check only' 'API size-only warning'
 fi
 api_args="$(grep api.github.com "$tmpdir/curl.log")"
 [[ "$api_args" == *'--max-time 30'* ]] || fail 'release metadata retains fixed timeout'
 asset_args="$(grep -E 'example.com/core.gz|releases/download/' "$tmpdir/curl.log")"
 [[ "$asset_args" == *'--speed-limit 2048 --speed-time 60 --retry 2'* ]] || fail "core asset uses stall timeout and retry: $asset_args"
 [[ "$asset_args" != *'--max-time'* ]] || fail 'core asset has no fixed total timeout'
 pass "core asset curl options (fallback=$fallback)"
done
