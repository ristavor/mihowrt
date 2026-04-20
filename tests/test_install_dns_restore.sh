#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

uci_log="$tmpdir/uci.log"
dns_log="$tmpdir/dns.log"
backup_file="$tmpdir/dns.backup"

export DNS_BACKUP_FILE="$backup_file"
export DNS_BACKUP_NAME="dns.backup"
export DNS_AUTO_RESOLVFILE="$tmpdir/resolv.conf.auto"
export BACKUP_DIR=""
export UCI_LOG="$uci_log"
export DNS_LOG="$dns_log"

: > "$DNS_AUTO_RESOLVFILE"

source_install_lib

DNS_BACKUP_FILE="$backup_file"
DNS_BACKUP_NAME="dns.backup"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.conf.auto"
BACKUP_DIR=""

log() {
	:
}

uci() {
	if [[ "${1:-}" == "-q" && "${2:-}" == "get" ]]; then
		case "${3:-}" in
			'dhcp.@dnsmasq[0].noresolv')
				printf '%s\n' "${TEST_UCI_NORESOLV:-0}"
				return 0
				;;
		esac
		return 1
	fi

	if [[ "${1:-}" == "-q" && "${2:-}" == "delete" ]]; then
		printf 'delete %s\n' "${3:-}" >>"$UCI_LOG"
		return 0
	fi

	case "${1:-}" in
		add_list)
			printf 'add_list %s\n' "${2:-}" >>"$UCI_LOG"
			;;
		set)
			printf 'set %s\n' "${2:-}" >>"$UCI_LOG"
			;;
		commit)
			printf 'commit %s\n' "${2:-}" >>"$UCI_LOG"
			;;
		*)
			return 1
			;;
	esac

	return 0
}

restart_dnsmasq() {
	printf 'restart\n' >>"$DNS_LOG"
}

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
ORIG_SERVER=9.9.9.9
EOF

: > "$UCI_LOG"
: > "$DNS_LOG"
restore_dns_from_backup_file "$backup_file"
assert_file_contains "$UCI_LOG" "delete dhcp.@dnsmasq[0].server" "restore_dns_from_backup_file should clear current dnsmasq servers"
assert_file_contains "$UCI_LOG" "delete dhcp.@dnsmasq[0].resolvfile" "restore_dns_from_backup_file should clear current resolvfile"
assert_file_contains "$UCI_LOG" "add_list dhcp.@dnsmasq[0].server=1.1.1.1" "restore_dns_from_backup_file should restore first server"
assert_file_contains "$UCI_LOG" "add_list dhcp.@dnsmasq[0].server=9.9.9.9" "restore_dns_from_backup_file should restore second server"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].cachesize=1000" "restore_dns_from_backup_file should restore cache size"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].noresolv=1" "restore_dns_from_backup_file should restore noresolv"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=/tmp/original.resolv" "restore_dns_from_backup_file should restore resolvfile"
assert_file_contains "$UCI_LOG" "commit dhcp" "restore_dns_from_backup_file should commit dhcp config"
assert_file_contains "$DNS_LOG" "restart" "restore_dns_from_backup_file should restart dnsmasq"

rm -f "$backup_file"
: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_UCI_NORESOLV="1"
restore_system_dns_defaults 1
assert_file_contains "$UCI_LOG" "delete dhcp.@dnsmasq[0].server" "restore_system_dns_defaults fallback should clear servers"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].noresolv=0" "restore_system_dns_defaults fallback should disable noresolv"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=$DNS_AUTO_RESOLVFILE" "restore_system_dns_defaults fallback should restore auto resolvfile"
assert_file_contains "$UCI_LOG" "commit dhcp" "restore_system_dns_defaults fallback should commit dhcp config"
assert_file_contains "$DNS_LOG" "restart" "restore_system_dns_defaults fallback should restart dnsmasq"

: > "$UCI_LOG"
: > "$DNS_LOG"
mkdir -p "$tmpdir/saved-backup"
BACKUP_DIR="$tmpdir/saved-backup"
cat > "$BACKUP_DIR/$DNS_BACKUP_NAME" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=4096
ORIG_NORESOLV=0
ORIG_RESOLVFILE=/tmp/saved.resolv
EOF
restore_system_dns_defaults 0
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].cachesize=4096" "restore_system_dns_defaults should use saved backup cachesize"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].noresolv=0" "restore_system_dns_defaults should use saved backup noresolv"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=/tmp/saved.resolv" "restore_system_dns_defaults should use saved backup resolvfile"
assert_file_contains "$DNS_LOG" "restart" "restore_system_dns_defaults should restart dnsmasq from saved backup"

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_UCI_NORESOLV="1"
BACKUP_DIR=""
restore_system_dns_defaults 0
[[ ! -s "$UCI_LOG" ]] || fail "restore_system_dns_defaults should not touch dhcp config without allow_fallback"
[[ ! -s "$DNS_LOG" ]] || fail "restore_system_dns_defaults should not restart dnsmasq without allow_fallback"

pass "installer DNS restore paths"
