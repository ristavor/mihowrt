#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh fetch.sh subscription.sh
setup_runtime_paths "$tmpdir"

PKG_TMP_DIR="$tmpdir/tmp"
PKG_PERSIST_DIR="$tmpdir/etc"
PKG_STATE_DIR="$tmpdir/run"
SUBSCRIPTION_META_FILE="$tmpdir/etc/subscription.json"
mkdir -p "$PKG_STATE_DIR"

subscription_set_fixture() {
 fake_uci_reset
 fake_uci_set mihowrt.settings.subscription_url https://same.example/sub
 fake_uci_set mihowrt.settings.subscription_auto_update 1
 : >"$tmpdir/set.calls"
 uci() {
  case " $* " in *' commit '*) echo commit >>"$tmpdir/set.calls" ;; *' set '*) echo set >>"$tmpdir/set.calls" ;; esac
  command uci "$@"
 }
 cron_update() { echo cron >>"$tmpdir/set.calls"; }
 dns_apply() { echo dns >>"$tmpdir/set.calls"; }
}

# polish: set unchanged skips commit
(
 set -e
 subscription_set_fixture
 subscription_set https://same.example/sub 1 || fail 'unchanged setter must succeed'
 assert_eq '' "$(cat "$tmpdir/set.calls")" 'set unchanged skips commit, writes, cron and DNS'
)
pass 'set unchanged skips commit'

# The changed URL path keeps its existing commit behaviour.
(
 set -e
 subscription_set_fixture
 subscription_set https://changed.example/sub 1 || fail 'changed setter must succeed'
 assert_eq 1 "$(grep -c '^commit$' "$tmpdir/set.calls")" 'changed URL commits once'
)
fake_uci_reset
pass 'changed URL commits once'

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
printf '%s' "${CURL_STDERR:-}" >&2
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
if CURL_STDERR='curl: private diagnostic' CURL_EXIT=7 http_fetch https://example.com/s "$tmpdir/o" 100 10 0 2>"$tmpdir/curl.err"; then fail "network failure must fail"; fi
assert_eq '' "$(cat "$tmpdir/curl.err")" 'curl stderr suppressed'
pass "fetch errors"

assert_eq "Личная 🚀" "$(subscription_decode_metadata_value 'base64:0JvQuNGH0L3QsNGPIPCfmoA=')" "UTF-8 decoded"
assert_eq "abc" "$(subscription_decode_metadata_value 'base64:YWJj')" "unpadded quartet"
assert_eq "plain text" "$(subscription_decode_metadata_value 'plain text')" "plain text kept"
assert_eq "" "$(subscription_decode_metadata_value 'base64:YWJj====')" "malformed padding dropped"
assert_eq "" "$(subscription_decode_metadata_value 'base64:YQBi')" "NUL byte dropped"
assert_eq "" "$(subscription_decode_metadata_value 'base64://4=')" "non-UTF-8 dropped"
assert_eq "" "$(subscription_decode_metadata_value 'base64:???')" "invalid chars dropped"
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
fake_uci_set mihowrt.settings.subscription_auto_update 0
assert_eq 0 "$(settings_subscription_interval)" "explicit 0 disables"
pass "auto interval"

# E: concurrent downloads use their own temp files.
grep -q 'fetch.headers.\$\$' "$MIHOWRT_LIB_DIR/fetch.sh" || fail "header dump must be per process"
grep -q 'subscription.\$\$.yaml' "$MIHOWRT_LIB_DIR/subscription.sh" || fail "subscription candidate must be per process"
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
config_api_wait() { :; }
lists_urls() { :; }
http_fetch() { echo "download" >>"$nft_log"; mkdir -p "$(dirname "$2")"; echo "proxies: []" >"$2"; }
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

payload="$(printf 'x%.0s' {1..12000} | busybox base64 | tr -d '\n')"
assert_eq 12000 "$(subscription_decode_metadata_value "base64:$payload" | wc -c | tr -d ' ')" "large valid metadata decoded"
assert_eq '' "$(subscription_decode_metadata_value "base64:${payload}AAAAA$(printf 'A%.0s' {1..400})")" "over limit metadata dropped"
assert_eq '' "$(subscription_decode_metadata_value base64:@@@)" "malformed metadata dropped"
assert_eq Hello "$(subscription_decode_metadata_value Hello)" "plain metadata"
for body in 'YWJjZA==' 'vless://x' '{"outbounds":[]}' '<html>'; do
 printf '%s\n' "$body" >"$tmpdir/body"
 assert_false "non-Clash format $body" subscription_is_clash "$tmpdir/body"
