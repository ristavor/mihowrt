#!/bin/ash

# Mihomo core install/update. The new binary is unpacked next to the old one,
# checked (-v and config test) and moved into place atomically. No RAM copy.

core_arch() {
	case "$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p" /etc/openwrt_release 2>/dev/null)" in
	aarch64_*) echo arm64 ;;
	x86_64) echo amd64 ;;
	i386_*) echo 386 ;;
	riscv64_*) echo riscv64 ;;
	loongarch64_*) echo loong64 ;;
	mips64el_*) echo mips64le ;;
	mips64_*) echo mips64 ;;
	mipsel_*hardfloat*) echo mipsle-hardfloat ;;
	mipsel_*) echo mipsle-softfloat ;;
	mips_*hardfloat*) echo mips-hardfloat ;;
	mips_*) echo mips-softfloat ;;
	arm_*neon-vfp*) echo armv7 ;;
	arm_*neon* | arm_*vfp*) echo armv6 ;;
	arm_*) echo armv5 ;;
	*) return 1 ;;
	esac
}

core_version() {
	[ -x "${1:-$CLASH_BIN}" ] || return 1
	"${1:-$CLASH_BIN}" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

core_version_json() {
	local version=""

	version="$(core_version)"
	jq -nc --arg v "$version" '{version: $v, installed: ($v != "")}'
}

core_asset_names() {
	case "$1" in
	amd64) printf '%s\n' "mihomo-linux-amd64-compatible-$2.gz" "mihomo-linux-amd64-v1-$2.gz" "mihomo-linux-amd64-$2.gz" ;;
	386) printf '%s\n' "mihomo-linux-386-$2.gz" "mihomo-linux-386-softfloat-$2.gz" ;;
	loong64) printf '%s\n' "mihomo-linux-loong64-abi1-$2.gz" "mihomo-linux-loong64-abi2-$2.gz" "mihomo-linux-loong64-$2.gz" ;;
	*) printf '%s\n' "mihomo-linux-$1-$2.gz" ;;
	esac
}

# Uncompressed size from the gzip trailer.
core_gzip_isize() {
	tail -c 4 "$1" 2>/dev/null | hexdump -v -e '4/1 "%u " "\n"' |
		awk 'NF == 4 { print $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 }'
}

core_free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

core_fail() {
	CORE_ERROR="$*"
	err "Core update: $*"
	rm -rf "$KERNEL_TMP_DIR" "$CLASH_BIN.new"
	return 1
}

# Install the latest release. Sets CORE_UPDATED (0|1), CORE_VERSION, CORE_ERROR.
core_update() {
	local arch="" json="" tag="" current="" name="" meta="" url="" digest="" size="" gz="" isize="" free=""
	local config="$PKG_TMP_DIR/core-test.yaml"

	CORE_UPDATED=0
	CORE_ERROR=""
	CORE_VERSION="$(core_version)"
	settings_load 2>/dev/null || true
	arch="$(core_arch)" || core_fail "unsupported architecture" || return 1
	ensure_dir "$KERNEL_TMP_DIR" || return 1
	json="$KERNEL_TMP_DIR/release.json"
	gz="$KERNEL_TMP_DIR/mihomo.gz"
	current="$CORE_VERSION"
	if http_fetch "$MIHOMO_RELEASES_API" "$json" "$KERNEL_RELEASE_JSON_MAX_BYTES" 30 0; then
		tag="$(jq -r '.tag_name // empty' "$json")"
		[ -n "$tag" ] || core_fail "release has no tag" || return 1
		[ "$current" != "$tag" ] || {
			rm -rf "$KERNEL_TMP_DIR"
			return 0
		}
		for name in $(core_asset_names "$arch" "$tag"); do
			meta="$(jq -r --arg n "$name" '.assets[]? | select(.name == $n) | "\(.browser_download_url)\t\(.digest // "")\t\(.size // "")"' "$json")"
			[ -n "$meta" ] && break
		done
		[ -n "$meta" ] || core_fail "no asset for $arch in $tag" || return 1
		url="$(printf '%s' "$meta" | cut -f1)"
		digest="$(printf '%s' "$meta" | cut -f2)"
		size="$(printf '%s' "$meta" | cut -f3)"
		http_fetch "$url" "$gz" "$KERNEL_ASSET_MAX_BYTES" 300 0 || core_fail "download failed ($FETCH_ERROR)" || return 1
	else
		# API blocked or rate-limited: tag from the github.com redirect and
		# direct download URLs (no published digest on this path).
		warn "Core update: GitHub API unavailable ($FETCH_ERROR); using github.com"
		tag="$(github_latest_tag "$MIHOMO_REPO")" || core_fail "cannot reach GitHub" || return 1
		[ "$current" != "$tag" ] || {
			rm -rf "$KERNEL_TMP_DIR"
			return 0
		}
		url=""
		for name in $(core_asset_names "$arch" "$tag"); do
			if http_fetch "https://github.com/$MIHOMO_REPO/releases/download/$tag/$name" "$gz" "$KERNEL_ASSET_MAX_BYTES" 300 0; then
				url="$name"
				break
			fi
		done
		[ -n "$url" ] || core_fail "no downloadable asset for $arch in $tag" || return 1
	fi
	if is_uint "$size" && [ "$(wc -c <"$gz" | tr -d ' ')" != "$size" ]; then
		core_fail "downloaded size does not match release" || return 1
	fi
	case "$digest" in
	sha256:*)
		[ "$(sha256sum "$gz" | cut -d' ' -f1)" = "${digest#sha256:}" ] || core_fail "sha256 mismatch" || return 1
		;;
	*) warn "Core update: release has no sha256 digest; size check only" ;;
	esac

	isize="$(core_gzip_isize "$gz")"
	free="$(core_free_kb "$(dirname "$CLASH_BIN")")"
	is_uint "$isize" && is_uint "$free" || core_fail "cannot check free space" || return 1
	[ $((free * 1024)) -ge $((isize + 4194304)) ] ||
		core_fail "not enough flash: need $(((isize + 4194304) / 1048576)) MiB, free $((free / 1024)) MiB" || return 1

	ensure_dir "$(dirname "$CLASH_BIN")" || return 1
	gzip -dc "$gz" >"$CLASH_BIN.new" && chmod 755 "$CLASH_BIN.new" || core_fail "unpack failed" || return 1
	[ -n "$(core_version "$CLASH_BIN.new")" ] || core_fail "new binary does not run on this router" || return 1
	if [ -r "$CLASH_CONFIG" ] && mihomo_config_generate "$CLASH_CONFIG" "$config" 2>/dev/null; then
		mihomo_config_test "$config" "$CLASH_BIN.new" || core_fail "new core rejects the current config" || return 1
		config_check_record ok
	fi
	mv -f "$CLASH_BIN.new" "$CLASH_BIN" || core_fail "cannot replace binary" || return 1
	rm -rf "$KERNEL_TMP_DIR" "$config" "$config.profile"
	CORE_UPDATED=1
	CORE_VERSION="$tag"
	log "Mihomo core updated: ${current:-none} -> $tag"
}

core_update_json() {
	local rc=0

	core_update || rc=$?
	jq -nc --arg v "$CORE_VERSION" --arg e "$CORE_ERROR" --arg u "$CORE_UPDATED" \
		'{updated: ($u == "1"), version: $v, error: (if $e == "" then null else $e end)}'
	return "$rc"
}
