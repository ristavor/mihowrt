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
export DNS_BACKUP_FILE="$PKG_PERSIST_DIR/dns.backup"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns.sh"

assert_false "dns recovery should ignore missing backup" dns_recovery_needed

dns_backup_state

[[ -f "$DNS_BACKUP_FILE" ]] || fail "dns backup file missing"
assert_file_contains "$DNS_BACKUP_FILE" "DNSMASQ_BACKUP=1" "backup marker missing"
assert_file_contains "$DNS_BACKUP_FILE" "ORIG_SERVER=1.1.1.1" "first DNS server missing"
assert_file_contains "$DNS_BACKUP_FILE" "ORIG_SERVER=9.9.9.9" "second DNS server missing"
assert_true "dns backup should validate" dns_backup_valid
assert_true "dns recovery should trigger when backup exists" dns_recovery_needed

dns_cleanup_backup_files
assert_false "dns recovery should clear once backup removed" dns_recovery_needed

pass "dns backup detection uses persistent backup only"
