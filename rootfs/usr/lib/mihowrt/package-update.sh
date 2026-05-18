#!/bin/ash

PACKAGE_UPDATE_NAME="${MIHOWRT_PACKAGE_NAME:-luci-app-mihowrt}"
PACKAGE_UPDATE_REPO_OWNER="${MIHOWRT_PACKAGE_REPO_OWNER:-ristavor}"
PACKAGE_UPDATE_REPO_NAME="${MIHOWRT_PACKAGE_REPO_NAME:-mihowrt}"
PACKAGE_UPDATE_RELEASE_URL="${MIHOWRT_PACKAGE_RELEASE_URL:-https://api.github.com/repos/${PACKAGE_UPDATE_REPO_OWNER}/${PACKAGE_UPDATE_REPO_NAME}/releases/latest}"
PACKAGE_UPDATE_RELEASE_MAX_BYTES="${MIHOWRT_PACKAGE_RELEASE_MAX_BYTES:-262144}"
PACKAGE_UPDATE_APK_MAX_BYTES="${MIHOWRT_PACKAGE_APK_MAX_BYTES:-16777216}"
PACKAGE_UPDATE_FETCH_TIMEOUT="${MIHOWRT_PACKAGE_FETCH_TIMEOUT:-60}"
PACKAGE_UPDATE_LATEST_VERSION=""
PACKAGE_UPDATE_ASSET_URL=""
PACKAGE_UPDATE_SERVICE_STOPPED=0
PACKAGE_UPDATE_SERVICE_RESTORED=0

package_update_state_file() {
	printf '%s\n' "${PACKAGE_UPDATE_STATE_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/package-update.state}"
}

package_update_log_file() {
	printf '%s\n' "${PACKAGE_UPDATE_LOG_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/package-update.log}"
}

package_update_lock_dir() {
	printf '%s\n' "${PACKAGE_UPDATE_LOCK_DIR:-${PKG_STATE_DIR:-/var/run/mihowrt}/package-update.lock}"
}

package_update_init_script() {
	printf '%s\n' "${MIHOWRT_INIT_SCRIPT:-/etc/init.d/mihowrt}"
}

package_update_value() {
	local key="$1" file=""

	file="$(package_update_state_file)"
	[ -r "$file" ] || return 1
	sed -n "s/^$key=//p" "$file" | tail -n 1
}

package_update_sanitize_state_value() {
	printf '%s' "$1" | tr '\r\n' '  '
}

package_update_installed_version() {
	local pkg="$PACKAGE_UPDATE_NAME"

	require_command apk || return 1
	apk list -I "$pkg" 2>/dev/null |
		awk -v pkg="$pkg" '
			BEGIN { prefix = pkg "-" }
			index($1, prefix) == 1 {
				sub("^" prefix, "", $1)
				print $1
				exit
			}
		'
}

package_update_asset_version() {
	local asset="$1" file="" version=""

	file="${asset%%\?*}"
	file="${file##*/}"
	case "$file" in
	"$PACKAGE_UPDATE_NAME"-*.apk)
		version="${file#"$PACKAGE_UPDATE_NAME"-}"
		version="${version%.apk}"
		[ -n "$version" ] || return 1
		printf '%s\n' "$version"
		;;
	*)
		return 1
		;;
	esac
}

package_update_store_state() {
	local status="$1" pid="${2:-}" current="${3:-}" latest="${4:-}" asset="${5:-}" message="${6:-}"
	local state_file="" state_dir="" tmp_file="" started_at="" finished_at="" now=""

	state_file="$(package_update_state_file)"
	state_dir="$(dirname "$state_file")"
	ensure_dir "$state_dir" || return 1
	tmp_file="${state_file}.tmp.$$"
	now="$(date +%s 2>/dev/null || printf '0')"
	started_at="$(package_update_value started_at 2>/dev/null || true)"
	[ -n "$started_at" ] || started_at="$now"
	if [ "$status" = "running" ]; then
		finished_at=""
	else
		finished_at="$now"
	fi

	{
		printf 'status=%s\n' "$(package_update_sanitize_state_value "$status")"
		printf 'pid=%s\n' "$(package_update_sanitize_state_value "$pid")"
		printf 'started_at=%s\n' "$(package_update_sanitize_state_value "$started_at")"
		printf 'finished_at=%s\n' "$(package_update_sanitize_state_value "$finished_at")"
		printf 'current_version=%s\n' "$(package_update_sanitize_state_value "$current")"
		printf 'latest_version=%s\n' "$(package_update_sanitize_state_value "$latest")"
		printf 'asset_url=%s\n' "$(package_update_sanitize_state_value "$asset")"
		printf 'message=%s\n' "$(package_update_sanitize_state_value "$message")"
	} >"$tmp_file" || {
		rm -f "$tmp_file"
		return 1
	}

	mv -f "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
}

