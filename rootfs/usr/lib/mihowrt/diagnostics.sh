#!/bin/ash

# Return recent MihoWRT log lines as JSON for LuCI diagnostics. The limit is
# clamped so diagnostics cannot stream unbounded logread output through rpcd.
logs_json() {
	local limit="${1:-200}"
	local logread_cmd="" raw_logs="" lines="" read_error=""

	require_command jq || return 1

	limit="$(positive_uint_or_default "$limit" 200)"
	if ! uint_lte "$limit" 1000; then
		limit=1000
	fi

	logread_cmd="$(command -v logread 2>/dev/null || true)"
	if [ -z "$logread_cmd" ]; then
		jq -nc \
			--argjson limit "$limit" \
			'{ available: false, limit: $limit, lines: [] }'
		return 0
	fi

	if raw_logs="$("$logread_cmd" 2>&1)"; then
		:
	else
		read_error="$(printf '%s' "$raw_logs" | mihowrt_single_line_value)"
		[ -n "$read_error" ] || read_error="logread failed"
		jq -nc \
			--argjson limit "$limit" \
			--arg error "$read_error" \
			'{ available: false, limit: $limit, lines: [], errors: [$error] }'
		return 0
	fi

	# procd, logger and different Mihomo builds do not use one stable tag. Match
	# known service/core names anywhere in the syslog record instead of requiring
	# the synthetic "mihowrt:" shape used by the old test fixture.
	lines="$(printf '%s\n' "$raw_logs" | awk '
		{
			line = tolower($0)
			if (line ~ /mihowrt/ || line ~ /mihomo/ || line ~ /(^|[[:space:]])clash(\[[^]]+\])?:/)
				print
		}
	' | tail -n "$limit")"

	jq -nc \
		--argjson limit "$limit" \
		--arg lines "$lines" \
		'{
			available: true,
			limit: $limit,
			lines: ($lines | split("\n") | map(select(length > 0))),
			errors: []
		}'
}
