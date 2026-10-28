#!/bin/sh
# MihoWRT installer: installs or updates the LuCI package (and the optional
# Russian translation) with apk (OpenWrt 25.12+) or opkg (24.10), then lets
# /usr/bin/mihowrt install the Mihomo core.
# Non-interactive: MIHOWRT_ACTION=install|remove MIHOWRT_LANGUAGE=en|ru
set -eu

REPO="ristavor/mihowrt"
RELEASE_URL="${MIHOWRT_RELEASE_URL:-https://github.com/$REPO/releases/latest/download}"
PKG="luci-app-mihowrt"
I18N_PKG="luci-i18n-mihowrt-ru"
DEPS="luci-base nftables jq kmod-nft-tproxy curl"
CORE="/opt/clash/bin/clash"
MIHOWRT_BIN="/usr/bin/mihowrt"
OPENWRT_RELEASE_FILE="/etc/openwrt_release"
FW4_BIN="/sbin/fw4"
WORK=""
MANAGER="apk"
EXT="apk"

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
	[ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null
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

# Verbatim copy of rootfs/usr/lib/mihowrt/pkg.sh (tests/test_pkg.sh checks parity).
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

# dep_installed <name>: opkg lists real names only, so nftables is satisfied by
# either variant; apk resolves the virtual name itself.
dep_installed() {
	case "$1" in
	nftables) pkg_installed nftables || pkg_installed nftables-json || pkg_installed nftables-nojson ;;
	*) pkg_installed "$1" ;;
	esac
}

# select_manager: apk -> .apk assets, opkg -> .ipk assets.
select_manager() {
	MANAGER="$(pkg_manager)" || die "no supported package manager (apk or opkg) found"
	case "$MANAGER" in
	apk) EXT=apk ;;
	opkg) EXT=ipk ;;
	esac
}

# check_platform: fw4/nftables is required; opkg systems must be 24.10 or newer
# (apk implies 25.12+).
check_platform() {
	local release="" major="" minor="" valid=0

	[ -x "$FW4_BIN" ] || die "this installer needs OpenWrt 24.10 or newer with firewall4 (fw4 and nftables)"
	[ "$MANAGER" = opkg ] || return 0
	release="$(awk -F"'" '$1 == "DISTRIB_RELEASE=" { print $2; exit }' "$OPENWRT_RELEASE_FILE" 2>/dev/null)"
	major="${release%%.*}"
	minor="${release#*.}"
	minor="${minor%%[!0-9]*}"
	case "$release" in
	*.*) [ -n "$major" ] && [ -n "$minor" ] && valid=1 ;;
	esac
	case "$major$minor" in
	*[!0-9]*) valid=0 ;;
	esac
	[ "$valid" = 1 ] || die "unrecognized OpenWrt release '${release:-unknown}': this installer needs 24.10 or newer"
	[ "$major" -gt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -ge 10 ]; } ||
		die "OpenWrt $release is not supported: this installer needs 24.10 or newer"
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
	if pkg_installed "$PKG"; then
		pkg_installed "$I18N_PKG" && echo ru || echo en
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
	local name="$1" out="$2"

	# Keep explicit non-HTTPS mirrors usable (for example local file:// assets).
	set --
	case "$RELEASE_URL" in
	https://*) set -- --proto =https --proto-redir =https ;;
	http://*) warn "MIHOWRT_RELEASE_URL uses plain HTTP; downloads and checksums are unauthenticated" ;;
	esac
	curl -fsSL "$@" --retry 3 --connect-timeout 15 --max-time 300 -o "$out" "$RELEASE_URL/$name"
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

# release_version: <version>-<release> from the versioned app package line of
# SHA256SUMS whose hash equals the hash of the fixed-name app package
# (luci-app-mihowrt-<ver>.apk or luci-app-mihowrt_<ver>_all.ipk).
release_version() {
	local hash="" name=""

	hash="$(awk -v n="$PKG.$EXT" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$WORK/SHA256SUMS")"
	[ -n "$hash" ] || return 0
	name="$(awk -v p="$PKG" -v fixed="$PKG.$EXT" -v e=".$EXT" -v h="$hash" '{ f = $2; sub(/^\*/, "", f) } $1 == h && f != fixed && index(f, p) == 1 && substr(f, length(f) - length(e) + 1) == e { print f; exit }' "$WORK/SHA256SUMS")"
	name="${name#"$PKG"}"
	name="${name#[-_]}"
	name="${name%.apk}"
	echo "${name%_all.ipk}"
}

install_packages() {
	local lang="$1" version="" with_ru=0 dep="" missing=""

	for dep in $DEPS; do
		dep_installed "$dep" || missing="${missing:+$missing }$dep"
	done
	if [ -n "$missing" ]; then
		log "Installing dependencies..."
		pkg_update >/dev/null || die "$MANAGER update failed"
		# shellcheck disable=SC2086
		pkg_install $missing >/dev/null || die "cannot install dependencies: $missing"
	fi
	check_space

	log "Downloading the latest MihoWRT release..."
	download_file SHA256SUMS "$WORK/SHA256SUMS" || die "cannot download the release checksums"
	download_file "$PKG.$EXT" "$WORK/$PKG.$EXT" || die "cannot download $PKG.$EXT"
	verify_asset "$PKG.$EXT" "$WORK/$PKG.$EXT"
	if [ "$lang" = ru ]; then
		if download_file "$I18N_PKG.$EXT" "$WORK/$I18N_PKG.$EXT"; then
			verify_asset "$I18N_PKG.$EXT" "$WORK/$I18N_PKG.$EXT"
			with_ru=1
		else
			warn "release has no Russian translation package"
		fi
	fi

	version="$(release_version)"
	log "Installing ${version:-the latest release}..."
	pkg_install_file "$WORK/$PKG.$EXT" >/dev/null || die "package installation failed"
	if [ "$with_ru" = 1 ]; then
		pkg_install_file "$WORK/$I18N_PKG.$EXT" >/dev/null || err "Russian translation failed to install"
	elif [ "$lang" != ru ] && pkg_installed "$I18N_PKG"; then
		pkg_remove "$I18N_PKG" >/dev/null || true
	fi
}

do_install() {
	local lang="" fresh=1 result="" reason="" before="" after=""

	lang="$(resolve_language)"
	if pkg_installed "$PKG"; then
		fresh=0
		before="$(pkg_version "$PKG")"
	fi
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
	log ""
	if [ "$fresh" = 1 ]; then
		/etc/init.d/mihowrt enable
		log "MihoWRT is installed. Open LuCI → Services → MihoWRT and connect your subscription."
	else
		after="$(pkg_version "$PKG")"
		if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
			log "MihoWRT is updated."
		else
			log "MihoWRT is reinstalled (version unchanged)."
		fi
	fi
}

do_remove() {
	local removed=0

	log "Removing MihoWRT..."
	if pkg_installed "$I18N_PKG"; then
		pkg_remove "$I18N_PKG" >/dev/null
		removed=1
	fi
	if pkg_installed "$PKG"; then
		pkg_remove "$PKG" >/dev/null
		removed=1
	fi
	if [ "$removed" = 1 ]; then
		log "MihoWRT and the Mihomo core are removed. Your configs stay in /opt/clash."
	else
		log "MihoWRT is not installed."
	fi
}

main() {
	select_manager
	check_platform
	trap cleanup EXIT
	case "$(resolve_action)" in
	install) do_install ;;
	remove) do_remove ;;
	esac
}

main "$@"