package_update_lock_owner() {
	local lock_dir=""

	lock_dir="$(package_update_lock_dir)"
	[ -r "$lock_dir/owner" ] || return 1
	head -n 1 "$lock_dir/owner" 2>/dev/null
}

package_update_pid_alive() {
	local pid="$1"

	case "$pid" in
	'' | *[!0-9]*)
		return 1
		;;
	esac
	kill -0 "$pid" 2>/dev/null
}

package_update_lock_active() {
	local owner=""

	[ -d "$(package_update_lock_dir)" ] || return 1
	owner="$(package_update_lock_owner 2>/dev/null || true)"
	package_update_pid_alive "$owner"
}

package_update_clear_stale_lock() {
	local lock_dir=""

	lock_dir="$(package_update_lock_dir)"
	[ -d "$lock_dir" ] || return 0
	package_update_lock_active && return 1
	rm -rf "$lock_dir"
}

package_update_acquire_lock() {
	local lock_dir=""

	lock_dir="$(package_update_lock_dir)"
	ensure_dir "$(dirname "$lock_dir")" || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		package_update_clear_stale_lock || return 1
	done
	printf '%s\n' "$$" >"$lock_dir/owner" 2>/dev/null || {
		rm -rf "$lock_dir"
		return 1
	}
}

package_update_set_lock_owner() {
	local lock_dir="" pid="$1"

	lock_dir="$(package_update_lock_dir)"
	[ -d "$lock_dir" ] || return 0
	printf '%s\n' "$pid" >"$lock_dir/owner" 2>/dev/null || true
}

package_update_release_lock() {
	rm -rf "$(package_update_lock_dir)"
}

package_update_refresh_running_state() {
	local status="" current="" latest="" asset=""

	status="$(package_update_value status 2>/dev/null || true)"
	[ "$status" = "running" ] || return 0
	package_update_lock_active && return 0

	current="$(package_update_value current_version 2>/dev/null || true)"
	latest="$(package_update_value latest_version 2>/dev/null || true)"
	asset="$(package_update_value asset_url 2>/dev/null || true)"
	package_update_store_state error "" "$current" "$latest" "$asset" "Package update interrupted"
}

package_update_status_json() {
	local status="" pid="" started_at="" finished_at="" current="" latest="" asset="" message="" owner=""

	package_update_refresh_running_state
	status="$(package_update_value status 2>/dev/null || true)"
	[ -n "$status" ] || status="idle"
	pid="$(package_update_value pid 2>/dev/null || true)"
	owner="$(package_update_lock_owner 2>/dev/null || true)"
	[ -n "$pid" ] || pid="$owner"
	started_at="$(package_update_value started_at 2>/dev/null || true)"
	finished_at="$(package_update_value finished_at 2>/dev/null || true)"
	current="$(package_update_installed_version 2>/dev/null || package_update_value current_version 2>/dev/null || true)"
	latest="$(package_update_value latest_version 2>/dev/null || true)"
	asset="$(package_update_value asset_url 2>/dev/null || true)"
	message="$(package_update_value message 2>/dev/null || true)"

	jq -n \
		--arg status "$status" \
		--arg pid "$pid" \
		--arg started_at "$started_at" \
		--arg finished_at "$finished_at" \
		--arg current_version "$current" \
		--arg latest_version "$latest" \
		--arg asset_url "$asset" \
		--arg message "$message" \
		'{
			available: true,
			running: ($status == "running"),
			status: $status,
			pid: $pid,
			started_at: $started_at,
			finished_at: $finished_at,
			current_version: $current_version,
			latest_version: $latest_version,
			asset_url: $asset_url,
			message: $message
		}'
}

