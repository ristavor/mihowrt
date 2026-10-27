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

# The YAML passed to Mihomo. Not started since boot: what it would get at
# start (built from the user's YAML, without the core test).
runtime_config_json() {
	# A preview is opened often; the real build at start logs the warnings.
	local scratch="" rc=0 MIHOWRT_QUIET=1

	if [ -r "$RUNTIME_CONFIG" ]; then
		sed 's/^secret: ".*"$/secret: "(hidden)"/' "$RUNTIME_CONFIG" | jq -Rs '{content: ., generated: false}'
		return
	fi
	settings_load || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	scratch="$(mktemp "$PKG_TMP_DIR/runtime-preview.XXXXXX")" || return 1
	if mihomo_config_generate "$CLASH_CONFIG" "$scratch"; then
		sed 's/^secret: ".*"$/secret: "(hidden)"/' "$scratch" | jq -Rs '{content: ., generated: true}' || rc=1
	else
		rc=1
	fi
	rm -f "$scratch" "$scratch.profile"
	return "$rc"
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

config_locked() {
	settings_load >/dev/null 2>&1 && config_api_wait
	with_lock "$@"
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

# Keep each saved inode until the entire rollback, including policy, succeeds.
config_install_restore_file() {
	local saved="$1" target="$2" staging="$2.restore.$$"

	if [ ! -f "$saved" ]; then
		rm -f "$target"
		return
	fi
	if { ln -f "$saved" "$staging" 2>/dev/null || cp -p "$saved" "$staging"; } && mv -f "$staging" "$target"; then
		return 0
	fi
	rm -f "$staging"
	return 1
}

# Restore the exact files saved before installation, not the older .bak.
config_install_restore() {
	local old_config="$1" old_runtime="$2" old_profile="$3" live="$4" same_runtime="$5"

	[ ! -f "$PROFILE_FILE" ] || mv -f "$PROFILE_FILE" "$old_profile.failed" || return 1
	config_install_restore_file "$old_config" "$CLASH_CONFIG" || return 1
	config_install_restore_file "$old_runtime" "$RUNTIME_CONFIG" || return 1
	config_install_restore_file "$old_profile" "$PROFILE_FILE" || return 1
	[ "$live" -eq 0 ] || [ "$same_runtime" -eq 1 ] || api_reload "$RUNTIME_CONFIG" || return 1
	config_profile_apply "$old_profile.failed"
}

# Validate a candidate, install, hot reload, then rotate the backup only on
# success. A failed reload or profile apply restores the pre-install state.
config_install() {
	local candidate="$1" runtime_candidate="$PKG_TMP_DIR/runtime.candidate.yaml"
	local old_profile="$PKG_TMP_DIR/profile.old" old_runtime="$PKG_TMP_DIR/runtime.old"
	local old_config="$CLASH_CONFIG.previous.$$" same_runtime=0 live=0 action=saved
	local error="" restore_error=""

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
	# Save the live profile before replacing YAML: status can rebuild it.
	# Hard links preserve YAML/runtime without another flash or tmpfs copy.
	rm -f "$old_profile" "$old_runtime" "$old_config"
	if ! {
		{ [ ! -f "$PROFILE_FILE" ] || cp "$PROFILE_FILE" "$old_profile"; } &&
			{ [ ! -f "$RUNTIME_CONFIG" ] || ln -f "$RUNTIME_CONFIG" "$old_runtime" 2>/dev/null || cp -p "$RUNTIME_CONFIG" "$old_runtime"; } &&
			{ [ ! -f "$CLASH_CONFIG" ] || ln -f "$CLASH_CONFIG" "$old_config" 2>/dev/null || cp -p "$CLASH_CONFIG" "$old_config"; }
	}; then
		rm -f "$old_profile" "$old_runtime" "$old_config" "$runtime_candidate" "$runtime_candidate.profile"
		err "Cannot back up $CLASH_CONFIG"
		return 1
	fi
	if ! { cp "$candidate" "$CLASH_CONFIG.tmp" && chmod 600 "$CLASH_CONFIG.tmp" && mv -f "$CLASH_CONFIG.tmp" "$CLASH_CONFIG"; }; then
		rm -f "$CLASH_CONFIG.tmp" "$runtime_candidate" "$runtime_candidate.profile" "$old_profile" "$old_runtime" "$old_config"
		err "Cannot write $CLASH_CONFIG"
		return 1
	fi
	config_check_record ok
	# Only x-mihowrt changed: Mihomo keeps running without a reload pause.
	cmp -s "$runtime_candidate" "$RUNTIME_CONFIG" && same_runtime=1
	if ! { mv -f "$runtime_candidate" "$RUNTIME_CONFIG" && mv -f "$runtime_candidate.profile" "$PROFILE_FILE" && touch "$PROFILE_FILE"; }; then
		error="Cannot publish the runtime config"
	fi
	if service_running && api_alive; then
		live=1
		action=hot_reloaded
		if [ -z "$error" ] && [ "$same_runtime" -eq 0 ]; then
			if error="$(api_reload "$RUNTIME_CONFIG" 2>&1)"; then
				error=""
			else
				error="${error:-Mihomo rejected the new config at reload}"
			fi
		fi
	fi
	if [ -z "$error" ]; then
		if error="$(config_profile_apply "$old_profile" 2>&1)"; then
			error=""
		else
			error="${error:-Failed to apply policy}"
		fi
	fi
	if [ -n "$error" ]; then
		error="$(printf '%s\n' "$error" | sed 's/^Error: //')"
		if restore_error="$(config_install_restore "$old_config" "$old_runtime" "$old_profile" "$live" "$same_runtime" 2>&1)"; then
			err "Failed to apply the new subscription settings: $error; the previous config is restored"
			rm -f "$old_profile" "$old_profile.failed" "$old_runtime" "$old_config"
		else
			restore_error="$(printf '%s\n' "$restore_error" | sed 's/^Error: //')"
			err "Failed to apply the new subscription settings: $error; restoring the previous config failed: ${restore_error:-Failed to restore config or policy}; the previous config is saved in $old_config"
		fi
		rm -f "$runtime_candidate" "$runtime_candidate.profile"
		return 1
	fi
	if [ -f "$old_config" ]; then
		mv -f "$old_config" "$CLASH_CONFIG_BACKUP" || {
			rm -f "$old_profile" "$old_runtime"
			err "Cannot rotate $CLASH_CONFIG_BACKUP"
			return 1
		}
	fi
	rm -f "$old_profile" "$old_runtime"
	[ "$action" != hot_reloaded ] || [ "$same_runtime" -eq 1 ] || log "Configuration hot-reloaded"
	printf '{"action":"%s"}\n' "$action"
}

config_has_keys() {
	yaml_has_top_key '[A-Za-z0-9_-]+' "$1"
}

config_save() {
	local tmp="$1" rc=0

	config_temp_path_allowed "$tmp" || {
		err "Config path not allowed: $tmp"
		return 1
	}
	if [ "$(wc -c <"$tmp")" -gt "$SUBSCRIPTION_MAX_BYTES" ]; then
		err "The YAML is larger than 8 MiB."
		rm -f "$tmp"
		return 1
	fi
	if ! config_has_keys "$tmp"; then
		err "The YAML is empty: nothing was changed."
		rm -f "$tmp"
		return 1
	fi
	config_install "$tmp" || rc=$?
	rm -f "$tmp"
	return "$rc"
}

# Install a copy: config_install replaces the backup with the current YAML.
config_restore() {
	local candidate="" rc=0

	[ -f "$CLASH_CONFIG_BACKUP" ] || {
		err "There is no previous configuration."
		return 1
	}
	ensure_dir "$PKG_TMP_DIR" || return 1
	candidate="$(mktemp "$PKG_TMP_DIR/restore.XXXXXX")" || return 1
	if cp "$CLASH_CONFIG_BACKUP" "$candidate"; then
		config_install "$candidate" || rc=$?
	else
		rc=1
	fi
	rm -f "$candidate"
	return "$rc"
}
