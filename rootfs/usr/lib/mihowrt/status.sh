#!/bin/ash

# Read-only status for LuCI and the CLI.

service_enabled() {
	local link=""

	for link in /etc/rc.d/S*mihowrt; do
		[ -e "$link" ] && return 0
	done
	return 1
}

json_bool() {
	if "$@"; then echo true; else echo false; fi
}

service_state() {
	local running="${1:-}"

	[ -n "$running" ] || running="$(json_bool service_running)"
	if [ "$running" = true ]; then
		if [ -f "$DEGRADED_FILE" ]; then echo degraded
		elif [ -f "$RUNNING_MARKER" ]; then echo running
		else echo starting
		fi
	elif [ -f "$USER_STOP_FILE" ]; then echo stopped
	elif [ -f "$LAST_ERROR_FILE" ]; then echo failed
	else echo stopped
	fi
}

# Read small snapshots without an external cat; callers strip trailing newlines.
status_file_read() {
	local line=""

	{
		while IFS= read -r line || [ -n "$line" ]; do
			printf '%s\n' "$line"
		done <"$1"
	} 2>/dev/null || :
}

health_json() {
	case "$(status_file_read "$HEALTH_FILE")" in
	ok) echo true ;;
	fail) echo false ;;
	*) echo null ;;
	esac
}

service_state_json() {
	local running=false

	service_running && running=true
	mihowrt-json build service --argjson running "$running" \
		--argjson enabled "$(json_bool service_enabled)" \
		--arg state "$(service_state "$running")" \
		--argjson dns_ok "$(health_json)" \
		--arg last_error "$(status_file_read "$LAST_ERROR_FILE")"
}

