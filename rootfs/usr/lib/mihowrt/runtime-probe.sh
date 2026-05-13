#!/bin/ash

process_pid_matches_pattern() {
	local pid="$1"
	local run_pattern="${2:-}"
	local cmdline=""

	[ -n "$run_pattern" ] || return 0
	[ -r "/proc/$pid/cmdline" ] || return 1

	cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
	[ -n "$cmdline" ] || return 1

	case "$cmdline" in
		*"$run_pattern"*)
			return 0
			;;
	esac

	return 1
}

process_running_state() {
	local pid_file="$1"
	local run_pattern="${2:-}"
	local pid=""

	if [ -f "$pid_file" ]; then
		IFS= read -r pid < "$pid_file" 2>/dev/null || pid=""
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			process_pid_matches_pattern "$pid" "$run_pattern" && return 0
		fi
	fi

	if [ -n "$run_pattern" ] && have_command pgrep; then
		pgrep -f "$run_pattern" >/dev/null 2>&1 && return 0
	fi

	return 1
}

service_running_state() {
	local pid_file="${SERVICE_PID_FILE:-/var/run/mihowrt/mihomo.pid}"
	local run_pattern="${SERVICE_RUN_PATTERN:-${ORCHESTRATOR:-/usr/bin/mihowrt} run-service}"
	local mihomo_pattern="${SERVICE_CHILD_PATTERN:-${CLASH_BIN:-/opt/clash/bin/clash} -d ${CLASH_DIR:-/opt/clash}}"
	local pid=""

	if [ -f "$pid_file" ]; then
		IFS= read -r pid < "$pid_file" 2>/dev/null || pid=""
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			process_pid_matches_pattern "$pid" "$run_pattern" && return 0
			process_pid_matches_pattern "$pid" "$mihomo_pattern" && return 0
		fi
	fi

	if [ -n "$run_pattern" ] && have_command pgrep; then
		pgrep -f "$run_pattern" >/dev/null 2>&1 && return 0
	fi
	if [ -n "$mihomo_pattern" ] && have_command pgrep; then
		pgrep -f "$mihomo_pattern" >/dev/null 2>&1 && return 0
	fi

	return 1
}

mihomo_ready_state() {
	local dns_port="$1"
	local tproxy_port="$2"

	service_running_state || return 1
	is_valid_port "$dns_port" || return 1
	is_valid_port "$tproxy_port" || return 1

	port_listening_udp "$dns_port" && { port_listening_tcp "$tproxy_port" || port_listening_udp "$tproxy_port"; }
}

hex_port() {
	printf '%04X' "$1"
}

port_listening_tcp() {
	local port_hex
	port_hex="$(hex_port "$1")"
	awk -v port=":$port_hex" '$2 ~ port && $4 == "0A" { found=1 } END { exit(found ? 0 : 1) }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

port_listening_udp() {
	local port_hex
	port_hex="$(hex_port "$1")"
	awk -v port=":$port_hex" '$2 ~ port { found=1 } END { exit(found ? 0 : 1) }' \
		/proc/net/udp /proc/net/udp6 2>/dev/null
}

wait_for_mihomo_ready() {
	local dns_port="$1"
	local tproxy_port="$2"
	local pid="$3"
	local i=0

	while [ "$i" -lt 30 ]; do
		kill -0 "$pid" 2>/dev/null || return 1

		if port_listening_udp "$dns_port" && { port_listening_tcp "$tproxy_port" || port_listening_udp "$tproxy_port"; }; then
			return 0
		fi

		sleep 1
		i=$((i + 1))
	done

	return 1
}
