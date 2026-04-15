#!/bin/sh

set -eu

REPO_OWNER="ristavor"
REPO_NAME="mihowrt"
PKG_NAME="luci-app-mihowrt"
RELEASES_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
TMP_APK=""
BACKUP_DIR=""
WAS_ENABLED=0
WAS_RUNNING=0
INIT_SCRIPT="/etc/init.d/mihowrt"
ORCHESTRATOR="/usr/bin/mihowrt"
SERVICE_PID_FILE="/var/run/mihowrt/mihomo.pid"

log() {
	printf '%s\n' "$*"
}

err() {
	printf 'Error: %s\n' "$*" >&2
}

cleanup() {
	[ -n "$TMP_APK" ] && rm -f "$TMP_APK"
	[ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
}

trap cleanup EXIT
trap 'exit 1' INT TERM HUP

have_command() {
	command -v "$1" >/dev/null 2>&1
}

require_command() {
	have_command "$1" || {
		err "required command missing: $1"
		exit 1
	}
}

create_tmp_apk() {
	TMP_APK="$(mktemp "/tmp/${PKG_NAME}.XXXXXX")"
}

create_backup_dir() {
	BACKUP_DIR="$(mktemp -d "/tmp/${PKG_NAME}.backup.XXXXXX")"
}

fetch_url() {
	if have_command wget && wget -qO- "$1"; then
		return 0
	fi

	if have_command curl && curl -fsL "$1"; then
		return 0
	fi

	err "need wget or curl"
	exit 1
}

download_file() {
	if have_command wget && wget -qO "$2" "$1"; then
		return 0
	fi

	if have_command curl && curl -fsL --retry 3 --connect-timeout 10 -o "$2" "$1"; then
		return 0
	fi

	err "need wget or curl"
	exit 1
}

latest_asset_url() {
	fetch_url "$RELEASES_API_URL" |
		tr '\n' ' ' |
		sed 's/,/\n/g' |
		sed -n "s/.*\"browser_download_url\":[[:space:]]*\"\\([^\"]*\\/${PKG_NAME}-[^\"]*\\.apk\\)\".*/\\1/p" |
		head -n1
}

package_installed() {
	apk list -I "$PKG_NAME" 2>/dev/null | grep -q "^${PKG_NAME}-"
}

can_prompt() {
	[ -c /dev/tty ] || return 1
	: >/dev/tty 2>/dev/null || return 1
	: </dev/tty 2>/dev/null || return 1
	return 0
}

apk_supports_force_reinstall() {
	apk add --help 2>&1 | grep -q -- '--force-reinstall'
}

backup_file() {
	local src="$1"
	local name="$2"

	[ -f "$src" ] || return 0
	cp -p "$src" "$BACKUP_DIR/$name"
}

restore_file() {
	local name="$1"
	local dst="$2"

	[ -f "$BACKUP_DIR/$name" ] || return 0
	mkdir -p "$(dirname "$dst")"
	cp -p "$BACKUP_DIR/$name" "$dst"
}

backup_user_state() {
	create_backup_dir
	backup_file /opt/clash/config.yaml config.yaml
	backup_file /etc/config/mihowrt mihowrt.uci
	backup_file /opt/clash/lst/always_proxy_dst.txt always_proxy_dst.txt
	backup_file /opt/clash/lst/always_proxy_src.txt always_proxy_src.txt
}

restore_user_state() {
	[ -n "$BACKUP_DIR" ] || return 0
	restore_file config.yaml /opt/clash/config.yaml
	restore_file mihowrt.uci /etc/config/mihowrt
	restore_file always_proxy_dst.txt /opt/clash/lst/always_proxy_dst.txt
	restore_file always_proxy_src.txt /opt/clash/lst/always_proxy_src.txt
}

service_enabled() {
	[ -x "$INIT_SCRIPT" ] || return 1
	"$INIT_SCRIPT" enabled >/dev/null 2>&1
}

service_running() {
	local pid=""

	if [ -f "$SERVICE_PID_FILE" ]; then
		pid="$(cat "$SERVICE_PID_FILE" 2>/dev/null || true)"
		[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	fi

	if have_command pgrep; then
		pgrep -f "$ORCHESTRATOR run-service" >/dev/null 2>&1 && return 0
	fi

	return 1
}

prepare_update() {
	backup_user_state

	service_enabled && WAS_ENABLED=1 || WAS_ENABLED=0
	service_running && WAS_RUNNING=1 || WAS_RUNNING=0

	if [ -x "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
		"$INIT_SCRIPT" disable >/dev/null 2>&1 || true
	fi

	if [ -x "$ORCHESTRATOR" ]; then
		log "Restoring system DNS/routing state before update..."
		"$ORCHESTRATOR" cleanup >/dev/null 2>&1 || true
	fi
}

restore_runtime_state() {
	if [ "$WAS_ENABLED" = "1" ] && [ -x "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" enable >/dev/null 2>&1 || true
	fi

	if [ "$WAS_RUNNING" = "1" ] && [ -x "$INIT_SCRIPT" ]; then
		log "Restarting MihoWRT service..."
		"$INIT_SCRIPT" restart >/dev/null 2>&1 || true
	fi
}

prompt_reinstall() {
	local choice

	if [ "${MIHOWRT_FORCE_REINSTALL:-0}" = "1" ]; then
		return 0
	fi

	if ! can_prompt; then
		err "${PKG_NAME} already installed. Re-run with MIHOWRT_FORCE_REINSTALL=1 to reinstall/update."
		return 2
	fi

	printf '%s\n' "${PKG_NAME} already installed." >/dev/tty
	printf '%s\n' "1. Reinstall/update" >/dev/tty
	printf '%s\n' "2. Cancel" >/dev/tty

	while :; do
		printf 'Choose [1-2] (default 1): ' >/dev/tty
		IFS= read -r choice </dev/tty || {
			err "failed to read answer from tty"
			return 2
		}
		case "$choice" in
			'') return 0 ;;
			1) return 0 ;;
			2) return 1 ;;
			*) printf '%s\n' "Enter 1 or 2." >/dev/tty ;;
		esac
	done
}

install_package() {
	local reinstall="$1"
	local apk_path="$2"

	log "Installing ${PKG_NAME} from $apk_path"

	if [ "$reinstall" = "1" ] && apk_supports_force_reinstall; then
		apk add --allow-untrusted --force-reinstall "$apk_path"
		return 0
	fi

	if [ "$reinstall" = "1" ]; then
		log "apk add lacks --force-reinstall. Removing installed package first."
		apk del "$PKG_NAME"
	fi

	apk add --allow-untrusted "$apk_path"
}

main() {
	local asset_url
	local reinstall=0
	local prompt_rc=0

	require_command apk
	require_command mktemp

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

	if [ "$reinstall" = "1" ]; then
		log "Saving current config and policy state..."
		prepare_update
	fi

	create_tmp_apk
	log "Downloading latest release asset..."
	download_file "$asset_url" "$TMP_APK"
	if ! install_package "$reinstall" "$TMP_APK"; then
		if [ "$reinstall" = "1" ]; then
			err "package install failed; restoring saved config and policy state"
			restore_user_state || err "failed to restore saved config and policy state"
			restore_runtime_state
		fi
		exit 1
	fi

	if [ "$reinstall" = "1" ]; then
		log "Restoring saved config and policy state..."
		restore_user_state
		restore_runtime_state
	fi
}

main "$@"
