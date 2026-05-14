#!/bin/ash

# User-Agent for all project HTTP fetches.
http_fetch_user_agent() {
	printf 'mihowrt/%s' "${PKG_VERSION:-unknown}"
}

http_fetch_header_value() {
	local value="$1"

	printf '%s' "$value" | tr '\r\n\t' '   ' | tr -d '[:cntrl:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

http_fetch_redacted_url() {
	local url="$1"
	local scheme="" rest="" authority=""

	case "$url" in
	http://*)
		scheme="http"
		rest="${url#http://}"
		;;
	https://*)
		scheme="https"
		rest="${url#https://}"
		;;
	*)
		printf '<redacted>'
		return 0
		;;
	esac

	authority="${rest%%/*}"
	authority="${authority%%\?*}"
	authority="${authority%%#*}"
	authority="${authority#*@}"
	[ -n "$authority" ] || authority="unknown-host"

	printf '%s://%s/<redacted>' "$scheme" "$authority"
}

device_read_file_value() {
	local file="$1"

	[ -r "$file" ] || return 1
	tr -d '\000\r\n' <"$file" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

device_material_value_valid() {
	local value=""

	value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	case "$value" in
	'' | 0 | unknown | none | unset | '00000000-0000-0000-0000-000000000000')
		return 1
		;;
	esac

	return 0
}

device_serial_material() {
	local paths="${MIHOWRT_DEVICE_SERIAL_FILES:-/sys/firmware/devicetree/base/serial-number /proc/device-tree/serial-number /sys/class/dmi/id/product_uuid /sys/class/dmi/id/board_serial /sys/class/dmi/id/product_serial}"
	local path="" value=""

	for path in $paths; do
		value="$(device_read_file_value "$path" 2>/dev/null || true)"
		device_material_value_valid "$value" || continue
		printf 'serial:%s\n' "$value"
		return 0
	done

	return 1
}

device_mac_valid() {
	local mac="$1"

	case "$mac" in
	00:00:00:00:00:00 | ff:ff:ff:ff:ff:ff)
		return 1
		;;
	??:??:??:??:??:??) ;;
	*)
		return 1
		;;
	esac
	case "$mac" in
	*[!0123456789abcdef:]*)
		return 1
		;;
	esac

	return 0
}

device_mac_material() {
	local net_dir="${MIHOWRT_NET_CLASS_DIR:-/sys/class/net}"
	local address_file="" iface="" mac="" macs=""

	[ -d "$net_dir" ] || return 1
	macs="$(
		for address_file in "$net_dir"/*/address; do
			[ -e "$address_file" ] || continue
			iface="${address_file%/address}"
			iface="${iface##*/}"
			[ "$iface" = "lo" ] && continue
			mac="$(device_read_file_value "$address_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
			device_mac_valid "$mac" || continue
			printf '%s\n' "$mac"
		done | sort -u | awk 'NF { printf "%s%s", sep, $0; sep = "," }'
	)"
	[ -n "$macs" ] || return 1
	printf 'macs:%s\n' "$macs"
}

device_hwid_material() {
	device_serial_material && return 0
	device_mac_material && return 0
	return 1
}

device_sha256() {
	if have_command sha256sum; then
		sha256sum | awk '{ print $1; exit }'
		return $?
	fi
	if have_command openssl; then
		openssl dgst -sha256 | awk '{ print $NF; exit }'
		return $?
	fi

	return 1
}

device_hwid_file() {
	printf '%s\n' "${MIHOWRT_HWID_FILE:-${PKG_PERSIST_DIR:-/etc/mihowrt}/hwid}"
}

device_hwid_valid() {
	case "$1" in
	????????????????????????????????????????????????????????????????)
		case "$1" in
		*[!0123456789abcdef]*)
			return 1
			;;
		esac
		return 0
		;;
	esac

	return 1
}

device_stored_hwid() {
	local hwid_file="" hwid=""

	hwid_file="$(device_hwid_file)"
	[ -r "$hwid_file" ] || return 1
	hwid="$(head -n 1 "$hwid_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
	device_hwid_valid "$hwid" || return 1
	printf '%s\n' "$hwid"
}

device_random_hwid() {
	local hwid_file="" hwid="" hwid_dir=""

	if ! have_command dd || ! have_command hexdump; then
		return 1
	fi

	hwid="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)"
	device_hwid_valid "$hwid" || return 1

	hwid_file="$(device_hwid_file)"
	hwid_dir="$(dirname "$hwid_file")"
	if ensure_dir "$hwid_dir" && printf '%s\n' "$hwid" >"$hwid_file" 2>/dev/null; then
		:
	fi
	printf '%s\n' "$hwid"
}

device_store_hwid() {
	local hwid="$1"
	local hwid_file="" hwid_dir=""

	device_hwid_valid "$hwid" || return 1
	hwid_file="$(device_hwid_file)"
	hwid_dir="$(dirname "$hwid_file")"
	ensure_dir "$hwid_dir" || return 1
	printf '%s\n' "$hwid" >"$hwid_file"
}

device_hwid() {
	local material="" hwid=""

	device_stored_hwid && return 0

	material="$(device_hwid_material 2>/dev/null || true)"
	if [ -n "$material" ]; then
		hwid="$(printf 'mihowrt-hwid-v1\n%s\n' "$material" | device_sha256 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
		if device_hwid_valid "$hwid"; then
			device_store_hwid "$hwid" 2>/dev/null || true
			printf '%s\n' "$hwid"
			return 0
		fi
	fi

	device_random_hwid
}

