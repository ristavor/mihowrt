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

fetch_http_reset_error() {
	FETCH_HTTP_STATUS=""
	FETCH_HTTP_ERROR_KIND=""
	FETCH_HTTP_ERROR_MESSAGE=""
}

fetch_http_set_error() {
	FETCH_HTTP_ERROR_KIND="$1"
	FETCH_HTTP_ERROR_MESSAGE="$2"
}

fetch_last_http_status() {
	local stderr_file="$1"

	awk '/HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ { code = $2 } END { if (code != "") print code }' "$stderr_file" 2>/dev/null
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

# Emit stored subscription URL for LuCI.
subscription_url_json() {
	local subscription_url=""

	require_command jq || return 1
	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"

	jq -nc --arg subscription_url "$subscription_url" '{ subscription_url: $subscription_url }'
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

	require_command jq || return 1
	require_command mktemp || return 1

	url="$(trim "${1:-}")"
	body_file="$(mktemp /tmp/mihowrt-subscription.XXXXXX)" || {
		err "Failed to allocate temporary subscription path"
		return 1
	}

	if fetch_subscription_config_to_file "$url" "$body_file"; then
		jq -Rs '{ok: true, content: .}' <"$body_file"
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