done
for body in '"proxies": []' 'proxy-providers:' "'proxies': []"; do
 printf '%s\n' "$body" >"$tmpdir/body"
 assert_true "Clash format $body" subscription_is_clash "$tmpdir/body"
done
# Invalid downloads must fail before install, leaving the current source intact.
http_fetch() { mkdir -p "$(dirname "$2")"; printf '%s' "$download" >"$2"; }
printf 'keep source\n' >"$CLASH_CONFIG"
config_install() { touch "$tmpdir/installed"; echo '{"action":"saved"}'; }
for download in 'YWJjZA==' 'vless://x' '{"outbounds":[]}' '<html>'; do
 assert_false "download gate rejects" subscription_update 2>"$tmpdir/gate.err"
 assert_file_contains "$tmpdir/gate.err" 'not a Clash/Mihomo config' "actionable format message"
 assert_eq 'keep source' "$(cat "$CLASH_CONFIG")" "installed source untouched"
 assert_false "install not reached" test -e "$tmpdir/installed"
done
# Malformed extension values do not reject a Clash subscription.
download=$'proxies: []\nx-mihowrt:\n  disable-quic: maybe\n  foo: 1\n  proxy-ips: [1.2.3.4]\n'
subscription_update >/dev/null
assert_true "broken extension still installs" test -f "$tmpdir/installed"
# Set-subscription now accepts only the auto-update boolean.
for auto in 1 0; do
 subscription_set https://sub.example/x "$auto"
 assert_eq "$auto" "$(uci_get subscription_auto_update)" "auto-update stored"
done
assert_false "numeric interval rejected" subscription_set https://sub.example/x 5 2>"$tmpdir/set.err"
assert_file_contains "$tmpdir/set.err" 'Auto-update must be 0 or 1' "auto-update validation message"
pass "metadata limits, subscription format gate and on/off setter"

# A replacement URL is committed only after installation succeeds.
settings_load() { SUBSCRIPTION_URL="$(uci_get subscription_url)"; BYPASS_SUBSCRIPTION_DNS=0; }
fake_uci_set mihowrt.settings.subscription_url https://old.example/sub
http_fetch() { printf '%s\n' "$1" >"$tmpdir/request-url"; printf 'proxies: []\n' >"$2"; }
config_install() { assert_eq https://old.example/sub "$(uci_get subscription_url)" 'old URL until install'; echo '{"action":"saved"}'; }
subscription_update https://new.example/sub >/dev/null
assert_eq https://new.example/sub "$(uci_get subscription_url)" 'successful URL saved'
assert_eq https://new.example/sub "$(cat "$tmpdir/request-url")" 'new URL downloaded'
config_install() { return 1; }
assert_false 'install failure rejects' subscription_update https://broken.example/sub >/dev/null 2>&1
assert_eq https://new.example/sub "$(uci_get subscription_url)" 'install failure keeps old URL'
http_fetch() { FETCH_ERROR=network; return 1; }
assert_false 'download failure rejects' subscription_update https://offline.example/sub >/dev/null 2>&1
assert_eq https://new.example/sub "$(uci_get subscription_url)" 'download failure keeps old URL'
assert_false 'invalid URL rejects' subscription_update javascript:evil >/dev/null 2>&1
assert_eq https://new.example/sub "$(uci_get subscription_url)" 'invalid URL keeps old URL'
pass 'replacement subscription URL transaction'

# Each subscription exit owns and removes its response headers.
for outcome in download_failure empty non_clash success; do
 http_fetch() {
  FETCH_HDR="$PKG_TMP_DIR/fetch.headers.$$"
  printf 'HTTP/1.1 200 OK\r\nProfile-Title: kept\r\n' >"$FETCH_HDR"
  case "$outcome" in
  download_failure) FETCH_ERROR=network; return 1 ;;
  empty) : >"$2" ;;
  non_clash) printf '<html>' >"$2" ;;
  success) printf 'proxies: []\n' >"$2" ;;
  esac
 }
 config_install() { echo '{"action":"saved"}'; }
 rm -f "$PKG_TMP_DIR"/fetch.headers.*
 if [ "$outcome" = success ]; then
  subscription_update >/dev/null
  assert_eq kept "$(jq -r .profile_title "$SUBSCRIPTION_META_FILE")" 'headers parsed before cleanup'
 else
  assert_false "$outcome rejected" subscription_update >/dev/null 2>&1
 fi
 assert_eq "" "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" "no header files left after subscription $outcome"
done
pass 'subscription response headers cleaned on every exit'
