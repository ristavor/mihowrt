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

MIHOWRT_HELPER_MODULES="${MIHOWRT_HELPER_MODULES:-validation.sh runtime-probe.sh config-io.sh fetch.sh diagnostics.sh version.sh}"
MIHOWRT_RUNTIME_MODULES="${MIHOWRT_RUNTIME_MODULES:-dns-state.sh lists.sh dns.sh nft.sh route.sh runtime-config.sh runtime-snapshot.sh policy.sh runtime-status.sh runtime.sh}"

mihowrt_source_module_list() {
	local modules="$1" module=""

	# shellcheck disable=SC2086
	for module in $modules; do
		mihowrt_source_module "$module" || return 1
	done
}

mihowrt_load_helper_modules() {
	mihowrt_source_module_list "$MIHOWRT_HELPER_MODULES"
}

mihowrt_load_runtime_modules() {
	mihowrt_source_module_list "$MIHOWRT_RUNTIME_MODULES"
}

mihowrt_load_helper_modules || return 1 2>/dev/null || exit 1
