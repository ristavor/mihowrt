#!/bin/ash

# Policy lists: one entry per line, IPv4, IPv6 or MAC (device lists only).
#   addr[/prefix][;ports]   e.g. 1.1.1.1, 2001:db8::/32;443
#   ;ports                  any address on these ports
#   URL[;ports]             remote list (cached); a trailing "| hours" is ignored
# Remote URLs are fetched by lists_update_remote and read from the cache, so
# applying policy never waits on the network. The provider may ship dst and
# direct lists (x-mihowrt proxy-ips/direct-ips); the user's list source
# setting picks provider, provider + own file, or own file only.

LISTS_REMOTE_MAX_BYTES="${LISTS_REMOTE_MAX_BYTES:-1048576}"
LISTS_OWN_MAX_BYTES=1048576
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

# Provider URLs may point only to public HTTPS hosts. DNS resolution is not
# checked here; this policy excludes private address literals, not DNS rebinding.
lists_provider_url_ok() {
	local url="$1" host=""

	case "$url" in https://?*) ;; *) return 1 ;; esac
	is_http_url "$url" || return 1
	host="$(url_host "${url%%#*}" | tr '[:upper:]' '[:lower:]')"
	case "$host" in '' | localhost | localhost. | *%*) return 1 ;; esac
	# curl accepts shortened, integer, hex and octal IPv4. Numeric hosts must
	# instead be canonical decimal dotted quads before the public-range check.
	printf '%s\n' "$host" | awk -F. '
		{
			n = NF; if ($n == "") n--
			for (i = 1; i <= n; i++)
				if ($i !~ /^[0-9]+$/ && $i !~ /^0x[0-9a-f]+$/) exit 0
			if (NF != 4 || n != 4) exit 1
			for (i = 1; i <= n; i++)
				if ($i !~ /^(0|[1-9][0-9]*)$/ || $i + 0 > 255) exit 1
		}
	' || return 1
	if is_ipv4 "$host"; then
		printf '%s\n' "$host" | awk -F. '
			{ exit ($1 == 0 || $1 == 10 || $1 == 127 ||
				($1 == 172 && $2 >= 16 && $2 <= 31) ||
				($1 == 192 && $2 == 168) || ($1 == 169 && $2 == 254) ||
				($1 == 100 && $2 >= 64 && $2 <= 127)) ? 1 : 0 }
		'
	elif is_ipv6 "$host"; then
		# Expand :: to reject mapped/compat IPv4 regardless of spelling.
		printf '%s\n' "$host" | awk '
			function group(s) { sub(/^0+/, "", s); return s == "" ? "0" : s }
			{
				dbl = index($0, "::")
				if (dbl) {
					left = substr($0, 1, dbl - 1); right = substr($0, dbl + 2)
					nl = left == "" ? 0 : split(left, l, ":")
					nr = right == "" ? 0 : split(right, r, ":")
					for (i = 1; i <= 8; i++)
						a[i] = i <= nl ? l[i] : (i > 8 - nr ? r[i - (8 - nr)] : "0")
				} else split($0, a, ":")
				zero = 1
				for (i = 1; i <= 5; i++) if (group(a[i]) != "0") zero = 0
				if (zero && (group(a[6]) == "0" || group(a[6]) == "ffff")) exit 1
				first = group(a[1])
				if (first ~ /^f[cd][0-9a-f][0-9a-f]$/ || first ~ /^fe[89ab][0-9a-f]$/) exit 1
			}
		'
	else
		# A colon-bearing host that is not a valid IPv6 literal is not public.
		case "$host" in *:*) return 1 ;; esac
	fi
}

lists_provider_entries() {
	local line="" url="" key=""

	case "$1" in
	dst) key=proxy-ip ;;
	direct) key=direct-ip ;;
	*) return 0 ;;
	esac
	profile_entries "$key" | lists_clean_lines | while IFS= read -r line; do
		case "$line" in
		*://*)
			url="${line%%;*}"
			lists_provider_url_ok "$url" || {
				warn "x-mihowrt: ignored list URL $url (only public https URLs)"
				continue
			}
			;;
		esac
		printf '%s\n' "$line"
	done
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
# slow on router CPUs). Prints "<family> <entry>", family 4, 6, mac or any; with
# -v bad=1 prints only the invalid lines.
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
			if (ports != "" && !ports_ok(ports)) fam = ""
			else if (addr == "") fam = (ports != "") ? "any" : ""
			else if (v4(addr)) fam = "4"
			else if (v6(addr)) fam = "6"
			else if (!index($0, ";") && mac(addr) && kind != "dst" && kind != "direct") { fam = "mac"; $0 = tolower($0) }
			if (bad) { if (fam == "") print; next }
			if (fam != "") print fam " " $0
		}
	'
}

