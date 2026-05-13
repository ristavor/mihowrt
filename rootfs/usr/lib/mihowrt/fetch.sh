#!/bin/ash

# User-Agent for all project HTTP fetches.
http_fetch_user_agent() {
	printf 'mihowrt/%s' "${PKG_VERSION:-unknown}"
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

	fetch_http_reset_error
	url="$(trim "${1:-}")"
	max_bytes="${2:-}"
	if ! is_http_fetch_url "$url"; then
		fetch_http_set_error "invalid_url" "Invalid $label URL: use http:// or https:// without whitespace"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	fi

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
	wget -S -T "$timeout" -U "$(http_fetch_user_agent)" -O - "$url" >"$fifo" 2>"$stderr_file" &
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
		fetch_http_set_error "io_error" "Failed to store $label from $url"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		rm -f "$stderr_file"
		return 1
	fi

	if [ "$wget_rc" -ne 0 ]; then
		if [ -n "$FETCH_HTTP_STATUS" ]; then
			fetch_http_set_error "http_error" "Failed to fetch $label from $url: HTTP $FETCH_HTTP_STATUS"
		elif fetch_stderr_looks_timeout "$stderr_file"; then
			fetch_http_set_error "timeout" "Failed to fetch $label from $url: timeout"
		else
			fetch_http_set_error "wget_failed" "Failed to fetch $label from $url"
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

	url="$(trim "${1:-}")"
	max_bytes="${2:-}"
	output="$(mktemp /tmp/mihowrt-fetch.XXXXXX)" || {
		fetch_http_set_error "temp_error" "Failed to allocate temporary $label path"
		err "$FETCH_HTTP_ERROR_MESSAGE"
		return 1
	}

	fetch_http_body_limited_to_file "$url" "$max_bytes" "$timeout" "$label" "$output" || {
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
	local cron_file="" marker="" tmp_file="" changed=0

	cron_file="$(subscription_cron_file)"
	marker="$(subscription_cron_marker)"
	tmp_file="${cron_file}.mihowrt.$$"
	ensure_dir "$(dirname "$cron_file")" || return 1

	if [ -r "$cron_file" ]; then
		grep -vF "$marker" "$cron_file" >"$tmp_file" || true
	else
		: >"$tmp_file"
	fi

	if [ "$enabled" = "1" ]; then
		printf '17 * * * * /usr/bin/mihowrt auto-update-subscription >/dev/null 2>&1 %s\n' "$marker" >>"$tmp_file"
	fi

	if [ -f "$cron_file" ] && cmp -s "$tmp_file" "$cron_file"; then
		rm -f "$tmp_file"
		return 0
	fi

	mv -f "$tmp_file" "$cron_file" || {
		rm -f "$tmp_file"
		return 1
	}
	changed=1

	[ "$changed" -eq 1 ] && subscription_restart_cron
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

subscription_store_auto_update_state() {
	local enabled="$1"
	local interval="$2"
	local reason="${3:-}"
	local reset_next="${4:-1}"
	local next_update="" changed=0 rc=0
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	require_command uci || return 1
	uci -q set "$pkg_config.settings=settings" || return 1

	subscription_set_option_if_changed subscription_auto_update_enabled "$enabled"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	subscription_set_option_if_changed subscription_auto_update_reason "$reason"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac

	if [ "$enabled" = "1" ]; then
		if [ "$reset_next" = "1" ]; then
			next_update="$(subscription_next_update_epoch "$interval")"
			subscription_set_option_if_changed subscription_next_update "$next_update"
			rc=$?
			case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
		fi
	else
		subscription_delete_option_if_present subscription_next_update
		rc=$?
		case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	fi

	subscription_commit_if_changed "$changed" || return 1
	subscription_sync_auto_update_cron "$enabled"
}

subscription_hot_reload_supported_for_config_json() {
	mihomo_hot_reload_supported "$1"
}

subscription_refresh_auto_update_state() {
	local config_json="$1"
	local subscription_url="" interval_override="" update_interval="" header_interval="" interval=""
	local reason=""

	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	interval_override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	interval="$(subscription_effective_update_interval "$interval_override" "$update_interval" "$header_interval")"

	if [ -z "$subscription_url" ]; then
		subscription_store_auto_update_state 0 "" "subscription URL is empty"
		return 0
	fi

	if [ -z "$interval" ] || [ "$interval" = "0" ]; then
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled"
		return 0
	fi

	if ! subscription_hot_reload_supported_for_config_json "$config_json"; then
		reason="${MIHOMO_API_REASON:-Mihomo API hot reload is unavailable}"
		subscription_store_auto_update_state 0 "$interval" "$reason"
		return 0
	fi

	subscription_store_auto_update_state 1 "$interval" ""
}

# Emit stored subscription URL for LuCI.
subscription_url_json() {
	local subscription_url="" interval_override="" update_interval="" header_interval=""
	local auto_enabled="" last_update="" next_update="" reason="" effective_interval=""

	require_command jq || return 1
	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"
	interval_override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	auto_enabled="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_auto_update_enabled" 2>/dev/null || true)"
	last_update="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_last_update" 2>/dev/null || true)"
	next_update="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_next_update" 2>/dev/null || true)"
	reason="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_auto_update_reason" 2>/dev/null || true)"
	effective_interval="$(subscription_effective_update_interval "$interval_override" "$update_interval" "$header_interval")"

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
		'{
			subscription_url: $subscription_url,
			subscription_interval_override: ($interval_override == "1"),
			subscription_update_interval: $update_interval,
			subscription_header_interval: $header_interval,
			subscription_effective_interval: $effective_interval,
			subscription_auto_update_enabled: ($auto_enabled == "1"),
			subscription_last_update: $last_update,
			subscription_next_update: $next_update,
			subscription_auto_update_reason: $reason
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
	local loaded_hot_reload_supported="${5:-1}"
	local current_config_json="" changed=0 rc=0
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
	uci -q set "$pkg_config.settings=settings" || {
		err "Failed to prepare subscription UCI section"
		return 1
	}

	subscription_set_option_if_changed subscription_url "$url"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	subscription_set_option_if_changed subscription_interval_override "$override"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	if [ -n "$interval" ]; then
		interval="$(normalize_uint "$interval")"
		subscription_set_option_if_changed subscription_update_interval "$interval"
		rc=$?
		case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	else
		subscription_delete_option_if_present subscription_update_interval
		rc=$?
		case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	fi
	if [ "$header_provided" -eq 1 ] && [ -n "$header_interval" ]; then
		header_interval="$(normalize_uint "$header_interval")"
		subscription_set_option_if_changed subscription_header_interval "$header_interval"
		rc=$?
		case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	elif [ "$header_provided" -eq 1 ]; then
		subscription_delete_option_if_present subscription_header_interval
		rc=$?
		case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	fi

	subscription_commit_if_changed "$changed" || return 1

	if [ "$loaded_hot_reload_supported" = "0" ]; then
		subscription_store_auto_update_state 0 "" "loaded subscription config has no safe Mihomo API for hot reload"
		return 0
	fi

	current_config_json="$(read_config_json 2>/dev/null || true)"
	if [ -n "$current_config_json" ]; then
		subscription_refresh_auto_update_state "$current_config_json"
	else
		subscription_store_auto_update_state 0 "" "active config metadata is unavailable"
	fi
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
	fetch_http_body_limited "$url" "$max_bytes" "$timeout" "Subscription config"
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
	fetch_http_body_limited_to_file "$url" "$max_bytes" "$timeout" "Subscription config" "$output"
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
	local enabled="" next_update="" now=""

	require_command uci || return 1
	enabled="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_auto_update_enabled" 2>/dev/null || true)"
	[ "$enabled" = "1" ] || return 1
	next_update="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_next_update" 2>/dev/null || true)"
	now="$(subscription_now_epoch)"
	[ -n "$next_update" ] && is_uint "$next_update" || return 0
	[ "$now" -ge "$next_update" ]
}

