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
DNS_BACKUP_FILE="/etc/mihowrt/dns.backup"
DNS_BACKUP_NAME="dns.backup"
DNSMASQ_INIT_SCRIPT="/etc/init.d/dnsmasq"
DNS_AUTO_RESOLVFILE="/tmp/resolv.conf.d/resolv.conf.auto"
ROUTE_STATE_FILE="/var/run/mihowrt/route.state"
NFT_TABLE_NAME="mihomo_podkop"
NFT_INTERCEPT_MARK="0x00001000"
SKIP_START_FILE="/tmp/${PKG_NAME}.skip-start"

log() {
	printf '%s\n' "$*"
}

err() {
	printf 'Error: %s\n' "$*" >&2
}

warn() {
	printf 'Warning: %s\n' "$*" >&2
}

cleanup() {
	[ -n "$TMP_APK" ] && rm -f "$TMP_APK"
	[ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
	rm -f "$SKIP_START_FILE"
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

set_skip_start() {
	: > "$SKIP_START_FILE"
}

clear_skip_start() {
	rm -f "$SKIP_START_FILE"
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
		awk -F'"' -v pkg="$PKG_NAME" '
			$2 == "browser_download_url" && $4 ~ "/" pkg "-[^/]*\\.apk$" {
				print $4
				exit
			}
		'
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
	backup_file "$DNS_BACKUP_FILE" "$DNS_BACKUP_NAME"
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
		IFS= read -r pid < "$SERVICE_PID_FILE" 2>/dev/null || pid=""
		[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	fi

	if have_command pgrep; then
		pgrep -f "$ORCHESTRATOR run-service" >/dev/null 2>&1 && return 0
	fi

	return 1
}

wait_for_service_stop() {
	local attempt=0

	while [ "$attempt" -lt 10 ]; do
		service_running || return 0
		sleep 1
		attempt=$((attempt + 1))
	done

	return 1
}

mark_shutdown_clean() {
	have_command uci || return 0
	uci set mihowrt.settings.shutdown_correctly='1' >/dev/null 2>&1 || true
	uci commit mihowrt >/dev/null 2>&1 || true
}

shutdown_state_dirty() {
	local shutdown_state=""

	have_command uci || return 1
	shutdown_state="$(uci -q get mihowrt.settings.shutdown_correctly 2>/dev/null || true)"
	[ "$shutdown_state" = "0" ]
}

restart_dnsmasq() {
	[ -x "$DNSMASQ_INIT_SCRIPT" ] || return 0
	"$DNSMASQ_INIT_SCRIPT" restart >/dev/null 2>&1 || warn "dnsmasq restart failed"
}

route_state_read() {
	local line key value

	ROUTE_TABLE_ID_EFFECTIVE=""
	ROUTE_RULE_PRIORITY_EFFECTIVE=""
	[ -f "$ROUTE_STATE_FILE" ] || return 1

	while IFS='=' read -r key value; do
		case "$key" in
			ROUTE_TABLE_ID)
				ROUTE_TABLE_ID_EFFECTIVE="$value"
				;;
			ROUTE_RULE_PRIORITY)
				ROUTE_RULE_PRIORITY_EFFECTIVE="$value"
				;;
		esac
	done < "$ROUTE_STATE_FILE"

	[ -n "$ROUTE_TABLE_ID_EFFECTIVE" ] && [ -n "$ROUTE_RULE_PRIORITY_EFFECTIVE" ]
}

cleanup_runtime_fallback() {
	if have_command nft; then
		nft delete table inet "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
	fi

	if have_command ip && route_state_read; then
		while ip rule del fwmark "$NFT_INTERCEPT_MARK"/"$NFT_INTERCEPT_MARK" table "$ROUTE_TABLE_ID_EFFECTIVE" priority "$ROUTE_RULE_PRIORITY_EFFECTIVE" 2>/dev/null; do :; done
		ip route flush table "$ROUTE_TABLE_ID_EFFECTIVE" 2>/dev/null || true
	fi

	rm -f "$ROUTE_STATE_FILE"
}

restore_dns_from_backup_file() {
	local backup_path="$1"
	local line orig_cachesize="" orig_noresolv="" orig_resolvfile="" server has_servers=0

	[ -f "$backup_path" ] || return 1
	have_command uci || return 1
	grep -q '^DNSMASQ_BACKUP=1$' "$backup_path" 2>/dev/null || return 1

	uci -q delete dhcp.@dnsmasq[0].server >/dev/null 2>&1 || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile >/dev/null 2>&1 || true

	while IFS= read -r line; do
		case "$line" in
			ORIG_CACHESIZE=*)
				orig_cachesize="${line#ORIG_CACHESIZE=}"
				;;
			ORIG_NORESOLV=*)
				orig_noresolv="${line#ORIG_NORESOLV=}"
				;;
			ORIG_RESOLVFILE=*)
				orig_resolvfile="${line#ORIG_RESOLVFILE=}"
				;;
			ORIG_SERVER=*)
				server="${line#ORIG_SERVER=}"
				if [ -n "$server" ]; then
					uci add_list dhcp.@dnsmasq[0].server="$server" >/dev/null 2>&1 || return 1
					has_servers=1
				fi
				;;
		esac
	done < "$backup_path"

	if [ -n "$orig_cachesize" ]; then
		uci set dhcp.@dnsmasq[0].cachesize="$orig_cachesize" >/dev/null 2>&1 || return 1
	else
		uci -q delete dhcp.@dnsmasq[0].cachesize >/dev/null 2>&1 || true
	fi

	if [ -n "$orig_noresolv" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$orig_noresolv" >/dev/null 2>&1 || return 1
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv >/dev/null 2>&1 || true
	fi

	if [ -n "$orig_resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$orig_resolvfile" >/dev/null 2>&1 || return 1
	elif [ "$has_servers" -eq 0 ] && [ -f "$DNS_AUTO_RESOLVFILE" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$DNS_AUTO_RESOLVFILE" >/dev/null 2>&1 || return 1
		[ "$orig_noresolv" = "1" ] || uci set dhcp.@dnsmasq[0].noresolv='0' >/dev/null 2>&1 || return 1
	fi

	uci commit dhcp >/dev/null 2>&1 || return 1
	restart_dnsmasq
	mark_shutdown_clean
	return 0
}

restore_dns_defaults_fallback() {
	have_command uci || return 1

	uci -q delete dhcp.@dnsmasq[0].server >/dev/null 2>&1 || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile >/dev/null 2>&1 || true
	uci -q delete dhcp.@dnsmasq[0].cachesize >/dev/null 2>&1 || true
	uci set dhcp.@dnsmasq[0].noresolv='0' >/dev/null 2>&1 || return 1

	if [ -f "$DNS_AUTO_RESOLVFILE" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$DNS_AUTO_RESOLVFILE" >/dev/null 2>&1 || return 1
	fi

	uci commit dhcp >/dev/null 2>&1 || return 1
	restart_dnsmasq
	mark_shutdown_clean
	return 0
}

restore_system_dns_defaults() {
	local current_noresolv=""
	local allow_fallback="${1:-0}"

	have_command uci || return 0

	if restore_dns_from_backup_file "$DNS_BACKUP_FILE"; then
		log "System DNS settings restored from MihoWRT backup."
		return 0
	fi

	if [ -n "$BACKUP_DIR" ] && restore_dns_from_backup_file "$BACKUP_DIR/$DNS_BACKUP_NAME"; then
		log "System DNS settings restored from saved MihoWRT backup."
		return 0
	fi

	if [ "$allow_fallback" != "1" ] && ! shutdown_state_dirty; then
		mark_shutdown_clean
		return 0
	fi

	current_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)"
	if [ "$current_noresolv" = "1" ]; then
		restore_dns_defaults_fallback || return 1
		log "System DNS settings restored using fallback defaults."
	fi

	mark_shutdown_clean
	return 0
}

prepare_update() {
	backup_user_state

	service_enabled && WAS_ENABLED=1 || WAS_ENABLED=0
	service_running && WAS_RUNNING=1 || WAS_RUNNING=0

	if [ -x "$ORCHESTRATOR" ]; then
		log "Restoring system DNS/routing state before update..."
		if ! "$ORCHESTRATOR" cleanup >/dev/null 2>&1; then
			warn "MihoWRT runtime cleanup failed, trying fallback cleanup"
		fi
	fi

	cleanup_runtime_fallback
	restore_system_dns_defaults 1 || {
		err "failed to restore system DNS defaults before update"
		return 1
	}
}

quiesce_postinstall_service() {
	if ! service_running; then
		return 0
	fi

	if [ -x "$INIT_SCRIPT" ]; then
		log "Stopping auto-started MihoWRT service..."
		if "$INIT_SCRIPT" stop >/dev/null 2>&1 && wait_for_service_stop; then
			return 0
		fi
		warn "failed to stop auto-started MihoWRT service cleanly"
	fi

	if [ -x "$ORCHESTRATOR" ]; then
		"$ORCHESTRATOR" cleanup >/dev/null 2>&1 || true
	fi

	cleanup_runtime_fallback
	restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after stopping auto-started service"
}

restore_runtime_state() {
	if [ -x "$INIT_SCRIPT" ]; then
		if [ "$WAS_ENABLED" = "1" ]; then
			"$INIT_SCRIPT" enable >/dev/null 2>&1 || true
		else
			"$INIT_SCRIPT" disable >/dev/null 2>&1 || true
		fi
	fi

	if [ "$WAS_RUNNING" = "1" ] && [ -x "$INIT_SCRIPT" ]; then
		log "Starting MihoWRT service..."
		if "$INIT_SCRIPT" start >/dev/null 2>&1; then
			return 0
		fi
		warn "failed to start MihoWRT service after update"
		cleanup_runtime_fallback
		restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after failed service start"
		return 1
	fi

	if [ "$WAS_RUNNING" != "1" ]; then
		cleanup_runtime_fallback
		restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after update"
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
		set_skip_start
	fi

	create_tmp_apk
	log "Downloading latest release asset..."
	download_file "$asset_url" "$TMP_APK"
	if ! install_package "$reinstall" "$TMP_APK"; then
		clear_skip_start
		if [ "$reinstall" = "1" ]; then
			err "package install failed; restoring saved config and policy state"
			restore_user_state || err "failed to restore saved config and policy state"
			restore_runtime_state
		fi
		exit 1
	fi
	clear_skip_start

	if [ "$reinstall" = "1" ]; then
		quiesce_postinstall_service
		log "Restoring saved config and policy state..."
		restore_user_state
		restore_runtime_state
	fi
}

main "$@"
