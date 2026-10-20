#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh fetch.sh
PKG_TMP_DIR="$tmpdir/tmp"
PKG_PERSIST_DIR="$tmpdir/etc"
PKG_STATE_DIR="$tmpdir/run"
SUBSCRIPTION_META_FILE="$tmpdir/etc/subscription.json"
mkdir -p "$PKG_STATE_DIR"

# curl stub: logs args, writes $CURL_BODY to -o and $CURL_HEADERS to -D.
cat >"$tmpdir/bin/curl" <<'C'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
out="" hdr=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift ;;
	-D) hdr="$2"; shift ;;
	esac
	shift
done
printf '%b' "${CURL_HEADERS:-HTTP/1.1 200 OK\r\n}" >"$hdr"
printf '%s' "${CURL_BODY:-}" >"$out"
exit "${CURL_EXIT:-0}"
C
chmod +x "$tmpdir/bin/curl"
export CURL_LOG="$tmpdir/curl.log"
mkdir -p "$PKG_PERSIST_DIR"
echo 0123456789abcdef >"$PKG_PERSIST_DIR/hwid"

: >"$CURL_LOG"
CURL_BODY=data http_fetch http://example.com/s "$tmpdir/o" 100 10 1 || fail "http fetch"
assert_file_not_contains "$CURL_LOG" "x-hwid" "no device headers over http"
pass "no hwid on http"

: >"$CURL_LOG"
CURL_BODY=data http_fetch https://example.com/s "$tmpdir/o" 100 10 1 || fail "https fetch"
assert_file_contains "$CURL_LOG" "x-hwid: 0123456789abcdef" "stored hwid sent over https"
assert_file_contains "$CURL_LOG" "--proto-redir =https" "redirects limited to https"
assert_file_contains "$CURL_LOG" "--max-filesize 100" "size limit passed to curl"
pass "hwid on https"

if CURL_BODY="$(printf 'x%.0s' {1..101})" http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then
	fail "oversize body must fail"
fi
assert_eq too_large "$FETCH_ERROR" "oversize error kind"
[[ ! -e "$tmpdir/o" ]] || fail "partial output removed"
if CURL_EXIT=63 http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then fail "curl 63 must fail"; fi
assert_eq too_large "$FETCH_ERROR" "curl max-filesize exit"
if CURL_EXIT=22 CURL_HEADERS='HTTP/1.1 403 Forbidden\r\n' http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then fail "403 must fail"; fi
assert_eq http_403 "$FETCH_ERROR" "http error kind"
pass "fetch errors"

assert_eq "Личная 🚀" "$(subscription_decode_metadata_value 'base64:0JvQuNGH0L3QsNGPIPCfmoA=')" "UTF-8 decoded"
assert_eq "abc" "$(subscription_decode_metadata_value 'base64:YWJj')" "unpadded quartet"
assert_eq "plain text" "$(subscription_decode_metadata_value 'plain text')" "plain text kept"
assert_eq "base64:YWJj====" "$(subscription_decode_metadata_value 'base64:YWJj====')" "malformed padding kept"
assert_eq "base64:YQBi" "$(subscription_decode_metadata_value 'base64:YQBi')" "NUL byte kept raw"
assert_eq "base64://4=" "$(subscription_decode_metadata_value 'base64://4=')" "non-UTF-8 kept raw"
assert_eq "base64:???" "$(subscription_decode_metadata_value 'base64:???')" "invalid chars kept"
pass "base64 metadata"

CURL_HEADERS='HTTP/1.1 302 Found\r\nprofile-title: old\r\n\r\nHTTP/1.1 200 OK\r\nProfile-Title: base64:0JvQuNGH0L3QsNGPIPCfmoA=\r\nsubscription-userinfo: upload=1; download=2; expire=1700000000\r\nprofile-update-interval: 12\r\n' \
	CURL_BODY=x http_fetch https://example.com/s "$tmpdir/o" 100 10 0
meta="$(subscription_metadata_from_headers)"
assert_eq "Личная 🚀" "$(jq -r .profile_title <<<"$meta")" "title from last redirect block"
assert_eq "null" "$(jq -r .total <<<"$meta")" "missing total stays null (unlimited)"
assert_eq "3|1700000000|12" "$(jq -r '"\(.upload + .download)|\(.expire)|\(.header_interval)"' <<<"$meta")" "userinfo fields"
pass "subscription metadata"

printf '%s\n' "$meta" >"$SUBSCRIPTION_META_FILE"
assert_eq 12 "$(settings_subscription_interval)" "auto interval from provider header"
fake_uci_set mihowrt.settings.subscription_interval 0
assert_eq 0 "$(settings_subscription_interval)" "explicit 0 disables"
pass "auto interval"

# E: concurrent downloads use their own temp files.
grep -q 'fetch.headers.\$\$' "$MIHOWRT_LIB_DIR/fetch.sh" || fail "header dump must be per process"
grep -q 'subscription.\$\$.yaml' "$MIHOWRT_LIB_DIR/fetch.sh" || fail "subscription candidate must be per process"
pass "per-process temp files"

# Subscription download bypasses Mihomo only while it runs.
load_modules lists.sh nft.sh
nft_log="$tmpdir/nft.log"
: >"$nft_log"
nft() { echo "nft $*" >>"$nft_log"; }
nft_active() { true; }
nslookup() { printf 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nName:\tsub.example.com\nAddress: 203.0.113.7\n\nName:\tsub.example.com\nAddress: 2001:db8::7\n'; }
with_lock() { "$@"; }
config_install() { echo "fetch-order" >>"$nft_log"; echo '{"action":"saved"}'; }
cron_update() { :; }
http_fetch() { echo "download" >>"$nft_log"; mkdir -p "$(dirname "$2")"; echo "mode: rule" >"$2"; }
settings_load() { SUBSCRIPTION_URL=https://sub.example.com/s; BYPASS_SUBSCRIPTION_DNS=1; }
subscription_update >/dev/null
assert_eq "nft add element inet mihowrt bypass_dst { 203.0.113.7 timeout 2m }
nft add element inet mihowrt bypass_dst6 { 2001:db8::7 timeout 2m }
download
nft delete element inet mihowrt bypass_dst { 203.0.113.7 }
nft delete element inet mihowrt bypass_dst6 { 2001:db8::7 }
fetch-order" "$(cat "$nft_log")" "bypass added before download and removed right after"
: >"$nft_log"
settings_load() { SUBSCRIPTION_URL=https://sub.example.com/s; BYPASS_SUBSCRIPTION_DNS=0; }
subscription_update >/dev/null
assert_eq $'download\nfetch-order' "$(cat "$nft_log")" "no bypass when the toggle is off"
pass "temporary subscription bypass"

# A broken metadata file must not break the subscription page.
: >"$SUBSCRIPTION_META_FILE"
subscription_json | jq -e '.url != null' >/dev/null || fail "empty metadata file must be ignored"
echo '{oops' >"$SUBSCRIPTION_META_FILE"
subscription_json | jq -e '.url != null' >/dev/null || fail "invalid metadata file must be ignored"
pass "subscription json tolerates broken metadata"
