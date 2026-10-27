#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
load_modules constants.sh helpers.sh validate.sh lists.sh

tmpdir="$(make_temp_dir)"
upload="/tmp/mihowrt-policy-list.ports.$$"
trap 'rm -rf "$tmpdir"; rm -f "$upload"' EXIT
setup_fake_uci "$tmpdir"
setup_runtime_paths "$tmpdir"
lists_ensure_files
settings_load() { :; }
cron_update() { :; }

for addr in 1.2.3.4 1.2.3.0/24 2001:db8::1 2001:db8::/32; do
 for ports in '' 0 65536 443-80 '80,' '80;;443'; do
  entry="$addr;$ports"
  assert_false "shell rejects invalid ports in $entry" is_port_spec "${entry#*;}"
 done
 for ports in 443 80,443 8000-8080; do
  entry="$addr;$ports"
  assert_true "shell accepts ports in $entry" is_port_spec "${entry#*;}"
 done
done
pass 'shell list port validation'

for awk_impl in default busybox; do
 (
  if [ "$awk_impl" = busybox ]; then awk() { busybox awk "$@"; }; fi
  for addr in 1.2.3.4 1.2.3.0/24 2001:db8::1 2001:db8::/32; do
   case "$addr" in *:*) family=6 ;; *) family=4 ;; esac
   for ports in '' 0 65536 443-80 '80,' '80;;443'; do
    entry="$addr;$ports"
    assert_eq '' "$(printf '%s\n' "$entry" | lists_classify)" "$awk_impl rejects $entry"
    assert_eq "$entry" "$(printf '%s\n' "$entry" | lists_classify 1)" "$awk_impl reports $entry as invalid"
   done
   for entry in "$addr" "$addr;443" "$addr;80,443" "$addr;8000-8080"; do
    assert_eq "$family $entry" "$(printf '%s\n' "$entry" | lists_classify)" "$awk_impl accepts $entry"
   done
  done
 )
done
pass 'awk list port validation'

for entry in '1.2.3.4;' '1.2.3.0/24;' '2001:db8::1;' '2001:db8::/32;' 'https://lists.example/list;'; do
 printf '%s\n' "$entry" >"$upload"
 assert_false "install rejects empty ports: $entry" lists_install "$upload" - - - >"$tmpdir/out" 2>"$tmpdir/err"
 assert_file_contains "$tmpdir/err" "Invalid dst entries: $entry" 'invalid entry reported before install'
 assert_false 'invalid upload not installed' test -s "$DST_LIST_FILE"
done
pass 'list install rejects empty ports'
