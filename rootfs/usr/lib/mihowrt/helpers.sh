#!/bin/ash

log() {
	logger -p daemon.info -t "mihowrt" "$*"
}

warn() {
	logger -p daemon.warn -t "mihowrt" "$*"
}

err() {
	logger -p daemon.err -t "mihowrt" "$*"
}

have_command() {
	command -v "$1" >/dev/null 2>&1
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

ensure_dir() {
	local dir="$1"
	[ -d "$dir" ] || mkdir -p "$dir"
}

remove_path_if_exists() {
	local path="$1"
	[ -e "$path" ] || [ -L "$path" ] || return 0
	rm -rf "$path"
}

is_uint() {
	case "$1" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	return 0
}

is_valid_port() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	[ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

is_valid_route_table_id() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	[ "$value" -ge 1 ] && [ "$value" -le 252 ]
}

is_valid_route_rule_priority() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	[ "$value" -ge 1 ] && [ "$value" -le 32765 ]
}

is_ipv4_octet() {
	local octet="$1"

	is_uint "$octet" || return 1
	case "$octet" in
		?|??|???)
			;;
		*)
			return 1
			;;
	esac
	[ "$octet" -le 255 ]
}

is_ipv4() {
	local value="$1"
	local octet1="" octet2="" octet3="" octet4="" rest=""

	case "$value" in
		*.*.*.*)
			;;
		*)
			return 1
			;;
	esac

	octet1="${value%%.*}"
	rest="${value#*.}"
	octet2="${rest%%.*}"
	rest="${rest#*.}"
	octet3="${rest%%.*}"
	octet4="${rest#*.}"

	case "$octet4" in
		*.*)
			return 1
			;;
	esac

	is_ipv4_octet "$octet1" &&
		is_ipv4_octet "$octet2" &&
		is_ipv4_octet "$octet3" &&
		is_ipv4_octet "$octet4"
}