device_os_name() {
	printf 'OpenWrt'
}

device_os_version() {
	local release_file="${MIHOWRT_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
	local release=""

	if [ -r "$release_file" ]; then
		release="$(awk -F"'" '/^DISTRIB_RELEASE=/ { print $2; exit }' "$release_file" 2>/dev/null)"
	fi
	[ -n "$release" ] || release="unknown"
	http_fetch_header_value "$release"
}

device_model() {
	local paths="${MIHOWRT_DEVICE_MODEL_FILES:-/tmp/sysinfo/model /sys/firmware/devicetree/base/model /proc/device-tree/model /tmp/sysinfo/board_name}"
	local path="" model=""

	for path in $paths; do
		model="$(device_read_file_value "$path" 2>/dev/null || true)"
		[ -n "$model" ] || continue
		http_fetch_header_value "$model"
		return 0
	done

	printf 'unknown'
}

device_hwid_header_value() {
	local hwid=""

	hwid="$(device_hwid 2>/dev/null || true)"
	device_hwid_valid "$hwid" || hwid="unknown"
	http_fetch_header_value "$hwid"
}

# Accept only simple http(s) URLs without whitespace. This is intentionally
# narrow because URLs come from LuCI/user config and are passed to wget.
is_http_fetch_url() {
	local url="$1"

	case "$url" in
	'' | *[[:space:]]*)
		return 1
		;;
	http:///* | https:///*)
		return 1
		;;
	http://?* | https://?*)
		return 0
		;;
	esac

	return 1
}

# Fetch a body through a FIFO and head -c so oversized responses stop at
# max_bytes + 1 instead of filling router RAM or flash.
FETCH_HTTP_STATUS=""
FETCH_HTTP_ERROR_KIND=""
FETCH_HTTP_ERROR_MESSAGE=""
FETCH_PROFILE_UPDATE_INTERVAL=""

fetch_http_reset_error() {
	FETCH_HTTP_STATUS=""
	FETCH_HTTP_ERROR_KIND=""
	FETCH_HTTP_ERROR_MESSAGE=""
	FETCH_PROFILE_UPDATE_INTERVAL=""
}

fetch_http_set_error() {
	FETCH_HTTP_ERROR_KIND="$1"
	FETCH_HTTP_ERROR_MESSAGE="$2"
}

fetch_last_http_status() {
	local stderr_file="$1"

	awk '/HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ { code = $2 } END { if (code != "") print code }' "$stderr_file" 2>/dev/null
}

fetch_profile_update_interval() {
	local stderr_file="$1"

	awk '
		BEGIN { value = "" }
		tolower($0) ~ /^[[:space:]]*profile-update-interval[[:space:]]*:/ {
			line = $0
			sub("^[^:]*:", "", line)
			gsub("^[[:space:]]+|[[:space:]]+$", "", line)
			if (line ~ /^[0-9]+$/) value = line
		}
		END { if (value != "") print value }
	' "$stderr_file" 2>/dev/null
}

fetch_stderr_looks_timeout() {
	local stderr_file="$1"

	grep -qiE 'timed?[ -]?out|timeout' "$stderr_file" 2>/dev/null
}

