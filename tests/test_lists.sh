#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh lists.sh
setup_runtime_paths "$tmpdir"


LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
PKG_TMP_DIR="$tmpdir/tmp"
lists_ensure_files

printf '1.1.1.1 | 12\n' >"$DST_LIST_FILE"
assert_eq '1.1.1.1|12' "$(lists_clean_lines "$DST_LIST_FILE")" "runtime keeps legacy pipe, making entry invalid"
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
[[ ! -s "$tmpdir/v4" && ! -s "$tmpdir/v6" ]] || fail "pipe entry must be invalid"
pass "lists runtime does not strip legacy suffix"

cat >"$DST_LIST_FILE" <<'L'
# comment
1.1.1.1
2001:db8::/32;443
;53
999.1.1.1
1.1.1.1
https://lists.example.com/a.txt;80
L
mkdir -p "$POLICY_CACHE_DIR"
printf '8.8.8.0/24\n2606:4700::1;8443\n' >"$(lists_cache_file https://lists.example.com/a.txt)"

stdout="$(lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null)"
assert_eq "" "$stdout" "resolve writes nothing to stdout (CLI output must stay JSON)"
assert_eq 3 "$(wc -l <"$tmpdir/v4" | tr -d ' ')" "v4 entries deduplicated"
assert_file_contains "$tmpdir/v4" "8.8.8.0/24;80" "remote entry inherits URL ports"
assert_file_contains "$tmpdir/v4" ";53" "port-only entry in v4"
assert_file_contains "$tmpdir/v6" "2001:db8::/32;443" "v6 entry"
assert_file_contains "$tmpdir/v6" "2606:4700::1;8443" "remote v6 keeps own ports"
assert_file_contains "$tmpdir/v6" ";53" "port-only entry in v6"
assert_file_not_contains "$tmpdir/v4" "999.1.1.1" "invalid entry skipped"
pass "mixed families resolved"

http_fetch() {
	FETCH_ERROR=network
	return 1
}
LISTS_INTERVAL=0
assert_eq unchanged "$(lists_update_remote 0)" "cached list not due without interval"
if lists_update_remote 1 >/dev/null 2>&1; then
	fail "forced update with failing fetch must report failure"
fi
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_file_contains "$tmpdir/v4" "8.8.8.0/24;80" "cache used when fetch fails"
pass "remote cache used offline"

http_fetch() {
	printf '9.9.9.9\nnot-an-ip\n' >"$2"
}
assert_eq changed "$(lists_update_remote 1)" "fetched content changes cache"
assert_eq "9.9.9.9" "$(cat "$(lists_cache_file https://lists.example.com/a.txt)")" "cache keeps only valid entries"
assert_eq unchanged "$(lists_update_remote 1)" "same content is unchanged"
pass "remote update"

printf '10.0.0.1\n300.1.1.1\n2001:db8::1;443\n1:2:3:4:5:6::7\nfe80::1/64\n::ffff:1.2.3.4\n;80\nbad\n' >"$DST_LIST_FILE"
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_eq "$(printf ';80\n10.0.0.1\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v4")" "v4 classification"
assert_eq "$(printf '1:2:3:4:5:6::7\n2001:db8::1;443\n;80\nfe80::1/64\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v6")" "v6 classification"
pass "bulk classification"

seq 1 20000 | awk '{ printf "10.%d.%d.0/24\n", int($1/256)%256, $1%256 }' >"$DST_LIST_FILE"
start=$(date +%s)
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ] || fail "20000 entries took ${elapsed}s (one fork per entry?)"
pass "large list resolves fast"

printf 'has proxy-ips\nproxy-ip 1.2.3.4\n' >"$PROFILE_FILE"
printf '5.6.7.8\n' >"$DST_LIST_FILE"
for source in provider merge own; do
 DST_LIST_SOURCE="$source"
 lists_resolve dst "$tmpdir/p4" "$tmpdir/p6"
 case "$source" in
 provider) expected=1.2.3.4 ;;
 merge) expected=$'1.2.3.4\n5.6.7.8' ;;
 own) expected=5.6.7.8 ;;
 esac
 assert_eq "$expected" "$(cat "$tmpdir/p4")" "provider source $source"
