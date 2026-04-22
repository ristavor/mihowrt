#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/uci" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-q" && "${2:-}" == "get" ]]; then
	case "${3:-}" in
		'dhcp.@dnsmasq[0].cachesize') printf '1000\n' ;;
		'dhcp.@dnsmasq[0].noresolv') printf '0\n' ;;
		'dhcp.@dnsmasq[0].resolvfile') printf '/tmp/resolv.conf.d/resolv.conf.auto\n' ;;
		'dhcp.@dnsmasq[0].server') printf '1.1.1.1\n9.9.9.9\n' ;;
		*) exit 1 ;;
	esac
else
	exit 1
fi
EOF

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmpbin/uci" "$tmpbin/logger"
export PATH="$tmpbin:$PATH"

export PKG_PERSIST_DIR="$tmpdir/etc/mihowrt"
export PKG_STATE_DIR="$tmpdir/run"
export DNS_BACKUP_FILE="$PKG_PERSIST_DIR/dns.backup"
export DNS_RUNTIME_BACKUP_FILE="$PKG_STATE_DIR/dns.backup"
export MIHOMO_DNS_LISTEN="0.0.0.0#7874"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns-state.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns.sh"

assert_false "dns backup should stay inactive without runtime copy or hijacked state" dns_backup_exists

dns_backup_state

[[ -f "$DNS_BACKUP_FILE" ]] || fail "dns backup file missing"
[[ -f "$DNS_RUNTIME_BACKUP_FILE" ]] || fail "runtime dns backup file missing"
assert_file_contains "$DNS_BACKUP_FILE" "DNSMASQ_BACKUP=1" "backup marker missing"
assert_file_contains "$DNS_BACKUP_FILE" "MIHOMO_DNS_TARGET=127.0.0.1#7874" "Mihomo DNS target metadata missing"
assert_file_contains "$DNS_BACKUP_FILE" "ORIG_SERVER=1.1.1.1" "first DNS server missing"
assert_file_contains "$DNS_BACKUP_FILE" "ORIG_SERVER=9.9.9.9" "second DNS server missing"
assert_true "dns backup should validate" dns_backup_valid
assert_true "dns backup should stay active while runtime copy exists" dns_backup_exists

touch -d '2020-01-01 00:00:00' "$DNS_BACKUP_FILE"
before_persist_mtime="$(stat -c %Y "$DNS_BACKUP_FILE")"
dns_cleanup_backup_files
[[ ! -f "$DNS_RUNTIME_BACKUP_FILE" ]] || fail "runtime dns backup should be removed on cleanup"
[[ -f "$DNS_BACKUP_FILE" ]] || fail "persistent dns backup cache should remain after cleanup"
assert_false "dns backup should not stay active from cached persistent copy alone" dns_backup_exists
assert_false "dns backup should not report valid active backup from cached persistent copy alone" dns_backup_valid

dns_backup_state
after_persist_mtime="$(stat -c %Y "$DNS_BACKUP_FILE")"
assert_eq "$before_persist_mtime" "$after_persist_mtime" "dns_backup_state should skip rewriting identical persistent backup cache"
assert_true "dns backup should reactivate after runtime copy returns" dns_backup_exists

cat > "$DNS_BACKUP_FILE" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=maybe
ORIG_RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
EOF
assert_false "dns_persist_backup_valid should reject invalid ORIG_NORESOLV values" dns_persist_backup_valid

cat > "$DNS_BACKUP_FILE" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=abc
ORIG_NORESOLV=0
ORIG_RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
EOF
assert_false "dns_persist_backup_valid should reject non-numeric ORIG_CACHESIZE values" dns_persist_backup_valid

cat > "$DNS_BACKUP_FILE" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=bad-target
ORIG_CACHESIZE=1000
ORIG_NORESOLV=0
ORIG_RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
EOF
assert_false "dns_persist_backup_valid should reject invalid MIHOMO_DNS_TARGET values" dns_persist_backup_valid

cat > "$DNS_BACKUP_FILE" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=0
ORIG_RESOLVFILE=relative.resolv
EOF
assert_false "dns_persist_backup_valid should reject non-absolute ORIG_RESOLVFILE values" dns_persist_backup_valid

cat > "$DNS_BACKUP_FILE" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=0
ORIG_RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
ORIG_SERVER=1.1.1.1#99999
EOF
assert_false "dns_persist_backup_valid should reject invalid ORIG_SERVER values" dns_persist_backup_valid

pass "dns backup runtime/cache semantics"
