#!/bin/ash

log() {
	logger -p daemon.info -t "mihowrt" "$*"
}

warn() {
	logger -p daemon.warn -t "mihowrt" "$*"
}

err() {
	logger -p daemon.err -t "mihowrt" "$*"
}

have_command() {
	command -v "$1" >/dev/null 2>&1
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

ensure_dir() {
	local dir="$1"
	[ -d "$dir" ] || mkdir -p "$dir"
}

remove_path_if_exists() {
	local path="$1"
	[ -e "$path" ] || [ -L "$path" ] || return 0
	rm -rf "$path"
}

require_command() {
	have_command "$1" || {
		err "Required command missing: $1"
		return 1
	}
}

mihowrt_lib_dir() {
	if [ -n "${MIHOWRT_LIB_DIR:-}" ]; then
		printf '%s\n' "$MIHOWRT_LIB_DIR"
		return 0
	fi
	printf '%s\n' "/usr/lib/mihowrt"
}

mihowrt_source_module() {
	local module="$1"
	local lib_dir="" path=""

	lib_dir="$(mihowrt_lib_dir)"
	path="$lib_dir/$module"
	[ -r "$path" ] || {
		err "Required helper module missing: $path"
		return 1
	}

	# shellcheck disable=SC1090
	. "$path"
}

mihowrt_load_helper_modules() {
	mihowrt_source_module validation.sh || return 1
	mihowrt_source_module runtime-probe.sh || return 1
	mihowrt_source_module config-io.sh || return 1
	mihowrt_source_module fetch.sh || return 1
	mihowrt_source_module diagnostics.sh || return 1
	mihowrt_source_module version.sh || return 1
}

mihowrt_load_helper_modules || return 1 2>/dev/null || exit 1
