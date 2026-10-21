#!/bin/ash

# Subscription metadata, settings, downloads and installation.

SUBSCRIPTION_MAX_BYTES="${SUBSCRIPTION_MAX_BYTES:-8388608}"
SUBSCRIPTION_TIMEOUT="${SUBSCRIPTION_TIMEOUT:-60}"
SUBSCRIPTION_META_FILE="${SUBSCRIPTION_META_FILE:-/etc/mihowrt/subscription.json}"

# --- subscription metadata ---------------------------------------------------

# Decode "base64:..." header values. A payload that cannot be decoded (bad
# format, over 16384 characters, invalid UTF-8, NUL) gives an empty value;
# plain values are kept as sent.
subscription_decode_metadata_value() {
	local raw="$1" payload="" decoded=""

	case "$raw" in
	base64:*) ;;
	*)
		printf '%s' "$raw"
		return 0
		;;
	esac
	payload="$(printf '%s' "${raw#base64:}" | tr -d ' \t\r\n')"
	# BusyBox base64 accepts malformed padding, so check the format first.
	case "$payload" in
	'' | *[!A-Za-z0-9+/=]* | *=[!=]* | *===*) return 0 ;;
	esac
	[ $((${#payload} % 4)) -eq 0 ] && [ "${#payload}" -le 16384 ] || return 0
	# OpenWrt has no base64 tool; jq decodes. jq turns invalid UTF-8 into
	# U+FFFD, so such values (and NUL bytes) are dropped.
	decoded="$(printf '%s' "$payload" | jq -Rr '@base64d | select(length > 0 and (explode | all(. != 0 and . != 65533)))' 2>/dev/null)"
	printf '%s' "$decoded"
}

userinfo_field() {
	printf '%s' "$1" | tr ';' '\n' | sed -n "s/^[[:space:]]*$2=\([0-9]*\).*/\1/p" | head -n 1
}

subscription_metadata_from_headers() {
	local userinfo=""

	userinfo="$(fetch_header "$FETCH_HDR" subscription-userinfo)"
	jq -nc \
		--arg title "$(subscription_decode_metadata_value "$(fetch_header "$FETCH_HDR" profile-title)")" \
		--arg announce "$(subscription_decode_metadata_value "$(fetch_header "$FETCH_HDR" announce)")" \
		--arg support "$(fetch_header "$FETCH_HDR" support-url)" \
		--arg web "$(fetch_header "$FETCH_HDR" profile-web-page-url)" \
		--arg interval "$(fetch_header "$FETCH_HDR" profile-update-interval)" \
		--arg upload "$(userinfo_field "$userinfo" upload)" \
		--arg download "$(userinfo_field "$userinfo" download)" \
		--arg total "$(userinfo_field "$userinfo" total)" \
		--arg expire "$(userinfo_field "$userinfo" expire)" '
		def num: if . == "" then null else (tonumber? // null) end;
		{profile_title: $title, announce: $announce, support_url: $support,
		 web_page_url: $web, header_interval: ($interval | num),
		 upload: ($upload | num), download: ($download | num),
		 total: ($total | num), expire: ($expire | num)}'
}

subscription_json() {
	local meta="{}"

	# A damaged file must not break the page: fall back to no metadata.
	[ -r "$SUBSCRIPTION_META_FILE" ] && meta="$(jq -c 'objects' "$SUBSCRIPTION_META_FILE" 2>/dev/null)"
	[ -n "$meta" ] || meta="{}"
	jq -nc --arg url "$(uci_get subscription_url)" --arg auto "$(uci_get subscription_auto_update 1)" \
		--arg effective "$(settings_subscription_interval)" --arg updated "$(date -r "$PKG_STATE_DIR/subscription.stamp" +%s 2>/dev/null)" --argjson meta "$meta" '
		$meta + {url: $url, auto_update: ($auto != "0"), effective_interval: ($effective | tonumber),
		         last_update: (if $updated == "" then null else ($updated | tonumber) end)}'
}

subscription_set() {
	local url="$1" auto="$2"

	[ -z "$url" ] || is_http_url "$url" || {
		err "Subscription URL must start with http:// or https://"
		return 1
	}
	case "$auto" in
	0 | 1) ;;
	*)
		err "Auto-update must be 0 or 1"
		return 1
		;;
	esac
	uci_set subscription_url "$url" && uci_set subscription_auto_update "$auto" && uci_commit || return 1
	settings_load && cron_update
	[ -f "$RUNNING_MARKER" ] && dns_apply
	return 0
}

# A and AAAA answers for a host from the router resolver (dnsmasq).
subscription_host_addresses() {
	is_ipv4 "$1" || is_ipv6 "$1" && {
		echo "$1"
		return 0
	}
	nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/ { name = 1; next } name && /^Address/ { sub(/^Address[^:]*:[[:space:]]*/, ""); print }'
}

# A Clash/Mihomo config has a top-level proxies or proxy-providers key.
# Catches V2Ray links, base64 lists, sing-box JSON and web pages early.
subscription_is_clash() {
	awk '
		NR == 1 { sub(/^\357\273\277/, "") }
		/^["\047]?(proxies|proxy-providers)["\047]?[[:space:]]*:/ { found = 1; exit }
		END { exit !found }
	' "$1"
}

# Download the subscription, validate and install it, update metadata.
# With a URL argument that link is tried and saved only if it works, so a
# typo never replaces the working link.
subscription_update() {
	local new_url="${1:-}" candidate="$PKG_TMP_DIR/subscription.$$.yaml" meta="" result="" bypass="" rc=0

	settings_load || return 1
	if [ -n "$new_url" ]; then
		is_http_url "$new_url" || {
			err "Subscription download failed: invalid_url"
			return 1
		}
		SUBSCRIPTION_URL="$new_url"
	fi
	[ -n "$SUBSCRIPTION_URL" ] || {
		err "Subscription URL is not set"
		return 1
	}
	# Download directly (not through Mihomo) when the toggle is on: the IPs
	# come from the same resolver curl uses and are removed right after.
	bypass=""
	if [ "${BYPASS_SUBSCRIPTION_DNS:-0}" = "1" ] && nft_active; then
		bypass="$(subscription_host_addresses "$(url_host "$SUBSCRIPTION_URL")")"
		# shellcheck disable=SC2086
		[ -z "$bypass" ] || nft_bypass add $bypass
	fi
	rc=0
	http_fetch "$SUBSCRIPTION_URL" "$candidate" "$SUBSCRIPTION_MAX_BYTES" "$SUBSCRIPTION_TIMEOUT" 1 || rc=$?
	# shellcheck disable=SC2086
	[ -z "$bypass" ] || nft_bypass delete $bypass
	if [ "$rc" -ne 0 ]; then
		rm -f "${FETCH_HDR:-}"
		err "Subscription download failed: $FETCH_ERROR"
		return 1
	fi
	[ -s "$candidate" ] || {
		rm -f "$candidate" "${FETCH_HDR:-}"
		err "Subscription returned an empty config"
		return 1
	}
	subscription_is_clash "$candidate" || {
		rm -f "$candidate" "$FETCH_HDR"
		err "The provider returned something that is not a Clash/Mihomo config (V2Ray links, base64, sing-box JSON or a web page). Use the Clash/Mihomo link from your provider's account."
		return 1
	}
	meta="$(subscription_metadata_from_headers)" || meta=""
	# Download without the lock; only installing needs it. A starting
	# Mihomo is awaited before the lock (run_service needs it to finish).
	config_api_wait || true
	result="$(with_lock config_install "$candidate")" || {
		rm -f "$candidate" "$FETCH_HDR"
		return 1
	}
	rm -f "$candidate"
	ensure_dir "$(dirname "$SUBSCRIPTION_META_FILE")"
	# Written only on change to spare flash, and only if it is valid JSON.
	if [ -n "$meta" ]; then
		printf '%s\n' "$meta" >"$PKG_TMP_DIR/subscription.json"
		cmp -s "$PKG_TMP_DIR/subscription.json" "$SUBSCRIPTION_META_FILE" ||
			mv -f "$PKG_TMP_DIR/subscription.json" "$SUBSCRIPTION_META_FILE"
		rm -f "$PKG_TMP_DIR/subscription.json"
	else
		warn "Subscription metadata could not be parsed; keeping the previous one"
	fi
	rm -f "$FETCH_HDR"
	if [ -n "$new_url" ] && [ "$new_url" != "$(uci_get subscription_url)" ]; then
		if ! { uci_set subscription_url "$new_url" && uci_commit; }; then
			warn "Failed to save the subscription URL"
		fi
	fi
	touch "$PKG_STATE_DIR/subscription.stamp" 2>/dev/null
	# Reload: the period header and provider lists may be new.
	settings_load || return 1
	if [ -n "$(lists_urls)" ] && [ "$(lists_update_remote 0)" = changed ] && service_ready; then
		with_lock nft_apply || warn "Failed to apply new remote lists"
	fi
	cron_update || warn "Failed to update cron schedule"
	printf '%s\n' "$result"
}

# Connect only after a successful install. Init owns its runtime lock in a
# separate process, so enable/restart must remain outside with_lock.
subscription_connect() {
	local result=""

	result="$(subscription_update "$1")" || return 1
	with_lock subscription_set "$1" 1 >/dev/null || return 1
	/etc/init.d/mihowrt enable 9>&- >/dev/null &&
		/etc/init.d/mihowrt restart 9>&- >/dev/null || return 1
	printf '%s\n' "$result"
}

subscription_due() {
	local stamp="$PKG_STATE_DIR/subscription.stamp"

	[ "$SUBSCRIPTION_INTERVAL" -gt 0 ] && [ -n "$SUBSCRIPTION_URL" ] || return 1
	[ -f "$stamp" ] || return 0
	[ -n "$(find "$stamp" -mmin +$((SUBSCRIPTION_INTERVAL * 60 - 5)) 2>/dev/null)" ]
}
