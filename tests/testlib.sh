#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIHOWRT_LIB_DIR="${MIHOWRT_LIB_DIR:-$ROOT_DIR/rootfs/usr/lib/mihowrt}"
export MIHOWRT_LIB_DIR

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	# Accumulate independent historical regressions when explicitly requested.
	if [[ ${MIHOWRT_REGRESSION_PROOF:-0} == 1 ]]; then
		trap 'exit 1' EXIT
		return 0
	fi
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

assert_file_not_contains() {
	local file="$1"
	local needle="$2"
	local message="$3"

	if grep -qF -- "$needle" "$file"; then
		fail "$message"
	fi
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

source_install_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/install.sh"
	sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	trap - EXIT INT TERM HUP
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

strip_mihowrt_cli_bootstrap() {
	sed '/^check_required_file \/lib\/functions\.sh$/,/^unset MIHOWRT_HELPERS_AUTOLOAD$/d' \
		"$ROOT_DIR/rootfs/usr/bin/mihowrt"
}

source_mihowrt_cli_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/mihowrt.sh"
	strip_mihowrt_cli_bootstrap |
		sed '/^[[:space:]]*case "\$1" in$/,$d' >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

source_init_mihowrt_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/init.sh"
	sed '1d' "$ROOT_DIR/rootfs/etc/init.d/mihowrt" >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

source_init_recover_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/recover.sh"
	sed '1d' "$ROOT_DIR/rootfs/etc/init.d/mihowrt-recover" >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

# Source runtime modules from the repository in the given order.
load_modules() {
	local module
	for module in "$@"; do
		# shellcheck disable=SC1090
		source "$MIHOWRT_LIB_DIR/$module"
	done
}

# Fake uci/logger on PATH. Values live in $FAKE_UCI_DB as key=value lines.
setup_fake_uci() {
	local dir="$1"

	mkdir -p "$dir/bin"
	export FAKE_UCI_DB="$dir/uci.db"
	: >"$FAKE_UCI_DB"
	cat >"$dir/bin/uci" <<'UCI'
#!/usr/bin/env bash
while [ "${1:-}" = "-q" ] || [ "${1:-}" = "-X" ]; do shift; done
cmd="${1:-}"; shift || true
case "$cmd" in
get)
	awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); f = 1; exit } END { exit !f }' "$FAKE_UCI_DB"
	;;
set)
	key="${1%%=*}"
	awk -v k="$key=" 'index($0, k) != 1' "$FAKE_UCI_DB" >"$FAKE_UCI_DB.tmp"
	printf '%s\n' "$1" >>"$FAKE_UCI_DB.tmp"
	mv "$FAKE_UCI_DB.tmp" "$FAKE_UCI_DB"
	;;
delete)
	awk -v k="$1=" 'index($0, k) != 1' "$FAKE_UCI_DB" >"$FAKE_UCI_DB.tmp"
	mv "$FAKE_UCI_DB.tmp" "$FAKE_UCI_DB"
	;;
show)
	grep "^${1:-}" "$FAKE_UCI_DB" || true
	;;
add_list)
	name="${1%%=*}"
	old="$(awk -v k="$name=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$FAKE_UCI_DB")"
	awk -v k="$name=" 'index($0, k) != 1' "$FAKE_UCI_DB" >"$FAKE_UCI_DB.tmp"
	echo "$name=${old:+$old }${1#*=}" >>"$FAKE_UCI_DB.tmp"
	mv "$FAKE_UCI_DB.tmp" "$FAKE_UCI_DB"
	;;
commit) ;;
*) exit 1 ;;
esac
UCI
	cat >"$dir/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
exit 0
LOGGER
	chmod +x "$dir/bin/uci" "$dir/bin/logger"
	export PATH="$dir/bin:$PATH"
}

fake_uci_reset() {
	: >"$FAKE_UCI_DB"
}

fake_uci_set() {
	uci set "$1=$2"
}

# Keep provider profiles, check state and the fourth list inside each fixture.
# Runtime ash does not use nounset; initialize values read before settings_load.
setup_runtime_paths() {
	local dir="$1"

	API_SECRET=""
	DST_LIST_SOURCE=provider
	DIRECT_LIST_SOURCE=provider
	CLASH_CONFIG="$dir/source.yaml"
	PROFILE_FILE="$dir/profile"
	DIRECT_SRC_LIST_FILE="$dir/direct_src.txt"
	PKG_TMP_DIR="$dir/tmp"
	PKG_STATE_DIR="$dir/run"
	CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
	CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
	NFT_APPLIED_FILE="$dir/nft.applied"
	mkdir -p "$PKG_STATE_DIR" "$PKG_TMP_DIR"
}
