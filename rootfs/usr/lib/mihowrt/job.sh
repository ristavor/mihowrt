#!/bin/ash

job_id_valid() {
	case "$1" in
	*-*) is_uint "${1%%-*}" && is_uint "${1#*-}" ;;
	*) return 1 ;;
	esac
}

job_usage() {
	err "Usage: job-start <connect <url>|update-subscription [url]|update-lists|apply-lists <path|-> <path|-> <path|-> <path|->|save-config <path>|restore-config|core-update|service <start|stop|restart>>"
	return 1
}

job_validate() {
	local op="${1:-}" path=""

	[ $# -gt 0 ] || { job_usage; return 1; }
	shift
	case "$op" in
	connect)
		[ $# -eq 1 ] || { job_usage; return 1; }
		is_http_url "$1" || { err "Subscription URL must start with http:// or https://"; return 1; }
		;;
	update-subscription)
		[ $# -le 1 ] || { job_usage; return 1; }
		[ -z "${1:-}" ] || is_http_url "$1" || { err "Subscription URL must start with http:// or https://"; return 1; }
		;;
	update-lists | restore-config | core-update)
		[ $# -eq 0 ] || { job_usage; return 1; }
		;;
	apply-lists)
		[ $# -eq 4 ] || { job_usage; return 1; }
		for path in "$@"; do
			[ "$path" = - ] || upload_path_allowed /tmp/mihowrt-policy-list. "$path" || {
				err "List path not allowed: $path"
				return 1
			}
		done
		;;
	save-config)
		[ $# -eq 1 ] || { job_usage; return 1; }
		config_temp_path_allowed "$1" || { err "Config path not allowed: $1"; return 1; }
		;;
	service)
		[ $# -eq 1 ] || { job_usage; return 1; }
		case "$1" in
		start | stop | restart) ;;
		*) job_usage; return 1 ;;
		esac
		;;
	*) err "Unknown operation: $op"; return 1 ;;
	esac
}

job_dir_prepare() {
	ensure_dir "$JOBS_DIR" && chmod 700 "$JOBS_DIR"
}

# Serialize only metadata changes, not operations or the runtime lock. In
# particular, stale-slot recovery must not unlink a newer starter's slot.
job_with_state_lock() (
	exec 8>>"$JOBS_DIR/state.flock" || exit 1
	flock 8 || exit 1
	"$@"
)

job_slot_release() {
	[ "$(readlink "$JOBS_DIR/active" 2>/dev/null)" != "$1" ] || rm -f "$JOBS_DIR/active"
	return 0
}

# Replace complete JSON only: status readers never see a partial write.
job_finish() {
	local id="$1" state="$2" result="$3" error="$4" tmp="$JOBS_DIR/$1.json.tmp.$$"

	jq -c --arg state "$state" --argjson result "$result" --arg error "$error" \
		--argjson finished "$(date +%s)" \
		'. + {state: $state, finished: $finished, result: $result,
		       error: (if $state == "ok" then null else $error end)}' \
		"$JOBS_DIR/$id.json" >"$tmp" && mv -f "$tmp" "$JOBS_DIR/$id.json"
}

# Alive = the pid runs and is still ours (job-start or job-run): a pid reused
# by another process after a reboot or crash must not hold the slot.
job_pid_alive() {
	is_uint "$1" && [ "$(uint_norm "$1")" -gt 0 ] && kill -0 "$1" 2>/dev/null &&
		tr '\000' ' ' <"${JOB_PROC_DIR:-/proc}/$1/cmdline" 2>/dev/null | grep -q 'mihowrt job-'
}

# A starter records its own live pid before claiming the slot, then replaces
# it with the detached child's pid. There is no pid-less startup window.
job_reconcile() {
	local id="$1" pid=""

	job_id_valid "$id" || return 1
	[ "$(jq -r .state "$JOBS_DIR/$id.json" 2>/dev/null)" = running ] || {
		job_slot_release "$id"
		return 0
	}
	pid="$(cat "$JOBS_DIR/$id.pid" 2>/dev/null)"
	job_pid_alive "$pid" && return 0
	job_finish "$id" error null 'Interrupted: the operation was stopped before it finished.' || return 1
	job_slot_release "$id"
}

