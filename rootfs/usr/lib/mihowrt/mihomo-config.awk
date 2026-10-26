# Buffer rendered lines until DNS mode is known, regardless of key order.
function emit(text) { output[++output_count] = text }
function injection_error(section) {
	print "Cannot inject mihowrt-direct into " section "; use a block-style list with plain entries" >"/dev/stderr"
	exit 1
}
# Print a provider list with the managed entry first. Only empty/null flow
# forms are safe to rewrite without a YAML parser; reject aliases/anchors and
# non-empty flow forms rather than risk duplicate keys or an invalid runtime.
function direct_section(kind, start, end,   i, j, ind, val, text, rest, item, name, collision, rootind) {
	val = start ? value_of(output[start]) : ""
	if (val != "" && val !~ /^(null|~|\[[[:space:]]*\])$/)
		injection_error(kind)
	ind = "  "
	for (i = start + 1; start && i <= end; i++) {
		if (output[i] ~ /^[[:space:]]*($|#)/) continue
		text = output[i]
		sub(/^[[:space:]]*/, "", text)
		if (text !~ /^-[[:space:]]+/) injection_error(kind)
		ind = substr(output[i], 1, indent_of(output[i]))
		break
	}
	print (start && val == "" ? output[start] : kind ":")
	if (kind == "rules")
		print ind "- IN-NAME,mihowrt-direct,DIRECT"
	else {
		print ind "- name: mihowrt-direct"
		print ind "  type: tproxy"
		print ind "  listen: 0.0.0.0"
		print ind "  port: " direct_tproxy
		print ind "  udp: true"
	}
	for (i = start + 1; start && i <= end; i++) {
		if (kind != "listeners" || output[i] ~ /^[[:space:]]*($|#)/) {
			print output[i]
			continue
		}
		text = substr(output[i], length(ind) + 1)
		if (text !~ /^-[[:space:]]+/) injection_error(kind)
		# Find the whole mapping item, including nested listener settings.
		for (j = i + 1; j <= end; j++)
			if (output[j] !~ /^[[:space:]]*($|#)/ && indent_of(output[j]) <= length(ind)) break
		item = j - 1
		match(text, /^-[[:space:]]+/)
		rootind = length(ind) + RLENGTH
		sub(/^-[[:space:]]+/, "", text)
		if (key_of(text) == "") injection_error(kind)
		collision = 0
		for (j = i; j <= item; j++) {
			rest = j == i ? text : substr(output[j], rootind + 1)
			if (j != i && indent_of(output[j]) != rootind) continue
			if (rest ~ /^<</) injection_error(kind)
			if (key_of(rest) != "name") continue
			name = unquote(value_of(rest))
			if (name ~ /^[*&!|>]/ || index(name, "\\")) injection_error(kind)
			if (name == "mihowrt-direct") collision = 1
		}
		if (collision)
			print "Provider listener mihowrt-direct replaced by the MihoWRT direct listener" >warnfile
		else
			for (j = i; j <= item; j++) print output[j]
		i = item
	}
}
function print_runtime(   i, j, kind, found_listeners, found_rules) {
	if (dns_mode() != "fake-ip" || filter == "whitelist") {
		for (i = 1; i <= output_count; i++) print output[i]
		return
	}
	for (i = 1; i <= output_count; i++) {
		kind = key_of(output[i])
		if (kind != "listeners" && kind != "rules") {
			print output[i]
			continue
		}
		if ((kind == "listeners" && found_listeners++) || (kind == "rules" && found_rules++))
			injection_error(kind)
		for (j = i + 1; j <= output_count; j++)
			if (output[j] ~ /^[^[:space:]#-]/) break
		direct_section(kind, i, j - 1)
		i = j - 1
	}
	if (!found_listeners) direct_section("listeners", 0, 0)
	if (!found_rules) direct_section("rules", 0, 0)
}
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
	sub(/^#.*/, "", text)
	sub(/[[:space:]]+#.*/, "", text)
	sub(/[[:space:]]+$/, "", text)
	return text
}
function unquote(text) {
	if (text ~ /^".*"$/)
		text = substr(text, 2, length(text) - 2)
	else if (text ~ /^\047.*\047$/) {
		text = substr(text, 2, length(text) - 2)
		gsub(/\047\047/, "\047", text)
	}
	return text
}
# First "- name:" item of the block-style proxy-groups list.
function group_item(line) {
	if (in_groups && group == "" && line ~ /^[[:space:]]*-[[:space:]]+["\047]?name["\047]?[[:space:]]*:/) {
		group = unquote(value_of(substr(line, index(line, "-") + 1)))
		if (group == "")
			group = "-"
	}
}
function indent_of(text) {
	match(text, /^[[:space:]]*/)
	return RLENGTH
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
{
	sub(/\r$/, "")
	if (NR == 1)
		sub(/^\357\273\277/, "")
	line = $0
	# Indentless list item ("key:\n- a"): part of the previous key.
	if (line ~ /^-([[:space:]]|$)/) {
		group_item(line)
		if (!skip)
			emit(line)
		next
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
			dns_line = line
			dns_pending = 1
			next
		}
		if (!skip)
			emit(line)
		next
	}
	if (in_x)
		x_line(line)
	group_item(line)
	if (skip)
		next
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
			next
	}
	emit(line)
}
END {
	if (in_dns)
		flush_dns()
	if (!seen_dns)
		enh = "redir-host"
	print "mode " ((dns_mode() == "fake-ip" && filter == "whitelist") ? "direct-first" : "proxy-first") >profile
	print "dns " dns_mode() >profile
	emit("")
	emit("# --- MihoWRT managed: generated, edits here are discarded ---")
	if (!seen_dns) {
		suffix = ""
		if (group != "" && group != "-" && group !~ /[#&"\\]/)
			suffix = "#" group
		else
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
	print_runtime()
}
