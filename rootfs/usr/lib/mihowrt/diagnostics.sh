#!/bin/ash

logs_json() {
	local limit="${1:-200}"
	local logread_cmd="" lines=""

	require_command jq || return 1

	if ! is_uint "$limit" || [ "$limit" -le 0 ]; then
		limit=200
	elif [ "$limit" -gt 1000 ]; then
		limit=1000
	fi

	logread_cmd="$(command -v logread 2>/dev/null || true)"
	if [ -z "$logread_cmd" ]; then
		jq -nc \
			--argjson limit "$limit" \
			'{ available: false, limit: $limit, lines: [] }'
		return 0
	fi

	lines="$("$logread_cmd" 2>/dev/null | grep -E '(^|[[:space:]])mihowrt(\[[0-9]+\])?:' | tail -n "$limit" || true)"

	jq -nc \
		--argjson limit "$limit" \
		--arg lines "$lines" \
		'{
			available: true,
			limit: $limit,
			lines: ($lines | split("\n") | map(select(length > 0)))
		}'
}