package_update_read_latest_release() {
	local release_file="" release_json="" release_tag=""

	release_file="$(mktemp /tmp/mihowrt-package-release.XXXXXX)" || return 1
	if ! fetch_http_body_limited_to_file "$PACKAGE_UPDATE_RELEASE_URL" "$PACKAGE_UPDATE_RELEASE_MAX_BYTES" "$PACKAGE_UPDATE_FETCH_TIMEOUT" "package release metadata" "$release_file" 0; then
		rm -f "$release_file"
		return 1
	fi

	release_json="$(cat "$release_file" 2>/dev/null || true)"
	rm -f "$release_file"
	PACKAGE_UPDATE_ASSET_URL="$(
		printf '%s' "$release_json" |
			jq -r --arg pkg "$PACKAGE_UPDATE_NAME" '[ .assets[]?.browser_download_url // empty | select(test("/" + $pkg + "-[^/]*\\.apk$")) ][0] // ""' 2>/dev/null
	)"
	release_tag="$(printf '%s' "$release_json" | jq -r '.tag_name // ""' 2>/dev/null || true)"
	PACKAGE_UPDATE_LATEST_VERSION="$(package_update_asset_version "$PACKAGE_UPDATE_ASSET_URL" 2>/dev/null || true)"
	[ -n "$PACKAGE_UPDATE_LATEST_VERSION" ] || PACKAGE_UPDATE_LATEST_VERSION="$(normalize_version "$release_tag")"
	[ -n "$PACKAGE_UPDATE_LATEST_VERSION" ] || PACKAGE_UPDATE_LATEST_VERSION="$(normalize_version "$PACKAGE_UPDATE_ASSET_URL")"
	[ -n "$PACKAGE_UPDATE_LATEST_VERSION" ] && [ -n "$PACKAGE_UPDATE_ASSET_URL" ]
}

package_update_needed() {
	local current="$1" latest="$2"

	[ -n "$latest" ] || return 1
	[ -n "$current" ] || return 0
	! version_ge "$current" "$latest"
}

package_update_service_running() {
	local init_script=""

	init_script="$(package_update_init_script)"
	[ -x "$init_script" ] || return 1
	"$init_script" running >/dev/null 2>&1
}

package_update_stop_service() {
	local init_script=""

	init_script="$(package_update_init_script)"
	[ -x "$init_script" ] || return 0
	"$init_script" stop
}

package_update_start_service() {
	local init_script=""

	init_script="$(package_update_init_script)"
	[ -x "$init_script" ] || return 0
	"$init_script" start
}

package_update_restore_stopped_service() {
	[ "$PACKAGE_UPDATE_SERVICE_STOPPED" = "1" ] || return 0
	[ "$PACKAGE_UPDATE_SERVICE_RESTORED" = "1" ] && return 0
	package_update_start_service || return 1
	PACKAGE_UPDATE_SERVICE_RESTORED=1
}

package_update_worker_signal() {
	trap - HUP INT TERM
	package_update_restore_stopped_service >/dev/null 2>&1 || true
	exit 1
}

