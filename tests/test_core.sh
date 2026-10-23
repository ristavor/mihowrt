#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh fetch.sh subscription.sh core.sh
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

# Cache only the installed binary, never a candidate under validation.
printf '#!/bin/sh\necho called >>"%s"\necho "Mihomo v1.19.30"\n' "$tmpdir/version.calls" >"$CLASH_BIN"
assert_eq v1.19.30 "$(core_version)" 'missing cache queries core'
assert_eq v1.19.30 "$(core_version)" 'cache returns version'
assert_eq 1 "$(wc -l <"$tmpdir/version.calls" | tr -d ' ')" 'installed core queried once'
assert_eq v1.19.30 "$(cat "$CORE_VERSION_CACHE")" 'version cache stored'
candidate="$tmpdir/candidate"
printf '#!/bin/sh\necho "Mihomo v1.20.0"\n' >"$candidate"
chmod +x "$candidate"
assert_eq v1.20.0 "$(core_version "$candidate")" 'candidate queried separately'
assert_eq v1.19.30 "$(cat "$CORE_VERSION_CACHE")" 'candidate does not pollute installed cache'
echo 'previous version' >"$CORE_VERSION_CACHE"
exec 8<"$CORE_VERSION_CACHE"
touch -d '2000-01-01' "$CORE_VERSION_CACHE"
assert_eq v1.19.30 "$(core_version)" 'newer binary refreshes cache'
assert_eq 2 "$(wc -l <"$tmpdir/version.calls" | tr -d ' ')" 'refresh queries once'
assert_eq 'previous version' "$(cat <&8)" 'core cache publication replaces inode'
exec 8<&-
pass 'core version cache'

# New core: prints its version; rejects configs when NEW_CORE_REJECTS=1.
new_core="$tmpdir/new-core"
cat >"$new_core" <<'N'
#!/bin/sh
case "$1" in -v) echo "Mihomo Meta v1.19.32 linux"; exit 0 ;; esac
[ "${NEW_CORE_REJECTS:-0}" = 1 ] && { echo "level=error msg=bad"; exit 1; }
exit 0
N
gzip -c "$new_core" >"$tmpdir/asset.gz"
asset_path="$tmpdir/asset.gz"
asset_sha="$(sha256sum "$tmpdir/asset.gz" | cut -d' ' -f1)"
asset_size="$(wc -c <"$tmpdir/asset.gz" | tr -d ' ')"
asset_digest="sha256:$asset_sha"

http_fetch() {
	FETCH_HDR="$PKG_TMP_DIR/fetch.headers.$$"
	mkdir -p "$PKG_TMP_DIR"
	echo headers >"$FETCH_HDR"
	case "$1" in
	*api.github.com*)
		jq -nc --arg d "$asset_digest" --arg s "$asset_size" \
			'{tag_name: "v1.19.32", assets: [{name: "mihomo-linux-arm64-v1.19.32.gz", browser_download_url: "https://x/a.gz", digest: $d, size: ($s | tonumber)}]}' >"$2"
		;;
	*) cp "$asset_path" "$2" ;;
	esac
}
free_kb=1000000
core_free_kb() { echo "$free_kb"; }

# A real, highly compressible executable in a valid gzip padded to exactly 1 MiB.
large_asset="$tmpdir/one-mib.gz"
{ cat "$new_core"; dd if=/dev/zero bs=1048576 count=8 2>/dev/null; } | gzip -nc >"$tmpdir/large.gz"
# Pad the optional gzip filename header, not the trailer used by the old check.
padding="$((1048576 - $(wc -c <"$tmpdir/large.gz") - 1))"
{
 head -c 3 "$tmpdir/large.gz"
 printf '\010'
 dd if="$tmpdir/large.gz" bs=1 skip=4 count=6 2>/dev/null
 head -c "$padding" /dev/zero | tr '\000' x
 printf '\000'
 tail -c +11 "$tmpdir/large.gz"
} >"$large_asset"
gzip -t "$large_asset" || fail 'fixture must be a valid gzip'
assert_eq 1048576 "$(wc -c <"$large_asset" | tr -d ' ')" 'fixture is exactly 1 MiB'

