#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/uci" <<'UCI'
#!/bin/sh
[ "$1" != -q ] || shift
[ -z "${UCI_CALLS:-}" ] || printf '%s\n' "$*" >>"$UCI_CALLS"
case "$1" in
show) cat "$UCI_FIXTURE.show" ;;
get) awk -v key="$2=" 'index($0,key)==1 {print substr($0,length(key)+1); found=1; exit} END {exit !found}' "$UCI_FIXTURE.get" ;;
*) exit 1 ;;
esac
UCI
chmod +x "$tmpdir/bin/uci"
export PATH="$tmpdir/bin:$PATH" UCI_CALLS="$tmpdir/uci-calls"
cat >"$tmpdir/snapshot.sh" <<'ASH'
#!/bin/ash
for module in constants helpers validate settings; do . "$MIHOWRT_LIB_DIR/$module.sh"; done
profile_ensure() { return 0; }
profile_get() { case "$1" in mode) echo direct-first ;; dns) echo fake-ip ;; direct_listener) echo 1 ;; 'set disable_quic') echo 0 ;; 'set dns_hijack') echo 0 ;; esac; }
profile_entries() { printf 'disable_quic 0\ndns_hijack 0\n'; }
API_SECRET_FILE="$SNAPSHOT_TMP/secret"
SUBSCRIPTION_META_FILE="$SNAPSHOT_TMP/meta"
settings_load || exit 1
for key in POLICY_MODE DNS_MODE DIRECT_LISTENER PROVIDER_KEYS PROVIDER_OVERRIDES DST_LIST_SOURCE DIRECT_LIST_SOURCE SOURCE_INTERFACES DNS_HIJACK DISABLE_QUIC NETBIRD_PROXY BYPASS_NTP BYPASS_SUBSCRIPTION_DNS BLOCK_CLIENT_IPV6 NETBIRD_MARK NETBIRD_INTERFACE SUBSCRIPTION_URL SUBSCRIPTION_INTERVAL LISTS_INTERVAL API_SECRET CRON_MINUTE DASHBOARD_ENABLED SETTINGS_LOADED; do
 eval 'value="${'"$key"'}"'
 printf '%s=%s\n' "$key" "$value"
done
ASH
export SNAPSHOT_TMP="$tmpdir"
printf 'fixture-secret\n' >"$tmpdir/secret"
printf '{"header_interval":12}\n' >"$tmpdir/meta"
mkdir -p "$tmpdir/bb"
ln -s "$(command -v busybox)" "$tmpdir/bb/awk"
for awk_impl in default busybox; do
path="$PATH"
[ "$awk_impl" = default ] || path="$tmpdir/bb:$PATH"
for name in defaults full lists quoting; do
 export UCI_FIXTURE="$ROOT_DIR/tests/fixtures/settings/$name"
 : >"$UCI_CALLS"
 PATH="$path" ash "$tmpdir/snapshot.sh" >"$tmpdir/$name.actual"
 if [ "${CAPTURE_SETTINGS_SNAPSHOTS:-0}" = 1 ]; then
  cp "$tmpdir/$name.actual" "$UCI_FIXTURE.snapshot"
 else
  assert_true "$awk_impl awk: $name settings identical to pre-X6 snapshot" cmp -s "$UCI_FIXTURE.snapshot" "$tmpdir/$name.actual"
  assert_eq 1 "$(grep -c '^show mihowrt$' "$UCI_CALLS" || true)" "$name one UCI show pass"
  assert_eq 0 "$(grep -c '^get mihowrt' "$UCI_CALLS" || true)" "$name no per-option UCI get"
 fi
done
# Values are eval'd: backticks, $() and a multi-line value must stay literal.
printf '%s\n' "mihowrt.settings='settings'" \
 "mihowrt.settings.provider_override='\`touch $tmpdir/pwned1\`\$(touch $tmpdir/pwned2)' 'line1" "touch $tmpdir/pwned3'" >"$tmpdir/inject.show"
: >"$tmpdir/inject.get"
UCI_FIXTURE="$tmpdir/inject" PATH="$path" ash "$tmpdir/snapshot.sh" >"$tmpdir/inject.actual" || true
assert_false "$awk_impl awk: injected settings never execute" test -e "$tmpdir/pwned1" -o -e "$tmpdir/pwned2" -o -e "$tmpdir/pwned3"
assert_true "$awk_impl awk: backtick value stays literal" grep -qF "PROVIDER_OVERRIDES=\`touch $tmpdir/pwned1\`\$(touch $tmpdir/pwned2)" "$tmpdir/inject.actual"
done
pass 'settings_load defaults, full, lists and quoting snapshots in ash (default and BusyBox awk)'