done
printf 'has proxy-ips\nproxy-ip 999.1.1.1\nproxy-ip https://p.example/l.txt\n' >"$PROFILE_FILE"
DST_LIST_SOURCE=provider
warn() { echo "$*" >>"$tmpdir/warnings"; }
lists_resolve dst "$tmpdir/p4" "$tmpdir/p6"
assert_file_not_contains "$tmpdir/p4" 999.1.1.1 "invalid provider address dropped"
assert_file_contains "$tmpdir/warnings" 999.1.1.1 "invalid provider address warned"
assert_eq https://p.example/l.txt "$(lists_urls)" "provider URL fetched"
rm "$PROFILE_FILE"
for DST_LIST_SOURCE in provider merge own; do
 assert_eq 5.6.7.8 "$(lists_source dst)" "no provider uses own list"
done
assert_eq "$DIRECT_SRC_LIST_FILE" "$(lists_file direct_src)" "fourth kind"
pass "provider list source selection and validation"

# Provider URLs alone are restricted; own files retain the same URLs.
urls=(http://p.example/l.txt https://127.0.0.1/x https://10.1.2.3/x
 https://192.168.1.1/x https://169.254.1.1/x https://100.64.0.1/x
 'https://[::1]/x' 'https://[fd00::1]/x' 'https://[fe80::1]/x'
 https://localhost/x https://172.16.0.1/x 'https://[0:0:0:0:0:0:0:1]/x'
 https://127.1/x https://2130706433/x https://0x7f000001/x https://0x7f.0.0.1/x
 https://0177.0.0.1/x https://127.0.0.1./x
 ftp://p.example/l.txt 'https://%31%32%37.0.0.1/x'
 'https://[::ffff:7f00:1]/x' 'https://[0:0:0:0:0:ffff:808:808]/x'
 'https://[::808:808]/x')
for url in https://p.example/l.txt https://123.example/x https://8.8.8.8/x 'https://[2606:4700::1111]/x'; do
 assert_true "public https URL allowed: $url" lists_provider_url_ok "$url"
done
for url in "${urls[@]}"; do
 assert_false "provider URL rejected: $url" lists_provider_url_ok "$url"
done
assert_false 'fragment cannot spoof the URL host' lists_provider_url_ok 'https://127.0.0.1#@p.example/x'
printf 'has proxy-ips\nproxy-ip https://p.example/l.txt\n' >"$PROFILE_FILE"
printf 'proxy-ip %s\n' "${urls[@]}" >>"$PROFILE_FILE"
printf '%s\n' "${urls[@]}" >"$DST_LIST_FILE"
DST_LIST_SOURCE=provider
assert_eq https://p.example/l.txt "$(lists_source dst)" 'provider URLs filtered'
for url in "${urls[@]}"; do
 assert_file_contains "$tmpdir/warnings" "x-mihowrt: ignored list URL $url (only public https URLs)" 'exact provider URL warning'
done
DST_LIST_SOURCE=own
assert_eq "$(printf '%s\n' "${urls[@]}")" "$(lists_source dst)" 'own URLs unrestricted'
rm "$PROFILE_FILE"
pass 'provider url policy'

printf '# Кириллица\n1.2.3.4\n\n' >"$DST_LIST_FILE"
printf '# Устройства\n10.0.0.1\n' >"$SRC_LIST_FILE"
printf '# Прямо\n' >"$DIRECT_DST_LIST_FILE"
rm "$DIRECT_SRC_LIST_FILE"
json="$(lists_json)"
for kind in dst src direct; do
 file="$(lists_file "$kind")"
 jq -e --arg k "$kind" --rawfile content "$file" '.[$k] == $content' <<<"$json" >/dev/null || fail "exact JSON file text: $kind"
done
assert_eq '' "$(jq -r .direct_src <<<"$json")" 'missing list JSON is empty'
lists_ensure_files
pass 'lists-json exact texts'

