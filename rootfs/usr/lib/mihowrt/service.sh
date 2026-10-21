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
	ensure_dir "$PKG_PERSIST_DIR" && cp "$CACHE_DB_TMPFS" "$PKG_PERSIST_DIR/cache.db"
}

policy_apply() {
	if nft_apply && route_setup && dns_apply; then
		log "Policy applied ($POLICY_MODE)"
		return 0
	fi
	policy_cleanup
	return 1
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

# procd payload. Exit 0 = stopped on request; exit 1 = failure, procd respawns.
run_service() {
	local pid="" fails=0 stop=0 rc=1 memlimit="" degraded=0

	settings_load || return 1
	[ -s "$RUNTIME_CONFIG" ] || runtime_config_build "$RUNTIME_CONFIG" || return 1
	memlimit="$(mihomo_memory_limit)"
	trap 'stop=1; MIHOWRT_STOP=1' INT TERM HUP
	GOMEMLIMIT="${memlimit:-off}" SAFE_PATHS="$PKG_TMP_DIR" \
		"$CLASH_BIN" -d "$CLASH_DIR" -f "$RUNTIME_CONFIG" &
	pid=$!
	echo "$pid" >"$SERVICE_PID_FILE"

	if wait_for_ready "$pid" && with_lock policy_apply; then
		echo "$$" >"$RUNNING_MARKER"
		log "MihoWRT ready (Mihomo pid $pid)"
		rc=0
		while [ "$stop" -eq 0 ] && kill -0 "$pid" 2>/dev/null; do
			sleep "$WATCHDOG_INTERVAL" &
			wait $! 2>/dev/null
			[ "$stop" -eq 0 ] || break
			kill -0 "$pid" 2>/dev/null || break
			lock_busy && continue
			if api_dns_probe; then
				fails=0
				[ "$degraded" -eq 1 ] || continue
				if with_lock policy_apply; then
					echo "$$" >"$RUNNING_MARKER"
					degraded=0
					log "watchdog: Mihomo DNS recovered, policy restored"
				fi
				continue
			fi
			[ "$degraded" -eq 1 ] && ! api_alive && {
				err "watchdog: Mihomo does not answer; restarting"
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
				err "watchdog: Mihomo does not answer; restarting"
				rc=1
				break
			fi
			rm -f "$RUNNING_MARKER"
			with_lock policy_cleanup
			degraded=1
			warn "watchdog: Mihomo DNS unresponsive, traffic goes direct"
		done
		[ "$stop" -eq 1 ] || kill -0 "$pid" 2>/dev/null || {
			err "Mihomo exited unexpectedly"
			rc=1
		}
	else
		err "Mihomo did not become ready; router stays on direct routing"
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
	rm -f "$SERVICE_PID_FILE"
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
	# 0.7.x had no marker: also wait for its Mihomo to exit.
	while { { is_uint "$owner" && kill -0 "$owner" 2>/dev/null; } || service_running; } && [ "$i" -lt 35 ]; do
		sleep 1
		i=$((i + 1))
	done
	RUNTIME_LOCK_TIMEOUT=10 with_lock service_recover || service_recover
}

# Apply changed UCI settings to a running service.
service_reload() {
	local candidate="$PKG_TMP_DIR/config.candidate.yaml"

	settings_load || return 1
	cron_update || warn "Failed to update cron schedule"
	service_ready || return 0
	runtime_config_build "$candidate" || {
		rm -f "$candidate" "$candidate.profile"
		return 1
	}
	mv -f "$candidate.profile" "$PROFILE_FILE"
	if ! cmp -s "$candidate" "$RUNTIME_CONFIG"; then
		if ! { mv -f "$candidate" "$RUNTIME_CONFIG" && api_reload "$RUNTIME_CONFIG"; }; then
			err "Mihomo hot reload failed"
			return 1
		fi
	fi
	rm -f "$candidate"
	policy_apply
}

subscription_due() {
	local stamp="$PKG_STATE_DIR/subscription.stamp"

	[ "$SUBSCRIPTION_INTERVAL" -gt 0 ] && [ -n "$SUBSCRIPTION_URL" ] || return 1
	[ -f "$stamp" ] || return 0
	[ -n "$(find "$stamp" -mmin +$((SUBSCRIPTION_INTERVAL * 60 - 5)) 2>/dev/null)" ]
}

# Hourly cron entry: downloads run unlocked, applying takes the runtime lock.
auto_update() {
	settings_load || return 1
	if subscription_due; then
		subscription_update && touch "$PKG_STATE_DIR/subscription.stamp"
	fi
	if [ "$LISTS_INTERVAL" -gt 0 ] && [ "$(lists_update_remote 0)" = changed ] && service_running; then
		with_lock nft_apply
	fi
	return 0
}

# Install edited lists uploaded by LuCI (/tmp/mihowrt-policy-list.*) after
# validating every line. Runs under the runtime lock; prints 1 if changed.
lists_install() {
	local kind="" tmp="" bad="" url="" changed=0 dst=""

	for kind in dst src direct direct_src; do
		tmp="$1"
		shift
		upload_path_allowed /tmp/mihowrt-policy-list. "$tmp" || {
			err "List path not allowed: $tmp"
			return 1
		}
		bad="$({ lists_clean_lines "$tmp" | grep -v '^https\?://' || true; } | lists_classify 1 | tr '\n' ' ')"
		for url in $(lists_clean_lines "$tmp" | sed -n '/^https\?:\/\//p'); do
			is_http_url "${url%%;*}" && { [ "${url%%;*}" = "$url" ] || is_port_spec "${url#*;}"; } || bad="$bad$url "
		done
		[ -z "$bad" ] || {
			err "Invalid $kind entries: $bad"
			return 1
		}
		eval "LIST_TMP_$kind=\"\$tmp\""
	done
	for kind in dst src direct direct_src; do
		eval "tmp=\"\$LIST_TMP_$kind\""
		dst="$(lists_file "$kind")"
		if ! cmp -s "$tmp" "$dst"; then
			# Copy next to the target and rename: a full flash cannot leave
			# a half-written list.
			if ! { cp "$tmp" "$dst.new" && mv -f "$dst.new" "$dst"; }; then
				rm -f "$dst.new"
				return 1
			fi
			changed=1
		fi
	done
	settings_load && cron_update
	echo "$changed"
}

# apply-lists: install under the lock, fetch new remote URLs without it,
# then rebuild nft under the lock.
lists_apply() {
	local changed="" rc=0

	changed="$(with_lock lists_install "$@")" || rc=1
	rm -f "$1" "$2" "$3" "$4"
	[ "$rc" -eq 0 ] || return 1
	if service_ready; then
		settings_load || return 1
		lists_update_remote 0 >/dev/null || warn "Some remote lists could not be fetched"
		with_lock nft_apply || return 1
	fi
	jq -nc --arg c "$changed" '{changed: ($c == "1")}'
}

lists_refresh() {
	local result=""

	settings_load || return 1
	result="$(lists_update_remote 1)" || warn "Some remote lists could not be fetched"
	[ "$result" = changed ] && service_running && { with_lock nft_apply || return 1; }
	jq -nc --arg r "$result" '{changed: ($r == "changed")}'
}
