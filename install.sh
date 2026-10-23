#!/bin/sh
# MihoWRT installer: installs or updates the LuCI package (and the optional
# Russian translation), then lets /usr/bin/mihowrt install the Mihomo core.
# Non-interactive: MIHOWRT_ACTION=install|remove MIHOWRT_LANGUAGE=en|ru
set -eu

REPO="ristavor/mihowrt"
RELEASE_URL="https://github.com/$REPO/releases/latest/download"
PKG="luci-app-mihowrt"
I18N_PKG="luci-i18n-mihowrt-ru"
DEPS="luci-base nftables jq kmod-nft-tproxy curl"
CORE="/opt/clash/bin/clash"
MIHOWRT_BIN="/usr/bin/mihowrt"
WORK=""

log() { printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 1
}

cleanup() {
	[ -z "$WORK" ] || rm -rf "$WORK"
}

can_prompt() {
	[ -c /dev/tty ] && : </dev/tty 2>/dev/null
}

# ask <question> <option1> <option2>: prints 1 or 2 (default 1).
ask() {
	local answer=""

	printf '%s\n1. %s (default)\n2. %s\n' "$1" "$2" "$3" >/dev/tty
	while :; do
		printf 'Choose [1-2]: ' >/dev/tty
		IFS= read -r answer </dev/tty || return 1
		case "$answer" in
		'' | 1) echo 1; return 0 ;;
		2) echo 2; return 0 ;;
		esac
	done
}

package_installed() {
	apk info -e "$1" >/dev/null 2>&1
}

resolve_action() {
	case "${MIHOWRT_ACTION:-}" in
	install | update | package) echo install ;;
	remove | uninstall) echo remove ;;
	'')
		can_prompt || die "no terminal: set MIHOWRT_ACTION=install or remove"
		[ "$(ask "MihoWRT installer" "Install or update" "Remove MihoWRT and the Mihomo core")" = 1 ] &&
			echo install || echo remove
		;;
	*) die "invalid MIHOWRT_ACTION: $MIHOWRT_ACTION" ;;
	esac
}

# Updates keep the current language unless MIHOWRT_LANGUAGE says otherwise.
resolve_language() {
	case "${MIHOWRT_LANGUAGE:-}" in
	en | EN) echo en; return 0 ;;
	ru | RU) echo ru; return 0 ;;
	'') ;;
	*) die "invalid MIHOWRT_LANGUAGE: $MIHOWRT_LANGUAGE" ;;
	esac
	if package_installed "$PKG"; then
		package_installed "$I18N_PKG" && echo ru || echo en
	elif can_prompt; then
		[ "$(ask "Choose language / Выберите язык" "English" "Русский")" = 2 ] && echo ru || echo en
	else
		echo en
	fi
}

free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Package reserve only; core-update checks the flash for the core itself.
check_space() {
	local need=2048 free=""

	mkdir -p /opt/clash
	free="$(free_kb /opt/clash)"
	[ -n "$free" ] || return 0
	[ "$free" -ge "$need" ] ||
		die "not enough flash: need $((need / 1024)) MiB, free $((free / 1024)) MiB"
}

# download_file <name> <out>: fixed-name release asset.
download_file() {
	curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$2" "$RELEASE_URL/$1"
}

# verify_asset <name> <file>: sha256 of <file> must match the SHA256SUMS line
# for <name> ("<hash>  <name>"); a missing entry or a mismatch aborts.
verify_asset() {
	local want="" got=""

	want="$(awk -v n="$1" '$2 == n || $2 == "*" n { print $1; exit }' "$WORK/SHA256SUMS")"
	[ -n "$want" ] || die "no checksum for $1"
	got="$(sha256sum "$2" | awk '{ print $1 }')"
	[ "$got" = "$want" ] || die "sha256 mismatch for $1"
}

# release_version: <version>-<release> from the versioned app APK line of
# SHA256SUMS whose hash equals the hash of the fixed-name app APK.
release_version() {
	local hash="" name=""

	hash="$(awk -v n="$PKG.apk" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$WORK/SHA256SUMS")"
	[ -n "$hash" ] || return 0
	name="$(awk -v p="$PKG-" -v h="$hash" '{ f = $2; sub(/^\*/, "", f) } $1 == h && index(f, p) == 1 && f ~ /\.apk$/ { print f; exit }' "$WORK/SHA256SUMS")"
	name="${name#"$PKG"-}"
	echo "${name%.apk}"
}

install_packages() {
	local lang="$1" version="" with_ru=0

	log "Installing dependencies..."
	apk update >/dev/null || die "apk update failed"
	# shellcheck disable=SC2086
	apk add $DEPS >/dev/null || die "cannot install dependencies: $DEPS"
	check_space

	log "Downloading the latest MihoWRT release..."
	download_file SHA256SUMS "$WORK/SHA256SUMS" || die "cannot download the release checksums"
	download_file "$PKG.apk" "$WORK/$PKG.apk" || die "cannot download $PKG.apk"
	verify_asset "$PKG.apk" "$WORK/$PKG.apk"
	if [ "$lang" = ru ]; then
		if download_file "$I18N_PKG.apk" "$WORK/$I18N_PKG.apk"; then
			verify_asset "$I18N_PKG.apk" "$WORK/$I18N_PKG.apk"
			with_ru=1
		else
			warn "release has no Russian translation package"
		fi
	fi

	version="$(release_version)"
	log "Installing ${version:-the latest release}..."
	apk add --allow-untrusted "$WORK/$PKG.apk" >/dev/null || die "package installation failed"
	if [ "$with_ru" = 1 ]; then
		apk add --allow-untrusted "$WORK/$I18N_PKG.apk" >/dev/null || err "Russian translation failed to install"
	elif [ "$lang" != ru ] && package_installed "$I18N_PKG"; then
		apk del "$I18N_PKG" >/dev/null || true
	fi
}

do_install() {
	local lang="" fresh=1 result="" reason=""

	lang="$(resolve_language)"
	package_installed "$PKG" && fresh=0
	WORK="$(mktemp -d /tmp/mihowrt-install.XXXXXX)" || die "cannot create a temporary directory"
	install_packages "$lang"

	if [ ! -x "$CORE" ]; then
		log "Installing the Mihomo core..."
		# stdout is the JSON; the backend's own "Error: ..." line stays on stderr.
		result="$("$MIHOWRT_BIN" core-update)" || {
			reason="$(printf '%s' "$result" | jq -r '.error // empty' 2>/dev/null)" || reason=""
			die "Mihomo core installation failed${reason:+: $reason}; retry from LuCI → Services → MihoWRT"
		}
	fi
	/etc/init.d/mihowrt enable

	log ""
	if [ "$fresh" = 1 ]; then
		log "MihoWRT is installed. Open LuCI → Services → MihoWRT and connect your subscription."
	else
		log "MihoWRT is updated."
	fi
}

do_remove() {
	log "Removing MihoWRT..."
	package_installed "$I18N_PKG" && apk del "$I18N_PKG" >/dev/null
	package_installed "$PKG" && apk del "$PKG" >/dev/null
	log "MihoWRT and the Mihomo core are removed. Your configs stay in /opt/clash."
}

main() {
	command -v apk >/dev/null 2>&1 || die "this installer needs OpenWrt 25.12 or newer (apk)"
	trap cleanup EXIT
	case "$(resolve_action)" in
	install) do_install ;;
	remove) do_remove ;;
	esac
}

main "$@"
