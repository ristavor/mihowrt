#!/bin/sh

set -eu

REPO_OWNER="ristavor"
REPO_NAME="mihowrt"
PKG_NAME="luci-app-mihowrt"
RELEASES_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
MIHOMO_RELEASES_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
TMP_APK=""
BACKUP_DIR=""
KERNEL_BACKUP_TMP=""
WAS_ENABLED=0
WAS_RUNNING=0
REINSTALL_HOLD_ACTIVE=0
PRESERVE_BACKUP_DIR=0
PRESERVE_KERNEL_TMP_DIR=0
SERVICE_READY_TIMEOUT="${SERVICE_READY_TIMEOUT:-30}"
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
CLASH_DIR="/opt/clash"
CLASH_BIN="${CLASH_DIR}/bin/clash"
KERNEL_TMP_DIR="/tmp/mihowrt/kernel-update"
REQUIRED_REPO_PACKAGES="luci-base nftables jq kmod-nft-tproxy"
REINSTALL_HOLD_VIRTUAL="${PKG_NAME}-reinstall-deps"
REQUIRED_APK_PACKAGES="${PKG_NAME} ${REQUIRED_REPO_PACKAGES}"
MISSING_PACKAGES=""

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
	if [ -n "$BACKUP_DIR" ] && [ "$PRESERVE_BACKUP_DIR" != "1" ]; then
		rm -rf "$BACKUP_DIR"
	fi
	if [ "$PRESERVE_KERNEL_TMP_DIR" != "1" ]; then
		rm -rf "$KERNEL_TMP_DIR"
	fi
	rm -f "$SKIP_START_FILE"
	release_reinstall_dependencies
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

kernel_backup_available() {
	[ -n "$KERNEL_BACKUP_TMP" ] && [ -f "$KERNEL_BACKUP_TMP" ]
}

clear_kernel_backup() {
	[ "$PRESERVE_KERNEL_TMP_DIR" = "1" ] && return 0
	[ -n "$KERNEL_BACKUP_TMP" ] && rm -f "$KERNEL_BACKUP_TMP"
	KERNEL_BACKUP_TMP=""
	rm -rf "$KERNEL_TMP_DIR"
	PRESERVE_KERNEL_TMP_DIR=0
}

preserve_kernel_backup_dir() {
	[ -d "$KERNEL_TMP_DIR" ] || return 0
	[ "$PRESERVE_KERNEL_TMP_DIR" = "1" ] && return 0

	PRESERVE_KERNEL_TMP_DIR=1
	warn "preserved kernel backup dir: $KERNEL_TMP_DIR"
}

stage_kernel_backup() {
	[ -f "$CLASH_BIN" ] || {
		clear_kernel_backup
		return 0
	}

	mkdir -p "$KERNEL_TMP_DIR" || return 1
	KERNEL_BACKUP_TMP="$KERNEL_TMP_DIR/clash.previous"

	if [ ! -f "$KERNEL_BACKUP_TMP" ] || ! cmp -s "$CLASH_BIN" "$KERNEL_BACKUP_TMP" 2>/dev/null; then
		cp -f "$CLASH_BIN" "$KERNEL_BACKUP_TMP" || return 1
	fi

	return 0
}

restore_kernel_backup() {
	kernel_backup_available || return 0

	mkdir -p "${CLASH_BIN%/*}" || return 1
	cp -f "$KERNEL_BACKUP_TMP" "$CLASH_BIN" || return 1
	clear_kernel_backup
	log "Restored previous Mihomo kernel"
	return 0
}

set_skip_start() {
	: > "$SKIP_START_FILE"
}

clear_skip_start() {
	rm -f "$SKIP_START_FILE"
}

wait_for_service_ready() {
	local waited=0
	local timeout="$SERVICE_READY_TIMEOUT"

	[ -x "$ORCHESTRATOR" ] || return 1

	while [ "$waited" -lt "$timeout" ]; do
		if "$ORCHESTRATOR" service-ready >/dev/null 2>&1; then
			return 0
		fi

		sleep 1
		waited=$((waited + 1))
	done

	return 1
}

stop_service_instance() {
	[ -x "$INIT_SCRIPT" ] || return 0

	"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
	wait_for_service_stop || true
}

fetch_url() {
	local have_fetcher=0

	if have_command wget && wget -qO- "$1"; then
		return 0
	fi
	have_command wget && have_fetcher=1

	if have_command curl && curl -fsL "$1"; then
		return 0
	fi
	have_command curl && have_fetcher=1

	if [ "$have_fetcher" = "1" ]; then
		err "failed to fetch $1"
	else
		err "need wget or curl"
	fi
	return 1
}

download_file() {
	local have_fetcher=0

	if have_command wget && wget -qO "$2" "$1"; then
		return 0
	fi
	have_command wget && have_fetcher=1

	if have_command curl && curl -fsL --retry 3 --connect-timeout 10 -o "$2" "$1"; then
		return 0
	fi
	have_command curl && have_fetcher=1

	if [ "$have_fetcher" = "1" ]; then
		err "failed to download $1"
	else
		err "need wget or curl"
	fi
	return 1
}

normalize_version() {
	printf '%s\n' "$1" | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d 'vV'
}

# Keep in sync with rootfs/usr/lib/mihowrt/helpers.sh.
# Installer duplicates these helpers so remote bootstrap stays standalone.
version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