is_ipv4_cidr() {
	local value="$1"
	local ip prefix

	case "$value" in
		*/*)
			ip="${value%/*}"
			prefix="${value#*/}"
			case "$ip:$prefix" in
				*/*)
					return 1
					;;
			esac
			is_ipv4 "$ip" || return 1
			case "$prefix" in
				[0-9]|[12][0-9]|3[0-2])
					return 0
					;;
				*)
					return 1
					;;
			esac
			;;
		*)
			is_ipv4 "$value"
			;;
	esac
}

shell_name_chars_valid() {
	case "$1" in
		''|*[!A-Za-z0-9._:%@:-]*)
			return 1
			;;
	esac

	return 0
}

is_dns_listen_host() {
	local value="$1"
	local inner=""

	case "$value" in
		\[*\])
			inner="${value#\[}"
			inner="${inner%\]}"
			shell_name_chars_valid "$inner"
			;;
		''|*'['*|*']'*)
			return 1
			;;
		*)
			shell_name_chars_valid "$value"
			;;
	esac
}

string_has_space() {
	case "$1" in
		*[[:space:]]*)
			return 0
			;;
	esac

	return 1
}

is_dns_listen() {
	local value="$1"
	local host port

	case "$value" in
		*#*)
			host="$(dns_listen_host "$value")"
			port="$(dns_listen_port "$value")"
			[ -n "$host" ] || return 1
			case "$host" in
				*'#'*|*[[:space:]]*) return 1 ;;
			esac
			is_dns_listen_host "$host" || return 1
			is_valid_port "$port"
			;;
		*)
			return 1
			;;
	esac
}

dns_listen_host() {
	printf '%s' "${1%#*}"
}

dns_listen_port() {
	printf '%s' "${1##*#}"
}

normalize_dns_server_target() {
	local host port

	host="$(dns_listen_host "$1")"
	port="$(dns_listen_port "$1")"

	case "$host" in
		''|0.0.0.0|::|'[::]')
			host="127.0.0.1"
			;;
	esac

	printf '%s#%s' "$host" "$port"
}

port_from_addr() {
	local value="$1"
	local host
	local port

	value="$(trim "$value")"
	[ -n "$value" ] || return 1

	case "$value" in
		\[*\]:*)
			host="${value%%]*}"
			host="${host#[}"
			port="${value##*:}"
			[ -n "$host" ] || return 1
			;;
		*:*:*)
			return 1
			;;
		*)
			port="${value##*:}"
			[ "$port" != "$value" ] || return 1
			;;
	esac

	is_valid_port "$port" || return 1

	printf '%s' "$port"
}

normalize_dns_server_target_from_addr() {
	local value="$1"
	local host=""
	local port=""

	value="$(trim "$value")"
	[ -n "$value" ] || return 1
	port="$(port_from_addr "$value")" || return 1

	case "$value" in
		\[*\]:*)
			host="${value%%]*}"
			host="${host#[}"
			;;
		*)
			host="${value%:*}"
			;;
	esac

	host="$(trim "$host")"
	case "$host" in
		''|0.0.0.0|::|'[::]')
			host="127.0.0.1"
			;;
	esac

	printf '%s#%s' "$host" "$port"
}

require_command() {
	have_command "$1" || {
		err "Required command missing: $1"
		return 1
	}
}

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

yaml_cleanup_scalar() {
	local value="$1"

	value="$(trim "$value")"

	case "$value" in
		\"*\")
			value="${value#\"}"
			value="${value%\"}"
			printf '%s' "$value"
			return 0
			;;
		\'*\')
			value="${value#\'}"
			value="${value%\'}"
			printf '%s' "$value"
			return 0
			;;
	esac

	value="${value%%[[:space:]]#*}"
	value="$(trim "$value")"
	printf '%s' "$value"
}

yaml_get_selected_scalars() {
	local file="$1"

	awk '
		function emit(key, line) {
			if (!seen[key]) {
				print key "\t" line
				seen[key] = 1
			}
		}

		/^dns:[[:space:]]*($|#)/ {
			in_dns = 1
			next
		}

		{
			if (in_dns && $0 ~ /^[^[:space:]#][^:]*:[[:space:]]*/) {
				in_dns = 0
			}

			if (in_dns) {
				line = $0
				if (line ~ /^[[:space:]]+listen:[[:space:]]*/) {
					sub("^[[:space:]]+listen:[[:space:]]*", "", line)
					emit("dns.listen", line)
					next
				}
				if (line ~ /^[[:space:]]+enhanced-mode:[[:space:]]*/) {
					sub("^[[:space:]]+enhanced-mode:[[:space:]]*", "", line)
					emit("dns.enhanced-mode", line)
					next
				}
				if (line ~ /^[[:space:]]+fake-ip-range:[[:space:]]*/) {
					sub("^[[:space:]]+fake-ip-range:[[:space:]]*", "", line)
					emit("dns.fake-ip-range", line)
					next
				}
			}

			line = $0
			if (line ~ /^tproxy-port:[[:space:]]*/) {
				sub("^tproxy-port:[[:space:]]*", "", line)
				emit("tproxy-port", line)
				next
			}
			if (line ~ /^routing-mark:[[:space:]]*/) {
				sub("^routing-mark:[[:space:]]*", "", line)
				emit("routing-mark", line)
				next
			}
			if (line ~ /^external-controller:[[:space:]]*/) {
				sub("^external-controller:[[:space:]]*", "", line)
				emit("external-controller", line)
				next
			}
			if (line ~ /^external-controller-tls:[[:space:]]*/) {
				sub("^external-controller-tls:[[:space:]]*", "", line)
				emit("external-controller-tls", line)
				next
			}
			if (line ~ /^secret:[[:space:]]*/) {
				sub("^secret:[[:space:]]*", "", line)
				emit("secret", line)
				next
			}
			if (line ~ /^external-ui:[[:space:]]*/) {
				sub("^external-ui:[[:space:]]*", "", line)
				emit("external-ui", line)
				next
			}
			if (line ~ /^external-ui-name:[[:space:]]*/) {
				sub("^external-ui-name:[[:space:]]*", "", line)
				emit("external-ui-name", line)
				next
			}
		}
	' "$file" 2>/dev/null
}

append_error() {
	local message="$1"

	if [ -n "$ERRORS_RAW" ]; then
		ERRORS_RAW="${ERRORS_RAW}
$message"
	else
		ERRORS_RAW="$message"
	fi
}

