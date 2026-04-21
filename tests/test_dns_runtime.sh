#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

uci_log="$tmpdir/uci.log"
dns_log="$tmpdir/dns.log"
event_log="$tmpdir/events.log"
backup_file="$tmpdir/dns.backup"

export DNS_BACKUP_FILE="$backup_file"
export PKG_PERSIST_DIR="$tmpdir/persist"
export MIHOMO_DNS_LISTEN="0.0.0.0#7874"
export DNS_AUTO_RESOLVFILE="$tmpdir/resolv.conf.auto"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns-state.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns.sh"

log() {
	printf 'log:%s\n' "$*" >>"$event_log"
}

warn() {
	printf 'warn:%s\n' "$*" >>"$event_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$event_log"
}

ensure_dir() {
	mkdir -p "$1"
}

dns_restart_service() {
	printf 'restart\n' >>"$dns_log"
	return 0
}

uci() {
	if [[ "${1:-}" == "-q" && "${2:-}" == "get" ]]; then
		case "${3:-}" in
			'dhcp.@dnsmasq[0].cachesize')
				printf '%s\n' "${TEST_CURRENT_CACHESIZE:-}"
				return 0
				;;
			'dhcp.@dnsmasq[0].noresolv')
				printf '%s\n' "${TEST_CURRENT_NORESOLV:-}"
				return 0
				;;
			'dhcp.@dnsmasq[0].resolvfile')
				printf '%s\n' "${TEST_CURRENT_RESOLVFILE:-}"
				return 0
				;;
			'dhcp.@dnsmasq[0].server')
				printf '%s\n' "${TEST_CURRENT_SERVERS:-}"
				return 0
				;;
		esac
		return 1
	fi

	if [[ "${1:-}" == "-q" && "${2:-}" == "delete" ]]; then
		printf 'delete %s\n' "${3:-}" >>"$uci_log"
		return 0
	fi

	case "${1:-}" in
		add_list)
			printf 'add_list %s\n' "${2:-}" >>"$uci_log"
			;;
		set)
			printf 'set %s\n' "${2:-}" >>"$uci_log"
			;;
		commit)
			printf 'commit %s\n' "${2:-}" >>"$uci_log"
			;;
		*)
			return 1
			;;
	esac

	return 0
}

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
ORIG_SERVER=9.9.9.9
EOF

: > "$uci_log"
: > "$dns_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
dns_setup
[[ ! -s "$uci_log" ]] || fail "dns_setup should skip no-op dhcp writes when Mihomo DNS is already active"
[[ ! -s "$dns_log" ]] || fail "dns_setup should skip dnsmasq restart when Mihomo DNS is already active"

: > "$uci_log"
: > "$dns_log"
TEST_CURRENT_CACHESIZE="1000"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE="/tmp/original.resolv"
TEST_CURRENT_SERVERS=$'1.1.1.1\n9.9.9.9'
dns_restore
[[ ! -s "$uci_log" ]] || fail "dns_restore should skip no-op dhcp writes when backup state is already active"
[[ ! -s "$dns_log" ]] || fail "dns_restore should skip dnsmasq restart when backup state is already active"
[[ ! -e "$backup_file" ]] || fail "dns_restore should remove backup marker after no-op restore"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
EOF
: > "$uci_log"
: > "$dns_log"
: > "$DNS_AUTO_RESOLVFILE"
TEST_CURRENT_CACHESIZE=""
TEST_CURRENT_NORESOLV="0"
TEST_CURRENT_RESOLVFILE="$DNS_AUTO_RESOLVFILE"
TEST_CURRENT_SERVERS=""
dns_restore_fallback
[[ ! -s "$uci_log" ]] || fail "dns_restore_fallback should skip no-op dhcp writes when fallback state is already active"
[[ ! -s "$dns_log" ]] || fail "dns_restore_fallback should skip dnsmasq restart when fallback state is already active"
[[ ! -e "$backup_file" ]] || fail "dns_restore_fallback should remove backup marker after no-op fallback"

pass "runtime DNS no-op paths"
