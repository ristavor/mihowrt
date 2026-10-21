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
	awk \
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
		-v warnfile="$tmp.warn" '
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
			sub(/[[:space:]]+$/, "", text)
			return text
		}
		function unquote(text) {
			if (text ~ /^".*"$/ || text ~ /^\047.*\047$/)
				text = substr(text, 2, length(text) - 2)
			return text
		}
		function indent_of(text) {
			match(text, /^[[:space:]]*/)
			return RLENGTH
		}
		function flush_dns(ind) {
			ind = (child == "") ? "  " : child
			print ind "enable: true"
			print ind "listen: 0.0.0.0:" dns_port
			if (dns_mode() == "fake-ip")
				print ind "fake-ip-range: " fakeip
			in_dns = 0
		}
		function dns_mode(m) {
			m = tolower(unquote(enh))
			return (m == "fake-ip" || m == "normal") ? m : "redir-host"
		}
		function bool_of(v) {
			v = tolower(unquote(v))
			if (v == "true" || v == "yes" || v == "on" || v == "1") return "1"
			if (v == "false" || v == "no" || v == "off" || v == "0") return "0"
			return ""
		}
		# One x-mihowrt child "key: value" (value empty for block lists).
		function x_key(key, val,   opt, b) {
			xlist = ""
			opt = ""
			if (key == "disable-quic") opt = "disable_quic"
			else if (key == "dns-hijack") opt = "dns_hijack"
			else if (key == "bypass-ntp") opt = "bypass_ntp"
			else if (key == "bypass-subscription-dns") opt = "bypass_subscription_dns"
			if (opt != "") {
				b = bool_of(val)
				if (b == "") print "ignored " key >profile
				else print "set " opt " " b >profile
				return
			}
			if (key == "lists-interval") {
				val = unquote(val)
				if (val ~ /^[0-9]+$/ && val + 0 <= 8760) print "set lists_interval " (val + 0) >profile
				else print "ignored " key >profile
				return
			}
			if (key == "proxy-ips" || key == "direct-ips") {
				if (val == "" || val ~ /^(~|null|\[[[:space:]]*\])$/) {
					print "has " key >profile
					if (val == "") xlist = (key == "proxy-ips") ? "proxy-ip" : "direct-ip"
				} else
					print "ignored " key >profile
				return
			}
			print "ignored " key >profile
		}
		function x_line(line,   ind, rest, key, item) {
			if (line !~ /^[[:space:]]*[^[:space:]#]/)
				return
			ind = indent_of(line)
			rest = substr(line, ind + 1)
			if (xchild < 0)
				xchild = ind
			if (rest ~ /^-/ && xlist != "" && ind >= xchild) {
				item = rest
				sub(/^-[[:space:]]*/, "", item)
				sub(/[[:space:]]+#.*/, "", item)
				sub(/[[:space:]]+$/, "", item)
				item = unquote(item)
				if (item != "")
					print xlist " " item >profile
				return
			}
			if (ind > xchild)
				return
			key = key_of(rest)
			if (key != "")
				x_key(key, value_of(rest))
		}
		{
			sub(/\r$/, "")
			if (NR == 1)
				sub(/^\357\273\277/, "")
			line = $0
			if (line ~ /^[^[:space:]#]/) {
				if (in_dns)
					flush_dns()
				in_x = 0
				in_groups = 0
				key = key_of(line)
				skip = (key != "" && index(drop, " " key " ") > 0)
				if (key == "ipv6")
					top_ipv6 = tolower(unquote(value_of(line)))
				if (key == "sniffer")
					seen_sniffer = 1
				if (key == "proxy-groups" && value_of(line) == "")
					in_groups = 1
				if (key == "x-mihowrt" && value_of(line) == "") {
					in_x = 1
					xchild = -1
					xlist = ""
				}
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
			if (in_x)
				x_line(line)
			if (in_groups && group == "" && line ~ /^[[:space:]]*-[[:space:]]+["\047]?name["\047]?[[:space:]]*:/) {
				group = unquote(value_of(substr(line, index(line, "-") + 1)))
				if (group == "")
					group = "-"
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
					if (key == "enhanced-mode")
						enh = value_of(substr(line, RLENGTH + 1))
					if (key == "fake-ip-filter-mode")
						filter = tolower(unquote(value_of(substr(line, RLENGTH + 1))))
				}
				if (dskip)
					next
			}
			print line
		}
		END {
			if (in_dns)
				flush_dns()
			if (!seen_dns)
				enh = "redir-host"
			print "mode " ((dns_mode() == "fake-ip" && filter == "whitelist") ? "direct-first" : "proxy-first") >profile
			print "dns " dns_mode() >profile
			print ""
			print "# --- MihoWRT managed: generated, edits here are discarded ---"
			if (!seen_dns) {
				suffix = ""
				if (group != "" && group != "-" && group !~ /[#&"\\]/)
					suffix = "#" group
				else
					print "No usable first proxy group: default DNS servers are queried directly" >warnfile
				print "dns:"
				child = ""
				flush_dns()
				print "  ipv6: " (top_ipv6 == "true" ? "true" : "false")
				print "  enhanced-mode: redir-host"
				print "  default-nameserver:"
				print "    - https://1.1.1.1/dns-query"
				print "    - https://9.9.9.9/dns-query"
				print "    - https://8.8.8.8/dns-query"
				print "  proxy-server-nameserver:"
				print "    - https://1.1.1.1/dns-query"
				print "    - https://9.9.9.9/dns-query"
				print "    - https://8.8.8.8/dns-query"
				print "  direct-nameserver:"
				print "    - https://common.dot.dns.yandex.net/dns-query"
				print "  nameserver:"
				print "    - \"https://cloudflare-dns.com/dns-query" suffix "\""
				print "    - \"https://dns.google/dns-query" suffix "\""
			}
			if (!seen_sniffer) {
				print "sniffer:"
				print "  enable: true"
				print "  force-dns-mapping: true"
				print "  parse-pure-ip: true"
				print "  override-destination: false"
				print "  sniff:"
				print "    HTTP:"
				print "      ports: [80, 8080-8880]"
				print "    TLS:"
				print "      ports: [443, 8443]"
			}
			print "tproxy-port: " tproxy
			print "routing-mark: " mark
			print "allow-lan: true"
			print "bind-address: \"*\""
			print "tun:"
			print "  enable: false"
			# Keep the selected servers and fake-ip mappings across restarts.
			print "profile:"
			print "  store-selected: true"
			print "  store-fake-ip: true"
			print "external-controller: " api
			print "external-controller-unix: " sock
			print "secret: \"" secret "\""
			print "external-ui: ui"
			print "external-ui-url: \"" ui_url "\""
		}
	' "$src" >"$tmp" || {
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
	chmod 600 "$tmp" && mv -f "$tmp.profile" "$dst.profile" && mv -f "$tmp" "$dst"
}

# Provider profile of the installed YAML. Rebuilt when missing or older
# than the YAML (e.g. after a reboot with the service disabled).
profile_ensure() {
	local scratch="$PKG_TMP_DIR/profile.$$.yaml"

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