fetch_http_body_limited_to_file() {
	local url="" output="${5:-}" fifo="" size="" max_bytes="" read_limit=0 stderr_file=""
	local reader_pid="" wget_pid="" reader_rc=0 wget_rc=0
	local timeout="${3:-30}"
	local label="${4:-download}"
	local include_device_headers="${6:-0}"
	local header_hwid="" header_device_os="" header_ver_os="" header_device_model=""
	local safe_url=""

	fetch_http_reset_error
	url="$(trim "${1:-}")"
	max_bytes="${2:-}"
	if ! is_http_fetch_url "$url"; then
		fetch_http_set_error "invalid_url" "Invalid $label URL: use http:// or https:// without whitespace"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	fi
	safe_url="$(http_fetch_redacted_url "$url")"

	if ! is_uint "$max_bytes"; then
		fetch_http_set_error "invalid_limit" "Invalid $label size limit: $max_bytes"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	fi
	max_bytes="$(normalize_uint "$max_bytes")"
	if [ "$max_bytes" = "0" ] || ! uint_lte "$max_bytes" 2147483646; then
		fetch_http_set_error "invalid_limit" "Invalid $label size limit: $max_bytes"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	fi

	[ -n "$output" ] || {
		fetch_http_set_error "temp_error" "Temporary $label output path is required"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}

	have_command wget || {
		fetch_http_set_error "command_missing" "Required command missing: wget"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}
	have_command mktemp || {
		fetch_http_set_error "command_missing" "Required command missing: mktemp"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}
	have_command mkfifo || {
		fetch_http_set_error "command_missing" "Required command missing: mkfifo"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}
	have_command head || {
		fetch_http_set_error "command_missing" "Required command missing: head"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}

	fifo="$(mktemp /tmp/mihowrt-fetch.pipe.XXXXXX)" || {
		fetch_http_set_error "temp_error" "Failed to allocate temporary $label pipe path"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}
	rm -f "$fifo"
	mkfifo "$fifo" || {
		fetch_http_set_error "temp_error" "Failed to create temporary $label pipe"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$fifo"
		return 1
	}
	stderr_file="$(mktemp /tmp/mihowrt-fetch.err.XXXXXX)" || {
		fetch_http_set_error "temp_error" "Failed to allocate temporary $label error path"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$fifo"
		return 1
	}

	read_limit=$((max_bytes + 1))
	head -c "$read_limit" <"$fifo" >"$output" &
	reader_pid=$!
	if [ "$include_device_headers" = "1" ]; then
		header_hwid="$(device_hwid_header_value)"
		header_device_os="$(device_os_name)"
		header_ver_os="$(device_os_version)"
		header_device_model="$(device_model)"
		wget -S -T "$timeout" -U "$(http_fetch_user_agent)" \
			--header "x-hwid: $header_hwid" \
			--header "x-device-os: $header_device_os" \
			--header "x-ver-os: $header_ver_os" \
			--header "x-device-model: $header_device_model" \
			-O - "$url" >"$fifo" 2>"$stderr_file" &
	else
		wget -S -T "$timeout" -U "$(http_fetch_user_agent)" -O - "$url" >"$fifo" 2>"$stderr_file" &
	fi
	wget_pid=$!

	wait "$wget_pid" || wget_rc=$?
	wait "$reader_pid" || reader_rc=$?
	rm -f "$fifo"
	FETCH_HTTP_STATUS="$(fetch_last_http_status "$stderr_file")"
	FETCH_PROFILE_UPDATE_INTERVAL="$(fetch_profile_update_interval "$stderr_file")"

	size="$(wc -c <"$output" 2>/dev/null | tr -d '[:space:]')"
	if ! is_uint "$size"; then
		fetch_http_set_error "io_error" "Failed to measure $label size"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$stderr_file"
		return 1
	fi

	if ! uint_lte "$size" "$max_bytes"; then
		fetch_http_set_error "too_large" "$label is too large: $size bytes, limit $max_bytes"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$stderr_file"
		return 1
	fi

	if [ "$reader_rc" -ne 0 ]; then
		fetch_http_set_error "io_error" "Failed to store $label from $safe_url"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$stderr_file"
		return 1
	fi

	if [ "$wget_rc" -ne 0 ]; then
		if [ -n "$FETCH_HTTP_STATUS" ]; then
			fetch_http_set_error "http_error" "Failed to fetch $label from $safe_url: HTTP $FETCH_HTTP_STATUS"
		elif fetch_stderr_looks_timeout "$stderr_file"; then
			fetch_http_set_error "timeout" "Failed to fetch $label from $safe_url: timeout"
		else
			fetch_http_set_error "wget_failed" "Failed to fetch $label from $safe_url"
		fi
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$stderr_file"
		return 1
	fi

	if [ ! -s "$output" ]; then
		fetch_http_set_error "empty" "$label returned empty content"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$stderr_file"
		return 1
	fi

	rm -f "$stderr_file"
	return 0
}

fetch_http_body_limited() {
	local url="" output="" rc=0 max_bytes=""
	local timeout="${3:-30}"
	local label="${4:-download}"
	local include_device_headers="${5:-0}"

	url="$(trim "${1:-}")"
	max_bytes="${2:-}"
	output="$(mktemp /tmp/mihowrt-fetch.XXXXXX)" || {
		fetch_http_set_error "temp_error" "Failed to allocate temporary $label path"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}

	fetch_http_body_limited_to_file "$url" "$max_bytes" "$timeout" "$label" "$output" "$include_device_headers" || {
		rc=$?
		rm -f "$output"
		return "$rc"
	}

	cat "$output"
	rc=$?
	rm -f "$output"
	return "$rc"
}

# Backward-compatible name used by older tests/helpers.
subscription_user_agent() {
	http_fetch_user_agent
}

# Subscription URLs use the same conservative URL validator as policy lists.
is_subscription_url() {
	is_http_fetch_url "$1"
}

subscription_interval_valid() {
	local value="$1"

	is_uint "$value" || return 1
	value="$(normalize_uint "$value")"
	uint_lte "$value" 8760
}

subscription_effective_update_interval() {
	local override="$1"
	local update_interval="$2"
	local header_interval="$3"

	if [ "$override" = "1" ]; then
		[ -n "$update_interval" ] || return 0
		subscription_interval_valid "$update_interval" || return 0
		normalize_uint "$update_interval"
		return 0
	fi

	[ -n "$header_interval" ] || return 0
	subscription_interval_valid "$header_interval" || return 0
	normalize_uint "$header_interval"
}

subscription_now_epoch() {
	date +%s 2>/dev/null || printf '0\n'
}

subscription_next_update_epoch() {
	local interval="$1" now=""

	if [ -z "$interval" ] || ! subscription_interval_valid "$interval"; then
		printf '%s' ''
		return 0
	fi
	now="$(subscription_now_epoch)"
	printf '%s' $((now + (interval * 3600)))
}

subscription_cron_file() {
	printf '%s' "${SUBSCRIPTION_CRON_FILE:-/etc/crontabs/root}"
}

subscription_cron_marker() {
	printf '%s' "# mihowrt subscription auto-update"
}

subscription_restart_cron() {
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 || true
}

