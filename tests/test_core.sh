#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh fetch.sh subscription.sh core.sh
setup_runtime_paths "$tmpdir"

PKG_TMP_DIR="$tmpdir/tmp"
CORE_TMP_DIR="$tmpdir/tmp/kernel"
CLASH_DIR="$tmpdir/clash"
CLASH_BIN="$CLASH_DIR/bin/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
mkdir -p "$CLASH_DIR/bin"
printf '#!/bin/sh\necho "Mihomo Meta v1.19.30 linux"\n' >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
echo "mode: rule" >"$CLASH_CONFIG"
core_arch() { echo arm64; }

# New core: prints its version; rejects configs when NEW_CORE_REJECTS=1.
new_core="$tmpdir/new-core"
cat >"$new_core" <<'N'
#!/bin/sh
case "$1" in -v) echo "Mihomo Meta v1.19.32 linux"; exit 0 ;; esac
[ "${NEW_CORE_REJECTS:-0}" = 1 ] && { echo "level=error msg=bad"; exit 1; }
exit 0
N
gzip -c "$new_core" >"$tmpdir/asset.gz"
asset_sha="$(sha256sum "$tmpdir/asset.gz" | cut -d' ' -f1)"
asset_size="$(wc -c <"$tmpdir/asset.gz" | tr -d ' ')"
asset_digest="sha256:$asset_sha"

http_fetch() {
	case "$1" in
	*api.github.com*)
		jq -nc --arg d "$asset_digest" --arg s "$asset_size" \
			'{tag_name: "v1.19.32", assets: [{name: "mihomo-linux-arm64-v1.19.32.gz", browser_download_url: "https://x/a.gz", digest: $d, size: ($s | tonumber)}]}' >"$2"
		;;
	*) cp "$tmpdir/asset.gz" "$2" ;;
	esac
}
free_kb=1000000
core_free_kb() { echo "$free_kb"; }

free_kb=10
if core_update 2>/dev/null; then fail "low space must fail"; fi
[[ "$CORE_ERROR" == "not enough flash"* ]] || fail "space error: $CORE_ERROR"
[[ ! -e "$CLASH_BIN.new" ]] || fail "no partial binary left"
assert_eq "v1.19.30" "$(core_version)" "old core kept"
pass "insufficient space"

free_kb=1000000
if NEW_CORE_REJECTS=1 core_update 2>/dev/null; then fail "config rejection must fail"; fi
assert_eq "v1.19.30" "$(core_version)" "old core kept when new rejects config"
pass "bad binary keeps old"

asset_digest="sha256:$(printf '0%.0s' {1..64})"
if core_update 2>/dev/null; then fail "digest mismatch must fail"; fi
assert_eq "sha256 mismatch" "$CORE_ERROR" "digest error"
asset_digest="sha256:$asset_sha"
pass "digest mismatch"

core_update || fail "update must succeed"
assert_eq "1:v1.19.32" "$CORE_UPDATED:$(core_version)" "core replaced"
core_update
assert_eq 0 "$CORE_UPDATED" "same version is a no-op"
assert_eq '{"updated":false,"version":"v1.19.32","error":null}' "$(core_update_json)" "json result"
pass "core update"

# GitHub API unreachable (or rate-limited): tag from the github.com redirect,
# asset from the direct download URL.
printf '#!/bin/sh\necho "Mihomo Meta v1.19.30 linux"\n' >"$CLASH_BIN"
fetched=""
http_fetch() {
	fetched="$fetched $1"
	case "$1" in
	*api.github.com*) FETCH_ERROR=network; return 1 ;;
	*/releases/download/v1.19.32/mihomo-linux-arm64-v1.19.32.gz) cp "$tmpdir/asset.gz" "$2" ;;
	*) FETCH_ERROR=http_404; return 1 ;;
	esac
}
curl() { case "$*" in *redirect_url*github.com/MetaCubeX/mihomo/releases/latest*) printf 'https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32' ;; *) return 1 ;; esac; }
core_update 2>/dev/null || fail "fallback update must succeed: $CORE_ERROR"
assert_eq "1:v1.19.32" "$CORE_UPDATED:$(core_version)" "core installed via github.com fallback"
[[ "$fetched" == *"https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-arm64-v1.19.32.gz"* ]] || fail "direct download URL used: $fetched"
pass "github.com fallback without API"