subscription_mark_update_success() {
	local interval="" next_update="" now="" changed=0 rc=0
	local override="" update_interval="" header_interval=""
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	require_command uci || return 1
	override="$(uci -q get "$pkg_config.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "$pkg_config.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "$pkg_config.settings.subscription_header_interval" 2>/dev/null || true)"
	interval="$(subscription_effective_update_interval "$override" "$update_interval" "$header_interval")"
	if [ -z "$interval" ] || [ "$interval" = "0" ]; then
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled"
		return 0
	fi

	now="$(subscription_now_epoch)"
	next_update="$(subscription_next_update_epoch "$interval")"
	uci -q set "$pkg_config.settings=settings" || return 1
	subscription_set_option_if_changed subscription_last_update "$now"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	subscription_set_option_if_changed subscription_next_update "$next_update"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	subscription_set_option_if_changed subscription_auto_update_enabled "1"
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	subscription_set_option_if_changed subscription_auto_update_reason ""
	rc=$?
	case "$rc" in 0) changed=1 ;; 2) return 1 ;; esac
	subscription_commit_if_changed "$changed" || return 1
	subscription_sync_auto_update_cron 1
}

update_subscription_config() {
	local url="" candidate="" result="" action="" header_interval="" override="" update_interval=""
	local interval="" rc=0

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

	if ! fetch_subscription_config_to_file "$url" "$candidate"; then
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
	if [ -z "$header_interval" ] || subscription_interval_valid "$header_interval"; then
		set_subscription_settings "$url" "$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)" "$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)" "$header_interval" >/dev/null 2>&1 || true
	fi

	result="$(apply_config_runtime_auto_update "$candidate")" || return $?
	action="$(printf '%s\n' "$result" | jq -r '.action // ""' 2>/dev/null || true)"
	case "$action" in
	saved | hot_reloaded | policy_reloaded)
		;;
	*)
		printf '%s\n' "$result"
		return 0
		;;
	esac

	override="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval_override" 2>/dev/null || true)"
	update_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_update_interval" 2>/dev/null || true)"
	header_interval="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_header_interval" 2>/dev/null || true)"
	interval="$(subscription_effective_update_interval "$override" "$update_interval" "$header_interval")"
	if [ -n "$interval" ] && [ "$interval" != "0" ]; then
		subscription_mark_update_success || true
	else
		subscription_store_auto_update_state 0 "" "auto-update interval is disabled" || true
	fi
	printf '%s\n' "$result"
}

auto_update_subscription_config() {
	if ! subscription_due_for_update; then
		printf 'updated=0\n'
		return 0
	fi

	update_subscription_config
}
