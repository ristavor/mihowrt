#!/bin/ash

# Policy routing: packets with the intercept mark are delivered locally so the
# TPROXY socket can take them. Table id and rule priority are picked from free
# ranges and remembered in $ROUTE_STATE_FILE for cleanup.

route_families() {
	echo 4
	[ -e /proc/net/if_inet6 ] && echo 6
	return 0
}

route_state_read() {
	ROUTE_TABLE=""
	ROUTE_PRIORITY=""
	[ -r "$ROUTE_STATE_FILE" ] || return 1
	ROUTE_TABLE="$(sed -n 's/^TABLE=//p' "$ROUTE_STATE_FILE")"
	ROUTE_PRIORITY="$(sed -n 's/^PRIORITY=//p' "$ROUTE_STATE_FILE")"
	# 0.7.x state keys, for upgrades while the old service is running.
	[ -n "$ROUTE_TABLE" ] || ROUTE_TABLE="$(sed -n 's/^ROUTE_TABLE_ID=//p' "$ROUTE_STATE_FILE")"
	[ -n "$ROUTE_PRIORITY" ] || ROUTE_PRIORITY="$(sed -n 's/^ROUTE_RULE_PRIORITY=//p' "$ROUTE_STATE_FILE")"
	is_uint "$ROUTE_TABLE" && is_uint "$ROUTE_PRIORITY"
}

# Print the first value in [min,max] that does not appear in the used list.
route_first_free() {
	local min="$1" max="$2" used="$3" value="$1"

	while [ "$value" -le "$max" ]; do
		case " $used " in
		*" $value "*) ;;
		*)
			echo "$value"
			return 0
			;;
		esac
		value=$((value + 1))
	done
	return 1
}

route_allocate() {
	local fam="" used_tables="" used_prios=""

	for fam in $(route_families); do
		used_tables="$used_tables $(ip -"$fam" route show table all 2>/dev/null | sed -n 's/.* table \([0-9]*\).*/\1/p' | sort -u | tr '\n' ' ')"
		used_tables="$used_tables $(ip -"$fam" rule show 2>/dev/null | sed -n 's/.* lookup \([0-9]*\).*/\1/p' | tr '\n' ' ')"
		used_prios="$used_prios $(ip -"$fam" rule show 2>/dev/null | sed -n 's/^\([0-9]*\):.*/\1/p' | tr '\n' ' ')"
	done
	ROUTE_TABLE="$(route_first_free "$ROUTE_TABLE_ID_AUTO_MIN" "$ROUTE_TABLE_ID_AUTO_MAX" "$used_tables")" || {
		err "No free routing table id in $ROUTE_TABLE_ID_AUTO_MIN-$ROUTE_TABLE_ID_AUTO_MAX"
		return 1
	}
	ROUTE_PRIORITY="$(route_first_free "$ROUTE_RULE_PRIORITY_AUTO_MIN" "$ROUTE_RULE_PRIORITY_AUTO_MAX" "$used_prios")" || {
		err "No free ip rule priority in $ROUTE_RULE_PRIORITY_AUTO_MIN-$ROUTE_RULE_PRIORITY_AUTO_MAX"
		return 1
	}
}

route_setup() {
	local fam="" mark="$NFT_INTERCEPT_MARK"

	route_state_read || route_allocate || return 1
	ensure_dir "$(dirname "$ROUTE_STATE_FILE")" || return 1
	printf 'TABLE=%s\nPRIORITY=%s\n' "$ROUTE_TABLE" "$ROUTE_PRIORITY" >"$ROUTE_STATE_FILE" || return 1
	for fam in $(route_families); do
		ip -"$fam" route replace local default dev lo table "$ROUTE_TABLE" || {
			err "Failed to add IPv$fam local route to table $ROUTE_TABLE"
			return 1
		}
		route_rule_present "$fam" && continue
		ip -"$fam" rule add fwmark "$mark/$mark" lookup "$ROUTE_TABLE" priority "$ROUTE_PRIORITY" || {
			err "Failed to add IPv$fam policy rule"
			return 1
		}
	done
	log "Policy routing: mark $mark -> table $ROUTE_TABLE (priority $ROUTE_PRIORITY)"
}

route_cleanup() {
	local fam="" mark=""

	route_state_read || return 0
	for fam in $(route_families); do
		for mark in "$NFT_INTERCEPT_MARK" "$OLD_NFT_INTERCEPT_MARK"; do
			while ip -"$fam" rule del fwmark "$mark/$mark" lookup "$ROUTE_TABLE" priority "$ROUTE_PRIORITY" 2>/dev/null; do :; done
		done
		ip -"$fam" route flush table "$ROUTE_TABLE" 2>/dev/null
	done
	rm -f "$ROUTE_STATE_FILE"
	log "Policy routing removed (table $ROUTE_TABLE)"
}

# BusyBox/ip-tiny lack "ip rule show priority N", so match the listing.
route_rule_present() {
	ip -"$1" rule show 2>/dev/null | grep -q "^$ROUTE_PRIORITY:.* lookup $ROUTE_TABLE"
}

route_active() {
	route_state_read && route_rule_present 4
}
