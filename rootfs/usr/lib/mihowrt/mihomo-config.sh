#!/bin/ash

# Build the runtime Mihomo config from the user's YAML without parsing it:
# router-owned top-level keys are cut out line by line and re-added in a
# managed section, owned dns children are replaced inside the dns block.
# The same pass writes <dst>.profile: the mode derived from the DNS settings
# and the provider's x-mihowrt settings (format in the 0.9 design, section 2).

MIHOMO_OWNED_KEYS="tproxy-port routing-mark allow-lan bind-address tun profile external-controller external-controller-unix external-controller-tls external-controller-pipe secret external-ui external-ui-url external-ui-name x-mihowrt"
MIHOMO_OWNED_DNS_KEYS="enable listen fake-ip-range fake-ip-range6"
MIHOMO_DASHBOARD_URL="https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"

lan_ip_detect() {
	local ip=""

	ip="$(uci -q get network.lan.ipaddr 2>/dev/null)" || ip=""
	ip="${ip%% *}"
	ip="${ip%%/*}"
	if is_ipv4 "$ip"; then
		printf '%s' "$ip"
	else
		printf '127.0.0.1'
	fi
}

mihomo_config_generate() {
	local src="$1" dst="$2" tmp="" line=""

	[ -r "$src" ] || {
		err "Mihomo config not found: $src"
		return 1
	}
	if grep -qE '^["'"'"']?dns["'"'"']?:[[:space:]]*\{' "$src"; then
		err "Flow-style 'dns: {...}' is not supported; use block style"
		return 1
	fi
	if grep -qE '^["'"'"']?x-mihowrt["'"'"']?:[[:space:]]*\{' "$src"; then
		err "Flow-style 'x-mihowrt: {...}' is not supported; use block style"
		return 1
	fi

	ensure_dir "$(dirname "$dst")" || return 1
	tmp="$dst.tmp.$$"
	awk -f "$(mihowrt_lib_dir)/mihomo-config.awk" \
		-v drop=" $MIHOMO_OWNED_KEYS " \
		-v dnsdrop=" $MIHOMO_OWNED_DNS_KEYS " \
		-v dns_port="$MIHOMO_DNS_PORT" \
		-v fakeip="$FAKEIP_RANGE" \
		-v tproxy="$MIHOMO_TPROXY_PORT" \
		-v mark="$MIHOMO_ROUTING_MARK" \
		-v api="$(lan_ip_detect):$MIHOMO_API_PORT" \
		-v sock="$MIHOMO_SOCKET_TMPFS" \
		-v secret="$API_SECRET" \
		-v ui_url="$MIHOMO_DASHBOARD_URL" \
		-v profile="$tmp.profile" \
		-v warnfile="$tmp.warn" \
		"$src" >"$tmp" || {
		rm -f "$tmp" "$tmp.profile" "$tmp.warn"
		err "Failed to generate runtime config"
		return 1
	}
	# A bad x-mihowrt never rejects the config: the key is ignored, logged.
	sed -n 's/^ignored //p' "$tmp.profile" 2>/dev/null | while IFS= read -r line; do
		warn "x-mihowrt: ignored invalid or unknown setting '$line'"
	done
	[ -s "$tmp.warn" ] && while IFS= read -r line; do warn "$line"; done <"$tmp.warn"
	rm -f "$tmp.warn"
	lists_profile_filter "$tmp.profile" || {
		rm -f "$tmp" "$tmp.profile"
		err "Failed to generate runtime config"
		return 1
	}
	chmod 600 "$tmp" && mv -f "$tmp.profile" "$dst.profile" && mv -f "$tmp" "$dst"
}

# Provider profile of the installed YAML. Rebuilt when missing or older
# than the YAML (e.g. after a reboot with the service disabled).
profile_ensure() {
	local scratch="$PKG_TMP_DIR/profile.$$.yaml" MIHOWRT_QUIET=1

	[ -r "$CLASH_CONFIG" ] || return 1
	[ -f "$PROFILE_FILE" ] && ! [ "$CLASH_CONFIG" -nt "$PROFILE_FILE" ] && return 0
	ensure_dir "$PKG_TMP_DIR" || return 1
	if mihomo_config_generate "$CLASH_CONFIG" "$scratch" 2>/dev/null &&
		mv -f "$scratch.profile" "$PROFILE_FILE"; then
		rm -f "$scratch"
		return 0
	fi
	rm -f "$scratch" "$scratch.profile"
	return 1
}

profile_get() {
	[ -r "$PROFILE_FILE" ] || return 0
	sed -n "s/^$1 //p" "$PROFILE_FILE" | head -n 1
}

profile_has() {
	[ -r "$PROFILE_FILE" ] && grep -qx "has $1" "$PROFILE_FILE"
}

profile_entries() {
	[ -r "$PROFILE_FILE" ] || return 0
	sed -n "s/^$1 //p" "$PROFILE_FILE"
}

# Validate a generated config with Mihomo itself. Its own error text is the
# most useful message for the user, so it is passed through.
mihomo_config_test() {
	local config="$1" bin="${2:-$CLASH_BIN}"

	CONFIG_TEST_OUTPUT=""
	[ -x "$bin" ] || {
		CONFIG_TEST_OUTPUT="Mihomo core is not installed: $bin"
		err "$CONFIG_TEST_OUTPUT"
		return 1
	}
	CONFIG_TEST_OUTPUT="$("$bin" -d "$CLASH_DIR" -f "$config" -t 2>&1)" && return 0
	printf '%s\n' "$CONFIG_TEST_OUTPUT" | tail -n 20 >&2
	err "Mihomo rejected the configuration"
	return 1
}

# Remember the last check of a config built from $CLASH_CONFIG, so status
# never has to run the core. ok|err (err keeps Mihomo's last 20 lines).
config_check_record() {
	ensure_dir "$PKG_STATE_DIR" || return 1
	if [ "$1" = ok ]; then
		rm -f "$CONFIG_ERR_FILE"
		touch "$CONFIG_OK_FILE"
	else
		rm -f "$CONFIG_OK_FILE"
		printf '%s\n' "$CONFIG_TEST_OUTPUT" | tail -n 20 >"$CONFIG_ERR_FILE"
	fi
}