subscription_sync_auto_update_cron() {
	local enabled="$1"
	local cron_file="" marker="" entry=""

	cron_file="$(subscription_cron_file)"
	marker="$(subscription_cron_marker)"
	entry="17 * * * * /usr/bin/mihowrt auto-update-subscription >/dev/null 2>&1 $marker"

	mihowrt_sync_cron_marker "$cron_file" "$marker" "$enabled" "$entry" || return 1
	[ "${MIHOWRT_CRON_CHANGED:-0}" -eq 1 ] && subscription_restart_cron
	return 0
}

subscription_set_option_if_changed() {
	local option="$1"
	local value="$2"
	local current=""
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	current="$(uci -q get "$pkg_config.settings.$option" 2>/dev/null || true)"
	[ "$current" != "$value" ] || return 1
	uci -q set "$pkg_config.settings.$option=$value" || return 2
	return 0
}

subscription_delete_option_if_present() {
	local option="$1"
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	uci -q get "$pkg_config.settings.$option" >/dev/null 2>&1 || return 1
	uci -q delete "$pkg_config.settings.$option" || return 2
	return 0
}

subscription_commit_if_changed() {
	local changed="$1"
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	[ "$changed" -eq 1 ] || return 0
	uci -q commit "$pkg_config" || {
		err "Failed to commit subscription settings"
		return 1
	}
}

subscription_configured_update_interval() {
	local interval_override="" update_interval="" header_interval=""

	require_command uci || return 1
	interval_override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	subscription_effective_update_interval "$interval_override" "$update_interval" "$header_interval"
}

subscription_auto_update_state_file() {
	printf '%s' "${SUBSCRIPTION_AUTO_UPDATE_STATE_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/subscription-auto.state}"
}

subscription_clear_auto_update_state() {
	rm -f "$(subscription_auto_update_state_file)"
}

subscription_state_value() {
	local key="$1"
	local file=""

	file="$(subscription_auto_update_state_file)"
	[ -r "$file" ] || return 1
	sed -n "s/^$key=//p" "$file" | tail -n 1
}

subscription_write_auto_update_state() {
	local interval="$1"
	local result="${2:-scheduled}"
	local reason="${3:-}"
	local manual_restart_required="${4:-0}"
	local manual_restart_reason="${5:-}"
	local next_update_override="${6:-}"
	local state_file="" state_dir="" tmp_file="" now="" next_update=""

	state_file="$(subscription_auto_update_state_file)"
	state_dir="$(dirname "$state_file")"
	ensure_dir "$state_dir" || return 1
	tmp_file="${state_file}.tmp.$$"
	now="$(subscription_now_epoch)"
	if [ -n "$next_update_override" ]; then
		next_update="$next_update_override"
	else
		next_update="$(subscription_next_update_epoch "$interval")"
	fi
	reason="$(printf '%s' "$reason" | tr '\n' ' ')"
	manual_restart_reason="$(printf '%s' "$manual_restart_reason" | tr '\n' ' ')"
	case "$manual_restart_required" in
	1 | true | yes) manual_restart_required=1 ;;
	*) manual_restart_required=0 ;;
	esac

	{
		printf 'enabled=1\n'
		printf 'interval=%s\n' "$interval"
		printf 'last_update=%s\n' "$now"
		printf 'next_update=%s\n' "$next_update"
		printf 'last_result=%s\n' "$result"
		printf 'reason=%s\n' "$reason"
		printf 'manual_restart_required=%s\n' "$manual_restart_required"
		printf 'manual_restart_reason=%s\n' "$manual_restart_reason"
	} >"$tmp_file" || {
		rm -f "$tmp_file"
		return 1
	}

	mv -f "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
}

subscription_write_auto_update_disabled_state() {
	local reason="${1:-}"
	local manual_restart_required="${2:-0}"
	local manual_restart_reason="${3:-}"
	local state_file="" state_dir="" tmp_file="" now=""

	state_file="$(subscription_auto_update_state_file)"
	state_dir="$(dirname "$state_file")"
	ensure_dir "$state_dir" || return 1
	tmp_file="${state_file}.tmp.$$"
	now="$(subscription_now_epoch)"
	reason="$(printf '%s' "$reason" | tr '\n' ' ')"
	manual_restart_reason="$(printf '%s' "$manual_restart_reason" | tr '\n' ' ')"
	case "$manual_restart_required" in
	1 | true | yes) manual_restart_required=1 ;;
	*) manual_restart_required=0 ;;
	esac

	{
		printf 'enabled=0\n'
		printf 'interval=\n'
		printf 'last_update=%s\n' "$now"
		printf 'next_update=\n'
		printf 'last_result=disabled\n'
		printf 'reason=%s\n' "$reason"
		printf 'manual_restart_required=%s\n' "$manual_restart_required"
		printf 'manual_restart_reason=%s\n' "$manual_restart_reason"
	} >"$tmp_file" || {
		rm -f "$tmp_file"
		return 1
	}

	mv -f "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
}

subscription_existing_manual_restart_state() {
	local manual_restart_required="" manual_restart_reason=""

	manual_restart_required="$(subscription_state_value manual_restart_required 2>/dev/null || true)"
	manual_restart_reason="$(subscription_state_value manual_restart_reason 2>/dev/null || true)"
	case "$manual_restart_required" in
	1 | true | yes) manual_restart_required=1 ;;
	*) manual_restart_required=0 ;;
	esac
	printf '%s	%s\n' "$manual_restart_required" "$manual_restart_reason"
}

