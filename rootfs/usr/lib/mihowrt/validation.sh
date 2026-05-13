#!/bin/ash

# Resolve validation module path separately from helpers.sh so tests can source
# validation.sh alone.
validation_lib_dir() {
	if [ -n "${MIHOWRT_LIB_DIR:-}" ]; then
		printf '%s\n' "$MIHOWRT_LIB_DIR"
		return 0
	fi
	printf '%s\n' "/usr/lib/mihowrt"
}

# Keep primitive validators split by domain while exposing one import point to
# callers that only need validation helpers.
validation_source_module() {
	local module="$1"
	local path=""

	path="$(validation_lib_dir)/$module"
	[ -r "$path" ] || return 1

	# shellcheck disable=SC1090
	. "$path"
}

validation_source_module validation-core.sh || return 1
validation_source_module validation-policy.sh || return 1
validation_source_module validation-dns.sh || return 1