# Exercise the fetch limit through the real http_fetch, stubbing transport only.
load_modules fetch.sh
curl() {
 local out='' headers=''
 while [ "$#" -gt 0 ]; do
  case "$1" in
  -o) out="$2"; shift ;;
  -D) headers="$2"; shift ;;
  esac
  shift
 done
 cp "$tmpdir/remote" "$out"
 printf 'HTTP/1.1 200 OK\n\n' >"$headers"
}
printf 'https://size.example/list\n' >"$DST_LIST_FILE"
: >"$SRC_LIST_FILE"; : >"$DIRECT_DST_LIST_FILE"; : >"$DIRECT_SRC_LIST_FILE"
# http_fetch is defined by fetch.sh, replacing the earlier local fake.
awk 'BEGIN { for (i=0;i<115200;i++) print "9.9.9.9" }' >"$tmpdir/remote"
assert_eq changed "$(lists_update_remote 1)" '900 KiB remote list accepted'
cache="$(lists_cache_file https://size.example/list)"
cp "$cache" "$tmpdir/cache.before"
awk 'BEGIN { for (i=0;i<144180;i++) print "8.8.8.8" }' >"$tmpdir/remote"
assert_false '1.1 MiB remote rejected' lists_update_remote 1 >/dev/null
assert_file_contains "$tmpdir/warnings" '(too_large)' 'too_large remote error'
cmp -s "$cache" "$tmpdir/cache.before" || fail 'oversized remote keeps cache'
pass 'remote size'

printf 'https://current.example/a\n' >"$DST_LIST_FILE"
current="$(lists_cache_file https://current.example/a)"
removed="$(lists_cache_file https://removed.example/b)"
printf '1.1.1.1\n' >"$current"; cp "$current" "$removed"
LISTS_INTERVAL=0
lists_update_remote 0 >/dev/null
assert_true 'current cache kept' test -f "$current"
assert_false 'removed URL cache deleted' test -e "$removed"
for n in $(seq 1 33); do
 url="https://many.example/$n"
 printf '%s\n' "$url"
 printf '1.1.1.1\n' >"$(lists_cache_file "$url")"
done >"$DST_LIST_FILE"
lists_update_remote 0 >/dev/null
assert_true '33rd URL cache retained' test -f "$(lists_cache_file https://many.example/33)"
pass 'cache gc includes URLs beyond fetch cap'

# Apply only src; unchanged lists retain their timestamps and content.
with_lock() { "$@"; }
settings_load() { :; }
cron_update() { :; }
service_ready() { return 1; }
upload="/tmp/mihowrt-policy-list.task8.$$"
printf '10.2.3.4\n' >"$upload"
for kind in dst direct direct_src; do touch -d '2024-01-01 00:00:00' "$(lists_file "$kind")"; done
cp "$DST_LIST_FILE" "$tmpdir/dst.before"
assert_eq '{"changed":true}' "$(lists_apply - "$upload" - -)" 'partial apply updates src'
assert_eq 10.2.3.4 "$(cat "$SRC_LIST_FILE")" 'src replaced'
cmp -s "$DST_LIST_FILE" "$tmpdir/dst.before" || fail 'dst kept'
for kind in dst direct direct_src; do
 assert_eq 1704067200 "$(stat -c %Y "$(lists_file "$kind")")" 'unchanged list mtime'
done
assert_eq '{"changed":false}' "$(lists_apply - - - -)" 'all unchanged'
awk 'BEGIN { for (i=0;i<144180;i++) print "8.8.8.8" }' >"$upload"
assert_false 'oversize own list rejected' lists_apply - "$upload" - - 2>"$tmpdir/own.err"
assert_file_contains "$tmpdir/own.err" 'List src is larger than 1 MiB.' 'exact own size error'
assert_eq 10.2.3.4 "$(cat "$SRC_LIST_FILE")" 'oversize upload keeps installed list'
victim="$(mktemp /tmp/somefile.XXXXXX)"
assert_false 'apply-lists rejects foreign path' lists_apply "$victim" - - - 2>/dev/null
assert_true 'rejected path is not deleted' test -f "$victim"
rm -f "$victim"
pass 'partial apply and own size'