subscription_detect_or_existing_manual_restart_state() {
	local detected_restart_state=""

	detected_restart_state="$(subscription_detect_manual_restart_state 2>/dev/null || true)"
	if [ -n "$detected_restart_state" ]; then
		printf '%s\n' "$detected_restart_state"
		return 0
	fi
	subscription_existing_manual_restart_state
}

subscription_store_auto_update_state() {
	local enabled="$1"
	local interval="$2"
	local reason="${3:-}"
	local reset_next="${4:-1}"
	local manual_restart_required="${5:-}"
	local manual_restart_reason="${6:-}"
	local existing_interval="" existing_next_update=""
	local existing_manual_restart="" existing_manual_reason=""
	local manual_restart_state=""

	if [ "$#" -lt 5 ]; then
		manual_restart_state="$(subscription_existing_manual_restart_state)"
		manual_restart_required="${manual_restart_state%%	*}"
		manual_restart_reason="${manual_restart_state#*	}"
	fi

	if [ "$enabled" != "1" ]; then
		subscription_sync_auto_update_cron 0 || return 1
		if [ -n "$reason" ]; then
			subscription_write_auto_update_disabled_state "$reason" "$manual_restart_required" "$manual_restart_reason" || return 1
		else
			subscription_clear_auto_update_state
		fi
		return 0
	fi

	if [ -z "$interval" ] || [ "$interval" = "0" ]; then
		subscription_sync_auto_update_cron 0 || return 1
		if [ -n "$reason" ]; then
			subscription_write_auto_update_disabled_state "$reason" "$manual_restart_required" "$manual_restart_reason" || return 1
		else
			subscription_clear_auto_update_state
		fi
		return 0
	fi

	if [ "$reset_next" != "1" ]; then
		existing_interval="$(subscription_state_value interval 2>/dev/null || true)"
		existing_next_update="$(subscription_state_value next_update 2>/dev/null || true)"
		existing_manual_restart="$(subscription_state_value manual_restart_required 2>/dev/null || true)"
		existing_manual_reason="$(subscription_state_value manual_restart_reason 2>/dev/null || true)"
		if [ "$existing_interval" = "$interval" ] && [ -n "$existing_next_update" ] && is_uint "$existing_next_update"; then
			case "$manual_restart_required" in
			1 | true | yes) manual_restart_required=1 ;;
			*) manual_restart_required=0 ;;
			esac
			if [ "$existing_manual_restart" != "$manual_restart_required" ] || [ "$existing_manual_reason" != "$manual_restart_reason" ]; then
				subscription_write_auto_update_state "$interval" "scheduled" "$reason" "$manual_restart_required" "$manual_restart_reason" "$existing_next_update" || return 1
			fi
			subscription_sync_auto_update_cron 1
			return $?
		fi
	fi

	subscription_write_auto_update_state "$interval" "scheduled" "$reason" "$manual_restart_required" "$manual_restart_reason" || return 1
	subscription_sync_auto_update_cron 1
}

subscription_hot_reload_supported_for_config_json() {
	mihomo_hot_reload_supported "$1"
}

subscription_detect_manual_restart_state() {
	local current_json="" live_json=""

	command -v read_config_json >/dev/null 2>&1 || return 1
	command -v mihomo_api_live_state_read >/dev/null 2>&1 || return 1
	command -v config_requires_service_restart >/dev/null 2>&1 || return 1

	current_json="$(read_config_json 2>/dev/null || true)"
	live_json="$(mihomo_api_live_state_read 2>/dev/null || true)"
	[ -n "$current_json" ] && [ -n "$live_json" ] || return 1

	if config_requires_service_restart "$live_json" "$current_json"; then
		printf '%s\n' "1	Mihomo API/UI settings changed; manual restart is required"
	else
		printf '%s\n' "0	"
	fi
}

# Called without args from cron/start sync and with explicit manual-restart state
# from config auto-update apply paths.
# shellcheck disable=SC2120
subscription_refresh_auto_update_state() {
	local subscription_url="" interval_override="" update_interval="" header_interval="" interval=""
	local manual_restart_required="" manual_restart_reason="" manual_restart_state=""
	local explicit_manual_restart=0

	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	interval_override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	interval="$(subscription_effective_update_interval "$interval_override" "$update_interval" "$header_interval")"

	if [ "$#" -ge 1 ]; then
		explicit_manual_restart=1
		manual_restart_required="${1:-0}"
		manual_restart_reason="${2:-}"
	fi

	if [ -z "$subscription_url" ]; then
		if [ "$explicit_manual_restart" -eq 1 ]; then
			subscription_store_auto_update_state 0 "" "subscription URL is empty" 1 "$manual_restart_required" "$manual_restart_reason"
			return 0
		fi
		subscription_store_auto_update_state 0 "" "subscription URL is empty"
		return 0
	fi

	if [ -z "$interval" ] || [ "$interval" = "0" ]; then
		if [ "$explicit_manual_restart" -eq 1 ]; then
			subscription_store_auto_update_state 0 "" "auto-update interval is disabled" 1 "$manual_restart_required" "$manual_restart_reason"
			return 0
		fi
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled"
		return 0
	fi

	if [ "$explicit_manual_restart" -eq 0 ]; then
		manual_restart_state="$(subscription_detect_or_existing_manual_restart_state)"
		manual_restart_required="${manual_restart_state%%	*}"
		manual_restart_reason="${manual_restart_state#*	}"
	fi

	subscription_store_auto_update_state 1 "$interval" "" 0 "$manual_restart_required" "$manual_restart_reason"
}

