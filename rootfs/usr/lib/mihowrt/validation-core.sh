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

bounded_positive_uint_or_default() {
	local value="" max="$3"

	value="$(positive_uint_or_default "${1:-}" "$2")"
	if [ -n "$max" ] && ! uint_lte "$value" "$max"; then
		value="$max"
	fi

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

	value="$(normalize_uint "$value")"
	[ "$value" != "0" ] || return 1
	uint_lte "$value" "252"
}

is_valid_route_rule_priority() {
	local value="$1"
	if ! is_uint "$value"; then
		return 1
	fi

	value="$(normalize_uint "$value")"
	[ "$value" != "0" ] || return 1
	uint_lte "$value" "32765"
}

is_valid_iface_name() {
	case "$1" in
		''|*[!A-Za-z0-9_.:@-]*)
			return 1
			;;
	esac

	return 0
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
