#!/bin/ash

# Package-manager adapter for apk (OpenWrt 25.12+) and opkg (24.10).
# install.sh carries a verbatim copy of these functions (tests/test_pkg.sh checks parity).

pkg_manager() {
	if command -v apk >/dev/null 2>&1; then
		echo apk
	elif command -v opkg >/dev/null 2>&1; then
		echo opkg
	else
		return 1
	fi
}

# Read names directly: no package-manager process or per-package queries.
pkg_installed_names() {
	if [ -f /lib/apk/db/installed ]; then
		awk '/^P:/ { print substr($0, 3) }' /lib/apk/db/installed
	elif [ -f /usr/lib/opkg/status ]; then
		# opkg keeps records like "Status: deinstall ok not-installed"; list only installed ones.
		awk '/^Package: / { name = substr($0, 10) } /^Status: .* installed$/ { print name }' /usr/lib/opkg/status
	fi
}

# pkg_installed <name>: apk also resolves virtual names; opkg lists real packages only.
pkg_installed() {
	case "$(pkg_manager)" in
	apk) apk info -e "$1" >/dev/null 2>&1 ;;
	opkg) pkg_installed_names | grep -qxF "$1" ;;
	*) return 1 ;;
	esac
}

# pkg_version <name>: installed "<version>-<release>", empty when not installed.
pkg_version() {
	local version=""

	case "$(pkg_manager)" in
	apk)
		version="$(apk info -v "$1" 2>/dev/null)" || version=""
		[ -z "$version" ] || echo "${version#"$1"-}"
		;;
	opkg)
		[ -f /usr/lib/opkg/status ] || return 0
		awk -v n="$1" '/^Package: / { name = substr($0, 10) } /^Version: / { ver = substr($0, 10) } name == n && /^Status: .* installed$/ { print ver; exit }' /usr/lib/opkg/status
		;;
	esac
}

# pkg_install_file <path>: a downloaded package file (apk needs --allow-untrusted).
pkg_install_file() {
	case "$(pkg_manager)" in
	apk) apk add --allow-untrusted "$1" ;;
	opkg) opkg install "$1" ;;
	*) return 1 ;;
	esac
}

# pkg_install <name>...: packages from the configured feeds.
pkg_install() {
	case "$(pkg_manager)" in
	apk) apk add "$@" ;;
	opkg) opkg install "$@" ;;
	*) return 1 ;;
	esac
}

pkg_remove() {
	case "$(pkg_manager)" in
	apk) apk del "$@" ;;
	opkg) opkg remove "$@" ;;
	*) return 1 ;;
	esac
}

pkg_update() {
	case "$(pkg_manager)" in
	apk) apk update ;;
	opkg) opkg update ;;
	*) return 1 ;;
	esac
}