# Emit stored subscription URL for LuCI.
subscription_url_json() {
	local subscription_url="" interval_override="" update_interval="" header_interval=""
	local auto_enabled="0" state_enabled="" last_update="" next_update="" reason="" effective_interval=""
	local manual_restart_required="" manual_restart_reason=""

	require_command jq || return 1
	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	interval_override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	effective_interval="$(subscription_effective_update_interval "$interval_override" "$update_interval" "$header_interval")"
	state_enabled="$(subscription_state_value enabled 2>/dev/null || true)"
	last_update="$(subscription_state_value last_update 2>/dev/null || true)"
	next_update="$(subscription_state_value next_update 2>/dev/null || true)"
	reason="$(subscription_state_value reason 2>/dev/null || true)"
	manual_restart_required="$(subscription_state_value manual_restart_required 2>/dev/null || true)"
	manual_restart_reason="$(subscription_state_value manual_restart_reason 2>/dev/null || true)"
	if [ -n "$subscription_url" ] && [ -n "$effective_interval" ] && [ "$effective_interval" != "0" ] && [ "$state_enabled" != "0" ]; then
		auto_enabled=1
	elif [ -z "$reason" ]; then
		if [ -z "$subscription_url" ]; then
			reason="subscription URL is empty"
		else
			reason="auto-update interval is disabled"
		fi
	fi

	jq -nc \
		--arg subscription_url "$subscription_url" \
		--arg interval_override "$interval_override" \
		--arg update_interval "$update_interval" \
		--arg header_interval "$header_interval" \
		--arg effective_interval "$effective_interval" \
		--arg auto_enabled "$auto_enabled" \
		--arg last_update "$last_update" \
		--arg next_update "$next_update" \
		--arg reason "$reason" \
		--arg manual_restart_required "$manual_restart_required" \
		--arg manual_restart_reason "$manual_restart_reason" \
		'{
			subscription_url: $subscription_url,
			subscription_interval_override: ($interval_override == "1"),
			subscription_update_interval: $update_interval,
			subscription_header_interval: $header_interval,
			subscription_effective_interval: $effective_interval,
			subscription_auto_update_enabled: ($auto_enabled == "1"),
			subscription_last_update: $last_update,
			subscription_next_update: $next_update,
			subscription_auto_update_reason: $reason,
			subscription_manual_restart_required: ($manual_restart_required == "1"),
			subscription_manual_restart_reason: $manual_restart_reason
		}'
}

# Persist subscription URL only when changed to avoid unnecessary UCI commits.
set_subscription_url() {
	local url="" current_url=""

	url="$(trim "${1:-}")"
	if [ -n "$url" ] && ! is_subscription_url "$url"; then
		err "Invalid subscription URL: use http:// or https:// without whitespace"
		return 1
	fi

	require_command uci || return 1
	current_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	[ "$url" != "$current_url" ] || return 0

	uci -q set "${PKG_CONFIG:-mihowrt}.settings=settings" || {
		err "Failed to prepare subscription UCI section"
		return 1
	}

	if [ -n "$url" ]; then
		uci -q set "${PKG_CONFIG:-mihowrt}.settings.subscription_url=$url" || {
			err "Failed to store subscription URL"
			return 1
		}
	else
		uci -q delete "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true
	fi

	uci -q commit "${PKG_CONFIG:-mihowrt}" || {
		err "Failed to commit subscription URL"
		return 1
	}
}

set_subscription_settings() {
	local url="" override="" interval="" header_interval="${4:-}" header_provided=0
	local current_url="" changed=0 rc=0
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	url="$(trim "${1:-}")"
	override="${2:-0}"
	interval="$(trim "${3:-}")"
	header_interval="$(trim "$header_interval")"
	[ "${4+x}" = x ] && header_provided=1 || header_provided=0

	if [ -n "$url" ] && ! is_subscription_url "$url"; then
		err "Invalid subscription URL: use http:// or https:// without whitespace"
		return 1
	fi
	case "$override" in
	1 | true | yes | on) override=1 ;;
	*) override=0 ;;
	esac
	if [ -n "$interval" ] && ! subscription_interval_valid "$interval"; then
		err "Invalid subscription update interval: $interval"
		return 1
	fi
	if [ -n "$header_interval" ] && ! subscription_interval_valid "$header_interval"; then
		header_interval=""
	fi

	require_command uci || return 1
	current_url="$(uci -q get "$pkg_config.settings.subscription_url" 2>/dev/null || true)"
	uci -q set "$pkg_config.settings=settings" || {
		err "Failed to prepare subscription UCI section"
		return 1
	}

	if subscription_set_option_if_changed subscription_url "$url"; then
		changed=1
	else
		rc=$?
		[ "$rc" -eq 1 ] || return 1
	fi
	if subscription_set_option_if_changed subscription_interval_override "$override"; then
		changed=1
	else
		rc=$?
		[ "$rc" -eq 1 ] || return 1
	fi
	if [ -n "$interval" ]; then
		interval="$(normalize_uint "$interval")"
		if subscription_set_option_if_changed subscription_update_interval "$interval"; then
			changed=1
		else
			rc=$?
			[ "$rc" -eq 1 ] || return 1
		fi
	else
		if subscription_delete_option_if_present subscription_update_interval; then
			changed=1
		else
			rc=$?
			[ "$rc" -eq 1 ] || return 1
		fi
	fi
	if [ "$header_provided" -eq 1 ] && [ -n "$header_interval" ]; then
		header_interval="$(normalize_uint "$header_interval")"
		if subscription_set_option_if_changed subscription_header_interval "$header_interval"; then
			changed=1
		else
			rc=$?
			[ "$rc" -eq 1 ] || return 1
		fi
	elif [ "$header_provided" -eq 1 ]; then
		if subscription_delete_option_if_present subscription_header_interval; then
			changed=1
		else
			rc=$?
			[ "$rc" -eq 1 ] || return 1
		fi
	elif [ "$url" != "$current_url" ]; then
		if subscription_delete_option_if_present subscription_header_interval; then
			changed=1
		else
			rc=$?
			[ "$rc" -eq 1 ] || return 1
		fi
	fi

	subscription_commit_if_changed "$changed" || return 1

	# shellcheck disable=SC2119
	subscription_refresh_auto_update_state
}

