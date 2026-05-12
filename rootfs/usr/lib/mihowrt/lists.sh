#!/bin/ash

ensure_policy_files() {
	ensure_dir "$LIST_DIR"
}

policy_remote_list_max_bytes() {
	local max_bytes="${POLICY_REMOTE_LIST_MAX_BYTES:-262144}"

	if ! is_uint "$max_bytes" || [ "$max_bytes" -le 0 ]; then
		max_bytes=262144
	fi

	printf '%s' "$max_bytes"
}

policy_effective_list_max_bytes() {
	local max_bytes="${POLICY_EFFECTIVE_LIST_MAX_BYTES:-1048576}"

	if ! is_uint "$max_bytes" || [ "$max_bytes" -le 0 ]; then
		max_bytes=1048576
	fi

	printf '%s' "$max_bytes"
}

policy_remote_list_fetch_timeout() {
	local timeout="${POLICY_REMOTE_LIST_FETCH_TIMEOUT:-15}"

	if ! is_uint "$timeout" || [ "$timeout" -le 0 ]; then
		timeout=15
	fi

	printf '%s' "$timeout"
}

is_policy_remote_list_url() {
	is_http_fetch_url "$1"
}

policy_effective_list_cleanup() {
	local path

	for path in "$@"; do
		rm -f "$path"
	done
}

