#!/bin/ash

# HTTP fetch with size/time limits, device headers and GitHub tags.

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
		curl -fsSLg --proto '=https,http' --proto-redir '=https' --max-redirs 5 \
			--max-filesize "$max" --connect-timeout 15 --max-time "$timeout" \
			-A "mihowrt/$PKG_VERSION" -H "x-hwid: $(device_hwid)" -H "x-device-os: OpenWrt" \
			-H "x-ver-os: $(device_os_version)" -H "x-device-model: $(device_model)" \
			-D "$FETCH_HDR" -o "$out" "$url" 2>/dev/null || rc=$?
		;;
	*)
		curl -fsSLg --proto '=https,http' --proto-redir '=https' --max-redirs 5 \
			--max-filesize "$max" --connect-timeout 15 --max-time "$timeout" \
			-A "mihowrt/$PKG_VERSION" -D "$FETCH_HDR" -o "$out" "$url" 2>/dev/null || rc=$?
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