# Strip comments and whitespace.
lists_clean_lines() {
	sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"
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

# Retain caches for every current URL, including those beyond the fetch cap.
lists_cache_gc() {
	local keys="" cache="" url=""

	keys="$(lists_urls | while IFS= read -r url; do lists_url_key "$url"; echo; done)"
	for cache in "$POLICY_CACHE_DIR"/*.txt; do
		[ -f "$cache" ] || continue
		printf '%s\n' "$keys" | grep -Fxq "$(basename "$cache" .txt)" || rm -f "$cache"
	done
}

# --rawfile preserves UTF-8, escaping and trailing newlines without shell
# argument-size limits; a missing file has the same contents as /dev/null.
lists_json() {
	local kind="" file=""

	set --
	for kind in dst src direct direct_src; do
		file="$(lists_file "$kind")" || return 1
		[ -f "$file" ] || file=/dev/null
		set -- "$@" --rawfile "$kind" "$file"
	done
	jq -nc "$@" '{dst: $dst, src: $src, direct: $direct, direct_src: $direct_src}'
}

# Optional fourth argument receives device MACs, separately from IP families.
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
			rm -f "${FETCH_HDR:-}"
			warn "Remote list fetch failed: $(url_host "$url") ($FETCH_ERROR)"
			failed=1
			continue
		fi
		rm -f "${FETCH_HDR:-}"
		lists_clean_lines "$tmp" | lists_classify | cut -d' ' -f2- >"$tmp.clean"
		if cmp -s "$tmp.clean" "$cache"; then
			touch "$cache"
		else
			mv -f "$tmp.clean" "$cache" && changed=1
		fi
	done
	set +f
	rm -f "$tmp" "$tmp.clean"
	lists_cache_gc || return 1
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

# Install edited lists uploaded by LuCI (/tmp/mihowrt-policy-list.*) after
# validating every line. Runs under the runtime lock; prints 1 if changed.
lists_install() {
	local kind="" tmp="" bad="" url="" changed=0 dst="" size=""

	for kind in dst src direct direct_src; do
		tmp="$1"
		shift
		eval "LIST_TMP_$kind=\"\$tmp\""
		[ "$tmp" != - ] || continue
		upload_path_allowed /tmp/mihowrt-policy-list. "$tmp" || {
			err "List path not allowed: $tmp"
			return 1
		}
		size="$(wc -c <"$tmp" | tr -d ' ')"
		[ "$size" -le "$LISTS_OWN_MAX_BYTES" ] || {
			err "List $kind is larger than 1 MiB."
			return 1
		}
		bad="$({ lists_clean_lines "$tmp" | grep -v '^https\?://' || true; } | lists_classify 1 "$kind" | tr '\n' ' ')"
		for url in $(lists_clean_lines "$tmp" | sed -n '/^https\?:\/\//p'); do
			is_http_url "${url%%;*}" && { [ "${url%%;*}" = "$url" ] || is_port_spec "${url#*;}"; } || bad="$bad$url "
		done
		[ -z "$bad" ] || {
			err "Invalid $kind entries: $bad"
			return 1
		}
	done
	for kind in dst src direct direct_src; do
		eval "tmp=\"\$LIST_TMP_$kind\""
		[ "$tmp" != - ] || continue
		dst="$(lists_file "$kind")"
		case "$kind" in
		src | direct_src)
			# Only MAC lines are case-normalized; preserve comments and IP text.
			if ! { awk '
				{
					entry = $0; sub(/#.*/, "", entry); gsub(/[[:space:]]/, "", entry)
					if (split(entry, a, ":") == 6) {
						valid = 1
						for (i = 1; i <= 6; i++) if (a[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) valid = 0
						if (valid) {
							comment = index($0, "#")
							$0 = comment ? tolower(substr($0, 1, comment - 1)) substr($0, comment) : tolower($0)
						}
					}
					print
				}
			' "$tmp" >"$tmp.normalized" && mv -f "$tmp.normalized" "$tmp"; }; then
				rm -f "$tmp.normalized"
				return 1
			fi
			;;
		esac
		if ! cmp -s "$tmp" "$dst"; then
			# Copy next to the target and rename: a full flash cannot leave
			# a half-written list.
			if ! { cp "$tmp" "$dst.new" && mv -f "$dst.new" "$dst"; }; then
				rm -f "$dst.new"
				return 1
			fi
			changed=1
		fi
	done
	settings_load && cron_update
	echo "$changed"
}

# apply-lists: install under the lock, fetch new remote URLs without it,
# then rebuild nft under the lock.
lists_apply() {
	local changed="" rc=0 tmp=""

	changed="$(with_lock lists_install "$@")" || rc=1
	for tmp in "$@"; do
		[ "$tmp" = - ] || rm -f "$tmp"
	done
	[ "$rc" -eq 0 ] || return 1
	if service_ready; then
		settings_load || return 1
		lists_update_remote 0 >/dev/null || warn "Some remote lists could not be fetched"
		with_lock nft_apply || return 1
	fi
	jq -nc --arg c "$changed" '{changed: ($c == "1")}'
}

lists_refresh() {
	local result=""

	settings_load || return 1
	result="$(lists_update_remote 1)" || warn "Some remote lists could not be fetched"
	[ "$result" = changed ] && service_ready && { with_lock nft_apply || return 1; }
	jq -nc --arg r "$result" '{changed: ($r == "changed")}'
}
