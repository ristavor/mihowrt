#!/bin/sh

set -eu

REPO_OWNER="ristavor"
REPO_NAME="mihowrt"
PKG_NAME="luci-app-mihowrt"
RELEASES_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
TMP_APK="$(mktemp /tmp/${PKG_NAME}.XXXXXX.apk)"

log() {
	printf '%s\n' "$*"
}

err() {
	printf 'Error: %s\n' "$*" >&2
}

cleanup() {
	rm -f "$TMP_APK"
}

trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM HUP

require_command() {
	command -v "$1" >/dev/null 2>&1 || {
		err "required command missing: $1"
		exit 1
	}
}

fetch_url() {
	if command -v curl >/dev/null 2>&1 && curl -fsL "$1"; then
		return 0
	fi

	if command -v wget >/dev/null 2>&1 && wget -qO- "$1"; then
		return 0
	fi

	err "need curl or wget"
	exit 1
}

download_file() {
	if command -v curl >/dev/null 2>&1 && curl -fL --retry 3 --connect-timeout 10 -o "$2" "$1"; then
		return 0
	fi

	if command -v wget >/dev/null 2>&1 && wget -O "$2" "$1"; then
		return 0
	fi

	err "need curl or wget"
	exit 1
}

latest_asset_url() {
	fetch_url "$RELEASES_API_URL" |
		sed 's/,/\n/g' |
		sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\/luci-app-mihowrt-[^"]*\.apk\)".*/\1/p' |
		head -n1
}

package_installed() {
	apk info -e "$PKG_NAME" >/dev/null 2>&1
}

prompt_reinstall() {
	local choice

	if [ "${MIHOWRT_FORCE_REINSTALL:-0}" = "1" ]; then
		return 0
	fi

	if ! command -v tty >/dev/null 2>&1 || ! tty -s >/dev/null 2>&1; then
		err "${PKG_NAME} already installed. Re-run with MIHOWRT_FORCE_REINSTALL=1 to reinstall/update."
		return 2
	fi

	printf '%s\n' "${PKG_NAME} already installed." >/dev/tty
	printf '%s\n' "1. Reinstall/update" >/dev/tty
	printf '%s\n' "2. Cancel" >/dev/tty

	while :; do
		printf 'Choose [1-2]: ' >/dev/tty
		IFS= read -r choice </dev/tty || {
			err "failed to read answer from tty"
			return 2
		}
		case "$choice" in
			1) return 0 ;;
			2) return 1 ;;
			*) printf '%s\n' "Enter 1 or 2." >/dev/tty ;;
		esac
	done
}

install_package() {
	if [ "${1:-0}" = "1" ]; then
		log "Installing ${PKG_NAME} from $2"
		apk add --allow-untrusted --force-reinstall "$2"
		return 0
	fi

	log "Installing ${PKG_NAME} from $2"
	apk add --allow-untrusted "$2"
}

main() {
	local asset_url
	local reinstall=0
	local prompt_rc=0

	require_command apk

	if package_installed; then
		if prompt_reinstall; then
			reinstall=1
		else
			prompt_rc="$?"
			case "$prompt_rc" in
			1)
				log "Cancelled."
				return 0
				;;
			*)
				return 1
				;;
			esac
		fi
	fi

	asset_url="$(latest_asset_url)"
	[ -n "$asset_url" ] || {
		err "failed to find latest ${PKG_NAME} apk in GitHub release"
		exit 1
	}

	log "Downloading latest release asset..."
	download_file "$asset_url" "$TMP_APK"
	install_package "$reinstall" "$TMP_APK"
}

main "$@"
