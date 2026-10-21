#!/bin/ash

log() {
	logger -p daemon.info -t "mihowrt" "$*"
}

warn() {
	logger -p daemon.warn -t "mihowrt" "$*"
}

# Errors go to syslog and stderr so LuCI can show the reason to the user.
err() {
	logger -p daemon.err -t "mihowrt" "$*"
	printf 'Error: %s\n' "$*" >&2
}

have_command() {
	command -v "$1" >/dev/null 2>&1
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

ensure_dir() {
	[ -d "$1" ] || mkdir -p "$1"
}

# Collapse a value to one printable line (used for HTTP header metadata).
single_line() {
	tr '\r\n\t' '   ' | tr -d '\000-\037' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

uci_get() {
	local value=""

	value="$(uci -q get "${PKG_CONFIG:-mihowrt}.settings.$1" 2>/dev/null)" || value=""
	[ -n "$value" ] || value="${2:-}"
	printf '%s' "$value"
}

uci_set() {
	uci -q set "${PKG_CONFIG:-mihowrt}.settings.$1=$2"
}

uci_commit() {
	uci -q commit "${PKG_CONFIG:-mihowrt}"
}

# One runtime lock serializes nft, route, DNS and config changes. ln -s is
# atomic on every OpenWrt filesystem and stores the owner pid in the link.
lock_acquire() {
	local lock="${RUNTIME_LOCK_FILE:-/var/run/mihowrt/runtime.lock}"
	local owner="" waited=0 timeout="${RUNTIME_LOCK_TIMEOUT:-120}"

	# Re-entrant: nested with_lock calls in the same process just count.
	if [ "$(readlink "$lock" 2>/dev/null)" = "$$" ]; then
		LOCK_DEPTH=$((${LOCK_DEPTH:-0} + 1))
		return 0
	fi
	ensure_dir "$(dirname "$lock")" || return 1
	while ! ln -s "$$" "$lock" 2>/dev/null; do
		owner="$(readlink "$lock" 2>/dev/null)"
		if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
			# Remove only if the dead owner still holds it: another waiter may
			# have taken the lock in between.
			[ "$(readlink "$lock" 2>/dev/null)" = "$owner" ] && rm -f "$lock"
			continue
		fi
		[ "$waited" -lt "$timeout" ] || {
			err "Runtime is busy (process $owner)"
			return 1
		}
		# run_service sets MIHOWRT_STOP from its signal trap.
		[ "${MIHOWRT_STOP:-0}" = 0 ] || return 1
		sleep 1
		waited=$((waited + 1))
	done
	LOCK_DEPTH=1
}

lock_release() {
	local lock="${RUNTIME_LOCK_FILE:-/var/run/mihowrt/runtime.lock}"

	[ "$(readlink "$lock" 2>/dev/null)" = "$$" ] || return 0
	LOCK_DEPTH=$((${LOCK_DEPTH:-1} - 1))
	[ "$LOCK_DEPTH" -gt 0 ] || rm -f "$lock"
	return 0
}

# True when another live process holds the runtime lock.
lock_busy() {
	local lock="${RUNTIME_LOCK_FILE:-/var/run/mihowrt/runtime.lock}" owner=""

	owner="$(readlink "$lock" 2>/dev/null)" || return 1
	[ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null
}

with_lock() {
	local rc=0

	lock_acquire || return 1
	"$@" || rc=$?
	lock_release
	return "$rc"
}

# Add or remove one marked crontab line; restart cron only on change.
cron_sync() {
	local marker="$1" enabled="$2" line="$3"
	local file="${CRON_FILE:-/etc/crontabs/root}" tmp=""

	ensure_dir "$(dirname "$file")" || return 1
	tmp="$file.mihowrt.$$"
	# grep -v exits 1 when nothing is left; 2 is a real error (e.g. ENOSPC).
	if [ -e "$file" ]; then
		grep -vF "$marker" "$file" >"$tmp" 2>/dev/null
		[ "$?" -le 1 ] || {
			rm -f "$tmp"
			return 1
		}
	else
		: >"$tmp" || return 1
	fi
	if [ "$enabled" = "1" ] && ! printf '%s %s\n' "$line" "$marker" >>"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	if cmp -s "$tmp" "$file" 2>/dev/null; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$file" || {
		rm -f "$tmp"
		return 1
	}
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
	return 0
}

# LuCI uploads land in /tmp/<prefix><suffix>: a plain file, no subdirectory,
# no symlink.
upload_path_allowed() {
	local prefix="$1" path="$2"

	case "$path" in
	"$prefix"?*) ;;
	*) return 1 ;;
	esac
	case "${path#/tmp/}" in
	*/*) return 1 ;;
	esac
	[ -f "$path" ] && [ ! -L "$path" ]
}

mihowrt_lib_dir() {
	printf '%s' "${MIHOWRT_LIB_DIR:-/usr/lib/mihowrt}"
}

# Modules are small; loading all of them keeps command dispatch trivial.
MIHOWRT_MODULES="validate.sh settings.sh mihomo-config.sh mihomo-api.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh route.sh config.sh core.sh service.sh status.sh migration.sh"

mihowrt_load_modules() {
	local module="" dir=""

	dir="$(mihowrt_lib_dir)"
	for module in $MIHOWRT_MODULES; do
		[ -r "$dir/$module" ] || {
			err "Required MihoWRT module missing: $dir/$module"
			return 1
		}
		# shellcheck disable=SC1090
		. "$dir/$module" || return 1
	done
}
