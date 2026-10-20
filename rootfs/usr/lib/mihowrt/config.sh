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

config_wait_ready() {
	local i=0

	while ! service_ready; do
		service_running || return 1
		[ "$i" -lt 30 ] || return 1
		sleep 1
		i=$((i + 1))
	done
}

config_runtime_reload() {
	runtime_config_build "$RUNTIME_CONFIG" && api_reload "$RUNTIME_CONFIG"
}

# Validate a candidate, back up the current config, install, hot reload.
# A failed reload restores the backup. Prints {"action": saved|hot_reloaded}.
config_install() {
	local candidate="$1" runtime_candidate="$PKG_TMP_DIR/runtime.candidate.yaml"

	settings_load || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	if ! { mihomo_config_generate "$candidate" "$runtime_candidate" && mihomo_config_test "$runtime_candidate"; }; then
		rm -f "$runtime_candidate"
		return 1
	fi
	[ -f "$CLASH_CONFIG" ] && cp -p "$CLASH_CONFIG" "$CLASH_CONFIG_BACKUP"
	if ! { cp "$candidate" "$CLASH_CONFIG.tmp" && chmod 600 "$CLASH_CONFIG.tmp" && mv -f "$CLASH_CONFIG.tmp" "$CLASH_CONFIG"; }; then
		rm -f "$CLASH_CONFIG.tmp" "$runtime_candidate"
		err "Cannot write $CLASH_CONFIG"
		return 1
	fi
	mv -f "$runtime_candidate" "$RUNTIME_CONFIG"

	if ! service_running; then
		echo '{"action":"saved"}'
		return 0
	fi
	# Mihomo may still be starting: wait for it instead of rolling back.
	config_wait_ready || {
		echo '{"action":"saved"}'
		return 0
	}
	if api_reload "$RUNTIME_CONFIG"; then
		log "Configuration hot-reloaded"
		echo '{"action":"hot_reloaded"}'
		return 0
	fi
	err "Mihomo rejected the new config at reload; restoring the previous one"
	if [ -f "$CLASH_CONFIG_BACKUP" ]; then
		cp -p "$CLASH_CONFIG_BACKUP" "$CLASH_CONFIG"
		config_runtime_reload || warn "Previous config reload failed too; restart the service"
	fi
	return 1
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
