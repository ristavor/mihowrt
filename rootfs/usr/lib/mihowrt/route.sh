#!/bin/ash

policy_route_state_read() {
	local line=""

	[ -f "$ROUTE_STATE_FILE" ] || return 1

	ROUTE_TABLE_ID_EFFECTIVE=""
	ROUTE_RULE_PRIORITY_EFFECTIVE=""
	while IFS= read -r line; do
		case "$line" in
			ROUTE_TABLE_ID=*)
				[ -z "$ROUTE_TABLE_ID_EFFECTIVE" ] && ROUTE_TABLE_ID_EFFECTIVE="${line#ROUTE_TABLE_ID=}"
				;;
			ROUTE_RULE_PRIORITY=*)
				[ -z "$ROUTE_RULE_PRIORITY_EFFECTIVE" ] && ROUTE_RULE_PRIORITY_EFFECTIVE="${line#ROUTE_RULE_PRIORITY=}"
				;;
		esac
	done < "$ROUTE_STATE_FILE"

	is_valid_route_table_id "$ROUTE_TABLE_ID_EFFECTIVE" || return 1
	is_valid_route_rule_priority "$ROUTE_RULE_PRIORITY_EFFECTIVE" || return 1
	return 0
}

policy_route_probe_state() {
	local state=0

	if "$@"; then
		printf '0\n'
		return 0
	else
		state=$?
	fi

	[ "$state" -eq 1 ] || return 1
	printf '1\n'
}

policy_route_table_id_in_use() {
	local route_table_id="$1"
	local table_state=""

	grep -qE "^[[:space:]]*${route_table_id}[[:space:]]+" "${ROUTE_TABLES_FILE:-/etc/iproute2/rt_tables}" 2>/dev/null && return 0
	table_state="$(policy_route_probe_state policy_route_table_has_entries "$route_table_id")" || return 0
	[ "$table_state" = "0" ]
}

policy_route_priority_in_use() {
	local route_rule_priority="$1"
	local rules_output=""

	rules_output="$(ip rule show 2>/dev/null)" || return 0
	printf '%s\n' "$rules_output" | awk -F: -v priority="$route_rule_priority" '$1 + 0 == priority { found=1 } END { exit(found ? 0 : 1) }'
}

policy_route_priority_conflicts() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rules_output="" mark="" mark_hex="" mark_dec=""

	[ -n "$route_table_id" ] || return 1
	[ -n "$route_rule_priority" ] || return 1
	have_command ip || return 2

	mark="$NFT_INTERCEPT_MARK"
	mark_hex="$(printf '0x%x' "$(( NFT_INTERCEPT_MARK ))")"
	mark_dec="$(( NFT_INTERCEPT_MARK ))"
	rules_output="$(ip rule show 2>/dev/null)" || return 2
	printf '%s\n' "$rules_output" | awk -v priority="$route_rule_priority" -v table="$route_table_id" -v mark="$mark" -v mark_hex="$mark_hex" -v mark_dec="$mark_dec" '
		$1 == priority ":" {
			table_match = (index($0, " lookup " table) || index($0, " table " table))
			mark_match = (index($0, " fwmark " mark "/" mark) || index($0, " fwmark " mark_hex "/" mark_hex) || index($0, " fwmark " mark_dec "/" mark_dec))
			if (table_match && mark_match) {
				next
			}
			conflict=1
		}
		END { exit(conflict ? 0 : 1) }
	'
}

policy_route_state_can_reuse() {
	local table_state="" priority_state=""

	if ! policy_route_state_read; then
		return 1
	fi

	table_state="$(policy_route_probe_state policy_route_table_has_foreign_entries "$ROUTE_TABLE_ID_EFFECTIVE")" || return 2
	case "$table_state" in
		0)
			warn "Route table $ROUTE_TABLE_ID_EFFECTIVE has foreign entries; selecting new table"
			return 1
			;;
		1)
			:
			;;
		*)
			return 2
			;;
	esac

	priority_state="$(policy_route_probe_state policy_route_priority_conflicts "$ROUTE_TABLE_ID_EFFECTIVE" "$ROUTE_RULE_PRIORITY_EFFECTIVE")" || return 2
	case "$priority_state" in
		0)
			warn "Route rule priority $ROUTE_RULE_PRIORITY_EFFECTIVE is occupied; selecting new priority"
			return 1
			;;
		1)
			return 0
			;;
		*)
			return 2
			;;
	esac
}