read_config_json() {
	local dns_listen_raw="" dns_port="" mihomo_dns_listen="" tproxy_port="" routing_mark=""
	local enhanced_mode="" catch_fakeip="" fake_ip_range=""
	local external_controller="" external_controller_tls="" secret="" external_ui="" external_ui_name=""
	local ERRORS_RAW=""
	local key raw value

	[ -r "$CLASH_CONFIG" ] || {
		err "Mihomo config missing at $CLASH_CONFIG"
		return 1
	}

	require_command jq || return 1

	while IFS="$(printf '\t')" read -r key raw; do
		value="$(yaml_cleanup_scalar "$raw")"

		case "$key" in
			dns.listen) dns_listen_raw="$value" ;;
			dns.enhanced-mode) enhanced_mode="$value" ;;
			dns.fake-ip-range) fake_ip_range="$value" ;;
			tproxy-port) tproxy_port="$value" ;;
			routing-mark) routing_mark="$value" ;;
			external-controller) external_controller="$value" ;;
			external-controller-tls) external_controller_tls="$value" ;;
			secret) secret="$value" ;;
			external-ui) external_ui="$value" ;;
			external-ui-name) external_ui_name="$value" ;;
		esac
	done <<EOF
$(yaml_get_selected_scalars "$CLASH_CONFIG")
EOF

	dns_port=""
	mihomo_dns_listen=""
	if [ -z "$dns_listen_raw" ]; then
		append_error "Missing dns.listen in $CLASH_CONFIG"
	else
		mihomo_dns_listen="$(normalize_dns_server_target_from_addr "$dns_listen_raw" 2>/dev/null || true)"
		if [ -z "$mihomo_dns_listen" ]; then
			append_error "Invalid dns.listen in $CLASH_CONFIG: $dns_listen_raw"
		else
			dns_port="$(dns_listen_port "$mihomo_dns_listen")"
		fi
	fi

	if [ -z "$tproxy_port" ]; then
		append_error "Missing tproxy-port in $CLASH_CONFIG"
	elif ! is_valid_port "$tproxy_port"; then
		append_error "Invalid tproxy-port in $CLASH_CONFIG: $tproxy_port"
	fi

	if [ -z "$routing_mark" ]; then
		append_error "Missing routing-mark in $CLASH_CONFIG"
	elif ! is_uint "$routing_mark"; then
		append_error "Invalid routing-mark in $CLASH_CONFIG: $routing_mark"
	fi

	catch_fakeip=0
	if [ "$enhanced_mode" = "fake-ip" ]; then
		catch_fakeip=1
		if [ -z "$fake_ip_range" ]; then
			append_error "Missing dns.fake-ip-range in $CLASH_CONFIG while dns.enhanced-mode=fake-ip"
		elif ! is_ipv4_cidr "$fake_ip_range"; then
			append_error "Invalid dns.fake-ip-range in $CLASH_CONFIG: $fake_ip_range"
		fi
	fi

	jq -nc \
		--arg config_path "$CLASH_CONFIG" \
		--arg dns_listen_raw "$dns_listen_raw" \
		--arg dns_port "$dns_port" \
		--arg mihomo_dns_listen "$mihomo_dns_listen" \
		--arg tproxy_port "$tproxy_port" \
		--arg routing_mark "$routing_mark" \
		--arg enhanced_mode "$enhanced_mode" \
		--arg catch_fakeip "$catch_fakeip" \
		--arg fake_ip_range "$fake_ip_range" \
		--arg external_controller "$external_controller" \
		--arg external_controller_tls "$external_controller_tls" \
		--arg secret "$secret" \
		--arg external_ui "$external_ui" \
		--arg external_ui_name "$external_ui_name" \
		--arg errors_raw "$ERRORS_RAW" \
		'{
			config_path: $config_path,
			dns_listen_raw: $dns_listen_raw,
			dns_port: $dns_port,
			mihomo_dns_listen: $mihomo_dns_listen,
			tproxy_port: $tproxy_port,
			routing_mark: $routing_mark,
			enhanced_mode: $enhanced_mode,
			catch_fakeip: ($catch_fakeip == "1"),
			fake_ip_range: $fake_ip_range,
			external_controller: $external_controller,
			external_controller_tls: $external_controller_tls,
			secret: $secret,
			external_ui: $external_ui,
			external_ui_name: $external_ui_name,
			errors: ($errors_raw | split("\n") | map(select(length > 0)))
		}' || {
		err "Failed to normalize config data from $CLASH_CONFIG"
		return 1
	}
}

read_config_json_for_path() {
	local config_path="$1"
	local active_config="$CLASH_CONFIG"
	local rc=0

	CLASH_CONFIG="$config_path"
	read_config_json || rc=$?
	CLASH_CONFIG="$active_config"
	return "$rc"
}

