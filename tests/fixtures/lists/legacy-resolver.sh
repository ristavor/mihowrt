# Frozen at 62bf46d5, before L7; used only for resolved-output parity.

lists_classify() {
	awk -v bad="${1:-0}" -v kind="${2:-}" '
		function port_ok(p) { return p ~ /^[0-9]+$/ && p + 0 >= 1 && p + 0 <= 65535 }
		function ports_ok(s,   n, i, a, r) {
			if (s == "" || s ~ /^,|,$|,,/) return 0
			n = split(s, a, ",")
			for (i = 1; i <= n; i++) {
				if (split(a[i], r, "-") == 2) {
					if (!port_ok(r[1]) || !port_ok(r[2]) || r[1] + 0 > r[2] + 0) return 0
				} else if (!port_ok(a[i])) return 0
			}
			return 1
		}
		function prefix_ok(p, max) { return p ~ /^[0-9]+$/ && p + 0 <= max }
		function v4(s,   n, i, a) {
			if (index(s, "/")) { if (!prefix_ok(substr(s, index(s, "/") + 1), 32)) return 0; s = substr(s, 1, index(s, "/") - 1) }
			if (split(s, a, ".") != 4) return 0
			for (i = 1; i <= 4; i++) if (a[i] !~ /^[0-9][0-9]?[0-9]?$/ || a[i] + 0 > 255) return 0
			return 1
		}
		function mac(s,   i, a) {
			if (split(tolower(s), a, ":") != 6) return 0
			for (i = 1; i <= 6; i++) if (a[i] !~ /^[0-9a-f][0-9a-f]$/) return 0
			return 1
		}
		function v6(s,   n, i, a, g, dbl) {
			if (index(s, "/")) { if (!prefix_ok(substr(s, index(s, "/") + 1), 128)) return 0; s = substr(s, 1, index(s, "/") - 1) }
			if (s !~ /:/ || s ~ /[^0-9A-Fa-f:]/ || s ~ /:::/) return 0
			dbl = gsub(/::/, "&", s)
			if (dbl > 1) return 0
			if (s ~ /^:[^:]/ || s ~ /[^:]:$/) return 0
			n = split(s, a, ":"); g = 0
			for (i = 1; i <= n; i++) if (a[i] != "") { if (length(a[i]) > 4) return 0; g++ }
			return dbl ? g <= 7 : g == 8
		}
		{
			addr = $0; ports = ""
			if (index($0, ";")) { addr = substr($0, 1, index($0, ";") - 1); ports = substr($0, index($0, ";") + 1) }
			fam = ""
			if (index($0, ";") && !ports_ok(ports)) fam = ""
			else if (addr == "") fam = (ports != "") ? "any" : ""
			else if (v4(addr)) fam = "4"
			else if (v6(addr)) fam = "6"
			else if (!index($0, ";") && mac(addr) && kind != "dst" && kind != "direct") { fam = "mac"; $0 = tolower($0) }
			if (bad) { if (fam == "") print; next }
			if (fam != "") print fam " " $0
		}
	'
}

lists_resolve() {
	local kind="$1" out4="$2" out6="$3" outmac="${4:-}" src="" line="" url="" ports="" cache="" bad=""

	src="$PKG_TMP_DIR/list.$kind.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	lists_source "$kind" >"$src" || return 1
	if ! { : >"$out4" && : >"$out6" && { [ -z "$outmac" ] || : >"$outmac"; }; }; then
		rm -f "$src"
		return 1
	fi
	# User files are validated on save; provider entries only here.
	bad="$({ grep -v '^https\?://' "$src" || true; } | lists_classify 1 "$kind" | tr '\n' ' ')"
	[ -z "$bad" ] || warn "Ignoring invalid $kind entries: $bad"
	{
		grep -v '^https\?://' "$src" || true
		# Remote entries inherit the URL's ports unless they carry their own.
		sed -n '/^https\?:\/\//p' "$src" | while IFS= read -r line; do
			url="${line%%;*}"
			ports=""
			[ "$url" = "$line" ] || ports="${line#*;}"
			cache="$(lists_cache_file "$url")"
			[ -r "$cache" ] || continue
			awk -v p="$ports" 'p != "" && !index($0, ";") { $0 = $0 ";" p } { print }' "$cache"
		done
	} | lists_classify 0 "$kind" | awk -v o4="$out4" -v o6="$out6" -v omac="$outmac" '
		$1 == "4" { print $2 >o4 }
		$1 == "6" { print $2 >o6 }
		$1 == "mac" && omac != "" { print $2 >omac }
		$1 == "any" { print $2 >o4; print $2 >o6 }
	'
	rm -f "$src"
	# BusyBox sort on OpenWrt has no -o.
	sort -u "$out4" >"$out4.sorted" && mv -f "$out4.sorted" "$out4" &&
		sort -u "$out6" >"$out6.sorted" && mv -f "$out6.sorted" "$out6" || return 1
	if [ -n "$outmac" ]; then
		sort -u "$outmac" >"$outmac.sorted" && mv -f "$outmac.sorted" "$outmac" || return 1
	fi
	return 0
}
