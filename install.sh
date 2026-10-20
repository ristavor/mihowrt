#!/bin/sh
# MihoWRT installer: installs or updates the LuCI package (and the optional
# Russian translation), then lets /usr/bin/mihowrt install the Mihomo core.
# Non-interactive: MIHOWRT_ACTION=install|remove MIHOWRT_LANGUAGE=en|ru
set -eu

REPO="ristavor/mihowrt"
RELEASES_API="https://api.github.com/repos/$REPO/releases/latest"
PKG="luci-app-mihowrt"
I18N_PKG="luci-i18n-mihowrt-ru"
DEPS="luci-base nftables jq kmod-nft-tproxy curl"
CORE="/opt/clash/bin/clash"
CORE_SPACE_KB=81920
WORK="/tmp/mihowrt-install.$$"
RELEASE_JSON=""

log() { printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 1
}

cleanup() {
	rm -rf "$WORK"
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

check_space() {
	local need=2048 free=""

	[ -x "$CORE" ] || need=$((need + CORE_SPACE_KB))
	mkdir -p /opt/clash
	free="$(free_kb /opt/clash)"
	[ -n "$free" ] || return 0
	[ "$free" -ge "$need" ] ||
		die "not enough flash: need $((need / 1024)) MiB, free $((free / 1024)) MiB (the Mihomo core is about 60 MiB)"
}

# asset_url <release.json> <name-prefix>: download URL and sha256 digest.
asset_info() {
	jq -r --arg p "$2-" '.assets[] | select(.name | startswith($p) and endswith(".apk"))
		| "\(.browser_download_url) \(.digest // "")"' "$1" | head -n 1
}

# Release info: GitHub API first (asset digests); if it is blocked or
# rate-limited, the tag comes from the github.com/releases/latest redirect.
fetch_release() {
	RELEASE_JSON="$WORK/release.json"
	curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 -o "$RELEASE_JSON" "$RELEASES_API" 2>/dev/null &&
		[ -n "$(jq -r '.tag_name // empty' "$RELEASE_JSON" 2>/dev/null)" ] && return 0
	RELEASE_JSON=""
	return 1
}

release_tag() {
	local url=""

	[ -n "${RELEASE_JSON:-}" ] || fetch_release
	if [ -n "${RELEASE_JSON:-}" ]; then
		jq -r .tag_name "$RELEASE_JSON"
		return 0
	fi
	url="$(curl -fsS -o /dev/null --connect-timeout 15 --max-time 30 -w '%{redirect_url}' \
		"https://github.com/$REPO/releases/latest" 2>/dev/null)" || return 1
	case "$url" in
	*/releases/tag/?*) echo "${url##*/releases/tag/}" ;;
	*) return 1 ;;
	esac
}

# download_asset <name-prefix> <out>
download_asset() {
	local prefix="$1" out="$2" info="" url="" digest="" tag=""

	if [ -n "${RELEASE_JSON:-}" ]; then
		info="$(asset_info "$RELEASE_JSON" "$prefix")"
		[ -n "$info" ] || return 1
		url="${info%% *}"
		digest="${info#* }"
	else
		tag="$(release_tag)" || return 1
		url="https://github.com/$REPO/releases/download/$tag/$prefix-${tag#v}-r1.apk"
	fi
	curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$out" "$url" || return 1
	case "$digest" in
	sha256:*)
		[ "$(sha256sum "$out" | cut -d' ' -f1)" = "${digest#sha256:}" ] || die "sha256 mismatch for $prefix"
		;;
	*) warn "no published checksum for $prefix (GitHub API unavailable); installing without checksum verification" ;;
	esac
}

install_packages() {
	local lang="$1" tag=""

	log "Installing dependencies..."
	apk update >/dev/null || die "apk update failed"
	# shellcheck disable=SC2086
	apk add $DEPS >/dev/null || die "cannot install dependencies: $DEPS"
	check_space

	log "Downloading the latest MihoWRT release..."
	fetch_release || log "GitHub API unavailable, using github.com directly"
	tag="$(release_tag)" || die "cannot reach GitHub (api.github.com and github.com failed)"
	download_asset "$PKG" "$WORK/$PKG.apk" || die "cannot download $PKG for $tag"
	log "Installing $tag..."
	apk add --allow-untrusted "$WORK/$PKG.apk" >/dev/null || die "package installation failed"

	if [ "$lang" = ru ]; then
		if download_asset "$I18N_PKG" "$WORK/$I18N_PKG.apk"; then
			apk add --allow-untrusted "$WORK/$I18N_PKG.apk" >/dev/null || err "Russian translation failed to install"
		else
			err "release has no Russian translation package"
		fi
	elif package_installed "$I18N_PKG"; then
		apk del "$I18N_PKG" >/dev/null || true
	fi
}

do_install() {
	local lang="" fresh=1

	lang="$(resolve_language)"
	package_installed "$PKG" && fresh=0
	mkdir -p "$WORK"
	install_packages "$lang"

	if [ ! -x "$CORE" ]; then
		log "Installing the Mihomo core..."
		/usr/bin/mihowrt core-update >/dev/null || die "Mihomo core installation failed; retry from LuCI → Services → MihoWRT"
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
	[ -x /etc/init.d/mihowrt ] && /etc/init.d/mihowrt stop >/dev/null 2>&1
	[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt recover >/dev/null 2>&1
	package_installed "$I18N_PKG" && apk del "$I18N_PKG" >/dev/null
	package_installed "$PKG" && apk del "$PKG" >/dev/null
	rm -f "$CORE"
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
