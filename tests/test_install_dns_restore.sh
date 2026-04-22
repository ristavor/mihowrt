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

TEST_FAIL_UCI_CMD=""

uci() {
	if [[ "${1:-}" == "-q" && "${2:-}" == "get" ]]; then
		case "${3:-}" in
			'dhcp.@dnsmasq[0].cachesize')
				printf '%s\n' "${TEST_CURRENT_CACHESIZE:-}"
				return 0
				;;
			'dhcp.@dnsmasq[0].noresolv')
				printf '%s\n' "${TEST_CURRENT_NORESOLV:-${TEST_UCI_NORESOLV:-0}}"
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
		printf 'delete %s\n' "${3:-}" >>"$UCI_LOG"
		[[ -n "$TEST_FAIL_UCI_CMD" && "delete ${3:-}" == "$TEST_FAIL_UCI_CMD" ]] && return 1
		return 0
	fi

	case "${1:-}" in
		add_list)
			printf 'add_list %s\n' "${2:-}" >>"$UCI_LOG"
			[[ -n "$TEST_FAIL_UCI_CMD" && "add_list ${2:-}" == "$TEST_FAIL_UCI_CMD" ]] && return 1
			;;
		set)
			printf 'set %s\n' "${2:-}" >>"$UCI_LOG"
			[[ -n "$TEST_FAIL_UCI_CMD" && "set ${2:-}" == "$TEST_FAIL_UCI_CMD" ]] && return 1
			;;
		commit)
			printf 'commit %s\n' "${2:-}" >>"$UCI_LOG"
			[[ -n "$TEST_FAIL_UCI_CMD" && "commit ${2:-}" == "$TEST_FAIL_UCI_CMD" ]] && return 1
			;;
		revert)
			printf 'revert %s\n' "${2:-}" >>"$UCI_LOG"
			;;
		*)
			return 1
			;;
	esac

	return 0
}

restart_dnsmasq() {
	printf 'restart\n' >>"$DNS_LOG"
	return "${TEST_DNSMASQ_RESTART_RC:-0}"
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

legacy_seed_backup="$tmpdir/legacy-seed.backup"
legacy_seed_config="$tmpdir/legacy-seed.yaml"
cat > "$legacy_seed_backup" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=
EOF
cat > "$legacy_seed_config" <<'EOF'
dns:
  listen: 192.168.70.1:7874
EOF
seed_dns_backup_target_metadata "$legacy_seed_backup" "$legacy_seed_config"
assert_file_contains "$legacy_seed_backup" "MIHOMO_DNS_TARGET=192.168.70.1#7874" "seed_dns_backup_target_metadata should migrate legacy backups using config target"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=maybe
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject invalid ORIG_NORESOLV values" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for invalid ORIG_NORESOLV"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for invalid ORIG_NORESOLV"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=abc
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject non-numeric ORIG_CACHESIZE values" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for invalid ORIG_CACHESIZE"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for invalid ORIG_CACHESIZE"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=bad-target
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject invalid MIHOMO_DNS_TARGET values" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for invalid MIHOMO_DNS_TARGET"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for invalid MIHOMO_DNS_TARGET"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=bad^server#53
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject malformed MIHOMO_DNS_TARGET hosts" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for malformed MIHOMO_DNS_TARGET host"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for malformed MIHOMO_DNS_TARGET host"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=relative.resolv
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject non-absolute ORIG_RESOLVFILE values" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for invalid ORIG_RESOLVFILE"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for invalid ORIG_RESOLVFILE"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1#99999
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject invalid ORIG_SERVER values" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for invalid ORIG_SERVER"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for invalid ORIG_SERVER"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=bad^server
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject malformed ORIG_SERVER tokens" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for malformed ORIG_SERVER token"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for malformed ORIG_SERVER token"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=/bad^/1.1.1.1
EOF
: > "$UCI_LOG"
: > "$DNS_LOG"
assert_false "restore_dns_from_backup_file should reject malformed ORIG_SERVER selectors" restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should not touch dhcp state for malformed ORIG_SERVER selector"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq for malformed ORIG_SERVER selector"

cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
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

: > "$UCI_LOG"
: > "$DNS_LOG"
cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
ORIG_SERVER=9.9.9.9
EOF
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_DNSMASQ_RESTART_RC=1
assert_false "restore_dns_from_backup_file should fail when dnsmasq restart fails after commit" restore_dns_from_backup_file "$backup_file"
assert_file_contains "$UCI_LOG" "commit dhcp" "restore_dns_from_backup_file should still commit before restart failure"
assert_file_contains "$DNS_LOG" "restart" "restore_dns_from_backup_file should attempt dnsmasq restart before failing"
TEST_DNSMASQ_RESTART_RC=0

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE="1000"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE="/tmp/original.resolv"
TEST_CURRENT_SERVERS=$'1.1.1.1\n9.9.9.9'
restore_dns_from_backup_file "$backup_file"
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_from_backup_file should skip no-op dhcp writes when state already matches backup"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should skip dnsmasq restart when state already matches backup"

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="add_list dhcp.@dnsmasq[0].server=1.1.1.1"
assert_false "restore_dns_from_backup_file should fail when restoring dnsmasq server list fails" restore_dns_from_backup_file "$backup_file"
assert_file_not_contains "$UCI_LOG" "commit dhcp" "restore_dns_from_backup_file should not commit partial restore after mutator failure"
assert_file_contains "$UCI_LOG" "revert dhcp" "restore_dns_from_backup_file should revert staged dhcp changes after restore failure"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq after mutator failure"
TEST_FAIL_UCI_CMD=""

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="delete dhcp.@dnsmasq[0].server"
assert_false "restore_dns_from_backup_file should fail when clearing existing dnsmasq server state fails" restore_dns_from_backup_file "$backup_file"
assert_file_not_contains "$UCI_LOG" "commit dhcp" "restore_dns_from_backup_file should not commit after delete failure"
assert_file_contains "$UCI_LOG" "revert dhcp" "restore_dns_from_backup_file should revert staged dhcp changes after delete failure"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_from_backup_file should not restart dnsmasq after delete failure"
TEST_FAIL_UCI_CMD=""

rm -f "$backup_file"
: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_UCI_NORESOLV="1"
unset TEST_CURRENT_CACHESIZE TEST_CURRENT_RESOLVFILE TEST_CURRENT_SERVERS
TEST_CURRENT_NORESOLV="1"
restore_system_dns_defaults 1
assert_file_contains "$UCI_LOG" "delete dhcp.@dnsmasq[0].server" "restore_system_dns_defaults fallback should clear servers"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].noresolv=0" "restore_system_dns_defaults fallback should disable noresolv"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=$DNS_AUTO_RESOLVFILE" "restore_system_dns_defaults fallback should restore auto resolvfile"
assert_file_contains "$UCI_LOG" "commit dhcp" "restore_system_dns_defaults fallback should commit dhcp config"
assert_file_contains "$DNS_LOG" "restart" "restore_system_dns_defaults fallback should restart dnsmasq"

