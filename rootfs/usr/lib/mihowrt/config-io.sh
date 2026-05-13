#!/bin/ash

# Clean one simple YAML scalar enough for the fields MihoWRT needs. Full YAML
# validation is still delegated to Mihomo before writes are applied.
yaml_cleanup_scalar() {
	local value="$1"
	local out="" char="" prev="" in_single=0 in_double=0

	value="$(trim "$value")"

	while [ -n "$value" ]; do
		char="${value%"${value#?}"}"
		value="${value#?}"

		case "$char" in
		"'")
			if [ "$in_double" -eq 0 ]; then
				if [ "$in_single" -eq 1 ]; then
					in_single=0
				else
					in_single=1
				fi
			fi
			;;
		'"')
			if [ "$in_single" -eq 0 ] && [ "$prev" != "\\" ]; then
				if [ "$in_double" -eq 1 ]; then
					in_double=0
				else
					in_double=1
				fi
			fi
			;;
		'#')
			if [ "$in_single" -eq 0 ] && [ "$in_double" -eq 0 ]; then
				case "$prev" in
				'' | [[:space:]])
					break
					;;
				esac
			fi
			;;
		esac

		out="${out}${char}"
		prev="$char"
	done

	value="$(trim "$out")"

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

	value="$(trim "$value")"
	printf '%s' "$value"
}

# Extract only router-integration scalar fields from Mihomo config. This avoids
# inventing a full YAML parser in ash while keeping Mihomo as syntax authority.
yaml_get_selected_scalars() {
	local file="$1"

	awk '
		function emit(key, line) {
			if (!seen[key]) {
				print key "\t" line
				seen[key] = 1
			}
		}

		/^dns:[[:space:]]*($|#)/ {
			in_dns = 1
			next
		}

		{
			if (in_dns && $0 ~ /^[^[:space:]#][^:]*:[[:space:]]*/) {
				in_dns = 0
			}

			if (in_dns) {
				line = $0
				if (line ~ /^[[:space:]]+listen:[[:space:]]*/) {
					sub("^[[:space:]]+listen:[[:space:]]*", "", line)
					emit("dns.listen", line)
					next
				}
				if (line ~ /^[[:space:]]+enhanced-mode:[[:space:]]*/) {
					sub("^[[:space:]]+enhanced-mode:[[:space:]]*", "", line)
					emit("dns.enhanced-mode", line)
					next
				}
				if (line ~ /^[[:space:]]+fake-ip-range:[[:space:]]*/) {
					sub("^[[:space:]]+fake-ip-range:[[:space:]]*", "", line)
					emit("dns.fake-ip-range", line)
					next
				}
			}

			line = $0
			if (line ~ /^port:[[:space:]]*/) {
				sub("^port:[[:space:]]*", "", line)
				emit("port", line)
				next
			}
			if (line ~ /^socks-port:[[:space:]]*/) {
				sub("^socks-port:[[:space:]]*", "", line)
				emit("socks-port", line)
				next
			}
			if (line ~ /^mixed-port:[[:space:]]*/) {
				sub("^mixed-port:[[:space:]]*", "", line)
				emit("mixed-port", line)
				next
			}
			if (line ~ /^redir-port:[[:space:]]*/) {
				sub("^redir-port:[[:space:]]*", "", line)
				emit("redir-port", line)
				next
			}
			if (line ~ /^tproxy-port:[[:space:]]*/) {
				sub("^tproxy-port:[[:space:]]*", "", line)
				emit("tproxy-port", line)
				next
			}
			if (line ~ /^routing-mark:[[:space:]]*/) {
				sub("^routing-mark:[[:space:]]*", "", line)
				emit("routing-mark", line)
				next
			}
			if (line ~ /^external-controller:[[:space:]]*/) {
				sub("^external-controller:[[:space:]]*", "", line)
				emit("external-controller", line)
				next
			}
			if (line ~ /^external-controller-tls:[[:space:]]*/) {
				sub("^external-controller-tls:[[:space:]]*", "", line)
				emit("external-controller-tls", line)
				next
			}
			if (line ~ /^external-controller-unix:[[:space:]]*/) {
				sub("^external-controller-unix:[[:space:]]*", "", line)
				emit("external-controller-unix", line)
				next
			}
			if (line ~ /^secret:[[:space:]]*/) {
				sub("^secret:[[:space:]]*", "", line)
				emit("secret", line)
				next
			}
			if (line ~ /^external-ui:[[:space:]]*/) {
				sub("^external-ui:[[:space:]]*", "", line)
				emit("external-ui", line)
				next
			}
			if (line ~ /^external-ui-name:[[:space:]]*/) {
				sub("^external-ui-name:[[:space:]]*", "", line)
				emit("external-ui-name", line)
				next
			}
		}
	' "$file" 2>/dev/null
}

# Accumulate config parsing errors into a newline-delimited string that jq later
# turns into an array.
append_error() {
	local message="$1"

	if [ -n "$ERRORS_RAW" ]; then
		ERRORS_RAW="${ERRORS_RAW}
$message"
	else
		ERRORS_RAW="$message"
	fi
}

# Return normalized config metadata for LuCI and runtime validation. Errors are
# reported in JSON instead of hard-failing so the UI can show all problems.
read_config_json() {
	local dns_listen_raw="" dns_port="" mihomo_dns_listen=""
	local port="" socks_port="" mixed_port="" redir_port="" tproxy_port="" routing_mark=""
	local routing_mark_normalized="" intercept_mark_normalized=""
	local enhanced_mode="" catch_fakeip="" fake_ip_range=""
	local external_controller="" external_controller_tls="" external_controller_unix=""
	local secret="" external_ui="" external_ui_name=""
	local ERRORS_RAW=""
	local key raw value

	[ -r "$CLASH_CONFIG" ] || {
		err "Mihomo config missing at $CLASH_CONFIG"
		return 1
	}

	require_command jq || return 1

	while IFS="$(printf '\t')" read -r key raw; do
		value="$(yaml_cleanup_scalar "$raw")"

		case "$key" in
		dns.listen) dns_listen_raw="$value" ;;
		dns.enhanced-mode) enhanced_mode="$value" ;;
		dns.fake-ip-range) fake_ip_range="$value" ;;
		port) port="$value" ;;
		socks-port) socks_port="$value" ;;
		mixed-port) mixed_port="$value" ;;
		redir-port) redir_port="$value" ;;
		tproxy-port) tproxy_port="$value" ;;
		routing-mark) routing_mark="$value" ;;
		external-controller) external_controller="$value" ;;
		external-controller-tls) external_controller_tls="$value" ;;
		external-controller-unix) external_controller_unix="$value" ;;
		secret) secret="$value" ;;
		external-ui) external_ui="$value" ;;
		external-ui-name) external_ui_name="$value" ;;
		esac
	done <<EOF