job_history() {
	jq -s 'sort_by(.started, (.id | split("-") | map(tonumber)))' "$JOBS_DIR"/*.json 2>/dev/null
}

job_prune() {
	local id="" ids=""

	ids="$(job_history | jq -r '[.[] | select(.state != "running")] | .[:-5][] | .id')" || return 1
	for id in $ids; do
		job_id_valid "$id" || continue
		rm -f "$JOBS_DIR/$id.json" "$JOBS_DIR/$id.pid" "$JOBS_DIR/$id.out" "$JOBS_DIR/$id.err"
	done
}

job_start() {
	job_validate "$@" || return 1
	job_dir_prepare || return 1
	job_with_state_lock job_start_locked "$@"
}

job_start_locked() {
	local op="$1" id="" active="" started="" pid="" busy_op=""
	started="$(date +%s)"
	id="$started-$$"
	# Direct shell callers may start twice in the same second and process.
	while [ -e "$JOBS_DIR/$id.json" ]; do
		sleep 1
		started="$(date +%s)"
		id="$started-$$"
	done
	jq -nc --arg id "$id" --arg op "$op" --argjson started "$started" \
		'{id: $id, op: $op, state: "running", started: $started,
		  finished: null, result: null, error: null}' >"$JOBS_DIR/$id.json.tmp.$$" &&
		mv -f "$JOBS_DIR/$id.json.tmp.$$" "$JOBS_DIR/$id.json" || return 1
	printf '%s\n' "$$" >"$JOBS_DIR/$id.pid" || return 1
	while ! ln -s "$id" "$JOBS_DIR/active" 2>/dev/null; do
		active="$(readlink "$JOBS_DIR/active" 2>/dev/null)"
		if ! job_id_valid "$active"; then
			err "Cannot claim the operation slot"
			rm -f "$JOBS_DIR/$id.json" "$JOBS_DIR/$id.pid"
			return 1
		fi
		job_reconcile "$active" || return 1
		if [ "$(readlink "$JOBS_DIR/active" 2>/dev/null)" = "$active" ]; then
			busy_op="$(jq -r .op "$JOBS_DIR/$active.json")"
			rm -f "$JOBS_DIR/$id.json" "$JOBS_DIR/$id.pid"
			err "Another operation is running: $busy_op"
			return 1
		fi
	done
	job_prune
	( /usr/bin/mihowrt job-run "$id" "$@" ) 8>&- 9>&- </dev/null >/dev/null 2>&1 &
	pid=$!
	printf '%s\n' "$pid" >"$JOBS_DIR/$id.pid"
	jq -nc --arg id "$id" '{id: $id}'
}

# Do not wrap this dispatcher in the runtime lock: init restarts acquire it
# in a new process. Each operation owns only its documented lock sections.
job_execute() {
	local op="$1"

	shift
	case "$op" in
	connect) subscription_connect "$1" ;;
	update-subscription) subscription_update "${1:-}" ;;
	update-lists) lists_refresh ;;
	apply-lists) lists_apply "$@" ;;
	save-config)
		settings_load >/dev/null 2>&1 && config_api_wait
		with_lock config_save "$1"
		;;
	restore-config)
		settings_load >/dev/null 2>&1 && config_api_wait
		with_lock config_restore
		;;
	core-update) core_update_cmd ;;
	service) /etc/init.d/mihowrt "$1" 9>&- >/dev/null && printf '{}\n' ;;
	esac
}

job_run() {
	local id="${1:-}" op="${2:-}" state=ok result=null error=""

	if ! job_id_valid "$id"; then
		err "Invalid job id: $id"
		return 1
	fi
	shift
	if ! error="$(job_validate "$@" 2>&1)"; then
		error="$(printf '%s\n' "$error" | sed 's/^Error: //')"
	elif [ "$(readlink "$JOBS_DIR/active" 2>/dev/null)" != "$id" ] ||
		[ "$(jq -r '.state + ":" + .op' "$JOBS_DIR/$id.json" 2>/dev/null)" != "running:$op" ]; then
		error="Job is not active: $id"
	fi
	if [ -n "$error" ]; then
		job_with_state_lock job_fail_owned "$id" "$error"
		err "$error"
		return 1
	fi
	if ! job_execute "$@" >"$JOBS_DIR/$id.out" 2>"$JOBS_DIR/$id.err"; then
		state=error
		error="$(tail -n 20 "$JOBS_DIR/$id.err" | sed 's/^Error: //')"
		[ -n "$error" ] || error='The operation failed.'
	fi
	result="$(jq -sc 'if length == 1 then .[0] else null end' "$JOBS_DIR/$id.out" 2>/dev/null)" || result=null
	job_with_state_lock job_complete "$id" "$state" "$result" "$error"
}

# Startup failures may finalize only the still-running slot they own.
job_fail_owned() {
	[ "$(readlink "$JOBS_DIR/active" 2>/dev/null)" = "$1" ] &&
		[ "$(jq -r .state "$JOBS_DIR/$1.json" 2>/dev/null)" = running ] || return 0
	job_complete "$1" error null "$2"
}

job_complete() {
	job_finish "$@" || return 1
	job_slot_release "$1"
	job_prune
}

job_status() {
	[ $# -le 1 ] || { err 'Usage: job-status [id]'; return 1; }
	[ $# -eq 0 ] || job_id_valid "$1" || { err "Invalid job id: $1"; return 1; }
	job_dir_prepare || return 1
	job_with_state_lock job_status_locked "$@"
}

job_status_locked() {
	local id="${1:-}"
	if [ -z "$id" ]; then
		id="$(readlink "$JOBS_DIR/active" 2>/dev/null)"
		[ -n "$id" ] || id="$(job_history | jq -r 'last.id // empty')"
	fi
	[ -n "$id" ] || { printf '{"state":"none"}\n'; return 0; }
	job_id_valid "$id" && [ -f "$JOBS_DIR/$id.json" ] || { err "Job not found: $id"; return 1; }
	job_reconcile "$id" || return 1
	# Router clock for the UI: the browser clock may differ.
	jq -c --argjson now "$(date +%s)" '. + {now: $now}' "$JOBS_DIR/$id.json"
}