# Size limit for subscription config downloads.
subscription_max_bytes() {
	bounded_positive_uint_or_default "${SUBSCRIPTION_MAX_BYTES:-}" 1048576 2147483646
}

# Fetch subscription YAML into stdout; caller decides whether to save/apply it.
fetch_subscription_config() {
	local url="" max_bytes=""
	local timeout="${SUBSCRIPTION_FETCH_TIMEOUT:-30}"

	url="$(trim "${1:-}")"
	if ! is_subscription_url "$url"; then
		err "Invalid subscription URL: use http:// or https:// without whitespace"
		return 1
	fi

	max_bytes="$(subscription_max_bytes)"
	fetch_http_body_limited "$url" "$max_bytes" "$timeout" "Subscription config" 1
}

fetch_subscription_config_to_file() {
	local url="" output="${2:-}" max_bytes=""
	local timeout="${SUBSCRIPTION_FETCH_TIMEOUT:-30}"

	url="$(trim "${1:-}")"
	if ! is_subscription_url "$url"; then
		fetch_http_set_error "invalid_url" "Invalid subscription URL: use http:// or https:// without whitespace"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	fi

	max_bytes="$(subscription_max_bytes)"
	fetch_http_body_limited_to_file "$url" "$max_bytes" "$timeout" "Subscription config" "$output" 1
}

fetch_subscription_json() {
	local url="" body_file="" rc=0
	local config_json="" hot_reload_supported=0 hot_reload_reason=""

	require_command jq || return 1
	require_command mktemp || return 1

	url="$(trim "${1:-}")"
	body_file="$(mktemp /tmp/mihowrt-subscription.XXXXXX)" || {
		err "Failed to allocate temporary subscription path"
		return 1
	}

	if fetch_subscription_config_to_file "$url" "$body_file"; then
		patch_config_api_defaults "$body_file" "$(read_config_json 2>/dev/null || true)" >/dev/null 2>&1 || true
		config_json="$(read_config_json_for_path "$body_file" 2>/dev/null || true)"
		if [ -n "$config_json" ] && mihomo_hot_reload_supported "$config_json"; then
			hot_reload_supported=1
			hot_reload_reason=""
		else
			hot_reload_supported=0
			hot_reload_reason="${MIHOMO_API_REASON:-Mihomo API hot reload is unavailable in subscription config}"
		fi
		jq -Rs --arg profile_update_interval "${FETCH_PROFILE_UPDATE_INTERVAL:-}" \
			--arg hot_reload_supported "$hot_reload_supported" \
			--arg hot_reload_reason "$hot_reload_reason" \
			'{
				ok: true,
				content: .,
				profile_update_interval: $profile_update_interval,
				hot_reload_supported: ($hot_reload_supported == "1"),
				hot_reload_reason: $hot_reload_reason
			}' <"$body_file"
		rc=$?
		rm -f "$body_file"
		return "$rc"
	fi

	rc=$?
	rm -f "$body_file"
	jq -nc \
		--arg kind "${FETCH_HTTP_ERROR_KIND:-fetch_failed}" \
		--arg message "${FETCH_HTTP_ERROR_MESSAGE:-Failed to fetch subscription config}" \
		--arg http_code "${FETCH_HTTP_STATUS:-}" \
		'{
			ok: false,
			error: {
				kind: $kind,
				message: $message,
				http_code: (if $http_code == "" then null else ($http_code | tonumber? // $http_code) end)
			}
		}'
	return 0
}

subscription_due_for_update() {
	local subscription_url="" interval="" next_update="" now=""

	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	interval="$(subscription_configured_update_interval)" || {
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled" || true
		return 1
	}
	if [ -z "$subscription_url" ] || [ -z "$interval" ] || [ "$interval" = "0" ]; then
		if [ -z "$subscription_url" ]; then
			subscription_store_auto_update_state 0 "" "subscription URL is empty" || true
		else
			subscription_store_auto_update_state 0 "" "auto-update interval is disabled" || true
		fi
		return 1
	fi

	next_update="$(subscription_state_value next_update 2>/dev/null || true)"
	if [ -z "$next_update" ]; then
		subscription_write_auto_update_state "$interval" "scheduled" "" || true
		return 1
	fi
	now="$(subscription_now_epoch)"
	[ -n "$next_update" ] && is_uint "$next_update" || return 0
	[ "$now" -ge "$next_update" ]
}