$(yaml_get_selected_scalars "$CLASH_CONFIG")
EOF

	dns_port=""
	mihomo_dns_listen=""
	if [ -z "$dns_listen_raw" ]; then
		append_error "Missing dns.listen in $CLASH_CONFIG"
	else
		mihomo_dns_listen="$(normalize_dns_server_target_from_addr "$dns_listen_raw" 2>/dev/null || true)"
		if [ -z "$mihomo_dns_listen" ]; then
			append_error "Invalid dns.listen in $CLASH_CONFIG: $dns_listen_raw"
		else
			dns_port="$(dns_listen_port "$mihomo_dns_listen")"
		fi
	fi

	if [ -z "$tproxy_port" ]; then
		append_error "Missing tproxy-port in $CLASH_CONFIG"
	elif ! is_valid_port "$tproxy_port"; then
		append_error "Invalid tproxy-port in $CLASH_CONFIG: $tproxy_port"
	fi

	if [ -z "$routing_mark" ]; then
		append_error "Missing routing-mark in $CLASH_CONFIG"
	elif ! is_valid_uint32_mark "$routing_mark"; then
		append_error "Invalid routing-mark in $CLASH_CONFIG: $routing_mark"
	else
		routing_mark_normalized="$(normalize_uint "$routing_mark")"
		intercept_mark_normalized="$(normalize_uint "$((${NFT_INTERCEPT_MARK:-0x00001000}))")"
		if [ "$routing_mark_normalized" = "$intercept_mark_normalized" ]; then
			append_error "Mihomo routing mark conflicts with MihoWRT intercept mark: $routing_mark"
		fi
	fi

	catch_fakeip=0
	if [ -z "$enhanced_mode" ]; then
		append_error "Missing dns.enhanced-mode in $CLASH_CONFIG; fake-ip is required"
	elif [ "$enhanced_mode" != "fake-ip" ]; then
		append_error "Invalid dns.enhanced-mode in $CLASH_CONFIG: $enhanced_mode; fake-ip is required"
	else
		catch_fakeip=1
		if [ -z "$fake_ip_range" ]; then
			append_error "Missing dns.fake-ip-range in $CLASH_CONFIG while dns.enhanced-mode=fake-ip"
		elif ! is_ipv4_cidr "$fake_ip_range"; then
			append_error "Invalid dns.fake-ip-range in $CLASH_CONFIG: $fake_ip_range"
		fi
	fi

	jq -nc \
		--arg config_path "$CLASH_CONFIG" \
		--arg dns_listen_raw "$dns_listen_raw" \
		--arg dns_port "$dns_port" \
		--arg mihomo_dns_listen "$mihomo_dns_listen" \
		--arg port "$port" \
		--arg socks_port "$socks_port" \
		--arg mixed_port "$mixed_port" \
		--arg redir_port "$redir_port" \
		--arg tproxy_port "$tproxy_port" \
		--arg routing_mark "$routing_mark" \
		--arg enhanced_mode "$enhanced_mode" \
		--arg catch_fakeip "$catch_fakeip" \
		--arg fake_ip_range "$fake_ip_range" \
		--arg external_controller "$external_controller" \
		--arg external_controller_tls "$external_controller_tls" \
		--arg external_controller_unix "$external_controller_unix" \
		--arg secret "$secret" \
		--arg external_ui "$external_ui" \
		--arg external_ui_name "$external_ui_name" \
		--arg errors_raw "$ERRORS_RAW" \
		'{
			config_path: $config_path,
			dns_listen_raw: $dns_listen_raw,
			dns_port: $dns_port,
			mihomo_dns_listen: $mihomo_dns_listen,
			port: $port,
			socks_port: $socks_port,
			mixed_port: $mixed_port,
			redir_port: $redir_port,
			tproxy_port: $tproxy_port,
			routing_mark: $routing_mark,
			enhanced_mode: $enhanced_mode,
			catch_fakeip: ($catch_fakeip == "1"),
			fake_ip_range: $fake_ip_range,
			external_controller: $external_controller,
			external_controller_tls: $external_controller_tls,
			external_controller_unix: $external_controller_unix,
			secret: $secret,
			external_ui: $external_ui,
			external_ui_name: $external_ui_name,
			errors: ($errors_raw | split("\n") | map(select(length > 0)))
		}' || {
		err "Failed to normalize config data from $CLASH_CONFIG"
		return 1
	}
}