apply_config_file() {
	local candidate="$1"
	local active_config="$CLASH_CONFIG"
	local target_tmp="${active_config}.tmp.$$"
	local test_output="" config_json="" config_errors=""

	[ -n "$candidate" ] || {
		err "temporary config path is required"
		return 1
	}

	case "$candidate" in
		/tmp/*)
			;;
		*)
			err "temporary config must be stored under /tmp"
			return 1
			;;
	esac

	[ -r "$candidate" ] || {
		err "temporary config missing at $candidate"
		return 1
	}

	[ -x "$CLASH_BIN" ] || {
		err "Mihomo binary missing at $CLASH_BIN"
		rm -f "$candidate"
		return 1
	}

	test_output="$("$CLASH_BIN" -d "$CLASH_DIR" -f "$candidate" -t 2>&1)" || {
		err "${test_output:-configuration test failed}"
		rm -f "$candidate"
		return 1
	}

	config_json="$(read_config_json_for_path "$candidate")" || {
		rm -f "$candidate"
		return 1
	}

	config_errors="$(printf '%s\n' "$config_json" | jq -r '.errors | join("; ")')" || {
		err "Failed to inspect normalized config errors for $candidate"
		rm -f "$candidate"
		return 1
	}

	if [ -n "$config_errors" ]; then
		err "$config_errors"
		rm -f "$candidate"
		return 1
	fi

	mkdir -p "$(dirname "$active_config")" || {
		err "Failed to prepare config directory for $active_config"
		rm -f "$candidate" "$target_tmp"
		return 1
	}

	if [ -f "$active_config" ] && cmp -s "$candidate" "$active_config" 2>/dev/null; then
		rm -f "$candidate"
		return 0
	fi

	cp -f "$candidate" "$target_tmp" || {
		err "Failed to stage validated config for $active_config"
		rm -f "$candidate" "$target_tmp"
		return 1
	}

	mv -f "$target_tmp" "$active_config" || {
		err "Failed to install validated config to $active_config"
		rm -f "$candidate" "$target_tmp"
		return 1
	}

	rm -f "$candidate"
	return 0
}

apply_config_contents() {
	local contents="$1"
	local candidate=""

	require_command mktemp || return 1
	candidate="$(mktemp /tmp/mihowrt-config.XXXXXX)" || {
		err "Failed to allocate temporary config path"
		return 1
	}

	printf '%s' "$contents" > "$candidate" || {
		err "Failed to stage temporary config contents"
		rm -f "$candidate"
		return 1
	}

	apply_config_file "$candidate"
}

logs_json() {
	local limit="${1:-200}"
	local logread_cmd="" lines=""

	require_command jq || return 1

	if ! is_uint "$limit" || [ "$limit" -le 0 ]; then
		limit=200
	elif [ "$limit" -gt 1000 ]; then
		limit=1000
	fi

	logread_cmd="$(command -v logread 2>/dev/null || true)"
	if [ -z "$logread_cmd" ]; then
		jq -nc \
			--argjson limit "$limit" \
			'{ available: false, limit: $limit, lines: [] }'
		return 0
	fi

	lines="$("$logread_cmd" 2>/dev/null | grep -E '(^|[[:space:]])mihowrt(\[[0-9]+\])?:' | tail -n "$limit" || true)"

	jq -nc \
		--argjson limit "$limit" \
		--arg lines "$lines" \
		'{
			available: true,
			limit: $limit,
			lines: ($lines | split("\n") | map(select(length > 0)))
		}'
}

normalize_version() {
	printf '%s\n' "$1" | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d 'vV'
}

version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

detect_mihomo_arch() {
	local release_info distrib_arch
	release_info="$(cat /etc/openwrt_release 2>/dev/null)"
	distrib_arch="$(printf '%s\n' "$release_info" | sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p")"

	case "$distrib_arch" in
		aarch64_*) echo "arm64" ;;
		x86_64) echo "amd64" ;;
		i386_*) echo "386" ;;
		riscv64_*) echo "riscv64" ;;
		loongarch64_*) echo "loong64" ;;
		mips64el_*) echo "mips64le" ;;
		mips64_*) echo "mips64" ;;
		mipsel_*hardfloat*) echo "mipsle-hardfloat" ;;
		mipsel_*) echo "mipsle-softfloat" ;;
		mips_*hardfloat*) echo "mips-hardfloat" ;;
		mips_*) echo "mips-softfloat" ;;
		arm_*neon-vfp*) echo "armv7" ;;
		arm_*neon*|arm_*vfp*) echo "armv6" ;;
		arm_*) echo "armv5" ;;
		*) return 1 ;;
	esac
}

current_mihomo_version() {
	[ -x "$CLASH_BIN" ] || return 1
	"$CLASH_BIN" -v 2>/dev/null | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1
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
