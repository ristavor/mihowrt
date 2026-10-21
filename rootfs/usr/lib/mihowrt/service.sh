#!/bin/ash

# Service lifecycle: layout, policy apply/cleanup, the procd payload with its
# DNS watchdog, reload and scheduled updates.

# Keep Mihomo's frequently written data in tmpfs; links stay in /opt/clash.
layout_link() {
	local link="$1" target="$2" kind="$3"

	if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
		[ "$kind" = file ] || ensure_dir "$target"
		return 0
	fi
	ensure_dir "$(dirname "$target")" || return 1
	if [ -d "$link" ] && [ ! -L "$link" ]; then
		ensure_dir "$target" && cp -a "$link"/. "$target"/ && rm -rf "$link" || return 1
	elif [ -f "$link" ] && [ ! -L "$link" ]; then
		mv -f "$link" "$target" || return 1
	fi
	[ "$kind" = file ] || ensure_dir "$target"
	ln -sfn "$target" "$link"
}

layout_init() {
	ensure_dir "$PKG_TMP_DIR" && ensure_dir "$PKG_STATE_DIR" || return 1
	ensure_dir "$(dirname "$MIHOMO_SOCKET_TMPFS")" && chmod 700 "$(dirname "$MIHOMO_SOCKET_TMPFS")" || return 1
	chmod 700 "$PKG_STATE_DIR" "$PKG_TMP_DIR" || return 1
	layout_link "$RULESET_LINK" "$RULESET_TMPFS" dir || return 1
	layout_link "$PROXY_PROVIDERS_LINK" "$PROXY_PROVIDERS_TMPFS" dir || return 1
	if [ ! -e "$CACHE_DB_TMPFS" ] && [ -f "$PKG_PERSIST_DIR/cache.db" ]; then
		cp "$PKG_PERSIST_DIR/cache.db" "$CACHE_DB_TMPFS"
	fi
	layout_link "$CACHE_DB_LINK" "$CACHE_DB_TMPFS" file || return 1
	lists_ensure_files
}

# Persist selected proxies across reboots; written only when changed.
cache_db_persist() {
	[ -f "$CACHE_DB_TMPFS" ] || return 0
	cmp -s "$CACHE_DB_TMPFS" "$PKG_PERSIST_DIR/cache.db" && return 0
	# Copy next to the target and rename: a power cut never leaves a torn file.
	ensure_dir "$PKG_PERSIST_DIR" || return 1
	if ! { cp "$CACHE_DB_TMPFS" "$PKG_PERSIST_DIR/cache.db.new" && mv -f "$PKG_PERSIST_DIR/cache.db.new" "$PKG_PERSIST_DIR/cache.db"; }; then
		rm -f "$PKG_PERSIST_DIR/cache.db.new"
		return 1
	fi
}

policy_apply() {
	settings_require || return 1

	if nft_apply && route_setup && dns_apply; then
		log "Policy applied ($POLICY_MODE)"
		return 0
	fi
	policy_cleanup
	return 1
}

# run_service is long-lived: reload settings, a cron update or a UCI change
# may have switched mode, DNS or lists since it started.
policy_reapply() {
	settings_load && policy_apply
}

policy_cleanup() {
	dns_cleanup
	nft_cleanup
	route_cleanup
	return 0
}

service_pid() {
	local pid=""

	pid="$(cat "$SERVICE_PID_FILE" 2>/dev/null)" || return 1
	is_uint "$pid" && kill -0 "$pid" 2>/dev/null || return 1
	grep -q "$CLASH_BIN" "/proc/$pid/cmdline" 2>/dev/null || return 1
	echo "$pid"
}

service_running() {
	service_pid >/dev/null
}

# Ready = policy applied to a live Mihomo (run_service writes the marker).
service_ready() {
	[ -f "$RUNNING_MARKER" ] && service_running
}

# Remove leftovers of a crashed or killed service. A Mihomo without its
# run-service supervisor is an orphan and is stopped too.
service_recover() {
	local pid=""

	pgrep -f "/usr/bin/mihowrt run-service" >/dev/null 2>&1 && return 0
	pid="$(service_pid)" && kill -9 "$pid" 2>/dev/null
	policy_cleanup
	rm -f "$RUNNING_MARKER" "$SERVICE_PID_FILE"
}

# Build and check a runtime config from $CLASH_CONFIG; remember the result.
runtime_config_build() {
	mihomo_config_generate "$CLASH_CONFIG" "$1" || return 1
	if mihomo_config_test "$1"; then
		config_check_record ok
		return 0
	fi
	config_check_record err
	return 1
}

