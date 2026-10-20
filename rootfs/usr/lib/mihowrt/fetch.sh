#!/bin/ash

# HTTP fetch with size/time limits, device headers and subscription handling.

SUBSCRIPTION_MAX_BYTES="${SUBSCRIPTION_MAX_BYTES:-8388608}"
SUBSCRIPTION_TIMEOUT="${SUBSCRIPTION_TIMEOUT:-60}"
SUBSCRIPTION_META_FILE="${SUBSCRIPTION_META_FILE:-/etc/mihowrt/subscription.json}"

# --- device identity (stable across upgrades: same algorithm as 0.7) -------

device_hwid() {
	local file="$PKG_PERSIST_DIR/hwid" hwid="" material="" path="" mac=""

	hwid="$(head -n 1 "$file" 2>/dev/null | tr -d ' \r')"
	case "$hwid" in
	'' | *[!0-9a-f]*) ;;
	*)
		[ "${#hwid}" -eq 16 ] || [ "${#hwid}" -eq 64 ] && {
			echo "$hwid"
			return 0
		}
		;;
	esac

	for path in /sys/firmware/devicetree/base/serial-number /proc/device-tree/serial-number \
		/sys/class/dmi/id/product_uuid /sys/class/dmi/id/board_serial /sys/class/dmi/id/product_serial; do
		[ -r "$path" ] || continue
		material="$(tr -d '\000-\037' <"$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		case "$(echo "$material" | tr '[:upper:]' '[:lower:]')" in
		'' | 0 | unknown | none | unset | 00000000-0000-0000-0000-000000000000) material="" ;;
		*)
			material="serial:$material"
			break
			;;
		esac
	done
	if [ -z "$material" ]; then
		material="$(for path in /sys/class/net/*/address; do
			[ "${path%/address}" = /sys/class/net/lo ] && continue
			mac="$(tr '[:upper:]' '[:lower:]' <"$path" 2>/dev/null)"
			case "$mac" in
			00:00:00:00:00:00 | ff:ff:ff:ff:ff:ff | *[!0-9a-f:]*) ;;
			??:??:??:??:??:??) echo "$mac" ;;
			esac
		done | sort -u | awk 'NF { printf "%s%s", s, $0; s = "," }')"
		[ -z "$material" ] || material="macs:$material"
	fi
	if [ -n "$material" ]; then
		hwid="$(printf 'mihowrt-hwid-v2\n%s\n' "$material" | sha256sum | cut -c1-16)"
	else
		hwid="$(hexdump -n 8 -v -e '/1 "%02x"' /dev/urandom)"
	fi
	ensure_dir "$PKG_PERSIST_DIR" && (umask 077 && echo "$hwid" >"$file")
	echo "$hwid"
}

device_model() {
	local path=""

	for path in /tmp/sysinfo/model /sys/firmware/devicetree/base/model /tmp/sysinfo/board_name; do
		[ -r "$path" ] && {
			tr -d '\000-\037' <"$path"
			return 0
		}
	done
	echo unknown
}

device_os_version() {
	sed -n "s/^DISTRIB_RELEASE='\(.*\)'$/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

# --- HTTP ------------------------------------------------------------------

# Last value of a response header across redirect blocks.
fetch_header() {
	awk -v name="$2" '
		BEGIN { name = tolower(name) }
		/^HTTP\// { value = "" }
		{
			line = $0
			sub(/\r$/, "", line)
			i = index(line, ":")
			if (i && tolower(substr(line, 1, i - 1)) == name) {
				value = substr(line, i + 1)
				sub(/^[[:space:]]+/, "", value)
			}
		}
		END { print value }
	' "$1" 2>/dev/null | single_line
}

# http_fetch <url> <out> <max_bytes> <timeout> <device_headers 0|1>
# Sets FETCH_ERROR (network|too_large|http_<code>|invalid_url), FETCH_HTTP_STATUS
# and FETCH_HDR (path of the response header dump, valid until the next call).
http_fetch() {
	local url="$1" out="$2" max="$3" timeout="$4" device="${5:-0}" size="" rc=0

	FETCH_ERROR=""
	FETCH_HTTP_STATUS=""
	# Per process: downloads run without the lock and may overlap.
	FETCH_HDR="$PKG_TMP_DIR/fetch.headers.$$"
	is_http_url "$url" || {
		FETCH_ERROR=invalid_url
		return 1
	}
	ensure_dir "$PKG_TMP_DIR" || return 1
	: >"$FETCH_HDR"
	# Device headers identify the router to the provider; only over HTTPS.
	case "$device:$url" in
	1:https://*)
		curl -fsSL --proto '=https,http' --proto-redir '=https' --max-redirs 5 \
			--max-filesize "$max" --connect-timeout 15 --max-time "$timeout" \
			-A "mihowrt/$PKG_VERSION" -H "x-hwid: $(device_hwid)" -H "x-device-os: OpenWrt" \
			-H "x-ver-os: $(device_os_version)" -H "x-device-model: $(device_model)" \
			-D "$FETCH_HDR" -o "$out" "$url" || rc=$?
		;;
	*)
		curl -fsSL --proto '=https,http' --proto-redir '=https' --max-redirs 5 \
			--max-filesize "$max" --connect-timeout 15 --max-time "$timeout" \
			-A "mihowrt/$PKG_VERSION" -D "$FETCH_HDR" -o "$out" "$url" || rc=$?
		;;
	esac
	FETCH_HTTP_STATUS="$(awk '/^HTTP\// { s = $2 } END { print s }' "$FETCH_HDR" 2>/dev/null)"
	size=""
	[ -f "$out" ] && size="$(wc -c <"$out" | tr -d ' ')"
	if [ "$rc" -eq 63 ] || { is_uint "$size" && [ "$size" -gt "$max" ]; }; then
		FETCH_ERROR=too_large
	elif [ "$rc" -eq 22 ]; then
		FETCH_ERROR="http_$FETCH_HTTP_STATUS"
	elif [ "$rc" -ne 0 ]; then
		FETCH_ERROR=network
	fi
	[ -z "$FETCH_ERROR" ] && return 0
	rm -f "$out"
	return 1
}

