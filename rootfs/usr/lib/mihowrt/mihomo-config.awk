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
			print line
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
			print line
		next
	}
	if (in_x)
		x_line(line)
	group_item(line)
	if (skip)
		next
	if (in_dns && line ~ /^[[:space:]]+[^[:space:]#]/) {
		if (dns_pending) {
			print dns_line
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
