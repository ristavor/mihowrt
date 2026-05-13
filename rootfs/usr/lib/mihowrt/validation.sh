#!/bin/ash

is_uint() {
	case "$1" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	return 0
}

normalize_uint() {
	local value="$1"

	while [ "${value#0}" != "$value" ]; do
		value="${value#0}"
	done
	[ -n "$value" ] || value=0
	printf '%s' "$value"
}

uint_lte() {
	local value="$1"
	local max="$2"
	local value_digit="" max_digit=""

	is_uint "$value" && is_uint "$max" || return 1
	value="$(normalize_uint "$value")"
	max="$(normalize_uint "$max")"

	[ "${#value}" -lt "${#max}" ] && return 0
	[ "${#value}" -gt "${#max}" ] && return 1

	while [ -n "$value" ]; do
		value_digit="${value%"${value#?}"}"
		max_digit="${max%"${max#?}"}"

		[ "$value_digit" -lt "$max_digit" ] && return 0
		[ "$value_digit" -gt "$max_digit" ] && return 1

		value="${value#?}"
		max="${max#?}"
	done

	return 0
}

is_valid_uint32_mark() {
	local value=""

	is_uint "$1" || return 1
	value="$(normalize_uint "$1")"
	[ "$value" != "0" ] || return 1

	uint_lte "$value" "4294967295"
}

is_valid_port() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	value="$(normalize_uint "$value")"
	[ "$value" != "0" ] || return 1

	uint_lte "$value" "65535"
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

is_policy_port_spec() {
	local value="$1"
	local rest item start end

	case "$value" in
		'')
			return 1
			;;
		*,*)
			rest="$value"
			while :; do
				item="${rest%%,*}"
				case "$item" in
					''|*-*)
						return 1
						;;
				esac
				is_valid_port "$item" || return 1
				[ "$rest" != "${rest#*,}" ] || break
				rest="${rest#*,}"
			done
			;;
		*-*)
			start="${value%%-*}"
			end="${value#*-}"
			[ -n "$start" ] && [ -n "$end" ] || return 1
			is_valid_port "$start" || return 1
			is_valid_port "$end" || return 1
			start="$(normalize_uint "$start")"
			end="$(normalize_uint "$end")"
			[ "$start" -le "$end" ]
			;;
		*)
			is_valid_port "$value"
			;;
	esac
}

policy_entry_has_semicolon_ports() {
	local value="$1" ports=""

	case "$value" in
		*';'*)
			ports="${value##*;}"
			is_policy_port_spec "$ports"
			;;
		*)
			return 1
			;;
	esac
}

is_policy_entry() {
	local value="$1"
	local addr ports

	case "$value" in
		'')
			return 1
			;;
		*';'*)
			addr="${value%;*}"
			ports="${value##*;}"
			[ -n "$ports" ] || return 1
			[ -z "$addr" ] || is_ipv4_cidr "$addr" || return 1
			is_policy_port_spec "$ports"
			;;
		*:*:*)
			return 1
			;;
		*:*)
			addr="${value%:*}"
			ports="${value##*:}"
			[ -n "$ports" ] || return 1
			[ -z "$addr" ] || is_ipv4_cidr "$addr" || return 1
			is_policy_port_spec "$ports"
			;;
		*)
			is_ipv4_cidr "$value"
			;;
	esac
}

policy_entry_has_ports() {
	if policy_entry_has_semicolon_ports "$1"; then
		return 0
	fi

	case "$1" in
		*:*:*)
			return 1
			;;
		*:*)
			return 0
			;;
	esac

	return 1
}

policy_entry_ip() {
	if policy_entry_has_semicolon_ports "$1"; then
		printf '%s' "${1%;*}"
		return 0
	fi

	if policy_entry_has_ports "$1"; then
		printf '%s' "${1%:*}"
		return 0
	fi

	printf '%s' "$1"
}

policy_entry_ports() {
	if policy_entry_has_semicolon_ports "$1"; then
		printf '%s' "${1##*;}"
		return 0
	fi

	printf '%s' "${1##*:}"
}

