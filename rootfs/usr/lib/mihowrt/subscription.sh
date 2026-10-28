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
	# Keep metadata compatibility: drop NUL, invalid UTF-8 and U+FFFD.
	decoded="$(printf '%s' "$payload" | mihowrt-json base64 2>/dev/null)"
	printf '%s' "$decoded"
}

subscription_metadata_from_headers() {
	local file="${FETCH_HDR:-/dev/null}"
	local title="" announce="" support="" web="" interval=""
	local upload="" download="" total="" expire=""

	[ -f "$file" ] || file=/dev/null
	{
		IFS= read -r title || true
		IFS= read -r announce || true
		IFS= read -r support || true
		IFS= read -r web || true
		IFS= read -r interval || true
		IFS= read -r upload || true
		IFS= read -r download || true
		IFS= read -r total || true
		IFS= read -r expire || true
	} <<EOF
$(awk '
/^HTTP\// {
	title = ""; announce = ""; support = ""; web = ""; interval = ""; userinfo = ""
}
{
	line = $0
	sub(/\r$/, "", line)
	i = index(line, ":")
	if (i) {
		name = tolower(substr(line, 1, i - 1))
		val = substr(line, i + 1)
		gsub(/[\r\n\t]/, " ", val)
		gsub(/[\001-\037]/, "", val)
		sub(/^[[:space:]]+/, "", val)
		sub(/[[:space:]]+$/, "", val)
		if (name == "profile-title") title = val
		else if (name == "announce") announce = val
		else if (name == "support-url") support = val
		else if (name == "profile-web-page-url") web = val
		else if (name == "profile-update-interval") interval = val
		else if (name == "subscription-userinfo") userinfo = val
	}
}
END {
	if (userinfo != "") {
		n = split(userinfo, parts, ";")
		for (k = 1; k <= n; k++) {
			p = parts[k]
			sub(/^[[:space:]]+/, "", p)
			eq = index(p, "=")
			if (eq) {
				kname = substr(p, 1, eq - 1)
				val = substr(p, eq + 1)
				match(val, /^[0-9]*/)
				digits = substr(val, RSTART, RLENGTH)
				if (kname == "upload" && !has_u) { upload = digits; has_u = 1 }
				else if (kname == "download" && !has_d) { download = digits; has_d = 1 }
				else if (kname == "total" && !has_t) { total = digits; has_t = 1 }
				else if (kname == "expire" && !has_e) { expire = digits; has_e = 1 }
			}
		}
	}
	print title
	print announce
	print support
	print web
	print interval
	print upload
	print download
	print total
	print expire
}' "$file" 2>/dev/null)
EOF

	title="$(subscription_decode_metadata_value "$title")"
	announce="$(subscription_decode_metadata_value "$announce")"

	mihowrt-json build metadata \
		--arg title "$title" \
		--arg announce "$announce" \
		--arg support "$support" \
		--arg web "$web" \
		--arg interval "$interval" \
		--arg upload "$upload" \
		--arg download "$download" \
		--arg total "$total" \
		--arg expire "$expire"
}

subscription_stamp_file() {
	if [ -f "$PKG_STATE_DIR/subscription.stamp" ]; then
		printf '%s\n' "$PKG_STATE_DIR/subscription.stamp"
	elif [ -f "$SUBSCRIPTION_META_FILE" ]; then
		printf '%s\n' "$SUBSCRIPTION_META_FILE"
	else
		return 1
	fi
}

subscription_json() {
	local meta="{}" stamp="" backup=false

	stamp="$(subscription_stamp_file)" || stamp=""
	[ ! -f "$CLASH_CONFIG_BACKUP" ] || backup=true

	# A damaged file must not break the page: fall back to no metadata.
	[ -r "$SUBSCRIPTION_META_FILE" ] && meta="$(mihowrt-json object "$SUBSCRIPTION_META_FILE" 2>/dev/null)"
	[ -n "$meta" ] || meta="{}"
	mihowrt-json build subscription --arg url "$(uci_get subscription_url)" --arg auto "$(uci_get subscription_auto_update 1)" \
		--arg effective "$(settings_subscription_interval)" --arg updated "$(date -r "$stamp" +%s 2>/dev/null)" --argjson meta "$meta" \
		--argjson backup "$backup"
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
	# "Update now" saves the same values: no UCI commit, cron or DNS work.
	[ "$url" = "$(uci_get subscription_url)" ] && [ "$auto" = "$(uci_get subscription_auto_update)" ] && return 0
	uci_set subscription_url "$url" && uci_set subscription_auto_update "$auto" && uci_commit || return 1
	settings_load && cron_update
	[ -f "$RUNNING_MARKER" ] && dns_apply
	return 0
}