cron_update() {
	settings_require || return 1

	local enabled=0

	[ "$SUBSCRIPTION_INTERVAL" -gt 0 ] && [ -n "$SUBSCRIPTION_URL" ] && enabled=1
	[ "$LISTS_INTERVAL" -gt 0 ] && [ -n "$(lists_urls)" ] && enabled=1
	cron_sync "$CRON_MARKER" "$enabled" "$CRON_MINUTE * * * * /usr/bin/mihowrt auto-update >/dev/null 2>&1"
}

# Everything that can fail before procd starts Mihomo, with clear errors.
service_prepare() {
	service_recover
	settings_ensure_generated && settings_load || return 1
	layout_init || return 1
	cron_update || warn "Failed to update cron schedule"
	runtime_config_build "$RUNTIME_CONFIG"
}

port_hex() {
	printf ':%04X' "$1"
}

port_listening() {
	local proto="$1" port="" file=""

	port="$(port_hex "$2")"
	for file in "/proc/net/$proto" "/proc/net/${proto}6"; do
		[ -r "$file" ] || continue
		awk -v p="$port" -v tcp="$([ "$proto" = tcp ] && echo 1)" \
			'$2 ~ p"$" && (!tcp || $4 == "0A") { f = 1 } END { exit !f }' "$file" && return 0
	done
	return 1
}

