#!/bin/ash

# True only for unsigned decimal integers. Signs, hex, and whitespace stay
# invalid so user input cannot change meaning in shell arithmetic.
is_uint() {
	case "$1" in
	'' | *[!0-9]*)
		return 1
		;;
	esac

	return 0
}

# Strip leading zeroes before string-based numeric comparison.
normalize_uint() {
	local value="$1"

	while [ "${value#0}" != "$value" ]; do
		value="${value#0}"
	done
	[ -n "$value" ] || value=0
	printf '%s' "$value"
}

# Return input when it is a positive integer, otherwise return the caller's
# default. Used for environment tunables.
positive_uint_or_default() {
	local value="${1:-}"
	local default="$2"

	if ! is_uint "$value"; then
		printf '%s' "$default"
		return 0
	fi

	value="$(normalize_uint "$value")"
	if [ "$value" = "0" ]; then
		printf '%s' "$default"
	else
		printf '%s' "$value"
	fi
}

# Same as positive_uint_or_default, with an upper bound to keep later arithmetic
# and allocation limits sane.
bounded_positive_uint_or_default() {
	local value="" max="$3"

	value="$(positive_uint_or_default "${1:-}" "$2")"
	if [ -n "$max" ] && ! uint_lte "$value" "$max"; then
		value="$max"
	fi

	printf '%s' "$value"
}

# Compare unsigned integers as strings after normalization. This avoids overflow
# with very large user-provided values.
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

# Validate fwmark range accepted by nft/ip.
is_valid_uint32_mark() {
	local value=""

	is_uint "$1" || return 1
	value="$(normalize_uint "$1")"
	[ "$value" != "0" ] || return 1

	uint_lte "$value" "4294967295"
}

# Validate TCP/UDP port range.
is_valid_port() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	value="$(normalize_uint "$value")"
	[ "$value" != "0" ] || return 1

	uint_lte "$value" "65535"
}

# MihoWRT keeps managed tables below 253 to avoid Linux reserved/special tables.
is_valid_route_table_id() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	value="$(normalize_uint "$value")"
	[ "$value" != "0" ] || return 1
	uint_lte "$value" "252"
}

# Keep explicit priorities outside zero and below the kernel's special max.
is_valid_route_rule_priority() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	value="$(normalize_uint "$value")"
	[ "$value" != "0" ] || return 1
	uint_lte "$value" "32765"
}

# Interface names are copied into nft string sets, so reject anything that can
# break command serialization or cannot be a normal OpenWrt interface name.
is_valid_iface_name() {
	case "$1" in
	'' | *[!A-Za-z0-9_.:@-]*)
		return 1
		;;
	esac

	return 0
}

# Validate one IPv4 octet without accepting empty or overlong fields.
is_ipv4_octet() {
	local octet="$1"

	is_uint "$octet" || return 1
	case "$octet" in
	? | ?? | ???) ;;
	*)
		return 1
		;;
	esac
	[ "$octet" -le 255 ]
}

# Validate dotted IPv4 addresses with shell-safe splitting.
is_ipv4() {
	local value="$1"
	local octet1="" octet2="" octet3="" octet4="" rest=""

	case "$value" in
	*.*.*.*) ;;
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

# Validate IPv4 address or CIDR. IPv6 is intentionally out of scope for policy.
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
		[0-9] | [12][0-9] | 3[0-2])
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
