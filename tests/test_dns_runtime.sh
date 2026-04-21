#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

uci_log="$tmpdir/uci.log"
dns_log="$tmpdir/dns.log"
event_log="$tmpdir/events.log"
backup_file="$tmpdir/dns.backup"
runtime_backup_file="$tmpdir/run/dns.backup"

export DNS_BACKUP_FILE="$backup_file"
export DNS_RUNTIME_BACKUP_FILE="$runtime_backup_file"
export PKG_STATE_DIR="$tmpdir/run"
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

rm -f "$backup_file" "$runtime_backup_file"
: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
dns_setup
[[ ! -s "$uci_log" ]] || fail "dns_setup should not overwrite backup from already-hijacked dnsmasq state"
[[ ! -s "$dns_log" ]] || fail "dns_setup should not restart dnsmasq when hijack state is already active without backup"
[[ ! -f "$backup_file" ]] || fail "dns_setup should not create persistent backup from dirty hijacked state"
[[ ! -f "$runtime_backup_file" ]] || fail "dns_setup should not create runtime backup from dirty hijacked state"
assert_file_contains "$event_log" "warn:dnsmasq already configured to use Mihomo DNS 127.0.0.1#7874, but no recovery backup is active; fallback restore will be used if cleanup is needed" "dns_setup should warn when hijack state is active but backup is missing"

: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="1000"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE="/tmp/original.resolv"
TEST_CURRENT_SERVERS=$'1.1.1.1\n9.9.9.9'
dns_backup_state
[[ -f "$runtime_backup_file" ]] || fail "dns_backup_state should create runtime backup copy"

: > "$uci_log"
: > "$dns_log"
dns_restore
[[ ! -s "$uci_log" ]] || fail "dns_restore should skip no-op dhcp writes when backup state is already active"
[[ ! -s "$dns_log" ]] || fail "dns_restore should skip dnsmasq restart when backup state is already active"
[[ ! -e "$runtime_backup_file" ]] || fail "dns_restore should clear runtime backup marker after clean restore"
[[ -e "$backup_file" ]] || fail "dns_restore should keep persistent backup cache after clean restore"

: > "$uci_log"
: > "$dns_log"
: > "$event_log"
: > "$DNS_AUTO_RESOLVFILE"
rm -f "$backup_file" "$runtime_backup_file"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
dns_restore
assert_file_contains "$event_log" "warn:dnsmasq recovery backup unavailable while Mihomo DNS still appears active; applying fallback recovery" "dns_restore should fall back when hijack remains but backup is gone"
assert_file_contains "$uci_log" "delete dhcp.@dnsmasq[0].server" "dns_restore fallback should clear hijacked dnsmasq servers"
assert_file_contains "$uci_log" "set dhcp.@dnsmasq[0].noresolv=0" "dns_restore fallback should disable noresolv"
assert_file_contains "$uci_log" "set dhcp.@dnsmasq[0].resolvfile=$DNS_AUTO_RESOLVFILE" "dns_restore fallback should restore auto resolvfile"
assert_file_contains "$uci_log" "commit dhcp" "dns_restore fallback should commit dnsmasq defaults"
assert_file_contains "$dns_log" "restart" "dns_restore fallback should restart dnsmasq"

mkdir -p "$(dirname "$runtime_backup_file")"
: > "$runtime_backup_file"
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
[[ ! -e "$runtime_backup_file" ]] || fail "dns_restore_fallback should remove runtime backup marker after no-op fallback"

pass "runtime DNS no-op paths"
