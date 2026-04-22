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
	return "${TEST_DNS_RESTART_RC:-0}"
}

uci() {
	local cmd=""

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
		cmd="delete ${3:-}"
		printf '%s\n' "$cmd" >>"$uci_log"
		[[ -n "${TEST_FAIL_UCI_CMD:-}" && "$cmd" == "$TEST_FAIL_UCI_CMD" ]] && return 1
		return 0
	fi

	case "${1:-}" in
		add_list)
			cmd="add_list ${2:-}"
			;;
		set)
			cmd="set ${2:-}"
			;;
		commit)
			cmd="commit ${2:-}"
			;;
		revert)
			cmd="revert ${2:-}"
			;;
		*)
			return 1
			;;
	esac

	printf '%s\n' "$cmd" >>"$uci_log"
	[[ -n "${TEST_FAIL_UCI_CMD:-}" && "$cmd" == "$TEST_FAIL_UCI_CMD" ]] && return 1

	return 0
}

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
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

: > "$event_log"
TEST_CURRENT_CACHESIZE="1000"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE="/tmp/original.resolv"
TEST_CURRENT_SERVERS=$'1.1.1.1\n9.9.9.9'
dns_backup_state
: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="add_list dhcp.@dnsmasq[0].server=1.1.1.1"
assert_false "dns_restore should fail when restoring dnsmasq server list fails" dns_restore
assert_file_not_contains "$uci_log" "commit dhcp" "dns_restore should not commit partial restore after mutator failure"
assert_file_contains "$uci_log" "revert dhcp" "dns_restore should revert staged dhcp changes after restore failure"
[[ ! -s "$dns_log" ]] || fail "dns_restore should not restart dnsmasq after mutator failure"
assert_file_not_contains "$event_log" "log:dnsmasq settings restored" "dns_restore should not report success after mutator failure"
[[ -e "$runtime_backup_file" ]] || fail "dns_restore should keep runtime backup after restore failure"
unset TEST_FAIL_UCI_CMD

: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="delete dhcp.@dnsmasq[0].server"
assert_false "dns_restore should fail when clearing existing dnsmasq server state fails" dns_restore
assert_file_not_contains "$uci_log" "commit dhcp" "dns_restore should not commit when delete mutator fails"
assert_file_contains "$uci_log" "revert dhcp" "dns_restore should revert staged dhcp changes after delete failure"
[[ ! -s "$dns_log" ]] || fail "dns_restore should not restart dnsmasq after delete failure"
unset TEST_FAIL_UCI_CMD

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
: > "$event_log"
: > "$DNS_AUTO_RESOLVFILE"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="set dhcp.@dnsmasq[0].noresolv=0"
assert_false "dns_restore_fallback should fail when restoring noresolv fails" dns_restore_fallback
assert_file_not_contains "$uci_log" "commit dhcp" "dns_restore_fallback should not commit partial fallback restore"
assert_file_contains "$uci_log" "revert dhcp" "dns_restore_fallback should revert staged dhcp changes after failure"
[[ ! -s "$dns_log" ]] || fail "dns_restore_fallback should not restart dnsmasq after fallback mutator failure"
assert_file_not_contains "$event_log" "log:dnsmasq fallback state already active" "dns_restore_fallback should not claim no-op success on write failure"
[[ -e "$runtime_backup_file" ]] || fail "dns_restore_fallback should keep runtime backup after failure"
unset TEST_FAIL_UCI_CMD

: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="delete dhcp.@dnsmasq[0].server"
assert_false "dns_restore_fallback should fail when clearing hijacked dnsmasq servers fails" dns_restore_fallback
assert_file_not_contains "$uci_log" "commit dhcp" "dns_restore_fallback should not commit when delete mutator fails"
assert_file_contains "$uci_log" "revert dhcp" "dns_restore_fallback should revert staged dhcp changes after delete failure"
[[ ! -s "$dns_log" ]] || fail "dns_restore_fallback should not restart dnsmasq after delete failure"
unset TEST_FAIL_UCI_CMD