policy_effective_list_append_entry() {
	local output="$1"
	local entry="$2"
	local max_bytes="$3"
	local next_bytes=0

	next_bytes=$((POLICY_EFFECTIVE_LIST_BYTES + ${#entry} + 1))
	if [ "$next_bytes" -gt "$max_bytes" ]; then
		err "Effective policy list is too large: $next_bytes bytes, limit $max_bytes"
		return 1
	fi

	printf '%s\n' "$entry" >> "$output" || return 1
	POLICY_EFFECTIVE_LIST_BYTES="$next_bytes"
}

policy_merge_list_file() {
	local source="$1"
	local output="$2"
	local label="$3"
	local allow_urls="$4"
	local max_bytes="$5"
	local line="" entry="" remote_file=""
	local remote_max_bytes="" remote_timeout=""

	[ -f "$source" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim "$line")"
		case "$line" in
			''|'#'*) continue ;;
		esac

		if is_policy_remote_list_url "$line"; then
			if [ "$allow_urls" -ne 1 ]; then
				warn "Skipping nested remote policy list URL '$line' in $label"
				continue
			fi

			remote_file="$(mktemp "$PKG_TMP_DIR/policy-remote.XXXXXX")" || {
				err "Failed to allocate temporary remote policy list path"
				return 1
			}
			remote_max_bytes="$(policy_remote_list_max_bytes)"
			remote_timeout="$(policy_remote_list_fetch_timeout)"
			if ! fetch_http_body_limited "$line" "$remote_max_bytes" "$remote_timeout" "Remote policy list" > "$remote_file"; then
				rm -f "$remote_file"
				return 1
			fi
			policy_merge_list_file "$remote_file" "$output" "$line" 0 "$max_bytes" || {
				rm -f "$remote_file"
				return 1
			}
			rm -f "$remote_file"
			continue
		fi

		if ! is_policy_entry "$line"; then
			warn "Skipping invalid policy entry '$line' in $label"
			continue
		fi

		entry="$(policy_entry_normalized "$line")" || return 1
		policy_effective_list_append_entry "$output" "$entry" "$max_bytes" || return 1
	done < "$source"
}

policy_resolve_list_file() {
	local source="$1"
	local output="$2"
	local label="$3"
	local raw_output=""
	local max_bytes=""

	require_command mktemp || return 1
	require_command awk || return 1

	raw_output="$(mktemp "$PKG_TMP_DIR/policy-effective.raw.XXXXXX")" || {
		err "Failed to allocate temporary effective policy list path"
		return 1
	}
	: > "$raw_output" || {
		rm -f "$raw_output"
		return 1
	}

	POLICY_EFFECTIVE_LIST_BYTES=0
	max_bytes="$(policy_effective_list_max_bytes)"
	policy_merge_list_file "$source" "$raw_output" "$label" 1 "$max_bytes" || {
		rm -f "$raw_output"
		return 1
	}

	awk '!seen[$0]++' "$raw_output" > "$output" || {
		rm -f "$raw_output"
		return 1
	}
	rm -f "$raw_output"
}

policy_prepare_effective_list_path() {
	local path=""

	path="$(mktemp "$PKG_TMP_DIR/policy-effective.XXXXXX")" || {
		err "Failed to allocate temporary effective policy list path"
		return 1
	}
	: > "$path" || {
		rm -f "$path"
		return 1
	}
	printf '%s' "$path"
}

policy_clear_runtime_list_overrides() {
	if [ -n "${POLICY_EFFECTIVE_LIST_FILES:-}" ]; then
		# shellcheck disable=SC2086
		policy_effective_list_cleanup $POLICY_EFFECTIVE_LIST_FILES
	fi

	if [ "${POLICY_PREV_DST_LIST_FILE_SET:-0}" -eq 1 ]; then
		POLICY_DST_LIST_FILE="$POLICY_PREV_DST_LIST_FILE"
	else
		unset POLICY_DST_LIST_FILE
	fi

	if [ "${POLICY_PREV_SRC_LIST_FILE_SET:-0}" -eq 1 ]; then
		POLICY_SRC_LIST_FILE="$POLICY_PREV_SRC_LIST_FILE"
	else
		unset POLICY_SRC_LIST_FILE
	fi

	if [ "${POLICY_PREV_DIRECT_LIST_FILE_SET:-0}" -eq 1 ]; then
		POLICY_DIRECT_DST_LIST_FILE="$POLICY_PREV_DIRECT_LIST_FILE"
	else
		unset POLICY_DIRECT_DST_LIST_FILE
	fi

	unset POLICY_EFFECTIVE_LIST_FILES
	unset POLICY_PREV_DST_LIST_FILE POLICY_PREV_SRC_LIST_FILE POLICY_PREV_DIRECT_LIST_FILE
	unset POLICY_PREV_DST_LIST_FILE_SET POLICY_PREV_SRC_LIST_FILE_SET POLICY_PREV_DIRECT_LIST_FILE_SET
	unset POLICY_EFFECTIVE_LIST_BYTES
}

policy_resolve_runtime_lists() {
	local dst_effective="" src_effective="" direct_effective=""
	local mode="${POLICY_MODE:-direct-first}"

	ensure_dir "$PKG_TMP_DIR"
	[ -z "${POLICY_EFFECTIVE_LIST_FILES:-}" ] || policy_clear_runtime_list_overrides

	POLICY_PREV_DST_LIST_FILE_SET=0
	POLICY_PREV_SRC_LIST_FILE_SET=0
	POLICY_PREV_DIRECT_LIST_FILE_SET=0
	[ "${POLICY_DST_LIST_FILE+x}" = x ] && {
		POLICY_PREV_DST_LIST_FILE_SET=1
		POLICY_PREV_DST_LIST_FILE="$POLICY_DST_LIST_FILE"
	}
	[ "${POLICY_SRC_LIST_FILE+x}" = x ] && {
		POLICY_PREV_SRC_LIST_FILE_SET=1
		POLICY_PREV_SRC_LIST_FILE="$POLICY_SRC_LIST_FILE"
	}
	[ "${POLICY_DIRECT_DST_LIST_FILE+x}" = x ] && {
		POLICY_PREV_DIRECT_LIST_FILE_SET=1
		POLICY_PREV_DIRECT_LIST_FILE="$POLICY_DIRECT_DST_LIST_FILE"
	}

	case "$mode" in
		direct-first)
			dst_effective="$(policy_prepare_effective_list_path)" || {
				policy_clear_runtime_list_overrides
				return 1
			}
			src_effective="$(policy_prepare_effective_list_path)" || {
				rm -f "$dst_effective"
				policy_clear_runtime_list_overrides
				return 1
			}
			POLICY_EFFECTIVE_LIST_FILES="$dst_effective $src_effective"
			policy_resolve_list_file "${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}" "$dst_effective" "proxy destination list" || {
				policy_clear_runtime_list_overrides
				return 1
			}
			policy_resolve_list_file "${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}" "$src_effective" "proxy source list" || {
				policy_clear_runtime_list_overrides
				return 1
			}
			POLICY_DST_LIST_FILE="$dst_effective"
			POLICY_SRC_LIST_FILE="$src_effective"
			;;
		proxy-first)
			direct_effective="$(policy_prepare_effective_list_path)" || {
				policy_clear_runtime_list_overrides
				return 1
			}
			POLICY_EFFECTIVE_LIST_FILES="$direct_effective"
			policy_resolve_list_file "${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}" "$direct_effective" "direct destination list" || {
				policy_clear_runtime_list_overrides
				return 1
			}
			POLICY_DIRECT_DST_LIST_FILE="$direct_effective"
			;;
		*)
			err "Invalid policy mode: $mode"
			policy_clear_runtime_list_overrides
			return 1
			;;
	esac
}

count_valid_list_entries() {
	local file="$1"
	local count=0
	local line

	[ -f "$file" ] || {
		echo 0
		return 0
	}

	while IFS= read -r line; do
		line="$(trim "$line")"
		case "$line" in
			''|'#'*) continue ;;
		esac

		if is_policy_entry "$line"; then
			count=$((count + 1))
		fi
	done < "$file"

	echo "$count"
}
