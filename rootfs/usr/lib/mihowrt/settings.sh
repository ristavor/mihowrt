#!/bin/ash

# Load UCI settings into shell variables and validate them once. Provider
# values from the profile (x-mihowrt) replace UCI values unless the user
# overrides that setting (list provider_override).

# UCI value, or the provider's when it sets the option and it is not overridden.
settings_value() {
	case " $PROVIDER_KEYS " in
	*" $1 "*)
		case " $PROVIDER_OVERRIDES " in
		*" $1 "*) ;;
		*)
			profile_get "set $1"
			return 0
			;;
		esac
		;;
	esac
	uci_get "$1" "$2"
}

settings_bool() {
	case "$(settings_value "$1" "$2")" in
	1 | on | true | yes | enabled) printf '1' ;;
	*) printf '0' ;;
	esac
}

settings_hours() {
	local value=""

	value="$(settings_value "$1" 0)"
	is_uint "$value" && [ "$value" -le 8760 ] || return 1
	printf '%s' "$((value))"
}

lan_device_detect() {
	local dev=""

	dev="$(uci -q get network.lan.device 2>/dev/null)" || dev=""
	dev="${dev%% *}"
	is_valid_iface_name "$dev" && {
		printf '%s' "$dev"
		return 0
	}
	printf 'br-lan'
}

# Reject marks that would collide with MihoWRT, zapret or NetBird namespaces.
settings_check_netbird_mark() {
	local mark="$1" intercept=$((NFT_INTERCEPT_MARK))

	is_valid_uint32_mark "$mark" || return 1
	mark=$((mark))
	[ $((mark & 255)) -eq 0 ] || return 1
	[ $((mark & intercept)) -eq 0 ] || return 1
	[ $((mark & ZAPRET_DESYNC_MARK)) -eq 0 ] || return 1
	[ $((mark & ZAPRET_DESYNC_MARK_POSTNAT)) -eq 0 ] || return 1
	[ "$MIHOMO_ROUTING_MARK" -lt "$mark" ] || [ "$MIHOMO_ROUTING_MARK" -gt $((mark + 255)) ]
}

# Auto-update on: the provider's profile-update-interval (no valid header =
# no automatic updates, the provider's choice). Off: 0.
settings_subscription_interval() {
	local header=""

	[ "$(uci_get subscription_auto_update 1)" = "0" ] && {
		echo 0
		return 0
	}
	header="$(jq -r '.header_interval // empty' "${SUBSCRIPTION_META_FILE:-/etc/mihowrt/subscription.json}" 2>/dev/null)"
	if is_uint "$header" && [ "$header" -gt 0 ] && [ "$header" -le 8760 ]; then
		echo "$((header))"
	else
		echo 0
	fi
}

settings_list_source() {
	case "$(uci_get "$1" provider)" in
	merge) printf 'merge' ;;
	own) printf 'own' ;;
	*) printf 'provider' ;;
	esac
}

settings_invalid() {
	err "Invalid $1: $2"
	return 1
}

settings_load() {
	local iface=""

	# The mode follows the YAML DNS settings; no profile = no YAML yet.
	profile_ensure 2>/dev/null || true
	POLICY_MODE="$(profile_get mode)"
	case "$POLICY_MODE" in
	direct-first | proxy-first) ;;
	*) POLICY_MODE="proxy-first" ;;
	esac
	DNS_MODE="$(profile_get dns)"
	case "$DNS_MODE" in
	fake-ip | redir-host | normal) ;;
	*) DNS_MODE="redir-host" ;;
	esac
	PROVIDER_KEYS="$(profile_entries set | cut -d' ' -f1 | tr '\n' ' ')"
	PROVIDER_OVERRIDES="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.provider_override" 2>/dev/null)" || PROVIDER_OVERRIDES=""
	DST_LIST_SOURCE="$(settings_list_source dst_list_source)"
	DIRECT_LIST_SOURCE="$(settings_list_source direct_list_source)"

	SOURCE_INTERFACES="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.source_network_interfaces" 2>/dev/null)" || SOURCE_INTERFACES=""
	[ -n "$SOURCE_INTERFACES" ] || SOURCE_INTERFACES="$(lan_device_detect)"
	for iface in $SOURCE_INTERFACES; do
		is_valid_iface_name "$iface" || settings_invalid source_network_interfaces "$iface" || return 1
	done

	DNS_HIJACK="$(settings_bool dns_hijack 1)"
	DISABLE_QUIC="$(settings_bool disable_quic 1)"
	NETBIRD_PROXY="$(settings_bool netbird_proxy 0)"
	BYPASS_NTP="$(settings_bool bypass_ntp 1)"
	BYPASS_SUBSCRIPTION_DNS="$(settings_bool bypass_subscription_dns 1)"

	NETBIRD_MARK="$(uci_get netbird_mark "$NETBIRD_DEFAULT_MARK")"
	settings_check_netbird_mark "$NETBIRD_MARK" || settings_invalid netbird_mark "$NETBIRD_MARK" || return 1
	NETBIRD_MARK=$((NETBIRD_MARK))
	NETBIRD_INTERFACE="$(uci_get netbird_interface "$NETBIRD_DEFAULT_IFACE")"
	is_valid_iface_name "$NETBIRD_INTERFACE" || settings_invalid netbird_interface "$NETBIRD_INTERFACE" || return 1

	SUBSCRIPTION_URL="$(uci_get subscription_url)"
	[ -z "$SUBSCRIPTION_URL" ] || is_http_url "$SUBSCRIPTION_URL" || settings_invalid subscription_url "$SUBSCRIPTION_URL" || return 1
	SUBSCRIPTION_INTERVAL="$(settings_subscription_interval)"
	LISTS_INTERVAL="$(settings_hours lists_interval)" || settings_invalid lists_interval "$(settings_value lists_interval)" || return 1

	API_SECRET="$(uci_get api_secret)"
	case "$API_SECRET" in
	*[!A-Za-z0-9._~-]*) settings_invalid api_secret "(unsupported characters)" || return 1 ;;
	esac
	CRON_MINUTE="$(uci_get cron_minute 17)"
	is_uint "$CRON_MINUTE" && [ "$CRON_MINUTE" -le 59 ] || CRON_MINUTE=17
	return 0
}

random_hex() {
	hexdump -n "$1" -v -e '/1 "%02x"' /dev/urandom 2>/dev/null
}

# Generate per-device values once: API secret and the cron minute that spreads
# subscription requests across the hour.
settings_ensure_generated() {
	local changed=0 secret="" minute=""

	secret="$(uci_get api_secret)"
	case "$secret" in
	'' | ? | ?? | ??? | ???? | ????? | ?????? | ??????? | *[!A-Za-z0-9._~-]*)
		secret="$(random_hex 24)"
		[ "${#secret}" -eq 48 ] || {
			err "Failed to generate Mihomo API secret"
			return 1
		}
		uci_set api_secret "$secret" || return 1
		changed=1
		;;
	esac

	minute="$(uci_get cron_minute)"
	if ! is_uint "$minute" || [ "$minute" -gt 59 ]; then
		minute=$(( 0x$(random_hex 1) % 60 ))
		uci_set cron_minute "$minute" || return 1
		changed=1
	fi

	[ "$changed" -eq 0 ] || uci_commit
}