policy_ports_normalized_spec() {
	local value="$1"
	local rest item start end expr="" items="" sorted="" current="" inserted=0

	is_policy_port_spec "$value" || return 1

	case "$value" in
		*,*)
			rest="$value"
			while :; do
				item="$(normalize_uint "${rest%%,*}")"
				case " $items " in
					*" $item "*)
						;;
					*)
						sorted=""
						inserted=0
						for current in $items; do
							if [ "$inserted" -eq 0 ] && [ "$item" -lt "$current" ]; then
								sorted="${sorted:+$sorted }$item"
								inserted=1
							fi
							sorted="${sorted:+$sorted }$current"
						done
						[ "$inserted" -eq 1 ] || sorted="${sorted:+$sorted }$item"
						items="$sorted"
						;;
				esac
				[ "$rest" != "${rest#*,}" ] || break
				rest="${rest#*,}"
			done
			for item in $items; do
				if [ -n "$expr" ]; then
					expr="$expr,$item"
				else
					expr="$item"
				fi
			done
			printf '%s' "$expr"
			;;
		*-*)
			start="$(normalize_uint "${value%%-*}")"
			end="$(normalize_uint "${value#*-}")"
			if [ "$start" -eq "$end" ]; then
				printf '%s' "$start"
			else
				printf '%s-%s' "$start" "$end"
			fi
			;;
		*)
			normalize_uint "$value"
			;;
	esac
}

policy_entry_normalized() {
	local value="$1" addr="" ports=""

	is_policy_entry "$value" || return 1
	if policy_entry_has_ports "$value"; then
		addr="$(policy_entry_ip "$value")"
		ports="$(policy_ports_normalized_spec "$(policy_entry_ports "$value")")" || return 1
		printf '%s:%s' "$addr" "$ports"
	else
		printf '%s' "$value"
	fi
}

policy_entry_with_ports() {
	local value="$1" ports="$2" normalized_ports=""

	is_policy_entry "$value" || return 1
	policy_entry_has_ports "$value" && {
		policy_entry_normalized "$value"
		return $?
	}

	normalized_ports="$(policy_ports_normalized_spec "$ports")" || return 1
	printf '%s:%s' "$value" "$normalized_ports"
}

policy_ports_nft_expr() {
	local value="$1"
	local rest item start end expr="" seen="" unique_count=0

	is_policy_port_spec "$value" || return 1

	case "$value" in
		*,*)
			rest="$value"
			while :; do
				item="${rest%%,*}"
				item="$(normalize_uint "$item")"
				case " $seen " in
					*" $item "*)
						;;
					*)
						if [ -n "$expr" ]; then
							expr="$expr, $item"
						else
							expr="$item"
						fi
						seen="$seen $item"
						unique_count=$((unique_count + 1))
						;;
				esac
				[ "$rest" != "${rest#*,}" ] || break
				rest="${rest#*,}"
			done
			if [ "$unique_count" -eq 1 ]; then
				printf '%s' "$expr"
			else
				printf '{ %s }' "$expr"
			fi
			;;
		*-*)
			start="${value%%-*}"
			end="${value#*-}"
			start="$(normalize_uint "$start")"
			end="$(normalize_uint "$end")"
			if [ "$start" -eq "$end" ]; then
				printf '%s' "$start"
			else
				printf '%s-%s' "$start" "$end"
			fi
			;;
		*)
			normalize_uint "$value"
			;;
	esac
}

policy_ports_include_port() {
	local value="$1"
	local needle="$2"
	local rest item start end

	is_policy_port_spec "$value" || return 1
	is_valid_port "$needle" || return 1
	needle="$(normalize_uint "$needle")"

	case "$value" in
		*,*)
			rest="$value"
			while :; do
				item="$(normalize_uint "${rest%%,*}")"
				[ "$item" -eq "$needle" ] && return 0
				[ "$rest" != "${rest#*,}" ] || break
				rest="${rest#*,}"
			done
			return 1
			;;
		*-*)
			start="$(normalize_uint "${value%%-*}")"
			end="$(normalize_uint "${value#*-}")"
			[ "$needle" -ge "$start" ] && [ "$needle" -le "$end" ]
			;;
		*)
			item="$(normalize_uint "$value")"
			[ "$item" -eq "$needle" ]
			;;
	esac
}

shell_name_chars_valid() {
	case "$1" in
		''|*[!-A-Za-z0-9._:%@]*)
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
