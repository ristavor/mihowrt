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
pass "IPv6 validators agree"