policy_route_drop_saved_state() {
	local route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
	local route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0
	policy_route_teardown_ids "$route_table_id" "$route_rule_priority" || return 1
	rm -f "$ROUTE_STATE_FILE"
}

policy_route_find_free_table_id() {
	local route_table_id="$ROUTE_TABLE_ID_AUTO_MIN"

	while [ "$route_table_id" -le "$ROUTE_TABLE_ID_AUTO_MAX" ]; do
		if ! policy_route_table_id_in_use "$route_table_id"; then
			printf '%s\n' "$route_table_id"
			return 0
		fi
		route_table_id=$((route_table_id + 1))
	done

	err "Unable to find free route table id"
	return 1
}

policy_route_find_free_priority() {
	local route_rule_priority="$ROUTE_RULE_PRIORITY_AUTO_MIN"

	while [ "$route_rule_priority" -le "$ROUTE_RULE_PRIORITY_AUTO_MAX" ]; do
		if ! policy_route_priority_in_use "$route_rule_priority"; then
			printf '%s\n' "$route_rule_priority"
			return 0
		fi
		route_rule_priority=$((route_rule_priority + 1))
	done

	err "Unable to find free route rule priority"
	return 1
}

policy_route_resolve_ids() {
	local route_table_id="$MIHOMO_ROUTE_TABLE_ID"
	local route_rule_priority="$MIHOMO_ROUTE_RULE_PRIORITY"
	local state_rc=1

	if [ -z "$route_table_id" ] || [ -z "$route_rule_priority" ]; then
		if policy_route_state_can_reuse; then
			state_rc=0
		else
			state_rc=$?
		fi
		case "$state_rc" in
			0)
				[ -n "$route_table_id" ] || route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
				[ -n "$route_rule_priority" ] || route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"
				;;
			2)
				return 1
				;;
		esac
	fi

	if [ -z "$route_table_id" ] || [ -z "$route_rule_priority" ]; then
		if policy_route_state_read; then
			policy_route_drop_saved_state || return 1
		fi
	fi

	[ -n "$route_table_id" ] || route_table_id="$(policy_route_find_free_table_id)" || return 1
	[ -n "$route_rule_priority" ] || route_rule_priority="$(policy_route_find_free_priority)" || return 1

	ROUTE_TABLE_ID_RESOLVED="$route_table_id"
	ROUTE_RULE_PRIORITY_RESOLVED="$route_rule_priority"
}

policy_route_resolve_table_id() {
	local route_table_id
	local state_rc=1

	if [ -n "$MIHOMO_ROUTE_TABLE_ID" ]; then
		printf '%s\n' "$MIHOMO_ROUTE_TABLE_ID"
		return 0
	fi

	if policy_route_state_can_reuse; then
		state_rc=0
	else
		state_rc=$?
	fi
	case "$state_rc" in
		0)
			printf '%s\n' "$ROUTE_TABLE_ID_EFFECTIVE"
			return 0
			;;
		2)
			return 1
			;;
	esac

	if policy_route_state_read; then
		policy_route_drop_saved_state || return 1
	fi

	policy_route_find_free_table_id
}

policy_route_resolve_priority() {
	local route_rule_priority
	local state_rc=1

	if [ -n "$MIHOMO_ROUTE_RULE_PRIORITY" ]; then
		printf '%s\n' "$MIHOMO_ROUTE_RULE_PRIORITY"
		return 0
	fi

	if policy_route_state_can_reuse; then
		state_rc=0
	else
		state_rc=$?
	fi
	case "$state_rc" in
		0)
			printf '%s\n' "$ROUTE_RULE_PRIORITY_EFFECTIVE"
			return 0
			;;
		2)
			return 1
			;;
	esac

	if policy_route_state_read; then
		policy_route_drop_saved_state || return 1
	fi

	policy_route_find_free_priority
}

