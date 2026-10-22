#!/bin/ash

# One-time upgrade steps from 0.7.x and 0.8.x. Every step is idempotent.

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
	[ "$changed" -eq 1 ] && [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart 9>&- >/dev/null 2>&1
	log "Migrated dnsmasq settings left by MihoWRT 0.7"
}

migrate_settings() {
	local override="" hours="" option="" min=""

	# Traffic flags are saved with rmempty=false: write the defaults now, so the
	# first Save & Apply without edits changes no UCI option.
	[ -n "$(uci_get dns_hijack)" ] || uci_set dns_hijack 1
	[ -n "$(uci_get disable_quic)" ] || uci_set disable_quic 1
	[ -n "$(uci_get netbird_proxy)" ] || uci_set netbird_proxy 0
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

	# 0.9: auto-update is on/off, the provider sets the period. The mode
	# follows the YAML DNS settings.
	if uci -q get "${PKG_CONFIG:-mihowrt}.settings.subscription_interval" >/dev/null 2>&1; then
		if [ "$(uci_get subscription_interval)" = "0" ]; then
			uci_set subscription_auto_update 0
		else
			uci_set subscription_auto_update 1
		fi
		uci -q delete "${PKG_CONFIG:-mihowrt}.settings.subscription_interval"
	fi
	[ -n "$(uci_get subscription_auto_update)" ] || uci_set subscription_auto_update 1
	uci -q delete "${PKG_CONFIG:-mihowrt}.settings.policy_mode"

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

# Legacy route state is data, never shell code. Current state stays untouched.
migrate_route_07() {
	local table="" priority="" fam="" mark="" legacy_table="" legacy_priority="" old_mark="0x00001000"

	if [ -r "$ROUTE_STATE_FILE" ]; then
		legacy_table="$(sed -n 's/^ROUTE_TABLE_ID=//p' "$ROUTE_STATE_FILE")"
		legacy_priority="$(sed -n 's/^ROUTE_RULE_PRIORITY=//p' "$ROUTE_STATE_FILE")"
	fi
	if is_uint "$legacy_table" && is_uint "$legacy_priority"; then
		legacy_table="$(uint_norm "$legacy_table")"
		legacy_priority="$(uint_norm "$legacy_priority")"
		if [ "$legacy_table" -lt "$ROUTE_TABLE_ID_AUTO_MIN" ] || [ "$legacy_table" -gt "$ROUTE_TABLE_ID_AUTO_MAX" ]; then
			legacy_table=""
		fi
	else
		legacy_table=""
	fi
	for fam in 4 6; do
		[ "$fam" = 4 ] || [ -e /proc/net/if_inet6 ] || continue
		# ip-tiny supports listing all rules, not filtering by priority.
		ip -"$fam" rule show 2>/dev/null | awk '
			{
				mark = table = ""
				for (i = 1; i < NF; i++) {
					if ($i == "fwmark") mark = $(i + 1)
					if ($i == "lookup") table = $(i + 1)
				}
				priority = $1; sub(/:$/, "", priority)
				if (mark ~ /^0x0*1000(\/0x0*1000)?$/ && table ~ /^[0-9]+$/ && priority ~ /^[0-9]+$/)
					print priority, mark, table
			}' | while read -r priority mark table; do
			priority="$(uint_norm "$priority")"
			table="$(uint_norm "$table")"
			[ "$table" -ge "$ROUTE_TABLE_ID_AUTO_MIN" ] && [ "$table" -le "$ROUTE_TABLE_ID_AUTO_MAX" ] || continue
			while ip -"$fam" rule del fwmark "$mark" lookup "$table" priority "$priority" 2>/dev/null; do :; done
			ip -"$fam" route flush table "$table" 2>/dev/null
		done
		if [ -n "$legacy_table" ]; then
			while ip -"$fam" rule del fwmark "$old_mark/$old_mark" lookup "$legacy_table" priority "$legacy_priority" 2>/dev/null; do :; done
			ip -"$fam" route flush table "$legacy_table" 2>/dev/null
		fi
	done
	[ -z "$legacy_table" ] || rm -f "$ROUTE_STATE_FILE"
	return 0
}

migrate_list_suffix() {
	local file=""

	for file in "$DST_LIST_FILE" "$SRC_LIST_FILE" "$DIRECT_DST_LIST_FILE" "$DIRECT_SRC_LIST_FILE"; do
		[ -f "$file" ] || continue
		awk '
			/^[[:space:]]*#/ { next }
			/\|[[:space:]]*[0-9]+[[:space:]]*$/ { found = 1 }
			END { exit !found }
		' "$file" || continue
		if cp -p "$file" "$file.tmp" &&
			sed '/^[[:space:]]*#/!s/[[:space:]]*|[[:space:]]*[0-9][0-9]*[[:space:]]*$//' "$file" >"$file.tmp"; then
			mv "$file.tmp" "$file" || return 1
		else
			rm -f "$file.tmp"
			return 1
		fi
	done
	return 0
}

migrate_cron() {
	local file="${CRON_FILE:-/etc/crontabs/root}"

	grep -qE '# mihowrt (subscription|policy remote) auto-update' "$file" 2>/dev/null || return 0
	sed -i -e '/# mihowrt subscription auto-update/d' -e '/# mihowrt policy remote auto-update/d' "$file"
}

# 0.7 list templates described an IPv4-only ":port" syntax. Drop exactly
# those leading template lines; user entries and comments stay.
migrate_list_headers() {
	local file=""

	for file in "$DST_LIST_FILE" "$SRC_LIST_FILE" "$DIRECT_DST_LIST_FILE"; do
		[ "$(head -n 1 "$file" 2>/dev/null)" = "# One IPv4 or CIDR per line. Optional :port, :port-port, or :port,port." ] || continue
		if awk '
			BEGIN {
				n = split("# One IPv4 or CIDR per line. Optional :port, :port-port, or :port,port.|# Use :port without IP to match any IPv4 client.|# Use :port without IP to match any IPv4 destination.|# Use :port without IP to bypass any non-local IPv4 destination on that port.|# Matching non-local destinations bypass Mihomo in proxy-first mode.|# DNS/53 hijack still goes to Mihomo DNS when enabled.|# Domain flows resolved to fake-ip are still handled by Mihomo.|# Example:|# 1.1.1.1|# 8.8.8.0/24|# 8.8.8.8|# 9.9.9.0/24|# :443|# 192.168.1.10|# 192.168.1.32/27", a, "|")
				for (i = 1; i <= n; i++) old[a[i]] = 1
			}
			head && ($0 in old) { next }
			{ head = 0; print }
		' head=1 "$file" >"$file.tmp"; then
			mv "$file.tmp" "$file"
		else
			rm -f "$file.tmp"
		fi
	done
}

migrate() {
	# Never follow or reuse the pre-flock symlink, even with a live old pid.
	rm -f "$PKG_STATE_DIR/runtime.lock"
	migrate_dns_uci
	migrate_settings
	migrate_route_07
	migrate_list_suffix || return 1
	migrate_cron
	migrate_list_headers
	rm -f "$CLASH_DIR/mihomo.sock"
	settings_ensure_generated
}