# Temporarily point CLASH_CONFIG at a candidate file and restore caller state.
read_config_json_for_path() {
	local config_path="$1"
	local active_config="$CLASH_CONFIG"
	local rc=0

	CLASH_CONFIG="$config_path"
	read_config_json || rc=$?
	CLASH_CONFIG="$active_config"
	return "$rc"
}

# Marker for configs that already passed Mihomo and MihoWRT validation in the
# current boot. The init script can skip duplicate Mihomo tests after apply.
validated_config_stamp_file() {
	printf '%s\n' "${VALIDATED_CONFIG_FILE:-${PKG_TMP_DIR:-/tmp/mihowrt}/validated.config}"
}

# Store the exact validated config as the stamp content, not just a timestamp.
mark_validated_config() {
	local stamp_file

	stamp_file="$(validated_config_stamp_file)"
	ensure_dir "$(dirname "$stamp_file")" || return 1
	cp -f "$CLASH_CONFIG" "$stamp_file"
}

# True when live config still matches the last validated candidate.
current_config_has_validated_stamp() {
	local stamp_file

	stamp_file="$(validated_config_stamp_file)"
	[ -r "$CLASH_CONFIG" ] && [ -r "$stamp_file" ] && cmp -s "$CLASH_CONFIG" "$stamp_file"
}

