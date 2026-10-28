#!/bin/ash

# Build the runtime Mihomo config from the user's YAML without parsing it:
# router-owned top-level keys are cut out line by line and re-added in a
# managed section, owned dns children are replaced inside the dns block.
# The same pass writes <dst>.profile: the mode derived from the DNS settings
# and the provider's x-mihowrt settings (format in the 0.9 design, section 2).

MIHOMO_OWNED_KEYS="log-level tproxy-port routing-mark allow-lan bind-address tun profile external-controller external-controller-unix external-controller-tls external-controller-pipe secret external-ui external-ui-url external-ui-name x-mihowrt"
MIHOMO_OWNED_DNS_KEYS="enable listen fake-ip-range fake-ip-range6"
MIHOMO_DASHBOARD_URL="https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"

yaml_has_top_key() {
	awk -v key="$1" '
		{
			sub(/\r$/, "")
			if (NR == 1) sub(/^\357\273\277/, "")
			if ($0 !~ /^["\047]?[A-Za-z0-9_-]+["\047]?[[:space:]]*:/) next
			text = $0
			sub(/[[:space:]]*:.*/, "", text)
			gsub(/["\047]/, "", text)
			if (text ~ ("^(" key ")$")) { found = 1; exit }
		}
		END { exit !found }
	' "$2"
}

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

# mihomo_config_generate <src> <dst> [key]
# With "key", print a fingerprint of every generator input instead: the awk
# -v list below (hashed as is, so no input can be missed), the source bytes
# and the awk programs. The output paths are per build and not inputs.
# Returns 2 when the parser rejects the YAML itself, 1 on other failures.
mihomo_config_generate() {
	local src="$1" dst="$2" mode="${3:-}" tmp="" line="" rc=1 ui_url="" lib="" files="" source_hash="" key=""

	[ -r "$src" ] || {
		err "Mihomo config not found: $src"
		return 1
	}
	[ "${DASHBOARD_ENABLED:-0}" != 1 ] || ui_url="$MIHOMO_DASHBOARD_URL"
	lib="$(mihowrt_lib_dir)"
	set -- \
		-v drop=" $MIHOMO_OWNED_KEYS " \
		-v dnsdrop=" $MIHOMO_OWNED_DNS_KEYS " \
		-v log_level="${MIHOMO_LOG_LEVEL:-error}" \
		-v dns_port="$MIHOMO_DNS_PORT" \
		-v fakeip="$FAKEIP_RANGE" \
		-v tproxy="$MIHOMO_TPROXY_PORT" \
		-v direct_tproxy="$MIHOMO_DIRECT_TPROXY_PORT" \
		-v mark="$MIHOMO_ROUTING_MARK" \
		-v api="$(lan_ip_detect):$MIHOMO_API_PORT" \
		-v sock="$MIHOMO_SOCKET_TMPFS" \
		-v secret="$API_SECRET" \
		-v ui_url="$ui_url"
	if [ "$mode" = key ]; then
		files="$(sha256sum "$lib/yaml-lex.awk" "$lib/mihomo-config.awk")" &&
			source_hash="$(sha256sum <"$src")" || return 1
		# The list goes through a pipe only: the secret never reaches argv.
		key="$({ printf '%s\n' "$files" "$source_hash" "$@"; } | sha256sum)" || return 1
		printf '%s\n' "${key%% *}"
		return 0
	fi
	ensure_dir "$(dirname "$dst")" || return 1
	tmp="$dst.tmp.$$"
	awk -f "$lib/yaml-lex.awk" -f "$lib/mihomo-config.awk" "$@" \
		-v profile="$tmp.profile" \
		-v warnfile="$tmp.warn" \
		"$src" >"$tmp" || {
		if [ -s "$tmp.warn" ]; then
			# The parser explained why: the YAML itself is rejected (rc 2).
			while IFS= read -r line; do err "$line"; done <"$tmp.warn"
			rc=2
		else
			err "Failed to generate runtime config"
		fi
		rm -f "$tmp" "$tmp.profile" "$tmp.warn"
		return "$rc"
	}
	# Invalid x-mihowrt children are ignored and logged.
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

mihomo_config_key() {
	mihomo_config_generate "$1" "" key
}

# Remember the inputs $RUNTIME_CONFIG was generated from, or forget them with
# no key. Callers drop the key before replacing the config and store it only
# once the new config is live, so it never claims a file it does not describe.
runtime_config_key_store() {
	local file="$RUNTIME_CONFIG.inputs"

	rm -f "$file"
	[ -n "$1" ] || return 0
	{ printf '%s\n' "$1" >"$file.tmp.$$" && chmod 600 "$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"; } ||
		rm -f "$file" "$file.tmp.$$"
	return 0
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

# A start may reuse a successful test only for these bytes and core version.
mihomo_config_test_key() {
	local hash="" version=""

	hash="$(sha256sum "$1" 2>/dev/null)" || return 1
	version="$(core_version "${2:-$CLASH_BIN}" 2>/dev/null)" || return 1
	[ -n "$version" ] || return 1
	printf '%s %s\n' "${hash%% *}" "$version"
}

mihomo_memory_limit() {
	awk '/^MemTotal:/ { print int($2 / 2048) "MiB" }' /proc/meminfo 2>/dev/null
}

# Validate a generated config with Mihomo itself. Its own error text is the
# most useful message for the user, so it is passed through.
mihomo_config_test() {
	local config="$1" bin="${2:-$CLASH_BIN}" memlimit="" key="${3:-}"

	CONFIG_TEST_OUTPUT=""
	[ -x "$bin" ] || {
		CONFIG_TEST_OUTPUT="Mihomo core is not installed: $bin"
		err "$CONFIG_TEST_OUTPUT"
		return 1
	}
	memlimit="$(mihomo_memory_limit)"
	memlimit="$(uint_norm "${memlimit%MiB}")"
	# A candidate core runs beside the old one, so it gets half; a quarter-RAM
	# limit on the installed core made large configs GC-bound (8 MiB: 18 → 35 s).
	[ "$bin" = "$CLASH_BIN" ] || memlimit=$((memlimit / 2))
	if CONFIG_TEST_OUTPUT="$(
		if [ "$memlimit" -gt 0 ]; then
			export GOMEMLIMIT="${memlimit}MiB"
		fi
		"$bin" -d "$CLASH_DIR" -f "$config" -t 2>&1
	)"; then
		if [ -n "$key" ] || key="$(mihomo_config_test_key "$config" "$bin")"; then
			ensure_dir "$PKG_STATE_DIR" && atomic_write "$CONFIG_TESTED_FILE" "$key"
		fi
		return 0
	fi
	printf '%s\n' "$CONFIG_TEST_OUTPUT" | tail -n 20 >&2
	err "Mihomo rejected the configuration"
	return 1
}

# Remember the last check of a config built from $CLASH_CONFIG, so status
# never has to run the core. ok|err (err keeps Mihomo's last 20 lines).
config_check_record() {
	ensure_dir "$PKG_STATE_DIR" || return 1
	if [ "$1" = ok ]; then
		rm -f "$CONFIG_ERR_FILE" "$CONFIG_INVALID_FILE"
		touch "$CONFIG_OK_FILE"
	else
		# A -t rejection needing geodata/network waits for YAML/UCI changes or manual Start.
		[ ! -x "$CLASH_BIN" ] || : >"$CONFIG_INVALID_FILE"
		rm -f "$CONFIG_OK_FILE"
		printf '%s\n' "$CONFIG_TEST_OUTPUT" | tail -n 20 >"$CONFIG_ERR_FILE"
	fi
}
