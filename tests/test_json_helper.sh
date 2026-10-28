#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
helper="$ROOT_DIR/rootfs/usr/bin/mihowrt-json"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
[[ -x "$helper" ]] || fail 'mihowrt-json executable helper is missing'
parity() {
 local label="$1" expected="$2"; shift 2
 local actual
 actual="$("$helper" "$@")" || fail "$label: helper failed"
 assert_eq "$expected" "$actual" "$label"
 pass "JSON helper: $label"
}
text=$'quotes " slash / backslash \\ русский 😀\n\t\r\001\037'
parity 'object escaping and key order' "$(jq -nc --arg name "$text" '{name:$name}')" build object --arg name "$text"
printf '%s\n\n' "$text" >"$tmpdir/raw"
parity 'rawfile keeps trailing newlines' "$(jq -nc --rawfile content "$tmpdir/raw" '{content:$content}')" build object --rawfile content "$tmpdir/raw"
# shellcheck disable=SC2094 # The path is metadata, never an output file.
parity 'pretty config JSON' "$(jq -Rs --arg p "$tmpdir/raw" '{path:$p,content:.}' <"$tmpdir/raw")" build config --arg p "$tmpdir/raw" <"$tmpdir/raw"
for number in '' 01 1.0 1e2 +2 .5 1. Infinity NaN -Infinity 1e999 9007199254740993 1.2345678901234567 '12x' '0x10' ' true '; do
 parity "tonumber parity [$number]" "$(jq -nc --arg interval "$number" '{profile_title:"",announce:"",support_url:"",web_page_url:"",header_interval:($interval|tonumber? // null),upload:null,download:null,total:null,expire:null}')" build metadata --arg interval "$number"
done
for input in '{"a":1.0,"b":1e20,"c":1e-7,"d":9007199254740993,"e":1.2345678901234567}' '{"z":0,"a":"/тест","n":false}' '{}'; do
 parity 'merge number formatting and order' "$(jq -c '. + {now:2}' <<<"$input")" merge object --argjson now 2 <<<"$input"
done
parity 'field default false' '' get header_interval empty <<< '{"header_interval":false}'
parity 'field extraction' 'running:service' get state:op <<< '{"state":"running","op":"service"}'
parity 'object filter rejects arrays' '' object <<< '[]'
assert_false 'invalid JSON fails' "$helper" get state <<< 'not-json'
assert_true 'Status presence, not truthiness' "$helper" has Status <<< '{"Status":null}'
assert_false 'missing Status' "$helper" has Status <<< '{}'
uri=$'AZaz09-_.~!*\047();:@&=+$,/?#[]% русский\n'
parity 'URI reserved set and UTF-8' "$(printf '%s\n' "$uri" | jq -sRr @uri)" uri <<<"$uri"
# URI consumes exact stdin, not an extra here-string newline.
assert_eq "$(printf '%s' "$uri" | jq -sRr @uri)" "$(printf '%s' "$uri" | "$helper" uri)" 'URI exact input'
for value in SGVsbG8= 0KLQtdGB0YI= AA== /w== 77+9 Zm9vCg==; do
 parity "base64 parity $value" "$(printf '%s' "$value" | jq -Rr '@base64d | select(length > 0 and (explode | all(. != 0 and . != 65533)))')" base64 <<<"$value"