# Plain upstream servers in dnsmasq bypass Mihomo; domain-scoped ones are fine.
dns_global_custom_servers() {
	local server=""

	for server in $(dns_custom_servers); do
		case "$server" in
		/*) ;;
		*) echo "$server" ;;
		esac
	done
}

# Last recorded check of the installed YAML: true, false or null (unknown).
# Status never runs the core itself (slow and memory-hungry on routers).
config_valid_json() {
	if [ -f "$CONFIG_OK_FILE" ] && ! [ "$CLASH_CONFIG" -nt "$CONFIG_OK_FILE" ]; then
		echo true
	elif [ -f "$CONFIG_ERR_FILE" ] && ! [ "$CLASH_CONFIG" -nt "$CONFIG_ERR_FILE" ]; then
		echo false
	else
		echo null
	fi
}

status_json() {
	local running=false policy=false config_valid=null config_error="" errors="" dashboard_installed=false

	settings_load 2>/dev/null || errors="Invalid MihoWRT settings"
	service_running && running=true
	if [ "$running" = true ]; then
		nft_active && route_active && policy=true
	fi
	[ ! -f "$CLASH_DIR/ui/index.html" ] || dashboard_installed=true
	config_valid="$(config_valid_json)"
	[ "$config_valid" = false ] && config_error="$(status_file_read "$CONFIG_ERR_FILE")"
	route_state_read 2>/dev/null

	mihowrt-json build status \
		--arg dashboard_host "$(lan_ip_detect)" \
		--argjson running "$running" \
		--argjson enabled "$(json_bool service_enabled)" \
		--argjson dns_ok "$(health_json)" \
		--arg state "$(service_state "$running")" \
		--arg last_error "$(status_file_read "$LAST_ERROR_FILE")" \
		--argjson dashboard_installed "$dashboard_installed" \
		--argjson policy "$policy" \
		--argjson config_valid "$config_valid" \
		--argjson config_backup "$(json_bool test -f "$CLASH_CONFIG_BACKUP")" \
		--arg config_error "$config_error" \
		--arg dns_mode "${DNS_MODE:-}" \
		--arg version "$PKG_VERSION" \
		--arg core "$(core_version)" \
		--arg mode "${POLICY_MODE:-}" \
		--arg block_client_ipv6 "${BLOCK_CLIENT_IPV6:-0}" \
		--arg url "${SUBSCRIPTION_URL:-}" \
		--arg custom "$(dns_global_custom_servers | tr '\n' ' ')" \
		--arg table "${ROUTE_TABLE:-}" \
		--arg priority "${ROUTE_PRIORITY:-}" \
		--arg interfaces "${SOURCE_INTERFACES:-}" \
		--arg dst "$(lists_count dst)" --arg src "$(lists_count src)" --arg direct "$(lists_count direct)" \
		--arg direct_src "$(lists_count direct_src)" \
		--arg errors "$errors"
}

# Provider profile for the Traffic page: mode, DNS, provider settings,
# the user's overrides and provider list state.
profile_json() {
	local dashboard_installed=false

	[ ! -f "$CLASH_DIR/ui/index.html" ] || dashboard_installed=true
	settings_load || return 1
	mihowrt-json build profile \
		--argjson dashboard_installed "$dashboard_installed" \
		--arg mode "$POLICY_MODE" --arg dns "$DNS_MODE" \
		--arg provider "$(profile_entries set)" \
		--arg overrides "$PROVIDER_OVERRIDES" \
		--argjson dst_provided "$(json_bool lists_provided dst)" \
		--arg dst_provider "$(lists_provider_entries dst | wc -l | tr -d ' ')" \
		--arg dst_own "$(lists_own_count dst)" --arg dst_source "$DST_LIST_SOURCE" \
		--argjson direct_provided "$(json_bool lists_provided direct)" \
		--arg direct_provider "$(lists_provider_entries direct | wc -l | tr -d ' ')" \
		--arg direct_own "$(lists_own_count direct)" --arg direct_source "$DIRECT_LIST_SOURCE"
}

diagnostics_json() {
	local package="" installed="" conflicts="" flash="" ram="" rss="" pid="" ports="" tmp_clash="" tmp_free=""

	installed="$(pkg_installed_names)"
	for package in $CONFLICT_PACKAGES; do
		case "
$installed
" in
		*"
$package
"*) conflicts="${conflicts}${package}
" ;;
		esac
	done
	tmp_clash="$(du -sk /tmp/clash 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')"
	tmp_free="$(df -kP /tmp 2>/dev/null | awk 'END { if (NR > 1 && $4 ~ /^[0-9]+$/) print $4 }')"
	flash="$(df -kP /opt/clash 2>/dev/null | awk 'END { if (NR > 1 && $4 ~ /^[0-9]+$/) print $4 }')"
	ram="$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	if pid="$(service_pid)"; then
		rss="$(awk '$1 == "VmRSS:" && $2 ~ /^[0-9]+$/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)"
	fi
	ports="$(awk -f "$(mihowrt_lib_dir)/yaml-lex.awk" -f - "$RUNTIME_CONFIG" 2>/dev/null <<'AWK'
		function report_port(value) {
			if (value ~ /^[0-9]+$/ && value + 0 > 0 && !seen[value + 0]++)
				printf "%.0f\n", value + 0
		}
		/^[[:space:]]*(#.*)?$/ { next }
		/^[^[:space:]]/ {
			auth_block = 0
			if ($0 !~ /^-[[:space:]]/) listeners_block = 0
		}
		/^([\042\047]?listeners[\042\047]?)[[:space:]]*:/ {
			value = value_of($0, 1)
			listeners_block = (value == "")
			item_indent = -1
			listener = 0
			next
		}
		listeners_block {
			indent = indent_of($0)
			line = substr($0, indent + 1)
			if (line ~ /^-[[:space:]]/ && (item_indent < 0 || indent == item_indent)) {
				item_indent = indent
				listener = ++listener_count
				sub(/^-[[:space:]]+/, "", line)
			} else if (!listener || indent != item_indent + 2) next
			key = key_of(line)
			if (key != "type" && key != "port" && key != "users") next
			value = value_of(line, 1)
			if (key == "users") {
				users_present[listener] = 1
				users_empty[listener] = (value ~ /^\[[[:space:]]*\]$/)
			} else {
				value = unquote(value, 1)
				if (key == "type") listener_type[listener] = value
				else listener_port[listener] = value
			}
			next
		}
		/^([\042\047]?authentication[\042\047]?)[[:space:]]*:/ {
			value = value_of($0, 1)
			if (value == "" || value == "null" || value == "~")
				auth_block = 1
			else if (value !~ /^\[[[:space:]]*\]$/)
				auth = 1
		}
		auth_block && /^[[:space:]]+-[[:space:]]/ { auth = 1 }
		/^(mixed-port|port|socks-port|redir-port)[[:space:]]*:/ {
			value = value_of($0, 1)
			value = unquote(value, 1)
			top_ports[++port_count] = value
		}
		END {
			if (!auth)
				for (i = 1; i <= port_count; i++) report_port(top_ports[i])
			for (i = 1; i <= listener_count; i++)
				if (listener_type[i] ~ /^(socks|http|mixed)$/ &&
				    (users_empty[i] || (!users_present[i] && !auth)))
					report_port(listener_port[i])
		}
AWK
)"
	mihowrt-json build diagnostics --arg conflicts "$conflicts" --arg flash "$flash" --arg ram "$ram" \
		--arg rss "$rss" --arg ports "$ports" --arg tmp_clash "$tmp_clash" --arg tmp_free "$tmp_free"
}

logs_json() {
	local limit="${1:-200}" lines=""

	is_uint "$limit" && [ "$limit" -ge 1 ] || limit=200
	[ "$limit" -le 1000 ] || limit=1000
	have_command logread || {
		mihowrt-json build logs --argjson available false
		return 0
	}
	lines="$(logread 2>/dev/null | grep -iE 'mihowrt|mihomo|clash' | tail -n "$limit")"
	mihowrt-json build logs --arg l "$lines"
}