policy_route_teardown_ids() {
	local route_table_id="$1"
	local route_rule_priority="$2"

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0
	have_command ip || return 1

	policy_route_delete_rule "$route_table_id" "$route_rule_priority" || return 1
	policy_route_delete_managed_route "$route_table_id" || return 1
	return 0
}

policy_route_rule_exists() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rules_output="" mark="" mark_hex="" mark_dec=""

	[ -n "$route_table_id" ] || return 1
	[ -n "$route_rule_priority" ] || return 1
	have_command ip || return 2

	mark="$NFT_INTERCEPT_MARK"
	mark_hex="$(printf '0x%x' "$(( NFT_INTERCEPT_MARK ))")"
	mark_dec="$(( NFT_INTERCEPT_MARK ))"
	rules_output="$(ip rule show 2>/dev/null)" || return 2
	printf '%s\n' "$rules_output" | awk -v priority="$route_rule_priority" -v table="$route_table_id" -v mark="$mark" -v mark_hex="$mark_hex" -v mark_dec="$mark_dec" '
		$1 == priority ":" &&
		(index($0, " lookup " table) || index($0, " table " table)) &&
		(index($0, " fwmark " mark "/" mark) || index($0, " fwmark " mark_hex "/" mark_hex) || index($0, " fwmark " mark_dec "/" mark_dec)) { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

policy_route_show_table() {
	local route_table_id="$1"
	local route_output="" route_rc=0

	if route_output="$(ip route show table "$route_table_id" 2>&1)"; then
		printf '%s\n' "$route_output"
		return 0
	else
		route_rc=$?
	fi

	case "$route_output" in
		*"FIB table does not exist"*|*"No such file"*|*"does not exist"*)
			return 0
			;;
	esac
	return "$route_rc"
}

policy_route_table_has_entries() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(policy_route_show_table "$route_table_id")" || return 2
	printf '%s\n' "$route_output" | grep -q .
}

policy_route_managed_route_exists() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(policy_route_show_table "$route_table_id")" || return 2
	printf '%s\n' "$route_output" | awk '
		$1 == "local" && ($2 == "0.0.0.0/0" || $2 == "default") {
			for (i = 3; i <= NF; i++) {
				if ($i == "dev" && (i + 1) <= NF && $(i + 1) == "lo") {
					found=1
				}
			}
		}
		END { exit(found ? 0 : 1) }
	'
}

policy_route_table_has_foreign_entries() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(policy_route_show_table "$route_table_id")" || return 2
	printf '%s\n' "$route_output" | awk '
		NF == 0 { next }
		$1 == "local" && ($2 == "0.0.0.0/0" || $2 == "default") {
			managed=0
			for (i = 3; i <= NF; i++) {
				if ($i == "dev" && (i + 1) <= NF && $(i + 1) == "lo") {
					managed=1
				}
			}
			if (managed) {
				next
			}
		}
		{ foreign=1 }
		END { exit(foreign ? 0 : 1) }
	'
}

policy_route_delete_managed_route() {
	local route_table_id="$1"
	local route_state=""

	[ -n "$route_table_id" ] || return 0

	route_state="$(policy_route_probe_state policy_route_managed_route_exists "$route_table_id")" || return 1
	[ "$route_state" = "1" ] && return 0

	while ip route del local 0.0.0.0/0 dev lo table "$route_table_id" 2>/dev/null; do :; done
	route_state="$(policy_route_probe_state policy_route_managed_route_exists "$route_table_id")" || return 1
	[ "$route_state" = "1" ]
}