done
printf '%s\n' '{"id":"10-20","started":10,"state":"ok"}' >"$tmpdir/a.json"
printf '%s\n' '{"id":"10-3","started":10,"state":"running"}' >"$tmpdir/b.json"
parity 'history numeric tie breaker' "$(jq -s 'sort_by(.started, (.id|split("-")|map(tonumber)))' "$tmpdir/"*.json)" history sort "$tmpdir/"*.json
parity 'history last' '10-20' history last <<< '[{"id":"10-3"},{"id":"10-20"}]'
parity 'history prune keeps five terminal jobs' '1-1' history prune <<< '[{"id":"0-1","state":"running"},{"id":"1-1"},{"id":"2-1"},{"id":"3-1"},{"id":"4-1"},{"id":"5-1"},{"id":"6-1"}]'
for input in '' '1 2' '{"n":1.0}' 'null' 'broken'; do
 printf '%s' "$input" >"$tmpdir/out"
 expected="$(jq -sc 'if length==1 then .[0] else null end' "$tmpdir/out" 2>/dev/null)" || expected=null
 actual="$("$helper" result "$tmpdir/out" 2>/dev/null)" || actual=null
 assert_eq "$expected" "$actual" 'single job result slurp'
done
pass 'JSON helper: job result slurp'
release='{"tag_name":"v1","assets":[{"name":"a","browser_download_url":"https://x/$(touch /tmp/injected)","size":1.0},{"name":"other"}]}'
parity 'release asset text is never evaluated' "$(jq -r '.assets[]?|select(.name=="a")|"\(.browser_download_url)\t\(.digest // "")\t\(.size // "")"' <<<"$release")" asset a <<<"$release"
# Exercise the documented 8 MiB cap without argv-size limits.
awk 'BEGIN { for(i=0;i<131072;i++) print "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/" }' >"$tmpdir/large"
"$helper" build object --rawfile content "$tmpdir/large" >"$tmpdir/actual"
jq -nc --rawfile content "$tmpdir/large" '{content:$content}' >"$tmpdir/expected"
assert_true 'large rawfile byte parity' cmp -s "$tmpdir/expected" "$tmpdir/actual"
pass 'JSON helper: 8 MiB rawfile byte parity'
proxies='{"proxies":{"GLOBAL":{"all":["Z","A","Z","hidden","GLOBAL","missing"]},"Z":{"type":"Selector","now":"one","all":["one","two"]},"A":{"type":"URLTest","all":[],"fixed":false},"B":{"type":"Fallback","now":null,"all":null},"hidden":{"type":"Selector","hidden":true},"one":{"history":[{"delay":1.0},{"delay":1e2}]},"two":{"history":[{"delay":0}]}}}'
# Keep the original runtime filter as the independent oracle.
filter='
		.proxies as $p
		| reduce (((($p.GLOBAL.all // []) + ($p | keys))[])
		    | select(. != "GLOBAL")
		    | select($p[.] != null and ($p[.].hidden | not)
		        and ($p[.].type | IN("Selector", "URLTest", "Fallback", "LoadBalance")))) as $k
		    ({seen: {}, out: []}; if .seen[$k] then . else .seen[$k] = true | .out += [$k] end)
		| [.out[] | {key: ., value: $p[.]}
		 | {name: .key, type: .value.type, now: .value.now, all: .value.all, fixed: (.value.fixed // ""),
		    delays: ([(.value.all // [])[] as $n | ($p[$n].history // []) | select(length > 0) | {($n): .[-1].delay}] | add // {})}]'
parity 'proxy group ordering, dedup, defaults and history' "$(jq -c "$filter" <<<"$proxies")" proxies <<<"$proxies"
parity 'status keeps a multiline settings error as one entry' "$(jq -nc '{running:false,enabled:false,state:"failed",last_error:"",version:"",core:"",dashboard_installed:false,core_installed:false,subscription_configured:false,subscription_insecure:false,config_valid:null,config_backup:false,config_error:"",dns_mode:"",dns_ok:null,policy_active:false,mode:"",block_client_ipv6:false,interfaces:[],custom_dns_servers:[],lists:{dst:0,src:0,direct:0,direct_src:0},route:{table:"",priority:""},errors:["first\nsecond"]}')" build status --argjson running false --argjson enabled false --arg state failed --arg last_error '' --arg version '' --arg core '' --argjson dashboard_installed false --arg url '' --argjson config_valid null --argjson config_backup false --arg config_error '' --arg dns_mode '' --argjson dns_ok null --argjson policy false --arg mode '' --arg block_client_ipv6 0 --arg interfaces '' --arg custom '' --arg dst 0 --arg src 0 --arg direct 0 --arg direct_src 0 --arg table '' --arg priority '' --arg errors $'first\nsecond'
parity 'empty history stream is silent' '' history last </dev/null
parity 'empty pruning stream is silent' '' history prune </dev/null
for bytes in '\xff\xc0\xaf' '\xe2\x82' '\xe2\x82A' '\xed\xa0\x80' '\xf4\x90\x80\x80' '\xe0\x80\x80' '\xf5\x80\x80\x80'; do
 printf '%b' "$bytes" >"$tmpdir/invalid"
 parity "rawfile invalid UTF-8 [$bytes]" "$(jq -nc --rawfile content "$tmpdir/invalid" '{content:$content}')" build object --rawfile content "$tmpdir/invalid"
 parity "URI invalid UTF-8 [$bytes]" "$(jq -sRr @uri <"$tmpdir/invalid")" uri <"$tmpdir/invalid"
done
for input in '{"n":1,"a":[0,42,-42],"s":"1.5"}' '{"n":1.5,"a":[1,2.00]}' '{"n":1e2}' '{"n":9007199254740993}' '{"n":-9007199254740993}' '{"n":-0}' '{"n":9007199254740992}' '{"n":-9007199254740992}'; do
 parity "native/decimal parser parity [$input]" "$(jq -c '.+{now:2}' <<<"$input")" merge object --argjson now 2 <<<"$input"
done
for input in '{"n":Infinity}' '{"n":-Infinity}' '{"n":NaN}' '{"d":1.0,"n":Infinity}'; do
 parity "non-finite JSON number parity [$input]" "$(jq -c '.+{now:2}' <<<"$input")" merge object --argjson now 2 <<<"$input"
done
# jq clamps/underflows here; parity intentionally not kept for out-of-double-range exponents.
for number in 1e1000000000 1e-99999999999999; do
 "$helper" build metadata --arg interval "$number" >"$tmpdir/extreme.json"
 assert_true "out-of-double-range exponent $number stays valid JSON" jq -e 'type == "object" and (.header_interval | type) == "number"' "$tmpdir/extreme.json" >/dev/null
 pass "JSON helper: out-of-double-range exponent $number stays valid JSON"
done
# json-c accepts extensions which jq rejects. Neither parser path may hang or accept them.
for input in '/* comment */{"a":1.5}' $'{"a":1.5// comment\n}' '{"a":1.5/* comment */}' "{'a':1.5}" '{"a":1.5,}' '[1.5,]' '{"a":1.5' "{\"a\":1.5,'x':1}" '{"a":1.5/*"*/}' '/* comment */{"a":1}' '{"a":1,}' '{"a":1/*"*/}'; do
 rc=0
 timeout 5 "$helper" object <<<"$input" >"$tmpdir/malformed.out" 2>"$tmpdir/malformed.err" || rc=$?
 assert_eq 1 "$rc" "malformed JSON rejects without hanging [$input]"
 assert_false 'malformed JSON emits no stdout' test -s "$tmpdir/malformed.out"
 assert_false 'jq rejects the same malformed input' jq -e . <<<"$input" >/dev/null 2>&1
 pass "JSON helper: malformed input rejects within timeout [$input]"
done
for input in '{"a":1.5,"x":"quote\" : []"}' '{"a":[1.50,{"b":true},null],"x":{"empty":[],"obj":{}}}' $'{\n "a" : 1.5, "x" : [false, "1.5"]\n}'; do
 parity 'tokenized nested/escaped JSON parity' "$(jq -c . <<<"$input")" object <<<"$input"
done
rc=0
"$helper" object <<< 'not-json' >"$tmpdir/error.out" 2>"$tmpdir/error.err" || rc=$?
assert_eq 1 "$rc" 'JSON parse error exit status'
assert_eq 1 "$(wc -l <"$tmpdir/error.err" | tr -d ' ')" 'JSON parse error has one line for job stderr'
assert_file_not_contains "$tmpdir/error.err" 'stacktrace' 'JSON parse error hides stack frames'
# Native errors currently stringify only their message. Force a structured error
# at the real handler entry to pin the message-only branch without a production hook.
sed "s/} catch (e) {/} catch (e) { e = {message: 'safe JSON error', stacktrace: ['private stack frame']};/" "$helper" >"$tmpdir/structured-error.uc"
rc=0
ucode "$tmpdir/structured-error.uc" object <<< 'not-json' >"$tmpdir/error.out" 2>"$tmpdir/error.err" || rc=$?
assert_eq 1 "$rc" 'structured JSON error exit status'
assert_eq 'mihowrt-json: safe JSON error' "$(cat "$tmpdir/error.err")" 'structured JSON error exposes message only'
pass 'JSON helper: error handler prints message only, without stack trace'
# Read-only snapshots deliberately keep malformed numeric state as null, not jq errors.
status_args=(--argjson running false --argjson enabled false --arg state stopped --arg last_error '' --arg version '' --arg core '' --argjson dashboard_installed false --arg url '' --argjson config_valid null --argjson config_backup false --arg config_error '' --arg dns_mode '' --argjson dns_ok null --argjson policy false --arg mode '' --arg block_client_ipv6 0 --arg interfaces '' --arg custom '' --arg dst '' --arg src not-a-number --arg direct 0 --arg direct_src 0 --arg table '' --arg priority '' --arg errors '')
"$helper" build status "${status_args[@]}" >"$tmpdir/lenient-status.json"
assert_true 'status numeric snapshot leniency' jq -e '.lists == {dst:null,src:null,direct:0,direct_src:0}' "$tmpdir/lenient-status.json" >/dev/null
pass 'JSON helper: empty and malformed status counts are null'
parity 'empty profile counts are null' '{"dashboard_installed":false,"mode":"proxy-first","dns":"redir-host","provider":{},"overrides":[],"lists":{"dst":{"provided":false,"provider_count":null,"own_count":null,"source":"own"},"direct":{"provided":false,"provider_count":null,"own_count":null,"source":"own"}}}' build profile --argjson dashboard_installed false --arg mode proxy-first --arg dns redir-host --arg provider '' --arg overrides '' --argjson dst_provided false --arg dst_provider '' --arg dst_own '' --arg dst_source own --argjson direct_provided false --arg direct_provider '' --arg direct_own '' --arg direct_source own
parity 'malformed open proxy ports are null' '{"conflicts":[],"flash_free_kb":null,"tmp_clash_kb":null,"tmp_free_kb":null,"ram_available_kb":null,"mihomo_rss_kb":null,"open_proxy_ports":[null,null]}' build diagnostics --arg conflicts '' --arg flash '' --arg tmp_clash '' --arg tmp_free '' --arg ram '' --arg rss '' --arg ports $' \nnot-a-number'
parity 'empty open proxy ports stay empty' '{"conflicts":[],"flash_free_kb":null,"tmp_clash_kb":null,"tmp_free_kb":null,"ram_available_kb":null,"mihomo_rss_kb":null,"open_proxy_ports":[]}' build diagnostics --arg ports ''
printf '%s\n' '{"id":"10-3","started":10,"state":"ok"}' >"$tmpdir/history-valid.json"
printf '%s\n' '{"id":"10-x","started":10,"state":"ok"}' >"$tmpdir/history-invalid.json"
parity 'non-numeric history id segment sorts as null' $'[\n  {\n    "id": "10-x",\n    "started": 10,\n    "state": "ok"\n  },\n  {\n    "id": "10-3",\n    "started": 10,\n    "state": "ok"\n  }\n]' history sort "$tmpdir/history-valid.json" "$tmpdir/history-invalid.json"