: > "$event_log"
TEST_CURRENT_CACHESIZE="1000"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE="/tmp/original.resolv"
TEST_CURRENT_SERVERS=$'1.1.1.1\n9.9.9.9'
dns_backup_state
: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_DNS_RESTART_RC=1
assert_false "dns_restore should fail when dnsmasq restart fails after commit" dns_restore
assert_file_contains "$uci_log" "commit dhcp" "dns_restore should still commit restored state before restart failure"
assert_file_contains "$dns_log" "restart" "dns_restore should attempt dnsmasq restart before failing"
[[ -e "$runtime_backup_file" ]] || fail "dns_restore should keep runtime backup after restart failure"
assert_file_not_contains "$event_log" "log:dnsmasq settings restored" "dns_restore should not report success when dnsmasq restart fails"
TEST_DNS_RESTART_RC=0

: > "$uci_log"
: > "$dns_log"
: > "$event_log"
mkdir -p "$(dirname "$runtime_backup_file")"
: > "$runtime_backup_file"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_DNS_RESTART_RC=1
assert_false "dns_restore_fallback should fail when dnsmasq restart fails after commit" dns_restore_fallback
assert_file_contains "$uci_log" "commit dhcp" "dns_restore_fallback should still commit fallback state before restart failure"
assert_file_contains "$dns_log" "restart" "dns_restore_fallback should attempt dnsmasq restart before failing"
[[ -e "$runtime_backup_file" ]] || fail "dns_restore_fallback should keep runtime backup after restart failure"
assert_file_not_contains "$event_log" "log:dnsmasq fallback state already active" "dns_restore_fallback should not report no-op success when restart fails"
TEST_DNS_RESTART_RC=0

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

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
EOF
: > "$uci_log"
: > "$dns_log"
: > "$event_log"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="1.1.1.1#54"
dns_restore
[[ ! -s "$uci_log" ]] || fail "dns_restore should ignore cached backup when dnsmasq points to unrelated external DNS target"
[[ ! -s "$dns_log" ]] || fail "dns_restore should not restart dnsmasq for unrelated external DNS target"
assert_file_contains "$event_log" "log:No dnsmasq recovery backup found, skipping restore" "dns_restore should skip unrelated external DNS target without fallback"

read_config_json() {
	printf '%s\n' '{"mihomo_dns_listen":"192.168.50.1#7874","errors":[]}'
}

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
EOF
rm -f "$runtime_backup_file"
: > "$uci_log"
: > "$dns_log"
: > "$event_log"
MIHOMO_DNS_LISTEN=""
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="192.168.50.1#7874"
assert_true "dns_restore should recover from old backup format using current config target" dns_restore
assert_file_contains "$uci_log" "add_list dhcp.@dnsmasq[0].server=1.1.1.1" "dns_restore should still restore old backup format when config reveals Mihomo target"
assert_file_contains "$event_log" "log:dnsmasq settings restored" "dns_restore should report success for old backup recovery"

read_config_json() {
	printf '%s\n' '{"mihomo_dns_listen":"","errors":["parse failed"]}'
}

runtime_snapshot_status_json() {
	printf '%s\n' '{"mihomo_dns_listen":"192.168.60.1#7874","mihomo_tproxy_port":"7894"}'
}

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=9.9.9.9
EOF
rm -f "$runtime_backup_file"
: > "$uci_log"
: > "$dns_log"
: > "$event_log"
MIHOMO_DNS_LISTEN=""
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="192.168.60.1#7874"
assert_true "dns_restore should recover old backup format from runtime snapshot target when config parsing fails" dns_restore
assert_file_contains "$uci_log" "add_list dhcp.@dnsmasq[0].server=9.9.9.9" "dns_restore should still restore legacy backup when snapshot reveals Mihomo target"

pass "runtime DNS no-op paths"
