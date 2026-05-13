#!/bin/ash

http_fetch_user_agent() {
	printf 'mihowrt/%s' "${PKG_VERSION:-unknown}"
}

is_http_fetch_url() {
	local url="$1"

	case "$url" in
		''|*[[:space:]]*)
			return 1
			;;
		http:///*|https:///*)
			return 1
			;;
		http://?*|https://?*)
			return 0
			;;
	esac

	return 1
}

fetch_http_body_limited() {
	local url="" output="" fifo="" size="" rc=0 max_bytes="" read_limit=0
	local reader_pid="" wget_pid="" reader_rc=0 wget_rc=0
	local timeout="${3:-30}"
	local label="${4:-download}"

	url="$(trim "${1:-}")"
	max_bytes="${2:-}"
	if ! is_http_fetch_url "$url"; then
		err "Invalid $label URL: use http:// or https:// without whitespace"
		return 1
	fi

	if ! is_uint "$max_bytes" || [ "$max_bytes" -le 0 ]; then
		err "Invalid $label size limit: $max_bytes"
		return 1
	fi

	require_command wget || return 1
	require_command mktemp || return 1
	require_command mkfifo || return 1
	require_command head || return 1

	output="$(mktemp /tmp/mihowrt-fetch.XXXXXX)" || {
		err "Failed to allocate temporary $label path"
		return 1
	}

	fifo="$(mktemp /tmp/mihowrt-fetch.pipe.XXXXXX)" || {
		err "Failed to allocate temporary $label pipe path"
		rm -f "$output"
		return 1
	}
	rm -f "$fifo"
	mkfifo "$fifo" || {
		err "Failed to create temporary $label pipe"
		rm -f "$output" "$fifo"
		return 1
	}

	read_limit=$((max_bytes + 1))
	head -c "$read_limit" < "$fifo" > "$output" &
	reader_pid=$!
	wget -q -T "$timeout" -U "$(http_fetch_user_agent)" -O - "$url" > "$fifo" &
	wget_pid=$!

	wait "$wget_pid" || wget_rc=$?
	wait "$reader_pid" || reader_rc=$?
	rm -f "$fifo"

	size="$(wc -c < "$output" 2>/dev/null | tr -d '[:space:]')"
	if ! is_uint "$size"; then
		err "Failed to measure $label size"
		rm -f "$output"
		return 1
	fi

	if [ "$size" -gt "$max_bytes" ]; then
		err "$label is too large: $size bytes, limit $max_bytes"
		rm -f "$output"
		return 1
	fi

	if [ "$reader_rc" -ne 0 ]; then
		err "Failed to store $label from $url"
		rm -f "$output"
		return 1
	fi

	if [ "$wget_rc" -ne 0 ]; then
		err "Failed to fetch $label from $url"
		rm -f "$output"
		return 1
	fi

	if [ ! -s "$output" ]; then
		err "$label returned empty content"
		rm -f "$output"
		return 1
	fi

	cat "$output"
	rc=$?
	rm -f "$output"
	return "$rc"
}

subscription_user_agent() {
	http_fetch_user_agent
}

is_subscription_url() {
	is_http_fetch_url "$1"
}

subscription_url_json() {
	local subscription_url=""

	require_command jq || return 1
	require_command uci || return 1
	subscription_url="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_url" 2>/dev/null || true)"

	jq -nc --arg subscription_url "$subscription_url" '{ subscription_url: $subscription_url }'
}

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

subscription_max_bytes() {
	local max_bytes="${SUBSCRIPTION_MAX_BYTES:-1048576}"

	if ! is_uint "$max_bytes" || [ "$max_bytes" -le 0 ]; then
		max_bytes=1048576
	fi

	printf '%s' "$max_bytes"
}

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