apply_config_result_json() {
	local action="$1"
	local restart_required="$2"
	local hot_reloaded="${3:-0}"
	local policy_reloaded="${4:-0}"
	local reason="${5:-}"
	local http_code="${6:-}"

	require_command jq || return 1
	jq -nc \
		--arg action "$action" \
		--arg restart_required "$restart_required" \
		--arg hot_reloaded "$hot_reloaded" \
		--arg policy_reloaded "$policy_reloaded" \
		--arg reason "$reason" \
		--arg http_code "$http_code" \
		'{
			action: $action,
			saved: true,
			restart_required: ($restart_required == "1"),
			hot_reloaded: ($hot_reloaded == "1"),
			policy_reloaded: ($policy_reloaded == "1"),
			reason: $reason,
			http_code: $http_code
		}'
}

config_json_value() {
	local json="$1"
	local key="$2"

	printf '%s\n' "$json" | jq -r --arg key "$key" '.[$key] // ""'
}

config_json_field_changed() {
	local old_json="$1"
	local new_json="$2"
	local key="$3"
	local old_value="" new_value=""

	old_value="$(config_json_value "$old_json" "$key")" || return 0
	new_value="$(config_json_value "$new_json" "$key")" || return 0
	[ "$old_value" != "$new_value" ]
}

config_requires_service_restart() {
	local old_json="$1"
	local new_json="$2"
	local key=""

	for key in external_controller external_controller_tls external_controller_unix secret external_ui external_ui_name; do
		config_json_field_changed "$old_json" "$new_json" "$key" && return 0
	done

	return 1
}

config_requires_policy_reload() {
	local old_json="$1"
	local new_json="$2"
	local key=""

	for key in dns_port mihomo_dns_listen tproxy_port routing_mark enhanced_mode catch_fakeip fake_ip_range; do
		config_json_field_changed "$old_json" "$new_json" "$key" && return 0
	done

	if runtime_snapshot_valid 2>/dev/null && ! runtime_snapshot_policy_config_matches_current 2>/dev/null; then
		return 0
	fi

	return 1
}

config_requires_mihomo_force_reload() {
	local old_json="$1"
	local new_json="$2"
	local key=""

	for key in dns_port port socks_port mixed_port redir_port tproxy_port; do
		config_json_field_changed "$old_json" "$new_json" "$key" && return 0
	done

	return 1
}

config_refresh_subscription_auto_update_state() {
	local config_json="$1"

	if command -v subscription_refresh_auto_update_state >/dev/null 2>&1; then
		subscription_refresh_auto_update_state "$config_json" || true
	fi
}

wait_for_current_mihomo_listeners() {
	local pid="" dns_port="" tproxy_port=""
	local timeout="${MIHOMO_HOT_RELOAD_READY_TIMEOUT:-8}"
	local waited=0

	case "$timeout" in
	'' | *[!0-9]*)
		timeout=8
		;;
	esac

	load_runtime_config || return 1
	dns_port="$(dns_listen_port "${MIHOMO_DNS_LISTEN:-}")"
	tproxy_port="${MIHOMO_TPROXY_PORT:-}"

	if [ -r "${SERVICE_PID_FILE:-}" ]; then
		IFS= read -r pid <"$SERVICE_PID_FILE" 2>/dev/null || pid=""
	fi

	while [ "$waited" -lt "$timeout" ]; do
		if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
			return 1
		fi

		mihomo_ports_ready_state "$dns_port" "$tproxy_port" && return 0
		sleep 1
		waited=$((waited + 1))
	done

	return 1
}