: > "$UCI_LOG"
: > "$DNS_LOG"
cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
ORIG_SERVER=9.9.9.9
EOF
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_DNSMASQ_RESTART_RC=1
assert_false "restore_dns_defaults_fallback should fail when dnsmasq restart fails after commit" restore_dns_defaults_fallback
assert_file_contains "$UCI_LOG" "commit dhcp" "restore_dns_defaults_fallback should still commit before restart failure"
assert_file_contains "$DNS_LOG" "restart" "restore_dns_defaults_fallback should attempt dnsmasq restart before failing"
TEST_DNSMASQ_RESTART_RC=0

: > "$UCI_LOG"
: > "$DNS_LOG"
cat > "$backup_file" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=1.1.1.1
ORIG_SERVER=9.9.9.9
EOF
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_DNSMASQ_RESTART_RC=1
assert_false "restore_system_dns_defaults should fail when matching backup restore fails after commit" restore_system_dns_defaults 1
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=/tmp/original.resolv" "restore_system_dns_defaults should attempt backup restore before failing"
assert_file_not_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].noresolv=0" "restore_system_dns_defaults should not run fallback after matching backup restore failure"
assert_file_not_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=$DNS_AUTO_RESOLVFILE" "restore_system_dns_defaults should not overwrite backup restore with fallback defaults after failure"
assert_eq "1" "$(grep -c '^restart$' "$DNS_LOG" || true)" "restore_system_dns_defaults should only attempt backup restart once on matching restore failure"
TEST_DNSMASQ_RESTART_RC=0
rm -f "$backup_file"

: > "$UCI_LOG"
: > "$DNS_LOG"
mkdir -p "$tmpdir/saved-backup"
BACKUP_DIR="$tmpdir/saved-backup"
cat > "$BACKUP_DIR/$DNS_BACKUP_NAME" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=4096
ORIG_NORESOLV=0
ORIG_RESOLVFILE=/tmp/saved.resolv
EOF
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
restore_system_dns_defaults 0
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].cachesize=4096" "restore_system_dns_defaults should use saved backup cachesize"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].noresolv=0" "restore_system_dns_defaults should use saved backup noresolv"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=/tmp/saved.resolv" "restore_system_dns_defaults should use saved backup resolvfile"
assert_file_contains "$DNS_LOG" "restart" "restore_system_dns_defaults should restart dnsmasq from saved backup"