detect_mihomo_arch() {
	local release_info distrib_arch

	release_info="$(cat /etc/openwrt_release 2>/dev/null || true)"
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

kernel_asset_url() {
	local release_json="$1"
	local asset_name="$2"

	printf '%s' "$release_json" |
		sed -n "s/.*\"browser_download_url\":[[:space:]]*\"\\([^\"]*\\/${asset_name}\\)\".*/\\1/p" |
		head -n1
}

kernel_install_or_update() {
	local arch release_json latest_tag latest_ver current_ver asset_name asset_url
	local tmpgz tmpbin bindir

	clear_kernel_backup
	require_command gzip

	arch="$(detect_mihomo_arch)" || {
		err "unable to detect Mihomo architecture from /etc/openwrt_release"
		return 1
	}

	release_json="$(fetch_url "$MIHOMO_RELEASES_API")" || {
		err "failed to query Mihomo latest release"
		return 1
	}

	latest_tag="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	[ -n "$latest_tag" ] || {
		err "latest Mihomo release has no tag_name"
		return 1
	}

	current_ver="$(normalize_version "$(current_mihomo_version 2>/dev/null || true)")"
	latest_ver="$(normalize_version "$latest_tag")"
	if [ -n "$current_ver" ] && [ -n "$latest_ver" ] && version_ge "$current_ver" "$latest_ver"; then
		log "Mihomo kernel already up to date ($current_ver)"
		return 0
	fi

	asset_name="mihomo-linux-${arch}-${latest_tag}.gz"
	asset_url="$(kernel_asset_url "$release_json" "$asset_name")"
	[ -n "$asset_url" ] || {
		err "no Mihomo asset found for architecture $arch"
		return 1
	}

	mkdir -p "$KERNEL_TMP_DIR"
	bindir="${CLASH_BIN%/*}"
	mkdir -p "$bindir"
	tmpgz="$KERNEL_TMP_DIR/$asset_name"
	tmpbin="$KERNEL_TMP_DIR/clash"

	rm -f "$tmpgz" "$tmpbin"
	download_file "$asset_url" "$tmpgz" || {
		rm -f "$tmpgz" "$tmpbin"
		err "failed to download Mihomo asset $asset_name"
		return 1
	}

	gzip -dc "$tmpgz" > "$tmpbin" || {
		rm -f "$tmpgz" "$tmpbin"
		err "failed to decompress Mihomo asset"
		return 1
	}

	chmod 0755 "$tmpbin" || {
		rm -f "$tmpgz" "$tmpbin"
		err "failed to chmod Mihomo binary"
		return 1
	}

	"$tmpbin" -v >/dev/null 2>&1 || {
		rm -f "$tmpgz" "$tmpbin"
		err "downloaded Mihomo binary failed self-check"
		return 1
	}

	if [ -f "$CLASH_BIN" ] && cmp -s "$tmpbin" "$CLASH_BIN" 2>/dev/null; then
		rm -f "$tmpgz" "$tmpbin"
		log "Downloaded Mihomo kernel is identical to installed binary"
		return 0
	fi

	stage_kernel_backup || {
		rm -f "$tmpgz" "$tmpbin"
		err "failed to stage previous Mihomo kernel"
		return 1
	}
	mv -f "$tmpbin" "$CLASH_BIN" || {
		rm -f "$tmpgz" "$tmpbin"
		err "failed to install Mihomo kernel"
		return 1
	}
	rm -f "$tmpgz"

	log "Updated Mihomo kernel to $latest_tag for arch $arch"
	return 0
}

kernel_remove() {
	rm -f "$CLASH_BIN" "$CLASH_BIN.bak"
	rm -rf "$KERNEL_TMP_DIR"
	rmdir "${CLASH_BIN%/*}" 2>/dev/null || true
}

latest_asset_url() {
	local release_json=""

	release_json="$(fetch_url "$RELEASES_API_URL")" || return 1

	printf '%s' "$release_json" |
		sed -n "s/.*\"browser_download_url\":[[:space:]]*\"\\([^\"]*\\/${PKG_NAME}-[^/\"]*\\.apk\\)\".*/\\1/p" |
		head -n1
}

package_installed() {
	package_present "$PKG_NAME"
}

package_present() {
	apk list -I "$1" 2>/dev/null | grep -q "^$1-"
}

package_requirement_present() {
	case "$1" in
		nftables)
			package_present nftables ||
			package_present nftables-json ||
			package_present nftables-nojson ||
			have_command nft
			;;
		*)
			package_present "$1"
			;;
	esac
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

apk_supports_virtual() {
	apk add --help 2>&1 | grep -q -- '--virtual'
}

verify_required_packages() {
	local pkg

	MISSING_PACKAGES=""
	for pkg in $REQUIRED_APK_PACKAGES; do
		package_requirement_present "$pkg" || MISSING_PACKAGES="${MISSING_PACKAGES}${MISSING_PACKAGES:+ }$pkg"
	done

	[ -z "$MISSING_PACKAGES" ]
}

hold_reinstall_dependencies() {
	apk_supports_virtual || return 1

	if package_present "$REINSTALL_HOLD_VIRTUAL"; then
		apk del "$REINSTALL_HOLD_VIRTUAL" >/dev/null 2>&1 || true
	fi

	apk add --virtual "$REINSTALL_HOLD_VIRTUAL" $REQUIRED_REPO_PACKAGES >/dev/null 2>&1 || return 1
	REINSTALL_HOLD_ACTIVE=1
	return 0
}

release_reinstall_dependencies() {
	[ "$REINSTALL_HOLD_ACTIVE" = "1" ] || package_present "$REINSTALL_HOLD_VIRTUAL" || return 0
	apk del "$REINSTALL_HOLD_VIRTUAL" >/dev/null 2>&1 || true
	REINSTALL_HOLD_ACTIVE=0
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
	if [ -f "$dst" ] && cmp -s "$BACKUP_DIR/$name" "$dst" 2>/dev/null; then
		return 0
	fi
	mkdir -p "$(dirname "$dst")"
	cp -p "$BACKUP_DIR/$name" "$dst"
}

backup_file_or_mark_missing() {
	local src="$1"
	local name="$2"
	local missing_marker="$BACKUP_DIR/$name.missing"

	if [ -f "$src" ]; then
		rm -f "$missing_marker"
		backup_file "$src" "$name" || return 1
		return 0
	fi

	rm -f "$BACKUP_DIR/$name"
	: > "$missing_marker"
}

