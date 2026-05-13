#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$tmpbin/uci" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_UCI_LOG"

if [[ "${1:-}" == "-q" ]]; then
	shift
fi

case "${1:-}" in
	get)
		[[ "${2:-}" == "mihowrt.settings.subscription_url" ]] || exit 1
		printf '%s\n' "${TEST_UCI_SUBSCRIPTION_URL:-}"
		;;
	set|delete|commit)
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF

cat > "$tmpbin/wget" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_WGET_LOG"

output=""
while [[ "$#" -gt 0 ]]; do
	case "$1" in
		-O)
			output="$2"
			shift 2
			;;
		-U|-T)
			shift 2
			;;
		-q)
			shift
			;;
		*)
			shift
			;;
	esac
done

[[ -n "$output" ]] || exit 1

case "${TEST_WGET_MODE:-ok}" in
	fail)
		exit 1
		;;
	empty)
		[ "$output" = "-" ] || : >"$output"
		;;
	large)
		if [ "$output" = "-" ]; then
			printf '1234567890'
		else
			printf '1234567890' >"$output"
		fi
		;;
	*)
		if [ "$output" = "-" ]; then
			printf 'mode: rule\n'
		else
			printf 'mode: rule\n' >"$output"
		fi
		;;
esac
EOF

chmod +x "$tmpbin/logger" "$tmpbin/uci" "$tmpbin/wget"
export PATH="$tmpbin:$PATH"
export TEST_UCI_LOG="$tmpdir/uci.log"
export TEST_WGET_LOG="$tmpdir/wget.log"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

assert_eq "mihowrt/0.5" "$(subscription_user_agent)" "subscription_user_agent should include package version"
assert_true "is_subscription_url should accept https URLs" is_subscription_url "https://example.com/sub.yaml"
assert_true "is_subscription_url should accept http URLs" is_subscription_url "http://example.com/sub.yaml"
assert_false "is_subscription_url should reject local paths" is_subscription_url "/tmp/sub.yaml"
assert_false "is_subscription_url should reject whitespace" is_subscription_url "https://example.com/sub yaml"
assert_false "is_subscription_url should reject empty hosts" is_subscription_url "https://"
assert_false "is_subscription_url should reject missing hosts" is_subscription_url "https:///sub.yaml"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
assert_eq "https://example.com/current.yaml" "$(subscription_url_json | jq -r '.subscription_url')" "subscription_url_json should expose saved UCI URL"
assert_file_contains "$TEST_UCI_LOG" "-q get mihowrt.settings.subscription_url" "subscription_url_json should read UCI option"

: >"$TEST_UCI_LOG"
set_subscription_url " https://example.com/new.yaml "
assert_file_contains "$TEST_UCI_LOG" "-q get mihowrt.settings.subscription_url" "set_subscription_url should read current URL before writing"
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings=settings" "set_subscription_url should ensure named UCI section"
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.subscription_url=https://example.com/new.yaml" "set_subscription_url should store trimmed URL"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "set_subscription_url should commit UCI config"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/same.yaml"
set_subscription_url "https://example.com/same.yaml"
assert_file_contains "$TEST_UCI_LOG" "-q get mihowrt.settings.subscription_url" "set_subscription_url should still read current URL for no-op saves"
assert_file_not_contains "$TEST_UCI_LOG" "-q commit mihowrt" "set_subscription_url should avoid NAND writes when URL is unchanged"

: >"$TEST_UCI_LOG"
export TEST_UCI_SUBSCRIPTION_URL="https://example.com/current.yaml"
set_subscription_url ""
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.subscription_url" "set_subscription_url should delete empty URL"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "set_subscription_url should commit URL deletion"

: >"$TEST_UCI_LOG"
assert_false "set_subscription_url should reject unsupported schemes" set_subscription_url "file:///tmp/config.yaml"
[[ ! -s "$TEST_UCI_LOG" ]] || fail "set_subscription_url should not touch UCI for invalid URL"

: >"$TEST_WGET_LOG"
SUBSCRIPTION_FETCH_TIMEOUT=7
SUBSCRIPTION_MAX_BYTES=128
assert_eq "128" "$(subscription_max_bytes)" "subscription_max_bytes should honor valid override"
assert_eq "mode: rule" "$(fetch_subscription_config "https://example.com/sub.yaml")" "fetch_subscription_config should print downloaded config"
assert_file_contains "$TEST_WGET_LOG" "-T 7" "fetch_subscription_config should bound wget timeout"
assert_file_contains "$TEST_WGET_LOG" "-U mihowrt/0.5" "fetch_subscription_config should send MihoWRT user agent"
assert_file_contains "$TEST_WGET_LOG" "-O -" "fetch_subscription_config should stream wget output through size cap"
assert_file_contains "$TEST_WGET_LOG" "https://example.com/sub.yaml" "fetch_subscription_config should pass URL to wget"

SUBSCRIPTION_MAX_BYTES=bad
assert_eq "1048576" "$(subscription_max_bytes)" "subscription_max_bytes should default to 1 MiB on invalid override"
SUBSCRIPTION_MAX_BYTES=0
assert_eq "1048576" "$(subscription_max_bytes)" "subscription_max_bytes should default to 1 MiB on zero override"
SUBSCRIPTION_MAX_BYTES=999999999999999999999
assert_eq "2147483646" "$(subscription_max_bytes)" "subscription_max_bytes should cap huge overrides before shell arithmetic"

export TEST_WGET_MODE=empty
assert_false "fetch_subscription_config should reject empty downloads" fetch_subscription_config "https://example.com/empty.yaml" >/dev/null

export TEST_WGET_MODE=large
SUBSCRIPTION_MAX_BYTES=4
assert_false "fetch_subscription_config should reject oversized downloads" fetch_subscription_config "https://example.com/large.yaml" >/dev/null

export TEST_WGET_MODE=fail
SUBSCRIPTION_MAX_BYTES=128
assert_false "fetch_subscription_config should fail when wget fails" fetch_subscription_config "https://example.com/fail.yaml" >/dev/null

assert_false "fetch_subscription_config should reject invalid URLs before wget" fetch_subscription_config "ftp://example.com/sub.yaml" >/dev/null

pass "subscription helpers"
