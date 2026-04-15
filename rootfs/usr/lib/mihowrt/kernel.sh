#!/bin/ash

kernel_cleanup_tmp() {
	rm -f "$1" "$2"
}

kernel_fetch_url() {
	curl -fsSL "$1"
}

kernel_download_file() {
	curl -fL "$1" -o "$2"
}

kernel_ensure_installed() {
	local bindir

	if [ -x "$CLASH_BIN" ]; then
		log "Mihomo core already present at $CLASH_BIN"
		echo "present:$CLASH_BIN"
		return 0
	fi

	bindir="${CLASH_BIN%/*}"
	ensure_dir "$bindir"
	kernel_update
}

kernel_update() {
	local arch release_json latest_tag latest_ver current_ver asset_name asset_url
	local tmpdir tmpgz tmpbin

	require_command curl || return 1
	require_command gzip || return 1
	require_command jq || return 1

	arch="$(detect_mihomo_arch)" || {
		err "Unable to detect Mihomo architecture from /etc/openwrt_release"
		return 1
	}

	current_ver="$(normalize_version "$(current_mihomo_version)")"
	release_json="$(kernel_fetch_url "$MIHOMO_RELEASES_API")" || {
		err "Failed to query Mihomo latest release"
		return 1
	}

	latest_tag="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')" || return 1
	[ -n "$latest_tag" ] || {
		err "Latest release has no tag_name"
		return 1
	}

	latest_ver="$(normalize_version "$latest_tag")"
	if [ -n "$current_ver" ] && version_ge "$current_ver" "$latest_ver"; then
		log "Mihomo already up to date ($current_ver)"
		echo "already_up_to_date:$current_ver"
		return 0
	fi

	asset_name="mihomo-linux-${arch}-${latest_tag}.gz"
	asset_url="$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' | head -n1)"
	[ -n "$asset_url" ] || {
		err "No Mihomo asset found for architecture $arch"
		return 1
	}

	tmpdir="$KERNEL_UPDATE_TMP_DIR"
	ensure_dir "$tmpdir"
	tmpgz="$tmpdir/$asset_name"
	tmpbin="$tmpdir/clash"

	kernel_cleanup_tmp "$tmpgz" "$tmpbin"
	kernel_download_file "$asset_url" "$tmpgz" || {
		kernel_cleanup_tmp "$tmpgz" "$tmpbin"
		err "Failed to download Mihomo asset $asset_name"
		return 1
	}

	gzip -dc "$tmpgz" > "$tmpbin" || {
		kernel_cleanup_tmp "$tmpgz" "$tmpbin"
		err "Failed to decompress Mihomo asset"
		return 1
	}

	chmod 0755 "$tmpbin" || {
		kernel_cleanup_tmp "$tmpgz" "$tmpbin"
		return 1
	}
	"$tmpbin" -v >/dev/null 2>&1 || {
		kernel_cleanup_tmp "$tmpgz" "$tmpbin"
		err "Downloaded Mihomo binary failed self-check"
		return 1
	}

	if [ -f "$CLASH_BIN" ]; then
		cp -f "$CLASH_BIN" "$CLASH_BIN.bak" 2>/dev/null || true
	fi
	mv -f "$tmpbin" "$CLASH_BIN" || {
		kernel_cleanup_tmp "$tmpgz" "$tmpbin"
		return 1
	}
	rm -f "$tmpgz"

	log "Updated Mihomo core to $latest_tag for arch $arch"
	echo "updated:$latest_tag"
	return 0
}