restore_file_or_remove() {
	local name="$1"
	local dst="$2"
	local missing_marker="$BACKUP_DIR/$name.missing"

	[ -n "$BACKUP_DIR" ] || return 0

	if [ -f "$missing_marker" ]; then
		if [ -e "$dst" ] || [ -L "$dst" ]; then
			rm -f "$dst"
		fi
		return 0
	fi

	restore_file "$name" "$dst"
}

preserve_backup_dir() {
	[ -n "$BACKUP_DIR" ] || return 0
	[ -d "$BACKUP_DIR" ] || return 0
	[ "$PRESERVE_BACKUP_DIR" = "1" ] && return 0

	PRESERVE_BACKUP_DIR=1
	warn "preserved backup dir: $BACKUP_DIR"
}

backup_user_state() {
	create_backup_dir || return 1
	backup_file_or_mark_missing /opt/clash/config.yaml config.yaml || return 1
	backup_file_or_mark_missing /etc/config/mihowrt mihowrt.uci || return 1
	backup_file_or_mark_missing /opt/clash/lst/always_proxy_dst.txt always_proxy_dst.txt || return 1
	backup_file_or_mark_missing /opt/clash/lst/always_proxy_src.txt always_proxy_src.txt || return 1
	backup_file_or_mark_missing "$DNS_BACKUP_FILE" "$DNS_BACKUP_NAME" || return 1
}

restore_user_state() {
	[ -n "$BACKUP_DIR" ] || return 0
	restore_file_or_remove config.yaml /opt/clash/config.yaml || return 1
	restore_file_or_remove mihowrt.uci /etc/config/mihowrt || return 1
	restore_file_or_remove always_proxy_dst.txt /opt/clash/lst/always_proxy_dst.txt || return 1
	restore_file_or_remove always_proxy_src.txt /opt/clash/lst/always_proxy_src.txt || return 1
}

service_enabled() {
	[ -x "$INIT_SCRIPT" ] || return 1
	"$INIT_SCRIPT" enabled >/dev/null 2>&1
}

service_running() {
	if [ -x "$ORCHESTRATOR" ] && "$ORCHESTRATOR" service-running >/dev/null 2>&1; then
		return 0
	fi

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

restart_dnsmasq() {
	[ -x "$DNSMASQ_INIT_SCRIPT" ] || return 0
	"$DNSMASQ_INIT_SCRIPT" restart >/dev/null 2>&1 || {
		warn "dnsmasq restart failed"
		return 1
	}
}

ensure_dns_state_helpers() {
	local script_dir=""
	local helper_path=""

	command -v dnsmasq_state_matches >/dev/null 2>&1 && return 0

	for helper_path in \
		"/usr/lib/mihowrt/dns-state.sh" \
		"./rootfs/usr/lib/mihowrt/dns-state.sh"
	do
		if [ -r "$helper_path" ]; then
			# shellcheck disable=SC1090
			. "$helper_path"
			command -v dnsmasq_state_matches >/dev/null 2>&1 && return 0
		fi
	done

	case "${0:-}" in
		/*|*/*)
			script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || script_dir=""
			;;
	esac
	if [ -n "$script_dir" ] && [ -r "$script_dir/rootfs/usr/lib/mihowrt/dns-state.sh" ]; then
		# shellcheck disable=SC1090
		. "$script_dir/rootfs/usr/lib/mihowrt/dns-state.sh"
		command -v dnsmasq_state_matches >/dev/null 2>&1 && return 0
	fi

	# Standalone installer fallback. Keep behavior in sync with
	# rootfs/usr/lib/mihowrt/dns-state.sh.
	dns_flatten_lines() {
		local line out="" sep="" tab=""

		tab="$(printf '\t')"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			out="${out}${sep}${line}"
			sep="$tab"
		done

		printf '%s' "$out"
	}

	dns_current_servers_flat() {
		uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | dns_flatten_lines
	}

	dnsmasq_state_matches() {
		local expected_cachesize="$1"
		local expected_noresolv="$2"
		local expected_resolvfile="$3"
		local expected_servers="$4"
		local current_cachesize="" current_noresolv="" current_resolvfile="" current_servers=""

		current_cachesize="$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)"
		current_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)"
		current_resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true)"
		current_servers="$(dns_current_servers_flat)"

		[ "$current_cachesize" = "$expected_cachesize" ] || return 1
		[ "$current_noresolv" = "$expected_noresolv" ] || return 1
		[ "$current_resolvfile" = "$expected_resolvfile" ] || return 1
		[ "$current_servers" = "$expected_servers" ]
	}
}

is_valid_port_value() {
	case "${1:-}" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_uint_value() {
	case "${1:-}" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	return 0
}

is_dns_listen_host_value() {
	printf '%s' "$1" | grep -qE '^(\[[A-Za-z0-9._:%@:-]+\]|[A-Za-z0-9._:%@:-]+)$'
}

is_dns_listen_value() {
	local value="$1"
	local host="" port=""

	case "$value" in
		*#*)
			host="${value%#*}"
			port="${value##*#}"
			[ -n "$host" ] || return 1
			case "$host" in
				*'#'*|*[[:space:]]*)
					return 1
					;;
			esac
			is_dns_listen_host_value "$host" || return 1
			is_valid_port_value "$port"
			;;
		*)
			return 1
			;;
	esac
}

dns_backup_text_has_controls_value() {
	printf '%s' "$1" | grep -q '[[:cntrl:]]'
}

dns_backup_server_atom_value_valid() {
	printf '%s' "$1" | grep -qE '^(\[[A-Za-z0-9._:%@:-]+\]|[A-Za-z0-9._:%@:-]+)$'
}

dns_backup_server_selector_value_valid() {
	printf '%s' "$1" | grep -qE '^[#A-Za-z0-9._*:/-]+$'
}

