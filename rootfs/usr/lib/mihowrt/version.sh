#!/bin/ash

# Extract semver-like core version from command output or release names.
normalize_version() {
	printf '%s\n' "$1" | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d 'vV'
}

# Compare normalized x.y.z versions without relying on BusyBox sort -V.
version_ge() {
	local left="$1" right="$2" rest=""
	local l_major="" l_minor="" l_patch=""
	local r_major="" r_minor="" r_patch=""

	l_major="${left%%.*}"
	rest="${left#*.}"
	[ "$rest" != "$left" ] || return 1
	l_minor="${rest%%.*}"
	l_patch="${rest#*.}"
	[ "$l_patch" != "$rest" ] || return 1

	r_major="${right%%.*}"
	rest="${right#*.}"
	[ "$rest" != "$right" ] || return 1
	r_minor="${rest%%.*}"
	r_patch="${rest#*.}"
	[ "$r_patch" != "$rest" ] || return 1

	case "$l_major:$l_minor:$l_patch:$r_major:$r_minor:$r_patch" in
	*[!0123456789:]* | *::* | :* | *:)
		return 1
		;;
	esac

	while [ "${l_major#0}" != "$l_major" ]; do l_major="${l_major#0}"; done
	while [ "${l_minor#0}" != "$l_minor" ]; do l_minor="${l_minor#0}"; done
	while [ "${l_patch#0}" != "$l_patch" ]; do l_patch="${l_patch#0}"; done
	while [ "${r_major#0}" != "$r_major" ]; do r_major="${r_major#0}"; done
	while [ "${r_minor#0}" != "$r_minor" ]; do r_minor="${r_minor#0}"; done
	while [ "${r_patch#0}" != "$r_patch" ]; do r_patch="${r_patch#0}"; done
	[ -n "$l_major" ] || l_major=0
	[ -n "$l_minor" ] || l_minor=0
	[ -n "$l_patch" ] || l_patch=0
	[ -n "$r_major" ] || r_major=0
	[ -n "$r_minor" ] || r_minor=0
	[ -n "$r_patch" ] || r_patch=0

	[ "$l_major" -gt "$r_major" ] && return 0
	[ "$l_major" -lt "$r_major" ] && return 1
	[ "$l_minor" -gt "$r_minor" ] && return 0
	[ "$l_minor" -lt "$r_minor" ] && return 1
	[ "$l_patch" -ge "$r_patch" ]
}

# Map OpenWrt DISTRIB_ARCH to Mihomo release asset architecture.
detect_mihomo_arch() {
	local release_info distrib_arch
	release_info="$(cat /etc/openwrt_release 2>/dev/null)"
	distrib_arch="$(printf '%s\n' "$release_info" | sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p")"

	case "$distrib_arch" in
	aarch64_*) echo "arm64" ;;
	x86_64) echo "amd64" ;;
	i386_*) echo "386" ;;
	riscv64_*) echo "riscv64" ;;
	loongarch64_*) echo "loong64" ;;
	mips64el_*) echo "mips64le" ;;
	mips64_*) echo "mips64" ;;
	mipsel_*hardfloat*) echo "mipsle-hardfloat" ;;
	mipsel_*) echo "mipsle-softfloat" ;;
	mips_*hardfloat*) echo "mips-hardfloat" ;;
	mips_*) echo "mips-softfloat" ;;
	arm_*neon-vfp*) echo "armv7" ;;
	arm_*neon* | arm_*vfp*) echo "armv6" ;;
	arm_*) echo "armv5" ;;
	*) return 1 ;;
	esac
}

# Read installed Mihomo core version when the binary exists.
current_mihomo_version() {
	[ -x "$CLASH_BIN" ] || return 1
	"$CLASH_BIN" -v 2>/dev/null | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# Lightweight local-only version probe for the LuCI overview page.
core_version_json() {
	local version="" installed=0

	require_command jq || return 1
	version="$(current_mihomo_version 2>/dev/null || true)"
	[ -n "$version" ] && installed=1
	jq -nc \
		--arg version "$version" \
		--arg installed "$installed" \
		'{ version: $version, installed: ($installed == "1") }'
}
