#!/bin/ash

sync_runtime_dir() {
	local src="$1"
	local dst="$2"
	local staged_dst="${dst}.tmp.$$"

	remove_path_if_exists "$staged_dst"
	ensure_dir "$staged_dst"
	if [ -d "$src" ] && [ ! -L "$src" ]; then
		cp -a "$src"/. "$staged_dst"/ || {
			remove_path_if_exists "$staged_dst"
			return 1
		}
	fi

	remove_path_if_exists "$dst"
	mv -f "$staged_dst" "$dst" || {
		remove_path_if_exists "$staged_dst"
		return 1
	}
	remove_path_if_exists "$src"
	ln -s "$dst" "$src" || return 1
	return 0
}

sync_runtime_file() {
	local src="$1"
	local dst="$2"
	local staged_dst="${dst}.tmp.$$"

	ensure_dir "$(dirname "$dst")"
	if [ -f "$src" ] && [ ! -L "$src" ]; then
		cp -a "$src" "$staged_dst" || {
			rm -f "$staged_dst"
			return 1
		}

		mv -f "$staged_dst" "$dst" || {
			rm -f "$staged_dst"
			return 1
		}
	fi

	if [ ! -L "$src" ] || [ "$(readlink "$src" 2>/dev/null)" != "$dst" ]; then
		remove_path_if_exists "$src"
		ln -s "$dst" "$src" || return 1
	fi

	return 0
}

setup_clash_runtime_dirs() {
	ensure_dir "$RULESET_TMPFS"
	ensure_dir "$PROXY_PROVIDERS_TMPFS"
	ensure_dir "$(dirname "$CACHE_DB_TMPFS")"

	if [ ! -L "$RULESET_LINK" ] || [ "$(readlink "$RULESET_LINK" 2>/dev/null)" != "$RULESET_TMPFS" ]; then
		sync_runtime_dir "$RULESET_LINK" "$RULESET_TMPFS" || return 1
	fi

	if [ ! -L "$PROXY_PROVIDERS_LINK" ] || [ "$(readlink "$PROXY_PROVIDERS_LINK" 2>/dev/null)" != "$PROXY_PROVIDERS_TMPFS" ]; then
		sync_runtime_dir "$PROXY_PROVIDERS_LINK" "$PROXY_PROVIDERS_TMPFS" || return 1
	fi

	if [ ! -L "$CACHE_DB_LINK" ] || [ "$(readlink "$CACHE_DB_LINK" 2>/dev/null)" != "$CACHE_DB_TMPFS" ]; then
		sync_runtime_file "$CACHE_DB_LINK" "$CACHE_DB_TMPFS" || return 1
	fi

	log "Runtime dirs/files set to tmpfs"
	return 0
}

init_runtime_layout() {
	ensure_policy_files || return 1
	setup_clash_runtime_dirs
}