apply_config_runtime() {
	local candidate="$1"
	local active_config="$CLASH_CONFIG"
	local old_config_json="" new_config_json=""
	local config_changed=1 policy_reload_needed=0 mihomo_force_reload=0
	local reason="" http_code=""

	if [ -r "$active_config" ]; then
		old_config_json="$(read_config_json_for_path "$active_config" 2>/dev/null || true)"
		cmp -s "$candidate" "$active_config" 2>/dev/null && config_changed=0 || config_changed=1
	fi

	apply_config_file "$candidate" || return 1

	if ! service_running_state; then
		apply_config_result_json "saved" 0 0 0
		return $?
	fi

	if [ "$config_changed" -eq 0 ]; then
		apply_config_result_json "saved" 0 0 0
		return $?
	fi

	[ -n "$old_config_json" ] || {
		apply_config_result_json "restart_required" 1 0 0 "active config metadata was unavailable before apply"
		return $?
	}

	new_config_json="$(read_config_json 2>/dev/null || true)"
	[ -n "$new_config_json" ] || {
		apply_config_result_json "restart_required" 1 0 0 "active config metadata is unavailable after apply"
		return $?
	}

	if config_requires_service_restart "$old_config_json" "$new_config_json"; then
		apply_config_result_json "restart_required" 1 0 0 "Mihomo controller/UI settings changed"
		return $?
	fi

	if config_requires_policy_reload "$old_config_json" "$new_config_json"; then
		policy_reload_needed=1
	fi
	config_refresh_subscription_auto_update_state "$new_config_json"

	if config_requires_mihomo_force_reload "$old_config_json" "$new_config_json"; then
		mihomo_force_reload=1
	fi

	if ! mihomo_hot_reload_config "$old_config_json" "$active_config" "$mihomo_force_reload"; then
		reason="${MIHOMO_API_REASON:-Mihomo API hot reload unavailable}"
		http_code="${MIHOMO_API_HTTP_CODE:-}"
		apply_config_result_json "restart_required" 1 0 0 "$reason" "$http_code"
		return $?
	fi

	log "Hot reloaded Mihomo config through external controller"

	if [ "$policy_reload_needed" -eq 0 ]; then
		apply_config_result_json "hot_reloaded" 0 1 0
		return $?
	fi

	if ! wait_for_current_mihomo_listeners; then
		apply_config_result_json "restart_required" 1 1 0 "Mihomo listeners were not ready after hot reload"
		return $?
	fi

	if ! MIHOWRT_ALLOW_MIHOMO_CONFIG_RELOAD=1 reload_runtime_state; then
		apply_config_result_json "restart_required" 1 1 0 "Policy reload failed after Mihomo hot reload"
		return $?
	fi

	apply_config_result_json "policy_reloaded" 0 1 1
}

apply_config_runtime_auto_update() {
	local candidate="$1"
	local active_config="$CLASH_CONFIG"
	local old_config_json="" new_config_json=""
	local config_changed=1 policy_reload_needed=0 mihomo_force_reload=0
	local reason="" http_code=""

	if [ -r "$active_config" ]; then
		old_config_json="$(read_config_json_for_path "$active_config" 2>/dev/null || true)"
		cmp -s "$candidate" "$active_config" 2>/dev/null && config_changed=0 || config_changed=1
	fi

	validate_config_candidate "$candidate" || {
		rm -f "$candidate"
		return 1
	}

	new_config_json="$(read_config_json_for_path "$candidate" 2>/dev/null || true)"
	[ -n "$new_config_json" ] || {
		rm -f "$candidate"
		subscription_store_auto_update_state 0 "" "subscription config metadata is unavailable" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 0 0 "subscription config metadata is unavailable"
		return $?
	}

	if ! mihomo_hot_reload_supported "$new_config_json"; then
		reason="${MIHOMO_API_REASON:-Mihomo API hot reload is unavailable in subscription config}"
		rm -f "$candidate"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 0 0 "$reason"
		return $?
	fi

	if ! service_running_state; then
		install_validated_config_candidate "$candidate" || return 1
		config_refresh_subscription_auto_update_state "$new_config_json"
		apply_config_result_json "saved" 0 0 0
		return $?
	fi

	[ -n "$old_config_json" ] || {
		rm -f "$candidate"
		reason="active config metadata was unavailable before auto-update"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 0 0 "$reason"
		return $?
	}

	if ! mihomo_hot_reload_supported "$old_config_json"; then
		reason="${MIHOMO_API_REASON:-Mihomo API hot reload is unavailable in active config}"
		rm -f "$candidate"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 0 0 "$reason"
		return $?
	fi

	if [ "$config_changed" -eq 0 ]; then
		rm -f "$candidate"
		config_refresh_subscription_auto_update_state "$new_config_json"
		apply_config_result_json "saved" 0 0 0
		return $?
	fi

	if config_requires_service_restart "$old_config_json" "$new_config_json"; then
		rm -f "$candidate"
		reason="Mihomo controller/UI settings changed; manual restart is required"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "manual_restart_required" 0 0 0 "$reason"
		return $?
	fi

	if config_requires_policy_reload "$old_config_json" "$new_config_json"; then
		policy_reload_needed=1
	fi
	if config_requires_mihomo_force_reload "$old_config_json" "$new_config_json"; then
		mihomo_force_reload=1
	fi

	install_validated_config_candidate "$candidate" || return 1

	if ! mihomo_hot_reload_config "$old_config_json" "$active_config" "$mihomo_force_reload"; then
		reason="${MIHOMO_API_REASON:-Mihomo API hot reload unavailable}"
		http_code="${MIHOMO_API_HTTP_CODE:-}"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 0 0 "$reason" "$http_code"
		return $?
	fi

	log "Auto-updated subscription config through Mihomo hot reload"

	if [ "$policy_reload_needed" -eq 0 ]; then
		config_refresh_subscription_auto_update_state "$new_config_json"
		apply_config_result_json "hot_reloaded" 0 1 0
		return $?
	fi

	if ! wait_for_current_mihomo_listeners; then
		reason="Mihomo listeners were not ready after auto-update hot reload"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 1 0 "$reason"
		return $?
	fi

	if ! MIHOWRT_ALLOW_MIHOMO_CONFIG_RELOAD=1 reload_runtime_state; then
		reason="Policy reload failed after auto-update hot reload"
		subscription_store_auto_update_state 0 "" "$reason" 2>/dev/null || true
		apply_config_result_json "auto_update_disabled" 0 1 0 "$reason"
		return $?
	fi

	config_refresh_subscription_auto_update_state "$new_config_json"
	apply_config_result_json "policy_reloaded" 0 1 1
}

