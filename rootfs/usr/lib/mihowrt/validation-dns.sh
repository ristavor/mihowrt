#!/bin/ash

# Allow only characters that are safe inside dnsmasq target fields and UCI
# values; stricter than full DNS syntax by design.
shell_name_chars_valid() {
	case "$1" in
	'' | *[!-A-Za-z0-9._:%@]*)
		return 1
		;;
	esac

	return 0
}

# Validate hosts used in dns.listen and dnsmasq server targets. Brackets are
# accepted only as a complete wrapper.
is_dns_listen_host() {
	local value="$1"
	local inner=""

	case "$value" in
	\[*\])
		inner="${value#\[}"
		inner="${inner%\]}"
		shell_name_chars_valid "$inner"
		;;
	'' | *'['* | *']'*)
		return 1
		;;
	*)
		shell_name_chars_valid "$value"
		;;
	esac
}

# Detect whitespace in values that will be embedded into UCI option/list atoms.
string_has_space() {
	case "$1" in
	*[[:space:]]*)
		return 0
		;;
	esac

	return 1
}

# Validate internal DNS listen format host#port.
is_dns_listen() {
	local value="$1"
	local host port

	case "$value" in
	*#*)
		host="$(dns_listen_host "$value")"
		port="$(dns_listen_port "$value")"
		[ -n "$host" ] || return 1
		case "$host" in
		*'#'* | *[[:space:]]*) return 1 ;;
		esac
		is_dns_listen_host "$host" || return 1
		is_valid_port "$port"
		;;
	*)
		return 1
		;;
	esac
}

# Extract host from internal host#port DNS target.
dns_listen_host() {
	printf '%s' "${1%#*}"
}

# Extract port from internal host#port DNS target.
dns_listen_port() {
	printf '%s' "${1##*#}"
}

# Convert wildcard bind hosts to loopback before writing dnsmasq upstream.
normalize_dns_server_target() {
	local host port

	host="$(dns_listen_host "$1")"
	port="$(dns_listen_port "$1")"

	case "$host" in
	'' | 0.0.0.0 | :: | '[::]')
		host="127.0.0.1"
		;;
	esac

	printf '%s#%s' "$host" "$port"
}

# Extract port from a raw listen address while rejecting ambiguous IPv6 forms
# that are not bracketed.
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

# Normalize Mihomo YAML listen values into host#port format used by dnsmasq.
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
	'' | 0.0.0.0 | :: | '[::]')
		host="127.0.0.1"
		;;
	esac

	printf '%s#%s' "$host" "$port"
}