subscription_mark_update_success() {
	local interval=""
	local manual_restart_required="${1:-0}" manual_restart_reason="${2:-}"

	interval="$(subscription_configured_update_interval)" || {
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled" 1 "$manual_restart_required" "$manual_restart_reason"
		return 0
	}
	if [ -z "$interval" ] || [ "$interval" = "0" ]; then
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled" 1 "$manual_restart_required" "$manual_restart_reason"
		return 0
	fi

	subscription_write_auto_update_state "$interval" "success" "" "$manual_restart_required" "$manual_restart_reason" || return 1
}

subscription_mark_update_failure() {
	local interval="" reason="${1:-subscription auto-update failed}"
	local manual_restart_required="" manual_restart_reason="" detected_restart_state=""

	interval="$(subscription_configured_update_interval)" || return 0
	[ -n "$interval" ] && [ "$interval" != "0" ] || return 0

	detected_restart_state="$(subscription_detect_manual_restart_state 2>/dev/null || true)"
	if [ -n "$detected_restart_state" ]; then
		manual_restart_required="${detected_restart_state%%	*}"
		manual_restart_reason="${detected_restart_state#*	}"
	else
		manual_restart_required="$(subscription_state_value manual_restart_required 2>/dev/null || true)"
		manual_restart_reason="$(subscription_state_value manual_restart_reason 2>/dev/null || true)"
	fi

	subscription_write_auto_update_state "$interval" "failure" "$reason" "$manual_restart_required" "$manual_restart_reason"
}

update_subscription_config() {
	local url="" candidate="" result="" action="" header_interval="" override="" update_interval=""
	local interval="" rc=0 restart_required="" restart_reason=""
	local settings_error=""

	require_command jq || return 1
	require_command mktemp || return 1
	require_command uci || return 1

	url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	if [ -z "$url" ]; then
		subscription_store_auto_update_state 0 "" "subscription URL is empty" || true
		jq -nc '{updated:false, reason:"subscription URL is empty"}'
		return 0
	fi

	candidate="$(mktemp /tmp/mihowrt-subscription-config.XXXXXX)" || {
		err "Failed to allocate temporary subscription config path"
		return 1
	}

	if fetch_subscription_config_to_file "$url" "$candidate"; then
		:
	else
		rc=$?
		rm -f "$candidate"
		jq -nc \
			--arg kind "${FETCH_HTTP_ERROR_KIND:-fetch_failed}" \
			--arg message "${FETCH_HTTP_ERROR_MESSAGE:-Failed to fetch subscription config}" \
			--arg http_code "${FETCH_HTTP_STATUS:-}" \
			'{updated:false, error:{kind:$kind,message:$message,http_code:(if $http_code == "" then null else ($http_code | tonumber? // $http_code) end)}}'
		return "$rc"
	fi

	header_interval="${FETCH_PROFILE_UPDATE_INTERVAL:-}"
	result="$(apply_config_runtime_auto_update "$candidate")" || return $?
	action="$(printf '%s\n' "$result" | jq -r '.action // ""' 2>/dev/null || true)"
	restart_required="$(printf '%s\n' "$result" | jq -r 'if .restart_required then "1" else "0" end' 2>/dev/null || printf '0')"
	restart_reason="$(printf '%s\n' "$result" | jq -r '.reason // ""' 2>/dev/null || true)"
	case "$action" in
	saved | hot_reloaded | policy_reloaded) ;;
	auto_update_disabled)
		printf '%s\n' "$result"
		return 1
		;;
	*)
		printf '%s\n' "$result"
		return 1
		;;
	esac

	if [ -z "$header_interval" ] || subscription_interval_valid "$header_interval"; then
		settings_error="$(
			set_subscription_settings "$url" "$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)" "$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)" "$header_interval" 2>&1 >/dev/null
		)" || {
			rc=$?
			err "${settings_error:-Failed to persist subscription update interval}"
			jq -nc \
				--arg message "${settings_error:-Failed to persist subscription update interval}" \
				'{updated:false,error:{kind:"uci_failed",message:$message,http_code:null}}'
			return "$rc"
		}
	fi

	override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	interval="$(subscription_effective_update_interval "$override" "$update_interval" "$header_interval")"
	if [ -n "$interval" ] && [ "$interval" != "0" ]; then
		subscription_mark_update_success "$restart_required" "$restart_reason" || true
	else
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled" 1 "$restart_required" "$restart_reason" || true
	fi
	printf '%s\n' "$result"
}

auto_update_subscription_config() {
	local output="" rc=0

	if ! subscription_due_for_update; then
		printf 'updated=0\n'
		return 0
	fi

	output="$(update_subscription_config)" || rc=$?
	printf '%s\n' "$output"
	if [ "$rc" -ne 0 ]; then
		if [ "$(printf '%s\n' "$output" | jq -r '.action // ""' 2>/dev/null || true)" != "auto_update_disabled" ]; then
			subscription_mark_update_failure "subscription auto-update failed" || true
		fi
		return "$rc"
	fi
	return 0
}
