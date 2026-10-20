#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

# Stock OpenWrt 25.12 BusyBox (verified on the VM) lacks od and base64, and
# its sort has no -o. Runtime code must not depend on them.
runtime=("$ROOT_DIR"/rootfs/usr/lib/mihowrt/*.sh "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$ROOT_DIR/rootfs/usr/bin/mihowrt-read")

check_absent() {
	local pattern="$1" message="$2" hits

	hits="$(grep -nE "$pattern" "${runtime[@]}" | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
	[[ -z "$hits" ]] || fail "$message: $hits"
}

check_absent '(^|[|;&(][[:space:]]*|\$\()od[[:space:]]' "od is not in OpenWrt BusyBox"
check_absent '(^|[|;&(][[:space:]]*|\$\()base64[[:space:]]' "base64 is not in OpenWrt BusyBox"
check_absent 'sort[^|;]*[[:space:]]-o[[:space:]]' "OpenWrt BusyBox sort has no -o"
pass "runtime uses only OpenWrt BusyBox tools"