policy_route_delete_rule() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rule_state=""

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0

	rule_state="$(policy_route_probe_state policy_route_rule_exists "$route_table_id" "$route_rule_priority")" || return 1
	[ "$rule_state" = "1" ] && return 0

	while ip rule del fwmark "$NFT_INTERCEPT_MARK"/"$NFT_INTERCEPT_MARK" table "$route_table_id" priority "$route_rule_priority" 2>/dev/null; do :; done
	rule_state="$(policy_route_probe_state policy_route_rule_exists "$route_table_id" "$route_rule_priority")" || return 1
	[ "$rule_state" = "1" ]
}

policy_route_setup() {
	local route_table_id route_rule_priority
	local table_state="" priority_state=""

	ROUTE_TABLE_ID_RESOLVED=""
	ROUTE_RULE_PRIORITY_RESOLVED=""
	policy_route_resolve_ids || return 1
	route_table_id="$ROUTE_TABLE_ID_RESOLVED"
	route_rule_priority="$ROUTE_RULE_PRIORITY_RESOLVED"

	table_state="$(policy_route_probe_state policy_route_table_has_foreign_entries "$route_table_id")" || return 1
	case "$table_state" in
		0)
			err "Route table $route_table_id has foreign entries"
			return 1
			;;
		1)
			:
			;;
		*)
			return 1
			;;
	esac

	priority_state="$(policy_route_probe_state policy_route_priority_conflicts "$route_table_id" "$route_rule_priority")" || return 1
	case "$priority_state" in
		0)
			err "Route rule priority $route_rule_priority is occupied"
			return 1
			;;
		1)
			:
			;;
		*)
			return 1
			;;
	esac

	policy_route_delete_rule "$route_table_id" "$route_rule_priority" || return 1
	ip route replace local 0.0.0.0/0 dev lo table "$route_table_id" 2>/dev/null || return 1
	ip rule add fwmark "$NFT_INTERCEPT_MARK"/"$NFT_INTERCEPT_MARK" table "$route_table_id" priority "$route_rule_priority" 2>/dev/null || {
		policy_route_teardown_ids "$route_table_id" "$route_rule_priority"
		return 1
	}

	ensure_dir "$PKG_STATE_DIR"
	if ! printf 'ROUTE_TABLE_ID=%s\nROUTE_RULE_PRIORITY=%s\n' "$route_table_id" "$route_rule_priority" > "$ROUTE_STATE_FILE"; then
		policy_route_teardown_ids "$route_table_id" "$route_rule_priority"
		return 1
	fi
	log "Installed policy routing for mark $NFT_INTERCEPT_MARK with table $route_table_id priority $route_rule_priority"
	return 0
}

policy_route_cleanup() {
	local route_table_id="" route_rule_priority=""
	local rule_state="" route_state="" had_live_state=0

	if policy_route_state_read; then
		route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
		route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"
	else
		route_table_id="$MIHOMO_ROUTE_TABLE_ID"
		route_rule_priority="$MIHOMO_ROUTE_RULE_PRIORITY"
	fi

	if [ -z "$route_table_id" ] || [ -z "$route_rule_priority" ]; then
		rm -f "$ROUTE_STATE_FILE"
		log "Policy routing for mark $NFT_INTERCEPT_MARK already clean"
		return 0
	fi

	rule_state="$(policy_route_probe_state policy_route_rule_exists "$route_table_id" "$route_rule_priority")" || return 1
	case "$rule_state" in
		0) had_live_state=1 ;;
		1) ;;
	esac

	route_state="$(policy_route_probe_state policy_route_managed_route_exists "$route_table_id")" || return 1
	case "$route_state" in
		0) had_live_state=1 ;;
		1) ;;
	esac

	policy_route_teardown_ids "$route_table_id" "$route_rule_priority" || return 1

	rm -f "$ROUTE_STATE_FILE"
	if [ "$had_live_state" -eq 1 ]; then
		log "Removed policy routing for mark $NFT_INTERCEPT_MARK"
	else
		log "Policy routing for mark $NFT_INTERCEPT_MARK already clean"
	fi
	return 0
}
