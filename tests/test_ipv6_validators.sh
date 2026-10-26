#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
load_modules validate.sh lists.sh

for value in ::1 1::/64 2001:db8::1 fe80::1 ::ffff:1.2.3.4 1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:8:9 1::2::3 12345:: :::; do
 # is_ipv6 validates addresses; lists_classify additionally accepts CIDRs.
 expected=""
 if is_ipv6 "${value%/*}"; then expected="6 $value"; fi
 assert_eq "$expected" "$(printf '%s\n' "$value" | lists_classify)" "IPv6 validators agree for $value"
done
for awk_impl in default busybox; do
 (
  if [ "$awk_impl" = busybox ]; then awk() { busybox awk "$@"; }; fi
  assert_eq '' "$(printf '1::/129\n' | lists_classify)" "$awk_impl rejects IPv6 prefix above 128"
  assert_eq '1::/129' "$(printf '1::/129\n' | lists_classify 1)" "$awk_impl reports invalid IPv6 prefix"
 )
done
pass "IPv6 validators agree"
