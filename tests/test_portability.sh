#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

# Stock OpenWrt 25.12 BusyBox (verified on the VM) lacks od and base64, and
# its sort has no -o. Runtime code must not depend on them.
runtime=("$ROOT_DIR"/rootfs/usr/lib/mihowrt/*.sh "$ROOT_DIR"/rootfs/usr/lib/mihowrt/*.awk "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$ROOT_DIR/rootfs/usr/bin/mihowrt-read")

check_absent() {
	local pattern="$1" message="$2" hits

	hits="$(grep -nE "$pattern" "${runtime[@]}" | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
	[[ -z "$hits" ]] || fail "$message: $hits"
}

check_absent '(^|[|;&(][[:space:]]*|\$\()od[[:space:]]' "od is not in OpenWrt BusyBox"
check_absent '(^|[|;&(][[:space:]]*|\$\()base64[[:space:]]' "base64 is not in OpenWrt BusyBox"
check_absent 'sort[^|;]*[[:space:]]-o[[:space:]]' "OpenWrt BusyBox sort has no -o"
pass "runtime uses only OpenWrt BusyBox tools"

# OpenWrt jq is built without Oniguruma: regex filters fail at runtime.
check_absent '(test|match|capture|sub|gsub|scan|splits)\("' "jq regex functions are unavailable on OpenWrt"
pass "runtime jq programs avoid regex filters"

# fd 9 belongs only to the runtime lock, never to long-lived children.
spawn_files=("$ROOT_DIR"/rootfs/usr/lib/mihowrt/*.sh "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$ROOT_DIR/rootfs/etc/hotplug.d/iface/90-mihowrt")
hits="$(grep -nE '(^|[^&]) &[[:space:]]*$' "${spawn_files[@]}" | grep -vF '9>&-' || true)"
[[ -z "$hits" ]] || fail "runtime background spawns must close lock fd 9: $hits"
pass "runtime background spawns close fd 9"
hits="$(grep -nE '/etc/init.d/[^[:space:]]+ (start|restart|reload)([[:space:]]|$)' "${spawn_files[@]}" | grep -vF '9>&-' || true)"
[[ -z "$hits" ]] || fail "daemon starts must close lock fd 9: $hits"
pass "runtime daemon starts close fd 9"
check_absent 'flock[^;|]*[[:space:]]-w' "BusyBox flock has no -w timeout"
