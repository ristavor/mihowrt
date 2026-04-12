#!/bin/ash

ensure_policy_files() {
	ensure_dir "$LIST_DIR"
	ensure_file "$DST_LIST_FILE"
	ensure_file "$SRC_LIST_FILE"
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

		if is_ipv4_cidr "$line"; then
			count=$((count + 1))
		fi
	done < "$file"

	echo "$count"
}
