#!/bin/ash

kernel_error() {
	err "$*"
	printf 'Error: %s\n' "$*" >&2
}

kernel_clear_stage() {
	[ -n "${KERNEL_STAGED_BIN:-}" ] && rm -f "$KERNEL_STAGED_BIN"
	KERNEL_STAGED_BIN=""
	KERNEL_STAGED_TAG=""
	KERNEL_STAGED_ARCH=""
	KERNEL_STAGED_ASSET=""
	KERNEL_STAGED_IDENTICAL=0
	rm -f "${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}"/*.gz 2>/dev/null || true
}

kernel_clear_all_tmp() {
	kernel_clear_stage
	rm -rf "${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}"
}

kernel_release_json() {
	fetch_http_body_limited \
		"${MIHOMO_RELEASES_API:-https://api.github.com/repos/MetaCubeX/mihomo/releases/latest}" \
		"${KERNEL_RELEASE_JSON_MAX_BYTES:-2097152}" \
		"${KERNEL_FETCH_TIMEOUT:-60}" \
		"Mihomo release"
}

kernel_release_tag() {
	jq -r '.tag_name // ""' 2>/dev/null
}

kernel_asset_url() {
	local asset_name="$1"

	jq -r --arg name "$asset_name" '
		.assets[]? | select(.name == $name) | .browser_download_url
	' 2>/dev/null | head -n1
}

kernel_asset_candidates() {
	local arch="$1"
	local tag="$2"

	case "$arch" in
	amd64)
		printf '%s\n' \
			"mihomo-linux-amd64-compatible-$tag.gz" \
			"mihomo-linux-amd64-v1-$tag.gz" \
			"mihomo-linux-amd64-$tag.gz"
		;;
	386)
		printf '%s\n' \
			"mihomo-linux-386-$tag.gz" \
			"mihomo-linux-386-softfloat-$tag.gz"
		;;
	loong64)
		printf '%s\n' \
			"mihomo-linux-loong64-abi1-$tag.gz" \
			"mihomo-linux-loong64-abi2-$tag.gz" \
			"mihomo-linux-loong64-$tag.gz"
		;;
	*)
		printf '%s\n' "mihomo-linux-$arch-$tag.gz"
		;;
	esac
}

kernel_select_asset() {
	local release_json="$1"
	local arch="$2"
	local tag="$3"
	local asset_name="" asset_url=""

	while IFS= read -r asset_name; do
		[ -n "$asset_name" ] || continue
		asset_url="$(printf '%s\n' "$release_json" | kernel_asset_url "$asset_name")"
		[ -n "$asset_url" ] || continue
		printf '%s	%s\n' "$asset_name" "$asset_url"
		return 0
	done <<EOF
$(kernel_asset_candidates "$arch" "$tag")
EOF

	return 1
}

kernel_stage_binary_from_asset() {
	local asset_url="$1"
	local asset_name="$2"
	local tmpgz="" tmpbin=""

	ensure_dir "${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}" || return 1
	tmpgz="${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}/$asset_name"
	tmpbin="${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}/clash.staged"

	rm -f "$tmpgz" "$tmpbin"
	if ! fetch_http_body_limited_to_file \
		"$asset_url" \
		"${KERNEL_ASSET_MAX_BYTES:-67108864}" \
		"${KERNEL_FETCH_TIMEOUT:-60}" \
		"Mihomo kernel" \
		"$tmpgz" \
		0; then
		rm -f "$tmpgz" "$tmpbin"
		kernel_error "${FETCH_HTTP_ERROR_MESSAGE:-failed to download Mihomo asset $asset_name}"
		return 1
	fi

	if ! gzip -dc "$tmpgz" >"$tmpbin"; then
		rm -f "$tmpgz" "$tmpbin"
		kernel_error "failed to decompress Mihomo asset $asset_name"
		return 1
	fi
	rm -f "$tmpgz"

	if ! chmod 0755 "$tmpbin"; then
		rm -f "$tmpbin"
		kernel_error "failed to chmod Mihomo binary"
		return 1
	fi

	if ! "$tmpbin" -v >/dev/null 2>&1; then
		rm -f "$tmpbin"
		kernel_error "downloaded Mihomo binary failed self-check"
		return 1
	fi

	if [ -f "$CLASH_BIN" ] && cmp -s "$tmpbin" "$CLASH_BIN" 2>/dev/null; then
		rm -f "$tmpbin"
		KERNEL_STAGED_IDENTICAL=1
		return 0
	fi

	KERNEL_STAGED_BIN="$tmpbin"
	KERNEL_STAGED_ASSET="$asset_name"
}

kernel_stage_available() {
	[ -n "${KERNEL_STAGED_BIN:-}" ] && [ -x "$KERNEL_STAGED_BIN" ]
}

kernel_restore_backup_after_failure() {
	local backup_path="${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}/clash.previous"

	rm -f "$CLASH_BIN" 2>/dev/null || true
	[ -f "$backup_path" ] || return 0
	cp -f "$backup_path" "$CLASH_BIN" || return 1
	chmod 0755 "$CLASH_BIN" 2>/dev/null || true
}

kernel_install_staged_update() {
	local backup_path="${KERNEL_TMP_DIR:-/tmp/mihowrt/kernel-update}/clash.previous"
	local clash_bin_dir=""

	kernel_stage_available || return 0
	clash_bin_dir="${CLASH_BIN%/*}"
	ensure_dir "$clash_bin_dir" || return 1

	rm -f "$backup_path"
	if [ -f "$CLASH_BIN" ]; then
		cp -f "$CLASH_BIN" "$backup_path" || {
			kernel_error "failed to stage previous Mihomo kernel"
			return 1
		}
	fi

	rm -f "$CLASH_BIN" || {
		kernel_error "failed to remove previous Mihomo kernel"
		return 1
	}

	if ! mv -f "$KERNEL_STAGED_BIN" "$CLASH_BIN"; then
		kernel_restore_backup_after_failure || true
		kernel_error "failed to install Mihomo kernel"
		return 1
	fi
	KERNEL_STAGED_BIN=""

	if ! chmod 0755 "$CLASH_BIN"; then
		kernel_restore_backup_after_failure || true
		kernel_error "failed to chmod installed Mihomo kernel"
		return 1
	fi

	rm -f "$backup_path"
	return 0
}

kernel_update_service_running() {
	command -v service_running_state >/dev/null 2>&1 || return 1
	service_running_state
}

kernel_update_result_json() {
	local action="$1"
	local updated="$2"
	local restart_required="$3"
	local arch="$4"
	local current_version="$5"
	local latest_version="$6"
	local asset_name="$7"
	local reason="$8"

	jq -nc \
		--arg action "$action" \
		--arg updated "$updated" \
		--arg restart_required "$restart_required" \
		--arg arch "$arch" \
		--arg current_version "$current_version" \
		--arg latest_version "$latest_version" \
		--arg asset "$asset_name" \
		--arg reason "$reason" \
		'{
			action: $action,
			updated: ($updated == "1"),
			restart_required: ($restart_required == "1"),
			arch: $arch,
			current_version: $current_version,
			latest_version: $latest_version,
			asset: $asset,
			reason: $reason
		}'
}

kernel_update_json() {
	local arch="" release_json="" latest_tag="" latest_ver=""
	local current_raw="" current_ver="" selected="" asset_name="" asset_url=""
	local restart_required=0

	require_command jq || return 1
	require_command gzip || return 1

	arch="$(detect_mihomo_arch)" || {
		kernel_error "unable to detect Mihomo architecture from /etc/openwrt_release"
		return 1
	}
	current_raw="$(current_mihomo_version 2>/dev/null || true)"
	current_ver="$(normalize_version "$current_raw")"

	release_json="$(kernel_release_json)" || {
		kernel_error "${FETCH_HTTP_ERROR_MESSAGE:-failed to query Mihomo latest release}"
		return 1
	}
	latest_tag="$(printf '%s\n' "$release_json" | kernel_release_tag)"
	[ -n "$latest_tag" ] || {
		kernel_error "latest Mihomo release has no tag_name"
		return 1
	}
	latest_ver="$(normalize_version "$latest_tag")"

	if [ -n "$current_ver" ] && [ -n "$latest_ver" ] && version_ge "$current_ver" "$latest_ver"; then
		kernel_update_result_json "up_to_date" 0 0 "$arch" "$current_raw" "$latest_tag" "" "Mihomo kernel already up to date"
		return 0
	fi

	selected="$(kernel_select_asset "$release_json" "$arch" "$latest_tag")" || {
		kernel_error "no Mihomo asset found for architecture $arch"
		return 1
	}
	asset_name="${selected%%	*}"
	asset_url="${selected#*	}"

	KERNEL_STAGED_BIN=""
	KERNEL_STAGED_TAG="$latest_tag"
	KERNEL_STAGED_ARCH="$arch"
	KERNEL_STAGED_ASSET="$asset_name"
	KERNEL_STAGED_IDENTICAL=0

	if ! kernel_stage_binary_from_asset "$asset_url" "$asset_name"; then
		kernel_clear_all_tmp
		return 1
	fi

	if [ "$KERNEL_STAGED_IDENTICAL" = "1" ]; then
		kernel_clear_all_tmp
		kernel_update_result_json "unchanged" 0 0 "$arch" "$current_raw" "$latest_tag" "$asset_name" "Downloaded Mihomo kernel is identical to installed binary"
		return 0
	fi

	kernel_update_service_running && restart_required=1 || restart_required=0
	if ! kernel_install_staged_update; then
		kernel_clear_stage
		return 1
	fi

	log "Updated Mihomo kernel to $latest_tag for arch $arch"
	kernel_update_result_json "updated" 1 "$restart_required" "$arch" "$current_raw" "$latest_tag" "$asset_name" "Mihomo kernel updated"
	kernel_clear_all_tmp
	return 0
}