# A and AAAA answers for a host from the router resolver (dnsmasq).
subscription_host_addresses() {
	{
		if is_ipv4 "$1" || is_ipv6 "$1"; then
			echo "$1"
		else
			nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/ { name = 1; next } name && /^Address/ { sub(/^Address[^:]*:[[:space:]]*/, ""); print }'
		fi
	} | awk -v range="$FAKEIP_RANGE" '
	function ipv4(ip, octets) {
		split(ip, octets, ".")
		return ((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4]
	}
	BEGIN { split(range, cidr, "/"); size = 2 ^ (32 - cidr[2]); network = int(ipv4(cidr[1]) / size) }
	index($0, ":") || int(ipv4($0) / size) != network { print }'
}

# A Clash/Mihomo config has a top-level proxies or proxy-providers key.
# Catches V2Ray links, base64 lists, sing-box JSON and web pages early.
subscription_is_clash() {
	yaml_has_top_key 'proxies|proxy-providers' "$1"
}

# Restore DNS exceptions from the saved URL after a failed replacement.
subscription_restore_dns() {
	settings_load && with_lock dns_apply
}

# Download the subscription, validate and install it, update metadata.
# With a URL argument that link is tried and saved only if it works, so a
# typo never replaces the working link.
subscription_update() {
	local new_url="${1:-}" candidate="$PKG_TMP_DIR/subscription.$$.yaml" headers_file="$PKG_TMP_DIR/subscription.$$.headers" meta="" result="" bypass="" rc=0 dns_changed=0 saved_host=""

	settings_load || return 1
	saved_host="$(url_host "$SUBSCRIPTION_URL")"
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
	if [ -f "$RUNNING_MARKER" ] && [ "$saved_host" != "$(url_host "$SUBSCRIPTION_URL")" ]; then
		dns_changed=1
		with_lock dns_apply || {
			subscription_restore_dns || warn "Failed to restore subscription DNS"
			return 1
		}
	fi
	# Download directly (not through Mihomo) when the toggle is on: the IPs
	# come from the same resolver curl uses and are removed right after.
	bypass=""
	if [ "${BYPASS_SUBSCRIPTION_DNS:-0}" = "1" ] && nft_active; then
		bypass="$(subscription_host_addresses "$(url_host "$SUBSCRIPTION_URL")")"
		# shellcheck disable=SC2086
		[ -z "$bypass" ] || nft_bypass add $bypass
	fi
	rc=0
	http_fetch "$SUBSCRIPTION_URL" "$candidate" "$SUBSCRIPTION_MAX_BYTES" "$SUBSCRIPTION_TIMEOUT" 1 "$headers_file" || rc=$?
	# shellcheck disable=SC2086
	[ -z "$bypass" ] || nft_bypass delete $bypass
	if [ "$rc" -ne 0 ]; then
		rm -f "$headers_file"
		err "Subscription download failed: $FETCH_ERROR"
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	fi
	[ -s "$candidate" ] || {
		rm -f "$candidate" "$headers_file"
		err "Subscription returned an empty config"
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	}
	subscription_is_clash "$candidate" || {
		rm -f "$candidate" "$headers_file"
		err "The provider returned something that is not a Clash/Mihomo config (V2Ray links, base64, sing-box JSON or a web page). Use the Clash/Mihomo link from your provider's account."
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	}
	meta="$(subscription_metadata_from_headers)" || meta=""
	# Download without the lock; only installing needs it. A starting
	# Mihomo is awaited before the lock (run_service needs it to finish).
	config_api_wait || true
	result="$(with_lock config_install "$candidate")" || {
		rm -f "$candidate" "$headers_file"
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	}
	rm -f "$candidate"
	ensure_dir "$(dirname "$SUBSCRIPTION_META_FILE")"
	# Written only on change to spare flash, and only if it is valid JSON.
	if [ -n "$meta" ]; then
		printf '%s\n' "$meta" >"$PKG_TMP_DIR/subscription.json"
		if ! cmp -s "$PKG_TMP_DIR/subscription.json" "$SUBSCRIPTION_META_FILE" &&
			! atomic_copy "$PKG_TMP_DIR/subscription.json" "$SUBSCRIPTION_META_FILE"; then
			warn "Cannot write $SUBSCRIPTION_META_FILE"
		fi
		rm -f "$PKG_TMP_DIR/subscription.json"
	else
		warn "Subscription metadata could not be parsed; keeping the previous one"
	fi
	rm -f "$headers_file"
	if [ -n "$new_url" ] && [ "$new_url" != "$(uci_get subscription_url)" ]; then
		if ! { uci_set subscription_url "$new_url" && uci_commit; }; then
			warn "Failed to save the subscription URL"
		fi
	fi
	touch "$PKG_STATE_DIR/subscription.stamp" 2>/dev/null
	# Reload: the period header and provider lists may be new.
	settings_load || return 1
	if [ -n "$(lists_urls)" ] && [ "$(lists_update_remote 0)" = changed ]; then
		with_lock nft_apply_if_ready || warn "Failed to apply new remote lists"
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
	local stamp=""

	[ "$SUBSCRIPTION_INTERVAL" -gt 0 ] && [ -n "$SUBSCRIPTION_URL" ] || return 1
	stamp="$(subscription_stamp_file)" || return 0
	[ -n "$(find "$stamp" -mmin +$((SUBSCRIPTION_INTERVAL * 60 - 5)) 2>/dev/null)" ]
}