dns_backup_server_target_value_valid() {
	local value="$1"
	local host="" port=""

	[ -n "$value" ] || return 1
	dns_backup_text_has_controls_value "$value" && return 1
	printf '%s' "$value" | grep -q '[[:space:]]' && return 1

	case "$value" in
		*#*)
			host="${value%#*}"
			port="${value##*#}"
			[ -n "$host" ] || return 1
			case "$host" in
				*'#'*|*/*)
					return 1
					;;
			esac
			dns_backup_server_atom_value_valid "$host" || return 1
			is_valid_port_value "$port" || return 1
			;;
		*)
			case "$value" in
				*/*)
					return 1
					;;
			esac
			dns_backup_server_atom_value_valid "$value" || return 1
			;;
	esac

	return 0
}

dns_backup_server_value_valid() {
	local value="$1"
	local rest="" prefix="" target=""

	[ -n "$value" ] || return 1
	dns_backup_text_has_controls_value "$value" && return 1
	printf '%s' "$value" | grep -q '[[:space:]]' && return 1

	case "$value" in
		/*)
			rest="${value#/}"
			case "$rest" in
				*/*)
					:
					;;
			*)
				return 1
				;;
		esac
		prefix="${rest%/*}"
		target="${rest##*/}"
		dns_backup_server_selector_value_valid "$prefix" || return 1
		[ -z "$target" ] && return 0
		[ "$target" = "#" ] && return 0
		dns_backup_server_target_value_valid "$target"
			;;
		*)
			dns_backup_server_target_value_valid "$value"
			;;
	esac
}

dns_backup_resolvfile_value_valid() {
	local value="$1"

	[ -n "$value" ] || return 0
	dns_backup_text_has_controls_value "$value" && return 1

	case "$value" in
		/*)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

trim_value() {
	printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

yaml_cleanup_scalar_value() {
	local value="$1"

	value="$(trim_value "$value")"

	case "$value" in
		\"*\")
			value="${value#\"}"
			value="${value%\"}"
			printf '%s' "$value"
			return 0
			;;
		\'*\')
			value="${value#\'}"
			value="${value%\'}"
			printf '%s' "$value"
			return 0
			;;
	esac

	value="$(printf '%s\n' "$value" | sed 's/[[:space:]]#.*$//')"
	trim_value "$value"
}

port_from_addr_value() {
	local value="$1"
	local host="" port=""

	value="$(trim_value "$value")"
	[ -n "$value" ] || return 1

	case "$value" in
		\[*\]:*)
			host="${value%%]*}"
			host="${host#[}"
			port="${value##*:}"
			[ -n "$host" ] || return 1
			;;
		*:*:*)
			return 1
			;;
		*)
			port="${value##*:}"
			[ "$port" != "$value" ] || return 1
			;;
	esac

	is_valid_port_value "$port" || return 1
	printf '%s' "$port"
}

normalize_dns_server_target_value() {
	local value="$1"
	local host="" port=""

	value="$(trim_value "$value")"
	[ -n "$value" ] || return 1
	port="$(port_from_addr_value "$value")" || return 1

	case "$value" in
		\[*\]:*)
			host="${value%%]*}"
			host="${host#[}"
			;;
		*)
			host="${value%:*}"
			;;
	esac

	host="$(trim_value "$host")"
	case "$host" in
		''|0.0.0.0|::|'[::]')
			host="127.0.0.1"
			;;
	esac

	printf '%s#%s\n' "$host" "$port"
}

config_mihomo_dns_target_from_path() {
	local config_path="$1"
	local dns_listen_raw=""

	[ -r "$config_path" ] || return 1

	dns_listen_raw="$(awk '
		/^dns:[[:space:]]*($|#)/ {
			in_dns = 1
			next
		}

		{
			if (in_dns && $0 ~ /^[^[:space:]#][^:]*:[[:space:]]*/) {
				in_dns = 0
			}

			if (in_dns && $0 ~ /^[[:space:]]+listen:[[:space:]]*/) {
				sub("^[[:space:]]+listen:[[:space:]]*", "", $0)
				print
				exit
			}
		}
	' "$config_path" 2>/dev/null || true)"

	dns_listen_raw="$(yaml_cleanup_scalar_value "$dns_listen_raw")"
	[ -n "$dns_listen_raw" ] || return 1

	normalize_dns_server_target_value "$dns_listen_raw"
}

dns_current_state_looks_hijacked() {
	local expected_target="${1:-}" current_cachesize="" current_noresolv="" current_resolvfile="" current_servers=""
	local current_host="" current_port="" tab=""

	have_command uci || return 1
	ensure_dns_state_helpers || return 1

	current_cachesize="$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)"
	current_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)"
	current_resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true)"
	current_servers="$(dns_current_servers_flat)"
	tab="$(printf '\t')"

	[ "$current_cachesize" = "0" ] || return 1
	[ "$current_noresolv" = "1" ] || return 1
	[ -z "$current_resolvfile" ] || return 1
	[ -n "$current_servers" ] || return 1

	case "$current_servers" in
		*"${tab}"*)
			return 1
			;;
		*"#"*)
			current_host="${current_servers%#*}"
			current_port="${current_servers##*#}"
			[ -n "$current_host" ] || return 1
			is_valid_port_value "$current_port" || return 1
			;;
		*)
			return 1
			;;
	esac

	if [ -n "$expected_target" ]; then
		[ "$current_servers" = "$expected_target" ] || return 1
	else
		case "$current_host" in
			127.0.0.1|::1|localhost)
				:
				;;
			*)
				return 1
				;;
		esac
	fi

	return 0
}

dns_backup_mihomo_target() {
	local backup_path="$1"
	local line="" mihomo_target=""

	[ -f "$backup_path" ] || return 1

	while IFS= read -r line; do
		case "$line" in
			MIHOMO_DNS_TARGET=*)
				mihomo_target="${line#MIHOMO_DNS_TARGET=}"
				break
				;;
		esac
	done < "$backup_path"

	[ -n "$mihomo_target" ] || return 1
	is_dns_listen_value "$mihomo_target" || return 1
	printf '%s\n' "$mihomo_target"
}