package_update_worker_impl() {
	local current="" latest="" asset="" apk_path="" was_running=0 new_current="" message=""

	require_command jq || return 1
	require_command apk || return 1
	require_command mktemp || return 1

	current="$(package_update_installed_version 2>/dev/null || true)"
	package_update_store_state running "$(package_update_lock_owner 2>/dev/null || true)" "$current" "" "" "Checking latest release" || return 1

	if ! package_update_read_latest_release; then
		message="${FETCH_HTTP_ERROR_MESSAGE:-Failed to query latest package release}"
		package_update_store_state error "" "$current" "" "" "$message"
		err "$message"
		return 1
	fi
	latest="$PACKAGE_UPDATE_LATEST_VERSION"
	asset="$PACKAGE_UPDATE_ASSET_URL"
	package_update_store_state running "$(package_update_lock_owner 2>/dev/null || true)" "$current" "$latest" "$asset" "Latest package release found" || return 1

	if ! package_update_needed "$current" "$latest"; then
		package_update_store_state already_current "" "$current" "$latest" "$asset" "Package is already up to date"
		return 0
	fi

	apk_path="$(mktemp "/tmp/${PACKAGE_UPDATE_NAME}.update.XXXXXX.apk")" || {
		package_update_store_state error "" "$current" "$latest" "$asset" "Failed to allocate temporary APK path"
		return 1
	}

	package_update_store_state running "$(package_update_lock_owner 2>/dev/null || true)" "$current" "$latest" "$asset" "Downloading package update" || {
		rm -f "$apk_path"
		return 1
	}
	if ! fetch_http_body_limited_to_file "$asset" "$PACKAGE_UPDATE_APK_MAX_BYTES" "$PACKAGE_UPDATE_FETCH_TIMEOUT" "package update" "$apk_path" 0; then
		message="${FETCH_HTTP_ERROR_MESSAGE:-Failed to download package update}"
		rm -f "$apk_path"
		package_update_store_state error "" "$current" "$latest" "$asset" "$message"
		err "$message"
		return 1
	fi

	if package_update_service_running; then
		was_running=1
		package_update_store_state running "$(package_update_lock_owner 2>/dev/null || true)" "$current" "$latest" "$asset" "Stopping service before package update" || {
			rm -f "$apk_path"
			return 1
		}
		if ! package_update_stop_service; then
			rm -f "$apk_path"
			package_update_store_state error "" "$current" "$latest" "$asset" "Failed to stop service before package update"
			return 1
		fi
		PACKAGE_UPDATE_SERVICE_STOPPED=1
	fi

	package_update_store_state running "$(package_update_lock_owner 2>/dev/null || true)" "$current" "$latest" "$asset" "Installing package update" || {
		rm -f "$apk_path"
		return 1
	}
	if ! apk add --allow-untrusted "$apk_path"; then
		rm -f "$apk_path"
		package_update_store_state error "" "$current" "$latest" "$asset" "Failed to install package update"
		return 1
	fi
	rm -f "$apk_path"

	if [ "$was_running" = "1" ] && ! package_update_restore_stopped_service; then
		new_current="$(package_update_installed_version 2>/dev/null || true)"
		package_update_store_state error "" "$new_current" "$latest" "$asset" "Package updated, but service failed to restart"
		return 1
	fi

	new_current="$(package_update_installed_version 2>/dev/null || true)"
	[ -n "$new_current" ] || new_current="$latest"
	package_update_store_state success "" "$new_current" "$latest" "$asset" "Package updated successfully"
}

package_update_worker() {
	local rc=0

	PACKAGE_UPDATE_SERVICE_STOPPED=0
	PACKAGE_UPDATE_SERVICE_RESTORED=0
	trap 'package_update_worker_signal' HUP INT TERM
	package_update_worker_impl
	rc=$?
	trap - HUP INT TERM
	if [ "$rc" -ne 0 ]; then
		package_update_restore_stopped_service >/dev/null 2>&1 || true
	fi
	return "$rc"
}

package_update_start_json() {
	local log_file="" worker_pid="" current=""

	ensure_dir "${PKG_STATE_DIR:-/var/run/mihowrt}" || return 1
	if ! package_update_acquire_lock; then
		package_update_status_json
		return 0
	fi

	log_file="$(package_update_log_file)"
	: >"$log_file" || {
		package_update_release_lock
		err "Failed to open package update log"
		return 1
	}
	current="$(package_update_installed_version 2>/dev/null || true)"
	package_update_store_state running "$$" "$current" "" "" "Package update started" || {
		package_update_release_lock
		return 1
	}

	(
		package_update_worker
		package_update_release_lock
	) >"$log_file" 2>&1 &
	worker_pid=$!
	package_update_set_lock_owner "$worker_pid"

	package_update_status_json
}
