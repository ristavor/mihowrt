#!/bin/ash

# Policy lists: one entry per line, IPv4 or IPv6.
#   addr[/prefix][;ports]   e.g. 1.1.1.1, 2001:db8::/32;443
#   ;ports                  any address on these ports
#   URL[;ports]             remote list (cached); a trailing "| hours" is ignored
# Remote URLs are fetched by lists_update_remote and read from the cache, so
# applying policy never waits on the network. The provider may ship dst and
# direct lists (x-mihowrt proxy-ips/direct-ips); the user's list source
# setting picks provider, provider + own file, or own file only.

LISTS_REMOTE_MAX_BYTES="${LISTS_REMOTE_MAX_BYTES:-262144}"
LISTS_REMOTE_MAX_URLS="${LISTS_REMOTE_MAX_URLS:-32}"
LISTS_REMOTE_TIMEOUT="${LISTS_REMOTE_TIMEOUT:-30}"

lists_file() {
	case "$1" in
	dst) printf '%s' "$DST_LIST_FILE" ;;
	src) printf '%s' "$SRC_LIST_FILE" ;;
	direct) printf '%s' "$DIRECT_DST_LIST_FILE" ;;
	direct_src) printf '%s' "$DIRECT_SRC_LIST_FILE" ;;
	*) return 1 ;;
	esac
}

# True when the provider ships this list (key present, even if empty).
lists_provided() {
	case "$1" in
	dst) profile_has proxy-ips ;;
	direct) profile_has direct-ips ;;
	*) return 1 ;;
	esac
}

lists_provider_entries() {
	case "$1" in
	dst) profile_entries proxy-ip | lists_clean_lines ;;
	direct) profile_entries direct-ip | lists_clean_lines ;;
	esac
}

# Cleaned entries that apply for one kind.
lists_source() {
	local kind="$1" file="" source="own"

	file="$(lists_file "$kind")" || return 1
	if lists_provided "$kind"; then
		case "$kind" in
		dst) source="${DST_LIST_SOURCE:-provider}" ;;
		direct) source="${DIRECT_LIST_SOURCE:-provider}" ;;
		esac
	fi
	case "$source" in
	provider | merge) lists_provider_entries "$kind" ;;
	esac
	[ "$source" = provider ] || [ ! -r "$file" ] || lists_clean_lines "$file"
	return 0
}

lists_ensure_files() {
	local kind=""

	ensure_dir "$LIST_DIR" || return 1
	for kind in dst src direct direct_src; do
		[ -f "$(lists_file "$kind")" ] || : >"$(lists_file "$kind")"
	done
}

# One awk pass validates and classifies entries (a fork per entry is far too
# slow on router CPUs). Prints "<family> <entry>", family 4, 6 or any; with
# -v bad=1 prints only the invalid lines.
lists_classify() {
	awk -v bad="${1:-0}" '
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
			if (ports != "" && !ports_ok(ports)) fam = ""
			else if (addr == "") fam = (ports != "") ? "any" : ""
			else if (v4(addr)) fam = "4"
			else if (v6(addr)) fam = "6"
			if (bad) { if (fam == "") print; next }
			if (fam != "") print fam " " $0
		}
	'
}

# Print 4, 6 or "any" for one entry; status 1 when invalid.
list_entry_family() {
	local family=""

	family="$(printf '%s\n' "$1" | lists_classify | cut -d' ' -f1)"
	[ -n "$family" ] && printf '%s' "$family"
}

# Strip comments, spaces and the legacy " | hours" suffix.
lists_clean_lines() {
	sed -e 's/#.*//' -e 's/|.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"
}

lists_url_key() {
	printf '%s' "$1" | sha256sum | cut -c1-16
}

lists_cache_file() {
	printf '%s/%s.txt' "$POLICY_CACHE_DIR" "$(lists_url_key "$1")"
}

lists_urls() {
	local kind=""

	for kind in dst src direct direct_src; do
		lists_source "$kind"
	done | sed -n 's/;.*//; /^https\?:\/\//p' | awk '!seen[$0]++'
}

lists_resolve() {
	local kind="$1" out4="$2" out6="$3" src="" line="" url="" ports="" cache="" bad=""

	src="$PKG_TMP_DIR/list.$kind.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	lists_source "$kind" >"$src" || return 1
	if ! { : >"$out4" && : >"$out6"; }; then
		rm -f "$src"
		return 1
	fi
	# User files are validated on save; provider entries only here.
	bad="$({ grep -v '^https\?://' "$src" || true; } | lists_classify 1 | tr '\n' ' ')"
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
	} | lists_classify | awk -v o4="$out4" -v o6="$out6" '
		$1 == "4" { print $2 >o4 }
		$1 == "6" { print $2 >o6 }
		$1 == "any" { print $2 >o4; print $2 >o6 }
	'
	rm -f "$src"
	# BusyBox sort on OpenWrt has no -o.
	sort -u "$out4" >"$out4.sorted" && mv -f "$out4.sorted" "$out4" &&
		sort -u "$out6" >"$out6.sorted" && mv -f "$out6.sorted" "$out6"
}

# True when the cache for a URL is missing or older than LISTS_INTERVAL hours.
lists_remote_due() {
	local cache="$1"

	[ -f "$cache" ] || return 0
	[ "${LISTS_INTERVAL:-0}" -gt 0 ] || return 1
	[ -n "$(find "$cache" -mmin +$((LISTS_INTERVAL * 60 - 5)) 2>/dev/null)" ]
}

# Fetch due remote lists into the cache. Prints "changed" or "unchanged".
lists_update_remote() {
	local force="${1:-0}" url="" cache="" tmp="" line="" count=0 changed=0 failed=0

	ensure_dir "$POLICY_CACHE_DIR" || return 1
	tmp="$PKG_TMP_DIR/list.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	# URLs come from providers too: no pathname expansion.
	set -f
	for url in $(lists_urls); do
		count=$((count + 1))
		[ "$count" -le "$LISTS_REMOTE_MAX_URLS" ] || {
			warn "Too many remote lists; only $LISTS_REMOTE_MAX_URLS are used"
			break
		}
		cache="$(lists_cache_file "$url")"
		[ "$force" = "1" ] || lists_remote_due "$cache" || continue
		if ! http_fetch "$url" "$tmp" "$LISTS_REMOTE_MAX_BYTES" "$LISTS_REMOTE_TIMEOUT" 0; then
			warn "Remote list fetch failed: $(url_host "$url") ($FETCH_ERROR)"
			failed=1
			continue
		fi
		lists_clean_lines "$tmp" | lists_classify | cut -d' ' -f2- >"$tmp.clean"
		if cmp -s "$tmp.clean" "$cache"; then
			touch "$cache"
		else
			mv -f "$tmp.clean" "$cache" && changed=1
		fi
	done
	set +f
	rm -f "$tmp" "$tmp.clean"
	if [ "$changed" -eq 1 ]; then
		echo changed
	else
		echo unchanged
	fi
	[ "$failed" -eq 0 ]
}

# Entries that apply (provider and/or own, per the list source).
lists_count() {
	lists_source "$1" | wc -l | tr -d ' '
}

# Entries in the user's own file.
lists_own_count() {
	local file=""

	file="$(lists_file "$1")" || return 1
	[ -r "$file" ] || {
		echo 0
		return 0
	}
	lists_clean_lines "$file" | wc -l | tr -d ' '
}
