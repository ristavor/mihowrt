#!/bin/ash

ensure_policy_files() {
	ensure_dir "$LIST_DIR"
}

policy_entry_has_legacy_colon_ports() {
	case "$1" in
		*';'*|*:*:*)
			return 1
			;;
		*:*)
			is_policy_entry "$1" && policy_entry_has_ports "$1"
			return $?
			;;
	esac

	return 1
}

policy_entry_legacy_colon_to_semicolon() {
	local value="$1"

	policy_entry_has_legacy_colon_ports "$value" || return 1
	printf '%s;%s' "${value%:*}" "${value##*:}"
}

policy_list_file_needs_migration() {
	local file="$1"
	local line="" trimmed=""

	[ -f "$file" ] || return 1

	while IFS= read -r line || [ -n "$line" ]; do
		trimmed="$(trim "$line")"
		case "$trimmed" in
			''|'#'*) continue ;;
		esac

		policy_entry_has_legacy_colon_ports "$trimmed" && return 0
	done < "$file"

	return 1
}

migrate_policy_list_file() {
	local file="$1"
	local tmp="" file_dir="" file_base="" line="" trimmed="" migrated=""
	local rc=0

	[ -f "$file" ] || return 0
	policy_list_file_needs_migration "$file" || return 0

	file_dir="$(dirname "$file")" || return 1
	file_base="$(basename "$file")" || return 1
	tmp="$(mktemp "$file_dir/.${file_base}.tmp.XXXXXX")" || return 1
	cp -p "$file" "$tmp" || {
		rm -f "$tmp"
		return 1
	}

	exec 3< "$file" || {
		rm -f "$tmp"
		return 1
	}
	exec 4> "$tmp" || {
		exec 3<&-
		rm -f "$tmp"
		return 1
	}

	while IFS= read -r line <&3 || [ -n "$line" ]; do
		trimmed="$(trim "$line")"
		if policy_entry_has_legacy_colon_ports "$trimmed"; then
			migrated="$(policy_entry_legacy_colon_to_semicolon "$trimmed")" || {
				rc=1
				break
			}
			printf '%s\n' "$migrated" >&4 || {
				rc=1
				break
			}
		else
			printf '%s\n' "$line" >&4 || {
				rc=1
				break
			}
		fi
	done

	exec 3<&-
	exec 4>&-
	[ "$rc" -eq 0 ] || {
		rm -f "$tmp"
		return 1
	}

	if cmp -s "$tmp" "$file" 2>/dev/null; then
		rm -f "$tmp"
		return 0
	fi

	mv -f "$tmp" "$file" || {
		rm -f "$tmp"
		return 1
	}
	log "Migrated legacy policy list port syntax in $file"
}

migrate_policy_list_files() {
	ensure_policy_files || return 1
	migrate_policy_list_file "$DST_LIST_FILE" || return 1
	migrate_policy_list_file "$SRC_LIST_FILE" || return 1
	migrate_policy_list_file "$DIRECT_DST_LIST_FILE" || return 1
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

policy_remote_list_fetch_budget() {
	local budget="${POLICY_REMOTE_LIST_FETCH_BUDGET:-60}"

	if ! is_uint "$budget" || [ "$budget" -le 0 ]; then
		budget=60
	fi

	printf '%s' "$budget"
}

policy_remote_list_max_urls() {
	local max_urls="${POLICY_REMOTE_LIST_MAX_URLS:-32}"

	if ! is_uint "$max_urls" || [ "$max_urls" -le 0 ]; then
		max_urls=32
	fi

	printf '%s' "$max_urls"
}

policy_remote_list_fetch_limits_begin() {
	local now="" budget=""

	require_command date || return 1
	now="$(date +%s)" || return 1
	is_uint "$now" || {
		err "Failed to read current time for remote policy list budget"
		return 1
	}

	budget="$(policy_remote_list_fetch_budget)"
	POLICY_REMOTE_LIST_URL_COUNT=0
	POLICY_REMOTE_LIST_FETCH_DEADLINE=$((now + budget))
}

policy_remote_list_register_url() {
	local url="$1"
	local label="$2"
	local max_urls=""

	max_urls="$(policy_remote_list_max_urls)"
	POLICY_REMOTE_LIST_URL_COUNT=$((${POLICY_REMOTE_LIST_URL_COUNT:-0} + 1))
	if [ "$POLICY_REMOTE_LIST_URL_COUNT" -gt "$max_urls" ]; then
		err "Too many remote policy list URLs in $label: $POLICY_REMOTE_LIST_URL_COUNT, limit $max_urls"
		return 1
	fi

	log "Fetching remote policy list $url"
}

policy_remote_list_effective_timeout() {
	local timeout="$1"
	local now="" remaining=0

	[ -n "${POLICY_REMOTE_LIST_FETCH_DEADLINE:-}" ] || {
		printf '%s' "$timeout"
		return 0
	}

	now="$(date +%s)" || return 1
	is_uint "$now" || {
		err "Failed to read current time for remote policy list budget"
		return 1
	}

	remaining=$((POLICY_REMOTE_LIST_FETCH_DEADLINE - now))
	if [ "$remaining" -le 0 ]; then
		err "Remote policy list fetch budget exceeded"
		return 1
	fi

	if [ "$timeout" -gt "$remaining" ]; then
		printf '%s' "$remaining"
	else
		printf '%s' "$timeout"
	fi
}

is_policy_remote_list_url() {
	policy_remote_list_url "$1" >/dev/null
}

policy_remote_list_url() {
	local value="$1" url="" ports=""

	case "$value" in
		*';'*)
			url="${value%;*}"
			ports="${value##*;}"
			is_http_fetch_url "$url" || return 1
			is_policy_port_spec "$ports" || return 1
			printf '%s' "$url"
			return 0
			;;
	esac

	is_http_fetch_url "$value" || return 1
	printf '%s' "$value"
}

