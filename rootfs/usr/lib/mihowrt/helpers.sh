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

mihowrt_sync_cron_marker() {
	local cron_file="$1"
	local marker="$2"
	local enabled="$3"
	local entry="$4"
	local cron_dir="" scratch_dir="" scratch_file="" tmp_file=""
	local marker_count="" entry_count=""

	MIHOWRT_CRON_CHANGED=0

	if [ "$enabled" != "1" ]; then
		[ -r "$cron_file" ] || return 0
		grep -qF "$marker" "$cron_file" 2>/dev/null || return 0
	else
		if [ -r "$cron_file" ]; then
			marker_count="$(grep -cF "$marker" "$cron_file" 2>/dev/null || true)"
			entry_count="$({ grep -Fx "$entry" "$cron_file" 2>/dev/null || true; } | wc -l | tr -d ' ')"
			[ "$marker_count" = "1" ] && [ "$entry_count" = "1" ] && return 0
		fi
	fi

	cron_dir="$(dirname "$cron_file")"
	scratch_dir="${TMPDIR:-/tmp}"
	scratch_file="$scratch_dir/mihowrt-cron.$$"
	tmp_file="${cron_file}.mihowrt.$$"

	ensure_dir "$scratch_dir" || return 1
	if [ -r "$cron_file" ]; then
		grep -vF "$marker" "$cron_file" >"$scratch_file" || true
	else
		: >"$scratch_file"
	fi

	if [ "$enabled" = "1" ]; then
		printf '%s\n' "$entry" >>"$scratch_file" || {
			rm -f "$scratch_file"
			return 1
		}
	fi

	if [ -f "$cron_file" ] && cmp -s "$scratch_file" "$cron_file"; then
		rm -f "$scratch_file"
		return 0
	fi

	ensure_dir "$cron_dir" || {
		rm -f "$scratch_file"
		return 1
	}
	cat "$scratch_file" >"$tmp_file" || {
		rm -f "$scratch_file" "$tmp_file"
		return 1
	}
	mv -f "$tmp_file" "$cron_file" || {
		rm -f "$scratch_file" "$tmp_file"
		return 1
	}
	rm -f "$scratch_file"
	MIHOWRT_CRON_CHANGED=1
	return 0
}

# Resolve module directory. Tests override MIHOWRT_LIB_DIR to load modules from
# the repository instead of an installed OpenWrt rootfs.
mihowrt_lib_dir() {
	if [ -n "${MIHOWRT_LIB_DIR:-}" ]; then
		printf '%s\n' "$MIHOWRT_LIB_DIR"
		return 0
	fi
	printf '%s\n' "/usr/lib/mihowrt"
}

# Source one required module and emit a shell-visible error. Missing modules are
# fatal because partial runtime loading can leave commands with undefined helpers.
mihowrt_source_module() {
	local module="$1"
	local lib_dir="" path="" message=""

	lib_dir="$(mihowrt_lib_dir)"
	path="$lib_dir/$module"
	[ -r "$path" ] || {
		message="Required MihoWRT module missing: $path"
		err "$message"
		printf 'Error: %s\n' "$message" >&2
		return 1
	}

	# shellcheck disable=SC1090
	. "$path"
}

MIHOWRT_HELPER_MODULES="${MIHOWRT_HELPER_MODULES:-validation.sh runtime-probe.sh config-io.sh mihomo-api.sh migration.sh fetch.sh diagnostics.sh version.sh}"
MIHOWRT_RUNTIME_MODULES="${MIHOWRT_RUNTIME_MODULES:-dns-state.sh lists.sh dns.sh nft.sh route.sh runtime-config.sh runtime-snapshot.sh policy.sh runtime-status.sh runtime.sh}"

# Load modules in caller-provided order; later modules may depend on functions
# defined by earlier ones.
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
