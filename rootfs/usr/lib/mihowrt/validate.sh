#!/bin/ash

# Input validators. Values are checked once at the boundary (UCI, lists, UI);
# runtime code trusts validated state.

is_uint() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	esac
	# Reject values that would overflow 64-bit shell arithmetic.
	[ "${#1}" -le 18 ]
}

# Decimal digits only; callers validate with is_uint before normalization.
uint_norm() {
	local value="$1"

	while [ "${value#0}" != "$value" ]; do
		value="${value#0}"
	done
	printf '%s' "${value:-0}"
}

is_valid_port() {
	is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Port spec used in policy lists: 443, 1000-2000 or 80,443,8000-8080.
is_port_spec() {
	local spec="$1" item="" old_ifs="$IFS"

	[ -n "$spec" ] || return 1
	case "$spec" in
	*[!0-9,-]* | ,* | *, | *,,*) return 1 ;;
	esac
	IFS=','
	for item in $spec; do
		case "$item" in
		*-*)
			is_valid_port "${item%-*}" && is_valid_port "${item#*-}" &&
				[ "${item%-*}" -le "${item#*-}" ] || {
				IFS="$old_ifs"
				return 1
			}
			;;
		*)
			is_valid_port "$item" || {
				IFS="$old_ifs"
				return 1
			}
			;;
		esac
	done
	IFS="$old_ifs"
}

is_valid_uint32_mark() {
	local value="$1"

	case "$value" in
	0x* | 0X*)
		case "${value#0[xX]}" in
		'' | *[!0-9A-Fa-f]*) return 1 ;;
		esac
		value="$((value))"
		;;
	esac
	is_uint "$value" && [ "$value" -gt 0 ] && [ "$value" -le 4294967295 ]
}

is_valid_iface_name() {
	case "$1" in
	'' | *[!A-Za-z0-9_.@-]*) return 1 ;;
	esac
	[ "${#1}" -le 15 ]
}

is_ipv4() {
	local value="$1" octet="" count=0 old_ifs="$IFS"

	case "$value" in
	*[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	IFS='.'
	for octet in $value; do
		count=$((count + 1))
		case "$octet" in
		? | ?? | ???) [ "$octet" -le 255 ] || count=9 ;;
		*) count=9 ;;
		esac
	done
	IFS="$old_ifs"
	[ "$count" -eq 4 ]
}

# Practical IPv6 check: hex groups, at most one "::", 2-8 groups.
is_ipv6() {
	local value="$1" rest="" groups=0 group="" old_ifs="$IFS"

	case "$value" in
	'' | *[!0-9A-Fa-f:]* | *:::*) return 1 ;;
	*::*::*) return 1 ;;
	*:*) ;;
	*) return 1 ;;
	esac
	rest="$value"
	case "$rest" in
	::*) rest="${rest#::}" ;;
	:*) return 1 ;;
	esac
	case "$rest" in
	*::) rest="${rest%::}" ;;
	*:) return 1 ;;
	esac
	IFS=':'
	for group in $rest; do
		# "::" leaves an empty field; it is not a group.
		[ -n "$group" ] || continue
		groups=$((groups + 1))
		[ "${#group}" -le 4 ] || groups=99
	done
	IFS="$old_ifs"
	case "$value" in
	*::*) [ "$groups" -le 7 ] ;;
	*) [ "$groups" -eq 8 ] ;;
	esac
}

is_http_url() {
	case "$1" in
	http://?* | https://?*) ;;
	*) return 1 ;;
	esac
	case "$1" in
	*[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
	esac
	return 0
}

# Host part of an http(s) URL without userinfo and port.
url_host() {
	local rest="${1#*://}"

	rest="${rest%%/*}"
	rest="${rest%%\?*}"
	rest="${rest##*@}"
	case "$rest" in
	\[*) rest="${rest#\[}"; rest="${rest%%\]*}" ;;
	*) rest="${rest%%:*}" ;;
	esac
	printf '%s' "$rest"
}