wait_for_ready() {
	local pid="$1" i=0

	while [ "$i" -lt 30 ]; do
		# Called from run_service: abort when a stop was requested.
		[ "${stop:-0}" -eq 0 ] || return 1
		kill -0 "$pid" 2>/dev/null || return 1
		port_listening tcp "$MIHOMO_TPROXY_PORT" && port_listening udp "$MIHOMO_DNS_PORT" && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

stop_child() {
	local pid="$1" i=0

	kill "$pid" 2>/dev/null || return 0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

mihomo_memory_limit() {
	awk '/^MemTotal:/ { print int($2 / 2048) "MiB" }' /proc/meminfo 2>/dev/null
}

service_error() {
	atomic_write "$LAST_ERROR_FILE" "$*"
	err "$*"
}

# procd payload. Exit 0 = stopped on request; exit 1 = failure, procd respawns.
run_service() {
	local pid="" fails=0 stop=0 rc=1 memlimit="" degraded=0 error=""

	# A long-lived supervisor must never retain its caller's lock.
	exec 9>&-
	LOCK_DEPTH=0

	ensure_dir "$PKG_STATE_DIR" || return 1
	rm -f "$HEALTH_FILE" "$DEGRADED_FILE"
	if ! { settings_load && { [ -s "$RUNTIME_CONFIG" ] || runtime_config_build "$RUNTIME_CONFIG"; }; } 2>"$LAST_ERROR_FILE.tmp.$$"; then
		cat "$LAST_ERROR_FILE.tmp.$$" >&2
		error="$(sed 's/^Error: //' "$LAST_ERROR_FILE.tmp.$$")"
		atomic_write "$LAST_ERROR_FILE" "${error:-MihoWRT could not start. See the system log.}"
		rm -f "$LAST_ERROR_FILE.tmp.$$"
		return 1
	fi
	cat "$LAST_ERROR_FILE.tmp.$$" >&2
	rm -f "$LAST_ERROR_FILE.tmp.$$"
	memlimit="$(mihomo_memory_limit)"
	trap 'stop=1; MIHOWRT_STOP=1' INT TERM HUP
	GOMEMLIMIT="${memlimit:-off}" SAFE_PATHS="$PKG_TMP_DIR" \
		"$CLASH_BIN" -d "$CLASH_DIR" -f "$RUNTIME_CONFIG" 9>&- &
	pid=$!
	echo "$pid" >"$SERVICE_PID_FILE"

	if wait_for_ready "$pid" && with_lock policy_reapply; then
		echo "$$" >"$RUNNING_MARKER"
		rm -f "$LAST_ERROR_FILE"
		log "MihoWRT ready (Mihomo pid $pid)"
		rc=0
		while [ "$stop" -eq 0 ] && kill -0 "$pid" 2>/dev/null; do
			sleep "$WATCHDOG_INTERVAL" 9>&- &
			wait $! 2>/dev/null
			[ "$stop" -eq 0 ] || break
			kill -0 "$pid" 2>/dev/null || break
			lock_busy && continue
			if api_dns_probe; then
				atomic_write "$HEALTH_FILE" ok
				fails=0
				[ "$degraded" -eq 1 ] || continue
				if with_lock policy_reapply; then
					echo "$$" >"$RUNNING_MARKER"
					degraded=0
					rm -f "$DEGRADED_FILE"
					log "watchdog: Mihomo DNS recovered, policy restored"
				fi
				continue
			fi
			atomic_write "$HEALTH_FILE" fail
			[ "$degraded" -eq 1 ] && ! api_alive && {
				service_error "watchdog: Mihomo does not answer; restarting"
				rc=1
				break
			}
			[ "$degraded" -eq 1 ] && continue
			fails=$((fails + 1))
			warn "watchdog: Mihomo DNS check failed ($fails/$WATCHDOG_FAILS)"
			[ "$fails" -ge "$WATCHDOG_FAILS" ] || continue
			# A live core with broken upstream DNS: go direct in place and
			# keep probing. A hung core is restarted by procd.
			if ! api_alive; then
				service_error "watchdog: Mihomo does not answer; restarting"
				rc=1
				break
			fi
			: >"$DEGRADED_FILE"
			rm -f "$RUNNING_MARKER"
			with_lock policy_cleanup
			degraded=1
			warn "watchdog: Mihomo DNS unresponsive, traffic goes direct"
		done
		[ "$stop" -eq 1 ] || kill -0 "$pid" 2>/dev/null || {
			service_error "Mihomo exited unexpectedly"
			rc=1
		}
	else
		service_error "Mihomo did not become ready; router stays on direct routing"
		rc=1
	fi

	trap - INT TERM HUP
	MIHOWRT_STOP=0
	# Restore direct DNS/routing first: a hung Mihomo may need SIGKILL. The
	# lock wait stays well below procd term_timeout (30 s).
	if RUNTIME_LOCK_TIMEOUT=10 lock_acquire; then
		rm -f "$RUNNING_MARKER"
		policy_cleanup
		lock_release
	else
		warn "Runtime lock busy at stop; cleaning up without it"
		rm -f "$RUNNING_MARKER"
		policy_cleanup
	fi
	stop_child "$pid"
	cache_db_persist
	rm -f "$SERVICE_PID_FILE" "$HEALTH_FILE" "$DEGRADED_FILE"
	[ "$stop" -eq 1 ] && {
		log "MihoWRT stopped"
		return 0
	}
	return "$rc"
}

# Called after procd sent the stop signal: wait until run-service finished its
# cleanup so `stop` is synchronous, then clear anything left behind.
service_wait_stopped() {
	local owner="" i=0

	owner="$(cat "$RUNNING_MARKER" 2>/dev/null)"
	# Also wait for a live Mihomo, even when the supervisor marker is gone.
	while { { is_uint "$owner" && kill -0 "$owner" 2>/dev/null; } || service_running; } && [ "$i" -lt 35 ]; do
		sleep 1
		i=$((i + 1))
	done
	RUNTIME_LOCK_TIMEOUT=10 with_lock service_recover || service_recover
}

# Apply changed UCI settings to a running service.
service_reload() {
	local candidate="$PKG_TMP_DIR/config.candidate.yaml" file=""

	settings_load || return 1
	cron_update || warn "Failed to update cron schedule"
	service_ready || return 0
	runtime_config_build "$candidate" || {
		rm -f "$candidate" "$candidate.profile"
		return 1
	}
	rm -f "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev"
	for file in "$RUNTIME_CONFIG" "$PROFILE_FILE"; do
		if [ -f "$file" ] && ! cp -p "$file" "$file.prev"; then
			rm -f "$candidate" "$candidate.profile" "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev"
			return 1
		fi
	done
	if ! { mv -f "$candidate.profile" "$PROFILE_FILE" &&
		{ cmp -s "$candidate" "$RUNTIME_CONFIG" ||
			{ mv -f "$candidate" "$RUNTIME_CONFIG" && api_reload "$RUNTIME_CONFIG"; }; }; }; then
		for file in "$RUNTIME_CONFIG" "$PROFILE_FILE"; do
			if [ -f "$file.prev" ]; then
				mv -f "$file.prev" "$file"
			else
				rm -f "$file"
			fi
		done
		rm -f "$candidate" "$candidate.profile"
		err "Mihomo hot reload failed"
		return 1
	fi
	rm -f "$candidate" "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev"
	policy_apply
}

# Hourly cron entry: downloads run unlocked, applying takes the runtime lock.
auto_update() {
	settings_load || return 1
	if subscription_due; then
		subscription_update && touch "$PKG_STATE_DIR/subscription.stamp"
	fi
	if [ "$LISTS_INTERVAL" -gt 0 ] && [ "$(lists_update_remote 0)" = changed ] && service_ready; then
		with_lock nft_apply
	fi
	return 0
}