# Latest release tag without the GitHub API (blocked or rate-limited):
# github.com redirects /releases/latest to /releases/tag/<tag>.
github_latest_tag() {
	local url=""

	url="$(curl -fsS -o /dev/null --connect-timeout 15 --max-time 30 \
		-w '%{redirect_url}' "https://github.com/$1/releases/latest" 2>/dev/null)" || return 1
	case "$url" in
	*/releases/tag/?*) echo "${url##*/releases/tag/}" ;;
	*) return 1 ;;
	esac
}

# --- subscription metadata ---------------------------------------------------

# Decode "base64:..." header values; keep anything else (and invalid data) as is.
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
	'' | *[!A-Za-z0-9+/=]* | *=[!=]* | *===*)
		printf '%s' "$raw"
		return 0
		;;
	esac
	if [ $((${#payload} % 4)) -ne 0 ] || [ "${#payload}" -gt 4096 ]; then
		printf '%s' "$raw"
		return 0
	fi
	# OpenWrt has no base64 tool; jq decodes. jq turns invalid UTF-8 into
	# U+FFFD, so such values (and NUL bytes) keep the raw form.
	decoded="$(printf '%s' "$payload" | jq -Rr '@base64d | select(length > 0 and (explode | all(. != 0 and . != 65533)))' 2>/dev/null)"
	if [ -n "$decoded" ]; then
		printf '%s' "$decoded"
	else
		printf '%s' "$raw"
	fi
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
	jq -nc --arg url "$(uci_get subscription_url)" --arg interval "$(uci_get subscription_interval)" \
		--arg effective "$(settings_subscription_interval || echo 0)" --arg updated "$(date -r "$PKG_STATE_DIR/subscription.stamp" +%s 2>/dev/null)" --argjson meta "$meta" '
		$meta + {url: $url, interval: $interval, effective_interval: ($effective | tonumber),
		         last_update: (if $updated == "" then null else ($updated | tonumber) end)}'
}

subscription_set() {
	local url="$1" interval="$2"

	[ -z "$url" ] || is_http_url "$url" || {
		err "Subscription URL must start with http:// or https://"
		return 1
	}
	[ -z "$interval" ] || { is_uint "$interval" && [ "$interval" -le 8760 ]; } || {
		err "Update interval must be a number of hours (0-8760) or empty for automatic"
		return 1
	}
	uci_set subscription_url "$url" && uci_set subscription_interval "$interval" && uci_commit || return 1
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

# Download the subscription, validate and install it, update metadata.
subscription_update() {
	local candidate="$PKG_TMP_DIR/subscription.$$.yaml" meta="" result="" bypass="" rc=0

	settings_load || return 1
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
		err "Subscription download failed: $FETCH_ERROR"
		return 1
	fi
	[ -s "$candidate" ] || {
		rm -f "$candidate"
		err "Subscription returned an empty config"
		return 1
	}
	meta="$(subscription_metadata_from_headers)" || meta=""
	# Download without the lock; only installing needs it.
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
	touch "$PKG_STATE_DIR/subscription.stamp" 2>/dev/null
	cron_update
	printf '%s\n' "$result"
}