dns_backup_expected_target() {
	local backup_path="$1"
	local config_path="${2:-}"
	local line="" mihomo_target="" has_target_line=0

	while IFS= read -r line; do
		case "$line" in
			MIHOMO_DNS_TARGET=*)
				has_target_line=1
				mihomo_target="${line#MIHOMO_DNS_TARGET=}"
				break
				;;
		esac
	done < "$backup_path"

	if [ "$has_target_line" = "1" ] && [ -n "$mihomo_target" ]; then
		is_dns_listen_value "$mihomo_target" || return 1
		printf '%s\n' "$mihomo_target"
		return 0
	fi

	mihomo_target="$(dns_backup_mihomo_target "$backup_path" 2>/dev/null || true)"
	if [ -n "$mihomo_target" ]; then
		printf '%s\n' "$mihomo_target"
		return 0
	fi

	[ -n "$config_path" ] || return 1
	config_mihomo_dns_target_from_path "$config_path"
}

dns_backup_file_valid_for_restore() {
	local backup_path="$1"
	local line="" orig_cachesize="" orig_noresolv="" orig_resolvfile="" mihomo_target="" has_target_line=0

	[ -f "$backup_path" ] || return 1

	grep -q '^DNSMASQ_BACKUP=1$' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_CACHESIZE=' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_NORESOLV=' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_RESOLVFILE=' "$backup_path" 2>/dev/null || return 1

	while IFS= read -r line; do
		case "$line" in
			MIHOMO_DNS_TARGET=*)
				has_target_line=1
				mihomo_target="${line#MIHOMO_DNS_TARGET=}"
				;;
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
				[ -z "$server" ] || dns_backup_server_value_valid "$server" || return 1
				;;
		esac
	done < "$backup_path"

	if [ -n "$orig_cachesize" ] && ! is_uint_value "$orig_cachesize"; then
		return 1
	fi

	case "$orig_noresolv" in
		''|0|1)
			:
			;;
		*)
			return 1
			;;
	esac

	if [ "$has_target_line" = "1" ] && [ -n "$mihomo_target" ]; then
		is_dns_listen_value "$mihomo_target" || return 1
	fi

	dns_backup_resolvfile_value_valid "$orig_resolvfile" || return 1

	return 0
}

seed_dns_backup_target_metadata() {
	local backup_path="$1"
	local config_path="$2"
	local mihomo_target="" tmp_path=""

	[ -f "$backup_path" ] || return 0
	dns_backup_mihomo_target "$backup_path" >/dev/null 2>&1 && return 0

	mihomo_target="$(dns_backup_expected_target "$backup_path" "$config_path" 2>/dev/null || true)"
	[ -n "$mihomo_target" ] || return 0

	tmp_path="${backup_path}.tmp.$$"
	cp -f "$backup_path" "$tmp_path" || {
		rm -f "$tmp_path"
		return 1
	}
	printf 'MIHOMO_DNS_TARGET=%s\n' "$mihomo_target" >>"$tmp_path" || {
		rm -f "$tmp_path"
		return 1
	}
	mv -f "$tmp_path" "$backup_path" || {
		rm -f "$tmp_path"
		return 1
	}

	return 0
}

revert_dhcp_changes() {
	uci revert dhcp >/dev/null 2>&1 || true
}