# Both successful and failed list URLs release their response headers.
lists_urls() {
 case "$outcome" in
 success) echo https://ok.example/list ;;
 failure) echo https://fail.example/list ;;
 mixed) printf '%s\n' https://ok.example/list https://fail.example/list ;;
 esac
}
http_fetch() {
 FETCH_HDR="$PKG_TMP_DIR/fetch.headers.$$"
 echo headers >"$FETCH_HDR"
 case "$1" in
 *fail.example*) FETCH_ERROR=network; return 1 ;;
 *) echo 9.9.9.9 >"$2" ;;
 esac
}
for outcome in success failure mixed; do
 if [ "$outcome" = success ]; then
  lists_update_remote 1 >/dev/null
 else
  assert_false "$outcome list update reports failure" lists_update_remote 1 >/dev/null 2>&1
 fi
 assert_eq "" "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" "no header files left after $outcome list fetches"
done
pass 'list response headers cleaned'

assert_eq 'mac aa:bb:cc:dd:ee:ff' "$(printf 'AA:BB:CC:DD:EE:FF\n' | lists_classify)" 'classify mac lower-case'
for entry in aa-bb-cc-dd-ee-ff aa:bb:cc:dd:ee 'aa:bb:cc:dd:ee:ff;443' 'aa:bb:cc:dd:ee:ff;' 'aa:bb:cc:dd:ee:ff/48'; do
 assert_eq "$entry" "$(printf '%s\n' "$entry" | lists_classify 1)" "invalid MAC: $entry"
done
# Exercise the classifier with the actual BusyBox awk as well as the default awk.
( awk() { busybox awk "$@"; }; assert_eq 'mac aa:bb:cc:dd:ee:ff' "$(printf 'AA:BB:CC:DD:EE:FF\n' | lists_classify)" 'BusyBox classifies MAC' )
pass 'classify mac'
for kind in dst direct; do
 printf 'aa:bb:cc:dd:ee:ff\n' >"$upload"
 args=(- - - -)
 if [ "$kind" = dst ]; then args[0]="$upload"; else args[2]="$upload"; fi
 rc=0
 lists_apply "${args[@]}" >"$tmpdir/mac.out" 2>"$tmpdir/mac.err" || rc=$?
 assert_eq 1 "$rc" 'MAC rejected in address list'
 assert_eq "Error: Invalid $kind entries: aa:bb:cc:dd:ee:ff " "$(cat "$tmpdir/mac.err")" 'exact invalid MAC error'
done
for kind in src direct_src; do
 printf 'AA:BB:CC:DD:EE:FF # Device\n10.2.3.4\n' >"$upload"
 args=(- - - -)
 if [ "$kind" = src ]; then args[1]="$upload"; else args[3]="$upload"; fi
 assert_eq '{"changed":true}' "$(lists_apply "${args[@]}")" 'MAC accepted in device list'
 assert_file_contains "$(lists_file "$kind")" 'aa:bb:cc:dd:ee:ff # Device' 'MAC stored lower-case, comment retained'
 lists_resolve "$kind" "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
 assert_eq aa:bb:cc:dd:ee:ff "$(cat "$tmpdir/mac")" 'MAC resolved separately'
 assert_eq 10.2.3.4 "$(cat "$tmpdir/m4")" 'MAC not in IPv4 output'
done
printf 'AA:BB:CC:DD:EE:FF\n' >"$(lists_cache_file https://mac.example/list)"
for kind in dst direct src direct_src; do
 printf 'https://mac.example/list\naa:bb:cc:dd:ee:ff\n' >"$(lists_file "$kind")"
 lists_resolve "$kind" "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
 case "$kind" in
 src|direct_src) assert_eq aa:bb:cc:dd:ee:ff "$(cat "$tmpdir/mac")" 'remote and own MACs deduplicated' ;;
 *) assert_eq '' "$(cat "$tmpdir/mac")" 'address lists exclude remote and own MACs' ;;
 esac
done
printf 'has proxy-ips\nproxy-ip aa:bb:cc:dd:ee:ff\n' >"$PROFILE_FILE"
DST_LIST_SOURCE=provider
lists_resolve dst "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
assert_eq '' "$(cat "$tmpdir/mac")" 'provider destination MAC excluded'
pass 'mac only in device lists'
