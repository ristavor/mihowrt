#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "/etc/openwrt_release" ]]; then
	printf "%s\n" "${TEST_OPENWRT_RELEASE:-}"
else
	exec /bin/cat "$@"
fi
EOF

cat > "$tmpdir/clash" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Mihomo Meta v1.18.7 linux amd64
build date: 2026-01-01
OUT
EOF

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmpbin/cat" "$tmpdir/clash" "$tmpbin/logger"

export PATH="$tmpbin:$PATH"
export TEST_OPENWRT_RELEASE="DISTRIB_ARCH='aarch64_cortex-a53'"
export CLASH_BIN="$tmpdir/clash"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

extract_installer_function() {
	local function_name="$1"
	sed -n "/^${function_name}() {$/,/^}$/p" "$ROOT_DIR/install.sh" |
		sed "1s/^${function_name}()/installer_${function_name}()/"
}

eval "$(extract_installer_function normalize_version)"
eval "$(extract_installer_function version_ge)"
eval "$(extract_installer_function detect_mihomo_arch)"
eval "$(extract_installer_function current_mihomo_version)"

assert_eq "$(normalize_version 'release-v1.2.3-alpha')" "$(installer_normalize_version 'release-v1.2.3-alpha')" "normalize_version should stay in sync between runtime and installer helpers"
assert_eq "$(detect_mihomo_arch)" "$(installer_detect_mihomo_arch)" "detect_mihomo_arch should stay in sync between runtime and installer helpers"
assert_eq "$(current_mihomo_version)" "$(installer_current_mihomo_version)" "current_mihomo_version should stay in sync between runtime and installer helpers"

assert_true "runtime version_ge should accept newer version" version_ge "1.2.4" "1.2.3"
assert_true "installer version_ge should accept newer version" installer_version_ge "1.2.4" "1.2.3"
assert_false "runtime version_ge should reject older version" version_ge "1.2.2" "1.2.3"
assert_false "installer version_ge should reject older version" installer_version_ge "1.2.2" "1.2.3"

makefile_pkg_version="$(sed -n 's/^PKG_VERSION:=//p' "$ROOT_DIR/Makefile")"
runtime_pkg_version="$(sed -n 's/^PKG_VERSION="\([^"]*\)"/\1/p' "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh")"
assert_eq "$makefile_pkg_version" "$runtime_pkg_version" "runtime package version should match Makefile version for subscription User-Agent"

pass "version helper parity"
