#!/bin/ash

# Build the runtime Mihomo config from the user's YAML without parsing it:
# router-owned top-level keys are cut out line by line and re-added in a
# managed section, owned dns children are replaced inside the dns block.

MIHOMO_OWNED_KEYS="tproxy-port routing-mark allow-lan bind-address tun external-controller external-controller-unix external-controller-tls external-controller-pipe secret"
MIHOMO_OWNED_DNS_KEYS="enable listen enhanced-mode fake-ip-range"

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
	local src="$1" dst="$2" tmp=""

	[ -r "$src" ] || {
		err "Mihomo config not found: $src"
		return 1
	}
	if grep -qE '^["'"'"']?dns["'"'"']?:[[:space:]]*\{' "$src"; then
		err "Flow-style 'dns: {...}' is not supported; use block style"
		return 1
	fi

	ensure_dir "$(dirname "$dst")" || return 1
	tmp="$dst.tmp.$$"
	awk \
		-v drop=" $MIHOMO_OWNED_KEYS " \
		-v dnsdrop=" $MIHOMO_OWNED_DNS_KEYS " \
		-v dns_port="$MIHOMO_DNS_PORT" \
		-v fakeip="$FAKEIP_RANGE" \
		-v tproxy="$MIHOMO_TPROXY_PORT" \
		-v mark="$MIHOMO_ROUTING_MARK" \
		-v api="$(lan_ip_detect):$MIHOMO_API_PORT" \
		-v sock="$MIHOMO_SOCKET_TMPFS" \
		-v secret="$API_SECRET" '
		# Plain or quoted mapping key at the start of the text.
		function key_of(text) {
			if (text !~ /^["\047]?[A-Za-z0-9_-]+["\047]?[[:space:]]*:/)
				return ""
			sub(/[[:space:]]*:.*/, "", text)
			gsub(/["\047]/, "", text)
			return text
		}
		# Value after "key:" without a trailing comment.
		function value_of(text) {
			sub(/^[^:]*:[[:space:]]*/, "", text)
			sub(/[[:space:]]+#.*/, "", text)
			return text
		}
		function flush_dns(ind) {
			ind = (child == "") ? "  " : child
			print ind "enable: true"
			print ind "listen: 0.0.0.0:" dns_port
			print ind "enhanced-mode: fake-ip"
			print ind "fake-ip-range: " fakeip
			in_dns = 0
		}
		{
			sub(/\r$/, "")
			if (NR == 1)
				sub(/^\357\273\277/, "")
			line = $0
			if (line ~ /^[^[:space:]#]/) {
				if (in_dns)
					flush_dns()
				key = key_of(line)
				skip = (key != "" && index(drop, " " key " ") > 0)
				# "dns: ~" or "dns: null" holds no block: use the managed one.
				if (key == "dns" && value_of(line) != "")
					next
				if (key == "dns") {
					seen_dns = 1
					in_dns = 1
					child = ""
					dskip = 0
					print line
					next
				}
				if (!skip)
					print line
				next
			}
			if (skip)
				next
			if (in_dns && line ~ /^[[:space:]]+[^[:space:]#]/) {
				match(line, /^[[:space:]]+/)
				ind = substr(line, 1, RLENGTH)
				if (child == "")
					child = ind
				if (ind == child) {
					key = key_of(substr(line, RLENGTH + 1))
					if (key != "")
						dskip = (index(dnsdrop, " " key " ") > 0)
				}
				if (dskip)
					next
			}
			print line
		}
		END {
			if (in_dns)
				flush_dns()
			print ""
			print "# --- MihoWRT managed: generated, edits here are discarded ---"
			if (!seen_dns) {
				print "dns:"
				child = ""
				flush_dns()
				print "  nameserver:"
				print "    - https://1.1.1.1/dns-query"
				print "    - https://8.8.8.8/dns-query"
			}
			print "tproxy-port: " tproxy
			print "routing-mark: " mark
			print "allow-lan: true"
			print "bind-address: \"*\""
			print "tun:"
			print "  enable: false"
			print "external-controller: " api
			print "external-controller-unix: " sock
			print "secret: \"" secret "\""
		}
	' "$src" >"$tmp" || {
		rm -f "$tmp"
		err "Failed to generate runtime config"
		return 1
	}
	chmod 600 "$tmp" && mv -f "$tmp" "$dst"
}

# Validate a generated config with Mihomo itself. Its own error text is the
# most useful message for the user, so it is passed through.
mihomo_config_test() {
	local config="$1" bin="${2:-$CLASH_BIN}" out=""

	[ -x "$bin" ] || {
		err "Mihomo core is not installed: $bin"
		return 1
	}
	out="$("$bin" -d "$CLASH_DIR" -f "$config" -t 2>&1)" && return 0
	printf '%s\n' "$out" | tail -n 20 >&2
	err "Mihomo rejected the configuration"
	return 1
}
