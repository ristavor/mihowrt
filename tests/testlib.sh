#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

pass() {
	printf 'ok - %s\n' "$*"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"

	[[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_true() {
	local message="$1"
	shift

	"$@" || fail "$message"
}

assert_false() {
	local message="$1"
	shift

	if "$@"; then
		fail "$message"
	fi
}

assert_file_contains() {
	local file="$1"
	local needle="$2"
	local message="$3"

	grep -qF -- "$needle" "$file" || fail "$message"
}

assert_symlink_target() {
	local path="$1"
	local expected="$2"
	local message="$3"
	local actual

	[[ -L "$path" ]] || fail "$message: '$path' not symlink"
	actual="$(readlink "$path")"
	[[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

make_temp_dir() {
	mktemp -d "${TMPDIR:-/tmp}/mihowrt-tests.XXXXXX"
}