policy_remote_list_ports() {
	local value="$1" url="" ports=""

	case "$value" in
		*';'*)
			url="${value%;*}"
			ports="${value##*;}"
			is_http_fetch_url "$url" || return 1
			policy_ports_normalized_spec "$ports"
			return $?
			;;
	esac

	printf '%s' ''
}

count_remote_list_urls() {
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

		if is_policy_remote_list_url "$line"; then
			count=$((count + 1))
		fi
	done < "$file"

	echo "$count"
}

policy_list_fingerprint() {
	local file="$1"

	if ! have_command cksum || ! have_command awk; then
		printf '%s' ''
		return 0
	fi

	if [ -f "$file" ]; then
		cksum "$file" | awk '{ printf "%s:%s", $1, $2 }'
	else
		printf '%s' '4294967295:0'
	fi
}

policy_effective_list_cleanup() {
	local path

	for path in "$@"; do
		rm -f "$path"
	done
}

policy_effective_list_cleanup_paths() {
	local path

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		policy_effective_list_cleanup "$path"
	done <<EOF
${1:-}
EOF
}

policy_effective_list_append_entry() {
	local output="$1"
	local entry="$2"

	printf '%s\n' "$entry" >> "$output" || return 1
}

policy_merge_list_file() {
	local source="$1"
	local output="$2"
	local label="$3"
	local allow_urls="$4"
	local inherited_ports="${5:-}"
	local line="" entry="" remote_file="" remote_url="" remote_ports=""
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

			remote_url="$(policy_remote_list_url "$line")" || return 1
			remote_ports="$(policy_remote_list_ports "$line")" || return 1
			policy_remote_list_register_url "$remote_url" "$label" || return 1
			remote_file="$(mktemp "$PKG_TMP_DIR/policy-remote.XXXXXX")" || {
				err "Failed to allocate temporary remote policy list path"
				return 1
			}
			remote_max_bytes="$(policy_remote_list_max_bytes)"
			remote_timeout="$(policy_remote_list_fetch_timeout)"
			remote_timeout="$(policy_remote_list_effective_timeout "$remote_timeout")" || {
				rm -f "$remote_file"
				return 1
			}
			if ! fetch_http_body_limited "$remote_url" "$remote_max_bytes" "$remote_timeout" "Remote policy list" > "$remote_file"; then
				rm -f "$remote_file"
				return 1
			fi
			policy_merge_list_file "$remote_file" "$output" "$remote_url" 0 "$remote_ports" || {
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
		if [ -n "$inherited_ports" ] && ! policy_entry_has_ports "$entry"; then
			entry="$(policy_entry_with_ports "$entry" "$inherited_ports")" || return 1
		fi
		policy_effective_list_append_entry "$output" "$entry" || return 1
	done < "$source"
}

policy_resolve_list_file() {
	local source="$1"
	local output="$2"
	local label="$3"
	local raw_output=""
	local max_bytes=""
	local dedup_rc=0

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

	max_bytes="$(policy_effective_list_max_bytes)"
	policy_merge_list_file "$source" "$raw_output" "$label" 1 || {
		rm -f "$raw_output"
		return 1
	}

	awk -v max_bytes="$max_bytes" '
		!seen[$0]++ {
			total += length($0) + 1
			if (total > max_bytes)
				exit 2
			print
		}
	' "$raw_output" > "$output"
	dedup_rc=$?
	if [ "$dedup_rc" -ne 0 ]; then
		if [ "$dedup_rc" -eq 2 ]; then
			err "Effective policy list is too large after dedup: limit $max_bytes"
		else
			err "Failed to build effective policy list"
		fi
		rm -f "$raw_output"
		return 1
	fi
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
		policy_effective_list_cleanup_paths "$POLICY_EFFECTIVE_LIST_FILES"
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
	unset POLICY_SOURCE_DST_LIST_FILE POLICY_SOURCE_SRC_LIST_FILE POLICY_SOURCE_DIRECT_LIST_FILE
	unset POLICY_PREV_DST_LIST_FILE_SET POLICY_PREV_SRC_LIST_FILE_SET POLICY_PREV_DIRECT_LIST_FILE_SET
	unset POLICY_REMOTE_LIST_URL_COUNT POLICY_REMOTE_LIST_FETCH_DEADLINE
}

policy_resolve_runtime_lists() {
	local dst_effective="" src_effective="" direct_effective=""
	local mode="${POLICY_MODE:-direct-first}"

	ensure_dir "$PKG_TMP_DIR"
	[ -z "${POLICY_EFFECTIVE_LIST_FILES:-}" ] || policy_clear_runtime_list_overrides
	policy_remote_list_fetch_limits_begin || return 1

	POLICY_PREV_DST_LIST_FILE_SET=0
	POLICY_PREV_SRC_LIST_FILE_SET=0
	POLICY_PREV_DIRECT_LIST_FILE_SET=0
	POLICY_SOURCE_DST_LIST_FILE="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	POLICY_SOURCE_SRC_LIST_FILE="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"
	POLICY_SOURCE_DIRECT_LIST_FILE="${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}"
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
			POLICY_EFFECTIVE_LIST_FILES="$(printf '%s\n%s' "$dst_effective" "$src_effective")"
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
