#!/bin/ash

normalize_version() {
	printf '%s\n' "$1" | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d 'vV'
}

version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

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
		arm_*neon*|arm_*vfp*) echo "armv6" ;;
		arm_*) echo "armv5" ;;
		*) return 1 ;;
	esac
}

current_mihomo_version() {
	[ -x "$CLASH_BIN" ] || return 1
	"$CLASH_BIN" -v 2>/dev/null | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}
