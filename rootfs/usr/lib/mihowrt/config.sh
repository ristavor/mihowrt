#!/bin/ash

# The user's YAML: read, validate, install with backup, hot reload.

# Uploads from LuCI land in /tmp/mihowrt-config.* (file ACL); nothing else.
config_temp_path_allowed() {
	upload_path_allowed /tmp/mihowrt-config. "$1"
}

config_read_json() {
	local path="${1:-$CLASH_CONFIG}"

	[ "$path" = "$CLASH_CONFIG" ] || config_temp_path_allowed "$path" || {
		err "Config path not allowed: $path"
		return 1
	}
	if [ -r "$path" ]; then
		# shellcheck disable=SC2094 # $path is only read
		jq -Rs --arg p "$path" '{path: $p, content: .}' <"$path"
	else
		jq -nc --arg p "$path" '{path: $p, content: ""}'
	fi
}

# Wait without the lock for a starting Mihomo's API: run_service needs the
# lock to apply policy, so waiting inside it could stall both for 30 s.
config_api_wait() {
	local i=0

	while service_running && ! api_alive; do
		[ "$i" -lt 30 ] || return 1
		sleep 1
		i=$((i + 1))
	done
	return 0
}

config_runtime_reload() {
	runtime_config_build "$RUNTIME_CONFIG" && api_reload "$RUNTIME_CONFIG"
}

# The profile (mode, DNS, provider settings and lists) changed: re-apply
# schedule and policy. A DNS mode switch also flushes the dnsmasq cache so
# clients do not keep fake-IP answers.
config_profile_apply() {
	local old="$1" old_dns=""

	cmp -s "$old" "$PROFILE_FILE" && return 0
	old_dns="$(sed -n 's/^dns //p' "$old" 2>/dev/null)"
	settings_load || return 1
	cron_update || warn "Failed to update cron schedule"
	service_ready || return 0
	policy_apply || return 1
	if [ -n "$old_dns" ] && [ "$old_dns" != "$DNS_MODE" ]; then
		dns_restart_dnsmasq
		log "DNS mode changed ($old_dns -> $DNS_MODE): dnsmasq cache flushed"
	fi
	return 0
}

# Validate a candidate, back up the current config, install, hot reload.
# A failed reload restores the backup. Prints {"action": ...}: unchanged
# (nothing written), saved or hot_reloaded.
config_install() {
	local candidate="$1" runtime_candidate="$PKG_TMP_DIR/runtime.candidate.yaml"
	local old_profile="$PKG_TMP_DIR/profile.old" same_runtime=0

	# Same bytes: spare the flash and the reload.
	if [ -f "$CLASH_CONFIG" ] && cmp -s "$candidate" "$CLASH_CONFIG"; then
		echo '{"action":"unchanged"}'
		return 0
	fi
	settings_load || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	if ! { mihomo_config_generate "$candidate" "$runtime_candidate" && mihomo_config_test "$runtime_candidate"; }; then
		rm -f "$runtime_candidate" "$runtime_candidate.profile"
		return 1
	fi
	[ -f "$CLASH_CONFIG" ] && cp -p "$CLASH_CONFIG" "$CLASH_CONFIG_BACKUP"
	if ! { cp "$candidate" "$CLASH_CONFIG.tmp" && chmod 600 "$CLASH_CONFIG.tmp" && mv -f "$CLASH_CONFIG.tmp" "$CLASH_CONFIG"; }; then
		rm -f "$CLASH_CONFIG.tmp" "$runtime_candidate" "$runtime_candidate.profile"
		err "Cannot write $CLASH_CONFIG"
		return 1
	fi
	config_check_record ok
	# Only x-mihowrt changed: Mihomo keeps running without a reload pause.
	cmp -s "$runtime_candidate" "$RUNTIME_CONFIG" && same_runtime=1
	rm -f "$old_profile"
	[ -f "$PROFILE_FILE" ] && cp "$PROFILE_FILE" "$old_profile"
	mv -f "$runtime_candidate" "$RUNTIME_CONFIG"
	mv -f "$runtime_candidate.profile" "$PROFILE_FILE" && touch "$PROFILE_FILE"

	if ! service_running || ! api_alive; then
		config_profile_apply "$old_profile" || warn "Failed to apply the new subscription settings"
		rm -f "$old_profile"
		echo '{"action":"saved"}'
		return 0
	fi
	if [ "$same_runtime" -eq 0 ] && ! api_reload "$RUNTIME_CONFIG"; then
		rm -f "$old_profile"
		err "Mihomo rejected the new config at reload; restoring the previous one"
		if [ -f "$CLASH_CONFIG_BACKUP" ]; then
			cp -p "$CLASH_CONFIG_BACKUP" "$CLASH_CONFIG"
			config_runtime_reload || warn "Previous config reload failed too; restart the service"
		fi
		return 1
	fi
	[ "$same_runtime" -eq 1 ] || log "Configuration hot-reloaded"
	config_profile_apply "$old_profile" || warn "Failed to apply the new subscription settings"
	rm -f "$old_profile"
	echo '{"action":"hot_reloaded"}'
}

config_save() {
	local tmp="$1" rc=0

	config_temp_path_allowed "$tmp" || {
		err "Config path not allowed: $tmp"
		return 1
	}
	config_install "$tmp" || rc=$?
	rm -f "$tmp"
	return "$rc"
}