: > "$UCI_LOG"
: > "$DNS_LOG"
cat > "$BACKUP_DIR/$DNS_BACKUP_NAME" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=4096
ORIG_NORESOLV=0
ORIG_RESOLVFILE=/tmp/legacy.resolv
EOF
cat > "$BACKUP_DIR/config.yaml" <<'EOF'
dns:
  listen: 192.168.50.1:7874
EOF
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="192.168.50.1#7874"
restore_system_dns_defaults 0
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].cachesize=4096" "restore_system_dns_defaults should recover old backup format using saved config target"
assert_file_contains "$UCI_LOG" "set dhcp.@dnsmasq[0].resolvfile=/tmp/legacy.resolv" "restore_system_dns_defaults should restore old backup format when saved config reveals Mihomo target"
assert_file_contains "$DNS_LOG" "restart" "restore_system_dns_defaults should restart dnsmasq for old backup recovery"

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="1.1.1.1#54"
restore_system_dns_defaults 0
[[ ! -s "$UCI_LOG" ]] || fail "restore_system_dns_defaults should ignore unrelated external DNS target"
[[ ! -s "$DNS_LOG" ]] || fail "restore_system_dns_defaults should not restart dnsmasq for unrelated external DNS target"

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE=""
TEST_CURRENT_NORESOLV="0"
TEST_CURRENT_RESOLVFILE="$DNS_AUTO_RESOLVFILE"
TEST_CURRENT_SERVERS=""
restore_dns_defaults_fallback
[[ ! -s "$UCI_LOG" ]] || fail "restore_dns_defaults_fallback should skip no-op dhcp writes when defaults already active"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_defaults_fallback should skip dnsmasq restart when defaults already active"

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="set dhcp.@dnsmasq[0].noresolv=0"
assert_false "restore_dns_defaults_fallback should fail when noresolv restore fails" restore_dns_defaults_fallback
assert_file_not_contains "$UCI_LOG" "commit dhcp" "restore_dns_defaults_fallback should not commit partial fallback restore"
assert_file_contains "$UCI_LOG" "revert dhcp" "restore_dns_defaults_fallback should revert staged dhcp changes after failure"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_defaults_fallback should not restart dnsmasq after fallback failure"
TEST_FAIL_UCI_CMD=""

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE="0"
TEST_CURRENT_NORESOLV="1"
TEST_CURRENT_RESOLVFILE=""
TEST_CURRENT_SERVERS="127.0.0.1#7874"
TEST_FAIL_UCI_CMD="delete dhcp.@dnsmasq[0].server"
assert_false "restore_dns_defaults_fallback should fail when clearing hijacked dnsmasq servers fails" restore_dns_defaults_fallback
assert_file_not_contains "$UCI_LOG" "commit dhcp" "restore_dns_defaults_fallback should not commit after delete failure"
assert_file_contains "$UCI_LOG" "revert dhcp" "restore_dns_defaults_fallback should revert staged dhcp changes after delete failure"
[[ ! -s "$DNS_LOG" ]] || fail "restore_dns_defaults_fallback should not restart dnsmasq after delete failure"
TEST_FAIL_UCI_CMD=""

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_CURRENT_CACHESIZE=""
TEST_CURRENT_NORESOLV="0"
TEST_CURRENT_RESOLVFILE="$DNS_AUTO_RESOLVFILE"
TEST_CURRENT_SERVERS=""
restore_system_dns_defaults 1
[[ ! -s "$UCI_LOG" ]] || fail "restore_system_dns_defaults should ignore cached backup when dnsmasq is not in hijacked state"
[[ ! -s "$DNS_LOG" ]] || fail "restore_system_dns_defaults should not restart dnsmasq from cached backup when hijack is inactive"

: > "$UCI_LOG"
: > "$DNS_LOG"
TEST_UCI_NORESOLV="1"
unset TEST_CURRENT_CACHESIZE TEST_CURRENT_RESOLVFILE TEST_CURRENT_SERVERS
TEST_CURRENT_NORESOLV="1"
BACKUP_DIR=""
restore_system_dns_defaults 0
[[ ! -s "$UCI_LOG" ]] || fail "restore_system_dns_defaults should not touch dhcp config without allow_fallback"
[[ ! -s "$DNS_LOG" ]] || fail "restore_system_dns_defaults should not restart dnsmasq without allow_fallback"

pass "installer DNS restore paths"