# polish: precheck uses gz size
(
 set -e
 asset_path="$large_asset"
 asset_size=1048576
 asset_digest="sha256:$(sha256sum "$asset_path" | cut -d' ' -f1)"
 cp "$CLASH_BIN" "$tmpdir/core.before"
 free_kb=5119
 if core_update 2>/dev/null; then fail 'precheck one KiB below gz plus reserve must fail'; fi
 assert_eq 'not enough flash: need 5 MiB, free 4 MiB' "$CORE_ERROR" 'precheck uses gz size rejection'
 assert_true 'precheck keeps old core byte-identical' cmp -s "$CLASH_BIN" "$tmpdir/core.before"
)
pass 'precheck uses gz size rejection'

# polish: precheck uses gz size exact boundary
(
 set -e
 asset_path="$large_asset"
 asset_size=1048576
 asset_digest="sha256:$(sha256sum "$asset_path" | cut -d' ' -f1)"
 free_kb=5120
 core_update 2>/dev/null || fail "precheck uses gz size exact boundary: $CORE_ERROR"
 assert_eq 1 "$CORE_UPDATED" 'precheck uses gz size proceeds at exact boundary'
)
printf '#!/bin/sh\necho "Mihomo Meta v1.19.30 linux"\n' >"$CLASH_BIN"
rm -f "$CORE_VERSION_CACHE"
pass 'precheck uses gz size exact boundary'

# polish: enospc keeps core
(
 set -e
 cp "$CLASH_BIN" "$tmpdir/enospc.before"
 mkdir -p "$tmpdir/enospc-bin"
 printf '#!/bin/sh\nprintf partial\necho "gzip: write error: No space left on device" >&2\nexit 1\n' >"$tmpdir/enospc-bin/gzip"
 chmod +x "$tmpdir/enospc-bin/gzip"
 if PATH="$tmpdir/enospc-bin:$PATH" core_update 2>/dev/null; then fail 'ENOSPC must fail'; fi
 [[ "$CORE_ERROR" == 'not enough flash: free '* ]] || fail "enospc keeps core: $CORE_ERROR"
 assert_false 'ENOSPC removes partial binary' test -e "$CLASH_BIN.new"
 assert_true 'ENOSPC keeps old binary byte-identical' cmp -s "$CLASH_BIN" "$tmpdir/enospc.before"
)
pass 'enospc keeps core'

# polish: unpack failed
(
 set -e
 cp "$CLASH_BIN" "$tmpdir/unpack.before"
 mkdir -p "$tmpdir/unpack-bin"
 printf '#!/bin/sh\nprintf partial\necho "gzip: invalid compressed data" >&2\nexit 1\n' >"$tmpdir/unpack-bin/gzip"
 chmod +x "$tmpdir/unpack-bin/gzip"
 if PATH="$tmpdir/unpack-bin:$PATH" core_update 2>/dev/null; then fail 'invalid gzip must fail'; fi
 assert_eq 'unpack failed' "$CORE_ERROR" 'unpack failed'
 assert_false 'unpack failure removes partial binary' test -e "$CLASH_BIN.new"
 assert_true 'unpack failure keeps old binary' cmp -s "$CLASH_BIN" "$tmpdir/unpack.before"
 assert_eq '' "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" 'failure removes fetch headers'
)
pass 'unpack failed'

free_kb=1000000
if NEW_CORE_REJECTS=1 core_update 2>/dev/null; then fail "config rejection must fail"; fi
assert_eq "v1.19.30" "$(core_version)" "old core kept when new rejects config"
pass "bad binary keeps old"

asset_digest="sha256:$(printf '0%.0s' {1..64})"
if core_update 2>/dev/null; then fail "digest mismatch must fail"; fi
assert_eq "sha256 mismatch" "$CORE_ERROR" "digest error"
asset_digest="sha256:$asset_sha"
pass "digest mismatch"

# A killed update must not consume space during the next free-space check.
mkdir -p "$CORE_TMP_DIR"
echo stale >"$CORE_TMP_DIR/x"
dd if=/dev/zero of="$CLASH_BIN.new" bs=1048576 count=5 2>/dev/null
core_free_kb() {
 [ ! -e "$CORE_TMP_DIR/x" ] && [ ! -e "$CLASH_BIN.new" ] || { echo 0; return; }
 echo "$free_kb"
}
core_update || fail "update must succeed after stale leftovers are removed"
assert_eq "" "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" "no header files left after core success"
assert_eq "1:v1.19.32" "$CORE_UPDATED:$(core_version)" "core replaced"
core_update
assert_eq 0 "$CORE_UPDATED" "same version is a no-op"
assert_eq "" "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" "no header files left after up-to-date core"
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