delete_dhcp_option_if_present() {
	local option="$1"

	uci -q get "$option" >/dev/null 2>&1 || return 0
	uci -q delete "$option" >/dev/null 2>&1
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

nft_table_exists_fallback() {
	nft list table inet "$NFT_TABLE_NAME" >/dev/null 2>&1
}

nft_delete_table_if_exists_fallback() {
	have_command nft || return 1
	nft_table_exists_fallback || return 0
	nft delete table inet "$NFT_TABLE_NAME" >/dev/null 2>&1 || return 1
	nft_table_exists_fallback && return 1
	return 0
}

route_rule_exists_fallback() {
	local route_table_id="$1"
	local route_rule_priority="$2"

	[ -n "$route_table_id" ] || return 1
	[ -n "$route_rule_priority" ] || return 1
	have_command ip || return 1

	ip rule show 2>/dev/null | awk -v priority="$route_rule_priority" -v table="$route_table_id" '
		$1 == priority ":" && (index($0, " lookup " table) || index($0, " table " table)) { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

route_table_has_entries_fallback() {
	local route_table_id="$1"

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 1
	ip route show table "$route_table_id" 2>/dev/null | grep -q .
}

route_delete_rule_fallback() {
	local route_table_id="$1"
	local route_rule_priority="$2"

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0

	route_rule_exists_fallback "$route_table_id" "$route_rule_priority" || return 0
	while ip rule del fwmark "$NFT_INTERCEPT_MARK"/"$NFT_INTERCEPT_MARK" table "$route_table_id" priority "$route_rule_priority" 2>/dev/null; do :; done
	route_rule_exists_fallback "$route_table_id" "$route_rule_priority" && return 1
	return 0
}

route_teardown_ids_fallback() {
	local route_table_id="$1"
	local route_rule_priority="$2"

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0
	have_command ip || return 1

	route_delete_rule_fallback "$route_table_id" "$route_rule_priority" || return 1
	if route_table_has_entries_fallback "$route_table_id"; then
		ip route flush table "$route_table_id" 2>/dev/null || return 1
		route_table_has_entries_fallback "$route_table_id" && return 1
	fi
	return 0
}

cleanup_runtime_fallback() {
	local rc=0

	if have_command nft; then
		if ! nft_delete_table_if_exists_fallback; then
			warn "failed to remove nft policy table $NFT_TABLE_NAME during fallback cleanup"
			rc=1
		fi
	fi

	if [ -f "$ROUTE_STATE_FILE" ]; then
		if ! route_state_read; then
			warn "failed to read route state from $ROUTE_STATE_FILE during fallback cleanup"
			rc=1
		elif ! route_teardown_ids_fallback "$ROUTE_TABLE_ID_EFFECTIVE" "$ROUTE_RULE_PRIORITY_EFFECTIVE"; then
			warn "failed to remove policy routing for table $ROUTE_TABLE_ID_EFFECTIVE priority $ROUTE_RULE_PRIORITY_EFFECTIVE during fallback cleanup"
			rc=1
		else
			rm -f "$ROUTE_STATE_FILE"
		fi
	fi

	[ "$rc" -eq 0 ]
}

restore_dns_from_backup_file() {
	local backup_path="$1"
	local line orig_cachesize="" orig_noresolv="" orig_resolvfile="" target_noresolv="" target_resolvfile=""
	local server has_servers=0 expected_servers="" server_sep="" tab=""

	[ -f "$backup_path" ] || return 1
	have_command uci || return 1
	ensure_dns_state_helpers || return 1
	dns_backup_file_valid_for_restore "$backup_path" || return 1

	tab="$(printf '\t')"

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
					expected_servers="${expected_servers}${server_sep}${server}"
					server_sep="$tab"
					has_servers=1
				fi
				;;
		esac
	done < "$backup_path"

	target_noresolv="$orig_noresolv"
	target_resolvfile="$orig_resolvfile"
	if [ -z "$target_resolvfile" ] && [ "$has_servers" -eq 0 ] && [ -f "$DNS_AUTO_RESOLVFILE" ]; then
		target_resolvfile="$DNS_AUTO_RESOLVFILE"
		[ "$orig_noresolv" = "1" ] || target_noresolv='0'
	fi

	if dnsmasq_state_matches "$orig_cachesize" "$target_noresolv" "$target_resolvfile" "$expected_servers"; then
		return 0
	fi

	delete_dhcp_option_if_present dhcp.@dnsmasq[0].server || {
		revert_dhcp_changes
		return 1
	}
	delete_dhcp_option_if_present dhcp.@dnsmasq[0].resolvfile || {
		revert_dhcp_changes
		return 1
	}
	while IFS= read -r line; do
		case "$line" in
			ORIG_SERVER=*)
				server="${line#ORIG_SERVER=}"
				if [ -n "$server" ]; then
					uci add_list dhcp.@dnsmasq[0].server="$server" >/dev/null 2>&1 || {
						revert_dhcp_changes
						return 1
					}
				fi
				;;
		esac
	done < "$backup_path"

	if [ -n "$orig_cachesize" ]; then
		uci set dhcp.@dnsmasq[0].cachesize="$orig_cachesize" >/dev/null 2>&1 || {
			revert_dhcp_changes
			return 1
		}
	else
		delete_dhcp_option_if_present dhcp.@dnsmasq[0].cachesize || {
			revert_dhcp_changes
			return 1
		}
	fi

	if [ -n "$orig_noresolv" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$orig_noresolv" >/dev/null 2>&1 || {
			revert_dhcp_changes
			return 1
		}
	else
		delete_dhcp_option_if_present dhcp.@dnsmasq[0].noresolv || {
			revert_dhcp_changes
			return 1
		}
	fi

	if [ -n "$orig_resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$orig_resolvfile" >/dev/null 2>&1 || {
			revert_dhcp_changes
			return 1
		}
	elif [ "$has_servers" -eq 0 ] && [ -f "$DNS_AUTO_RESOLVFILE" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$DNS_AUTO_RESOLVFILE" >/dev/null 2>&1 || {
			revert_dhcp_changes
			return 1
		}
		[ "$orig_noresolv" = "1" ] || uci set dhcp.@dnsmasq[0].noresolv='0' >/dev/null 2>&1 || {
			revert_dhcp_changes
			return 1
		}
	fi

	uci commit dhcp >/dev/null 2>&1 || {
		revert_dhcp_changes
		return 1
	}
	restart_dnsmasq
}

restore_dns_defaults_fallback() {
	local resolvfile=""

	have_command uci || return 1
	ensure_dns_state_helpers || return 1

	if [ -f "$DNS_AUTO_RESOLVFILE" ]; then
		resolvfile="$DNS_AUTO_RESOLVFILE"
	fi

	if dnsmasq_state_matches "" "0" "$resolvfile" ""; then
		return 0
	fi

	delete_dhcp_option_if_present dhcp.@dnsmasq[0].server || {
		revert_dhcp_changes
		return 1
	}
	delete_dhcp_option_if_present dhcp.@dnsmasq[0].resolvfile || {
		revert_dhcp_changes
		return 1
	}
	delete_dhcp_option_if_present dhcp.@dnsmasq[0].cachesize || {
		revert_dhcp_changes
		return 1
	}
	uci set dhcp.@dnsmasq[0].noresolv='0' >/dev/null 2>&1 || {
		revert_dhcp_changes
		return 1
	}

	if [ -n "$resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile" >/dev/null 2>&1 || {
			revert_dhcp_changes
			return 1
		}
	fi

	uci commit dhcp >/dev/null 2>&1 || {
		revert_dhcp_changes
		return 1
	}
	restart_dnsmasq
}

restore_system_dns_defaults() {
	local current_noresolv=""
	local allow_fallback="${1:-0}"
	local backup_target=""
	local active_config_path="${CLASH_DIR}/config.yaml"
	local backup_config_path=""

	have_command uci || return 0

	if dns_backup_file_valid_for_restore "$DNS_BACKUP_FILE"; then
		backup_target="$(dns_backup_expected_target "$DNS_BACKUP_FILE" "$active_config_path" 2>/dev/null || true)"
		if dns_current_state_looks_hijacked "$backup_target"; then
			restore_dns_from_backup_file "$DNS_BACKUP_FILE" || return 1
			log "System DNS settings restored from MihoWRT backup."
			return 0
		fi
	fi

	backup_target=""
	backup_config_path="${BACKUP_DIR}/config.yaml"
	if [ -n "$BACKUP_DIR" ] && dns_backup_file_valid_for_restore "$BACKUP_DIR/$DNS_BACKUP_NAME"; then
		backup_target="$(dns_backup_expected_target "$BACKUP_DIR/$DNS_BACKUP_NAME" "$backup_config_path" 2>/dev/null || true)"
		if [ -z "$backup_target" ]; then
			backup_target="$(dns_backup_expected_target "$BACKUP_DIR/$DNS_BACKUP_NAME" "$active_config_path" 2>/dev/null || true)"
		fi
		if dns_current_state_looks_hijacked "$backup_target"; then
			restore_dns_from_backup_file "$BACKUP_DIR/$DNS_BACKUP_NAME" || return 1
			log "System DNS settings restored from saved MihoWRT backup."
			return 0
		fi
	fi

	if [ "$allow_fallback" != "1" ]; then
		return 0
	fi

	current_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)"
	if [ "$current_noresolv" = "1" ]; then
		restore_dns_defaults_fallback || return 1
		log "System DNS settings restored using fallback defaults."
	fi

	return 0
}

prepare_update() {
	service_enabled && WAS_ENABLED=1 || WAS_ENABLED=0
	service_running && WAS_RUNNING=1 || WAS_RUNNING=0

	seed_dns_backup_target_metadata "$DNS_BACKUP_FILE" "${CLASH_DIR}/config.yaml" || warn "failed to add Mihomo DNS target metadata to existing dns backup"

	backup_user_state || {
		err "failed to back up current config and policy state"
		return 1
	}

	if apk_supports_virtual; then
		log "Holding MihoWRT dependencies during reinstall..."
		hold_reinstall_dependencies || {
			err "failed to hold required dependencies before reinstall"
			return 1
		}
	else
		warn "apk add lacks --virtual; reinstall may refresh dependencies"
	fi

	log "Restoring system DNS/routing state before update..."
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
		log "Stopping running MihoWRT service before state restore..."
		if "$INIT_SCRIPT" stop >/dev/null 2>&1 && wait_for_service_stop; then
			return 0
		fi
		warn "failed to stop running MihoWRT service cleanly"
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
		if service_running; then
			log "Restarting MihoWRT service..."
			if "$INIT_SCRIPT" restart >/dev/null 2>&1; then
				if wait_for_service_ready; then
					return 0
				fi
				warn "MihoWRT restart returned success but service never became ready"
			fi
			warn "failed to restart MihoWRT service after update"
			stop_service_instance
		fi

		log "Starting MihoWRT service..."
		if "$INIT_SCRIPT" start >/dev/null 2>&1; then
			if wait_for_service_ready; then
				return 0
			fi
			warn "MihoWRT start returned success but service never became ready"
		fi
		warn "failed to start MihoWRT service after update"
		stop_service_instance
		cleanup_runtime_fallback
		restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after failed service start"
		return 1
	fi

	if [ "$WAS_RUNNING" != "1" ]; then
		cleanup_runtime_fallback
		restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after update"
	fi
}

rollback_reinstall_state() {
	[ "${1:-0}" = "1" ] || return 0
	if ! restore_kernel_backup; then
		preserve_kernel_backup_dir
	fi
	restore_runtime_state || true
	release_reinstall_dependencies
	clear_kernel_backup
}

handle_install_failure() {
	local reinstall="$1"
	local message="$2"

	err "$message"
	clear_skip_start
	release_reinstall_dependencies

	if [ -x "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" disable >/dev/null 2>&1 || true
	fi

	quiesce_postinstall_service
	cleanup_runtime_fallback
	restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after incomplete package install"

	if [ "$reinstall" = "1" ]; then
		if ! restore_kernel_backup; then
			preserve_kernel_backup_dir
			warn "failed to restore previous Mihomo kernel after install failure"
		fi
		if ! restore_user_state; then
			preserve_backup_dir
			err "failed to restore saved config and policy files"
		fi
	fi

	clear_kernel_backup
	warn "MihoWRT service was disabled because package install is incomplete"
	return 1
}

remove_user_state() {
	rm -f /etc/apk/protected_paths.d/mihowrt.list
	rm -f /etc/config/mihowrt
	rm -f /etc/init.d/mihowrt
	rm -f /etc/init.d/mihowrt-recover
	rm -f /opt/clash/config.yaml
	rm -f /opt/clash/lst/always_proxy_dst.txt
	rm -f /opt/clash/lst/always_proxy_src.txt
	rm -rf /opt/clash/ruleset
	rm -rf /opt/clash/proxy_providers
	rm -f /opt/clash/cache.db
	rm -f /usr/bin/mihowrt
	rm -rf /usr/lib/mihowrt
	rm -f /usr/share/luci/menu.d/luci-app-mihowrt.json
	rm -f /usr/share/rpcd/acl.d/luci-app-mihowrt.json
	rm -rf /www/luci-static/resources/view/mihowrt
	rm -rf /www/luci-static/resources/mihowrt
	rm -rf /tmp/clash
	rm -rf /tmp/mihowrt
	rm -rf /var/run/mihowrt
	rm -rf /etc/mihowrt
	rmdir /opt/clash/lst 2>/dev/null || true
	rmdir /opt/clash 2>/dev/null || true
}

remove_package_and_kernel() {
	release_reinstall_dependencies
	clear_skip_start

	if [ -x "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" disable >/dev/null 2>&1 || true
		"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
		wait_for_service_stop || true
	fi

	if [ -x "$ORCHESTRATOR" ]; then
		"$ORCHESTRATOR" cleanup >/dev/null 2>&1 || true
	fi

	cleanup_runtime_fallback
	restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults before removal"

	kernel_remove

	if package_installed; then
		log "Removing ${PKG_NAME} and unused dependencies..."
		apk del "$PKG_NAME" || {
			err "failed to remove ${PKG_NAME}"
			return 1
		}
	fi

	remove_user_state
	log "Removed MihoWRT package and kernel"
	return 0
}

start_fresh_install_service() {
	[ -x "$INIT_SCRIPT" ] || return 0

	log "Starting MihoWRT service..."
	"$INIT_SCRIPT" enable >/dev/null 2>&1 || true
	if "$INIT_SCRIPT" start >/dev/null 2>&1; then
		if wait_for_service_ready; then
			return 0
		fi
		warn "MihoWRT start returned success but service never became ready"
	fi

	warn "failed to start MihoWRT service after install"
	stop_service_instance
	cleanup_runtime_fallback
	restore_system_dns_defaults 1 || warn "failed to restore system DNS defaults after failed fresh start"
	"$INIT_SCRIPT" disable >/dev/null 2>&1 || true
	return 1
}

perform_package_action() {
	local reinstall=0
	local asset_url=""

	asset_url="$(latest_asset_url)" || {
		err "failed to query latest ${PKG_NAME} release"
		return 1
	}
	[ -n "$asset_url" ] || {
		err "failed to find latest ${PKG_NAME} apk in GitHub release"
		return 1
	}

	if package_installed; then
		reinstall=1
		log "Saving current config and policy state..."
		if ! prepare_update; then
			rollback_reinstall_state "$reinstall"
			return 1
		fi
	fi

	log "Installing/updating Mihomo kernel..."
	if ! kernel_install_or_update; then
		rollback_reinstall_state "$reinstall"
		err "kernel install/update failed"
		return 1
	fi

	if ! set_skip_start; then
		rollback_reinstall_state "$reinstall"
		err "failed to set skip-start marker"
		return 1
	fi

	if ! create_tmp_apk; then
		clear_skip_start
		rollback_reinstall_state "$reinstall"
		err "failed to allocate temporary apk path"
		return 1
	fi

	log "Downloading latest release asset..."
	if ! download_file "$asset_url" "$TMP_APK"; then
		clear_skip_start
		rollback_reinstall_state "$reinstall"
		err "failed to download latest ${PKG_NAME} apk"
		return 1
	fi
	if ! install_package "$reinstall" "$TMP_APK"; then
		handle_install_failure "$reinstall" "package install failed; some packages may be missing"
		return 1
	fi
	clear_skip_start

	if ! verify_required_packages; then
		handle_install_failure "$reinstall" "package install incomplete; missing packages: $MISSING_PACKAGES"
		return 1
	fi

	if [ "$reinstall" = "1" ]; then
		quiesce_postinstall_service
		log "Restoring saved config and policy state..."
		if ! restore_user_state; then
			if [ -x "$INIT_SCRIPT" ]; then
				"$INIT_SCRIPT" disable >/dev/null 2>&1 || true
			fi
			if kernel_backup_available; then
				if ! restore_kernel_backup; then
					preserve_kernel_backup_dir
					warn "failed to restore previous Mihomo kernel after user-state restore failure"
				fi
			fi
			preserve_backup_dir
			err "failed to restore saved config and policy state"
			return 1
		fi
		if ! restore_runtime_state; then
			if kernel_backup_available; then
				warn "runtime restore failed after kernel update; retrying with previous Mihomo kernel"
				restore_kernel_backup || {
					preserve_kernel_backup_dir
					err "failed to restore previous Mihomo kernel after runtime restore failure"
					return 1
				}
				restore_runtime_state || return 1
			else
				return 1
			fi
		fi
		clear_kernel_backup
		release_reinstall_dependencies
		return 0
	fi

	clear_kernel_backup
	start_fresh_install_service || return 1
	return 0
}

perform_kernel_action() {
	log "Installing/updating Mihomo kernel..."
	kernel_install_or_update
}

resolve_action() {
	case "${MIHOWRT_ACTION:-}" in
		'' )
			;;
		1|package|pkg|install|update)
			printf '%s' "package"
			return 0
			;;
		2|kernel|core)
			printf '%s' "kernel"
			return 0
			;;
		3|remove|delete|uninstall)
			printf '%s' "remove"
			return 0
			;;
		4|stop|cancel)
			printf '%s' "stop"
			return 0
			;;
		*)
			err "invalid MIHOWRT_ACTION: ${MIHOWRT_ACTION}"
			return 1
			;;
	esac

	if [ "${MIHOWRT_FORCE_REINSTALL:-0}" = "1" ]; then
		printf '%s' "package"
		return 0
	fi

	if ! can_prompt; then
		err "no tty. Set MIHOWRT_ACTION=package|kernel|remove|stop"
		return 1
	fi

	printf '%s\n' "MihoWRT installer" >/dev/tty
	printf '%s\n' "1. Install/update package + kernel" >/dev/tty
	printf '%s\n' "2. Install/update kernel only" >/dev/tty
	printf '%s\n' "3. Remove package + kernel" >/dev/tty
	printf '%s\n' "4. Stop" >/dev/tty

	while :; do
		printf 'Choose [1-4] (default 1): ' >/dev/tty
		IFS= read -r choice </dev/tty || {
			err "failed to read answer from tty"
			return 1
		}
		case "$choice" in
			''|1) printf '%s' "package"; return 0 ;;
			2) printf '%s' "kernel"; return 0 ;;
			3) printf '%s' "remove"; return 0 ;;
			4) printf '%s' "stop"; return 0 ;;
			*) printf '%s\n' "Enter 1, 2, 3, or 4." >/dev/tty ;;
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
		apk del "$PKG_NAME" || return 1
	fi

	apk add --allow-untrusted "$apk_path"
}

main() {
	local action=""

	require_command apk
	require_command mktemp

	action="$(resolve_action)" || exit 1

	case "$action" in
		package)
			perform_package_action
			;;
		kernel)
			perform_kernel_action
			;;
		remove)
			remove_package_and_kernel
			;;
		stop)
			log "Stopped."
			return 0
			;;
	esac
}

main "$@"
