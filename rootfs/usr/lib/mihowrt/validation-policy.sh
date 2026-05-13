#!/bin/ash

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
