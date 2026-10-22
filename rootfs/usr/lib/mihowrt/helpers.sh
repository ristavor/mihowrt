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

# Publish a complete value without exposing a truncated file to status readers.
atomic_write() {
	local f="$1"

	if printf '%s\n' "$2" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; then
		return 0
	fi
	rm -f "$f.tmp.$$"
	return 1
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

# fd 9 is reserved for the runtime lock; background/daemon children close it.
# The kernel owns exclusion. The owner pid is diagnostic metadata only.
lock_acquire() {
	local lock="${RUNTIME_LOCK_FILE:-/var/run/mihowrt/runtime.flock}"
	local depth="" owner="" waited=0 timeout="${RUNTIME_LOCK_TIMEOUT:-120}"

	depth="$(uint_norm "${LOCK_DEPTH:-0}")"
	# Subshells inherit both fd 9 and depth: never open a second lock fd.
	if [ "$depth" -gt 0 ]; then
		LOCK_DEPTH=$((depth + 1))
		return 0
	fi
	is_uint "$timeout" || {
		err "Invalid RUNTIME_LOCK_TIMEOUT: $timeout"
		return 1
	}
	timeout="$(uint_norm "$timeout")"
	ensure_dir "$(dirname "$lock")" || return 1
	command exec 9>>"$lock" || return 1
	while :; do
		# run_service sets MIHOWRT_STOP from its signal trap.
		[ "${MIHOWRT_STOP:-0}" = 0 ] || {
			exec 9>&-
			return 1
		}
		if flock -n 9; then
			if ! echo "$$" >"$lock.owner"; then
				flock -u 9
				exec 9>&-
				return 1
			fi
			LOCK_DEPTH=1
			return 0
		fi
		[ "$waited" -lt "$timeout" ] || {
			owner="$(cat "$lock.owner" 2>/dev/null)"
			err "Runtime is busy (process $owner)"
			exec 9>&-
			return 1
		}
		sleep 1
		waited=$((waited + 1))
	done
}

lock_release() {
	local lock="${RUNTIME_LOCK_FILE:-/var/run/mihowrt/runtime.flock}" depth=""

	depth="$(uint_norm "${LOCK_DEPTH:-0}")"
	[ "$depth" -gt 0 ] || return 0
	LOCK_DEPTH=$((depth - 1))
	[ "$LOCK_DEPTH" -eq 0 ] || return 0
	# Remove metadata before unlocking so a new owner's pid cannot be removed.
	rm -f "$lock.owner"
	flock -u 9
	exec 9>&-
	return 0
}

# Probe through a separate fd; re-opening our own lock would report it busy.
lock_busy() {
	local lock="${RUNTIME_LOCK_FILE:-/var/run/mihowrt/runtime.flock}"

	[ "${LOCK_DEPTH:-0}" -gt 0 ] && return 1
	! ( exec 8>>"$lock"; flock -n 8 )
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
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart 9>&- >/dev/null 2>&1
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
MIHOWRT_MODULES="validate.sh settings.sh mihomo-config.sh mihomo-api.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh route.sh config.sh core.sh service.sh status.sh migration.sh job.sh"

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
