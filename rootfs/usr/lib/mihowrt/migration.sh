#!/bin/ash

# One-time upgrade steps from 0.7.x. Every step is idempotent.

OLD_DNS_BACKUP_FILE="${OLD_DNS_BACKUP_FILE:-/etc/mihowrt/dns.backup}"
OLD_SUBSCRIPTION_OPTIONS="subscription_interval_override subscription_update_interval subscription_header_interval subscription_profile_title subscription_userinfo subscription_support_url subscription_web_page_url subscription_announce"

# 0.7 edited dnsmasq UCI. If it crashed, dnsmasq may still point at Mihomo.
migrate_dns_uci() {
	local section="dhcp.@dnsmasq[0]" servers="" line="" changed=0

	servers="$(uci -q get "$section.server" 2>/dev/null)" || servers=""
	case " $servers " in
	*" 127.0.0.1#$MIHOMO_DNS_PORT "*) ;;
	*)
		rm -f "$OLD_DNS_BACKUP_FILE"
		return 0
		;;
	esac

	uci -q delete "$section.server"
	if [ -r "$OLD_DNS_BACKUP_FILE" ]; then
		while IFS= read -r line; do
			case "$line" in
			ORIG_NORESOLV=?*) uci -q set "$section.noresolv=${line#*=}" ;;
			ORIG_NORESOLV=) uci -q delete "$section.noresolv" ;;
			ORIG_RESOLVFILE=?*) uci -q set "$section.resolvfile=${line#*=}" ;;
			ORIG_CACHESIZE=?*) uci -q set "$section.cachesize=${line#*=}" ;;
			ORIG_SERVER=?*)
				for line in ${line#ORIG_SERVER=}; do
					uci -q add_list "$section.server=$line"
				done
				;;
			esac
		done <"$OLD_DNS_BACKUP_FILE"
	else
		uci -q delete "$section.noresolv"
	fi
	uci -q commit dhcp && changed=1
	rm -f "$OLD_DNS_BACKUP_FILE"
	[ "$changed" -eq 1 ] && [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1
	log "Migrated dnsmasq settings left by MihoWRT 0.7"
}

migrate_settings() {
	local override="" hours="" option="" min=""

	[ -n "$(uci_get bypass_ntp)" ] || uci_set bypass_ntp 1
	[ -n "$(uci_get bypass_subscription_dns)" ] || uci_set bypass_subscription_dns 1

	override="$(uci_get subscription_interval_override)"
	hours="$(uci_get subscription_update_interval)"
	if [ "$override" = "1" ] && is_uint "$hours" && [ -z "$(uci_get subscription_interval)" ]; then
		uci_set subscription_interval "$hours"
	fi
	for option in $OLD_SUBSCRIPTION_OPTIONS; do
		uci -q delete "${PKG_CONFIG:-mihowrt}.settings.$option"
	done

	# The API secret is not taken from the YAML: the read ACL can read that
	# file. settings_ensure_generated creates a fresh one.

	if [ -z "$(uci_get lists_interval)" ]; then
		min="$({ cat "$DST_LIST_FILE" "$SRC_LIST_FILE" "$DIRECT_DST_LIST_FILE" 2>/dev/null || true; } |
			sed -n 's/^[^#]*|[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' |
			awk '$1 > 0 && (m == "" || $1 < m) { m = $1 } END { print m + 0 }')"
		uci_set lists_interval "${min:-0}"
	fi
	uci_commit
}

migrate_cron() {
	local file="${CRON_FILE:-/etc/crontabs/root}"

	grep -qE '# mihowrt (subscription|policy remote) auto-update' "$file" 2>/dev/null || return 0
	sed -i -e '/# mihowrt subscription auto-update/d' -e '/# mihowrt policy remote auto-update/d' "$file"
}

migrate() {
	migrate_dns_uci
	migrate_settings
	migrate_cron
	rm -f "$CLASH_DIR/mihomo.sock"
	settings_ensure_generated
}
