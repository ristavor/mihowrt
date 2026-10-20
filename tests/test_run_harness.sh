#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/testlib.sh"

if ! command -v node >/dev/null 2>&1; then
	pass "js syntax checker handles quoted paths (node missing)"
	exit 0
fi

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

quoted_dir="$tmpdir/path'with-quote"
mkdir -p "$quoted_dir"

quoted_js="$quoted_dir/sample.js"
printf '%s\n' 'const answer = 42;' >"$quoted_js"

(
	# shellcheck disable=SC1091
	source "$ROOT_DIR/tests/run.sh"
	check_js_syntax "$quoted_js"
)

pass "js syntax checker handles quoted paths"