validate_config_candidate() {
	local candidate="$1"
	local test_output="" config_json="" config_errors=""

	[ -n "$candidate" ] || {
		err "temporary config path is required"
		return 1
	}

	case "$candidate" in
	/tmp/*) ;;
	*)
		err "temporary config must be stored under /tmp"
		return 1
		;;
	esac

	[ -r "$candidate" ] || {
		err "temporary config missing at $candidate"
		return 1
	}

	[ -x "$CLASH_BIN" ] || {
		err "Mihomo binary missing at $CLASH_BIN"
		return 1
	}

	test_output="$("$CLASH_BIN" -d "$CLASH_DIR" -f "$candidate" -t 2>&1)" || {
		err "${test_output:-configuration test failed}"
		return 1
	}

	config_json="$(read_config_json_for_path "$candidate")" || {
		return 1
	}

	config_errors="$(printf '%s\n' "$config_json" | jq -r '.errors | join("; ")')" || {
		err "Failed to inspect normalized config errors for $candidate"
		return 1
	}

	if [ -n "$config_errors" ]; then
		err "$config_errors"
		return 1
	fi
}

install_validated_config_candidate() {
	local candidate="$1"
	local active_config="$CLASH_CONFIG"
	local target_tmp="${active_config}.tmp.$$"

	mkdir -p "$(dirname "$active_config")" || {
		err "Failed to prepare config directory for $active_config"
		rm -f "$candidate" "$target_tmp"
		return 1
	}

	if [ -f "$active_config" ] && cmp -s "$candidate" "$active_config" 2>/dev/null; then
		rm -f "$candidate"
		mark_validated_config || err "Failed to record validated config marker"
		return 0
	fi

	cp -f "$candidate" "$target_tmp" || {
		err "Failed to stage validated config for $active_config"
		rm -f "$candidate" "$target_tmp"
		return 1
	}

	mv -f "$target_tmp" "$active_config" || {
		err "Failed to install validated config to $active_config"
		rm -f "$candidate" "$target_tmp"
		return 1
	}

	rm -f "$candidate"
	mark_validated_config || err "Failed to record validated config marker"
	return 0
}

# Validate a temp config with Mihomo and MihoWRT, then atomically replace the
# live config only after both checks pass.
apply_config_file() {
	local candidate="$1"

	validate_config_candidate "$candidate" || {
		rm -f "$candidate"
		return 1
	}
	install_validated_config_candidate "$candidate"
}

# LuCI convenience wrapper for content-based apply. It writes to /tmp first so
# apply_config_file can reuse the same safe path and cleanup rules.
apply_config_contents() {
	local contents="$1"
	local candidate=""

	require_command mktemp || return 1
	candidate="$(mktemp /tmp/mihowrt-config.XXXXXX)" || {
		err "Failed to allocate temporary config path"
		return 1
	}

	printf '%s' "$contents" >"$candidate" || {
		err "Failed to stage temporary config contents"
		rm -f "$candidate"
		return 1
	}

	apply_config_file "$candidate"
}
