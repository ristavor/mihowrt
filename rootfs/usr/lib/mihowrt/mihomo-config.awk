# Analyse the rendered shape in pass 1; emit each line immediately in pass 2.
# Only collision ranges are retained, never the source or rendered document.
function emit(text,   kind) {
	rendered_line++
	if (pass == 1) {
		scan_direct(text)
		return
	}
	if (!direct_enabled) {
		print text
		return
	}
	kind = ""
	if (("listeners" in section_start) && rendered_line == section_start["listeners"]) kind = "listeners"
	else if (("rules" in section_start) && rendered_line == section_start["rules"]) kind = "rules"
	if (kind != "") {
		print_direct(kind, value_of(text) == "" ? text : kind ":")
		return
	}
	if (rendered_line in collision_end)
		suppress_until = collision_end[rendered_line]
	if (rendered_line > suppress_until)
		print text
}
function injection_error(section) {
	if (unsupported_section == "") unsupported_section = section
}
function finish_listener() {
	if (item_collision) {
		collision_end[item_start] = rendered_line - 1
		listener_collision = 1
	}
	item_start = 0
	item_collision = 0
}
# Match the old injection boundaries, including comments after a listener item.
function scan_direct(text,   kind, rest, name, ind) {
	if (unsupported_section != "") return
	if (direct_section != "" && text ~ /^[^[:space:]#-]/) {
		finish_listener()
		direct_section = ""
	}
	if (direct_section == "") {
		kind = key_of(text)
		if (kind != "listeners" && kind != "rules") return
		if (kind in section_start) return injection_error(kind)
		section_start[kind] = rendered_line
		direct_section = kind
		section_indent[kind] = "  "
		section_has_item = 0
		rest = value_of(text)
		if (rest != "" && rest !~ /^(null|~|\[[[:space:]]*\])$/)
			injection_error(kind)
		return
	}
	if (text ~ /^[[:space:]]*($|#)/) return
	if (direct_section == "rules" && section_has_item) return
	ind = indent_of(text)
	if (!section_has_item) {
		rest = substr(text, ind + 1)
		if (rest !~ /^-[[:space:]]+/) return injection_error(direct_section)
		section_indent[direct_section] = substr(text, 1, ind)
		section_has_item = 1
	}
	if (direct_section == "rules") return
	if (item_start && ind <= length(section_indent[direct_section]))
		finish_listener()
	if (!item_start) {
		rest = substr(text, length(section_indent[direct_section]) + 1)
		if (rest !~ /^-[[:space:]]+/) return injection_error(direct_section)
		match(rest, /^-[[:space:]]+/)
		item_root_indent = length(section_indent[direct_section]) + RLENGTH
		sub(/^-[[:space:]]+/, "", rest)
		if (key_of(rest) == "") return injection_error(direct_section)
		item_start = rendered_line
	} else {
		if (ind != item_root_indent) return
		rest = substr(text, item_root_indent + 1)
	}
	if (rest ~ /^<</) return injection_error(direct_section)
	if (key_of(rest) != "name") return
	name = unquote(value_of(rest))
	if (name ~ /^[*&!|>]/ || index(name, "\\")) return injection_error(direct_section)
	if (name == "mihowrt-direct") item_collision = 1
}
function print_direct(kind, header,   ind) {
	ind = (kind in section_indent) ? section_indent[kind] : "  "
	print header
	if (kind == "rules")
		print ind "- IN-NAME,mihowrt-direct,DIRECT"
	else {
		print ind "- name: mihowrt-direct"
		print ind "  type: tproxy"
		print ind "  listen: 0.0.0.0"
		print ind "  port: " direct_tproxy
		print ind "  udp: true"
	}
}
# The source is a regular file supplied by mihomo_config_generate. Reopen it
# after analysis rather than keeping two copies of a potentially large YAML.
BEGIN {
	pass = 1
	source = ARGC > 1 ? ARGV[ARGC - 1] : "/dev/null"
	while ((read_status = (getline < source)) > 0)
		process_line($0, ++source_line)
	close(source)
	if (read_status < 0) {
		failed = 1
		exit 1
	}
	finish_document()
	rendered_line++
	finish_listener()
	if (dns_mode() == "fake-ip" && filter != "whitelist") {
		if (unsupported_section != "")
			print "Devices always direct with fake-IP DNS is unavailable: the provider\047s " unsupported_section " list uses a form MihoWRT cannot extend" >warnfile
		else {
			direct_enabled = 1
			print "direct_listener 1" >profile
			if (listener_collision)
				print "Provider listener mihowrt-direct replaced by the MihoWRT direct listener" >warnfile
		}
	}
	pass = 2
	rendered_line = 0
	in_dns = in_x = in_groups = skip = seen_dns = seen_sniffer = dns_pending = dskip = 0
	child = enh = filter = group = top_ipv6 = ""
}
# First "- name:" item of the block-style proxy-groups list.
function group_item(line) {
	if (in_groups && group == "" && line ~ /^[[:space:]]*-[[:space:]]+["\047]?name["\047]?[[:space:]]*:/) {
		group = unquote(value_of(substr(line, index(line, "-") + 1)))
		if (group == "")
			group = "-"
	}
}
function flush_dns(ind) {
	# "dns:" without children is null: the managed block is used.
	if (dns_pending) {
		dns_pending = 0
		seen_dns = 0
		in_dns = 0
		return
	}
	ind = (child == "") ? "  " : child
	emit(ind "enable: true")
	emit(ind "listen: 0.0.0.0:" dns_port)
	if (dns_mode() == "fake-ip")
		emit(ind "fake-ip-range: " fakeip)
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
	else if (key == "block-client-ipv6") opt = "block_client_ipv6"
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
		# The same cleanup as lists_clean_lines: the URL filter and the
		# fetcher must see one value.
		sub(/#.*/, "", item)
		gsub(/[[:space:]]/, "", item)
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
function process_line(line, number) {
	sub(/\r$/, "", line)
	if (number == 1)
		sub(/^\357\273\277/, "", line)
	# Indentless list item ("key:\n- a"): part of the previous key.
	if (line ~ /^-([[:space:]]|$)/) {
		group_item(line)
		if (!skip)
			emit(line)
		return
	}
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
		if (key == "dns" || key == "x-mihowrt") {
			val = value_of(line)
			if (val != "" && val !~ /^(~|null)$/) {
				print "Unsupported " key " form: use a block mapping" >warnfile
				failed = 1
				exit 1
			}
		}
		if (key == "x-mihowrt" && value_of(line) == "") {
			in_x = 1
			xchild = -1
			xlist = ""
		}
		# "dns: ~" or "dns: null" holds no block: use the managed one.
		if (key == "dns" && value_of(line) != "")
			return
		if (key == "dns") {
			seen_dns = 1
			in_dns = 1
			child = ""
			dskip = 0
			dns_line = line
			dns_pending = 1
			return
		}
		if (!skip)
			emit(line)
		return
	}
	if (in_x && pass == 1)
		x_line(line)
	group_item(line)
	if (skip)
		return
	if (in_dns && line ~ /^[[:space:]]+[^[:space:]#]/) {
		if (dns_pending) {
			emit(dns_line)
			dns_pending = 0
		}
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
			return
	}
	emit(line)
}
function finish_document() {
	if (in_dns)
		flush_dns()
	if (!seen_dns)
		enh = "redir-host"
	if (pass == 1) {
		print "mode " ((dns_mode() == "fake-ip" && filter == "whitelist") ? "direct-first" : "proxy-first") >profile
		print "dns " dns_mode() >profile
	}
	emit("")
	emit("# --- MihoWRT managed: generated, edits here are discarded ---")
	if (!seen_dns) {
		suffix = ""
		if (group != "" && group != "-" && group !~ /[#&"\\]/)
			suffix = "#" group
		else if (pass == 1)
			print "No usable first proxy group: default DNS servers are queried directly" >warnfile
		emit("dns:")
		child = ""
		flush_dns()
		emit("  ipv6: " (top_ipv6 == "true" ? "true" : "false"))
		emit("  enhanced-mode: redir-host")
		emit("  default-nameserver:")
		emit("    - https://1.1.1.1/dns-query")
		emit("    - https://9.9.9.9/dns-query")
		emit("    - https://8.8.8.8/dns-query")
		emit("  proxy-server-nameserver:")
		emit("    - https://1.1.1.1/dns-query")
		emit("    - https://9.9.9.9/dns-query")
		emit("    - https://8.8.8.8/dns-query")
		emit("  direct-nameserver:")
		emit("    - https://common.dot.dns.yandex.net/dns-query")
		emit("  nameserver:")
		emit("    - \"https://cloudflare-dns.com/dns-query" suffix "\"")
		emit("    - \"https://dns.google/dns-query" suffix "\"")
	}
	if (!seen_sniffer) {
		emit("sniffer:")
		emit("  enable: true")
		emit("  force-dns-mapping: true")
		emit("  parse-pure-ip: true")
		emit("  override-destination: false")
		emit("  sniff:")
		emit("    HTTP:")
		emit("      ports: [80, 8080-8880]")
		emit("    TLS:")
		emit("      ports: [443, 8443]")
	}
	emit("tproxy-port: " tproxy)
	emit("routing-mark: " mark)
	emit("allow-lan: true")
	emit("bind-address: \"*\"")
	emit("tun:")
	emit("  enable: false")
	# Keep the selected servers and fake-ip mappings across restarts.
	emit("profile:")
	emit("  store-selected: true")
	emit("  store-fake-ip: true")
	emit("external-controller: " api)
	emit("external-controller-unix: " sock)
	emit("secret: \"" secret "\"")
	emit("external-ui: ui")
	emit("external-ui-url: \"" ui_url "\"")
}
{ process_line($0, FNR) }
END {
	if (failed) exit 1
	finish_document()
	if (direct_enabled) {
		if (!("listeners" in section_start)) print_direct("listeners", "listeners:")
		if (!("rules" in section_start)) print_direct("rules", "rules:")
	}
}
