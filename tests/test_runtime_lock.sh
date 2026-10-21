#!/usr/bin/env bash
# Each case runs in ash, with the router's BusyBox flock applet.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
cases=(killed_holder busy_timeout stop_abort reentrant children lock_busy failure_cleanup)
if [ "$#" -eq 0 ]; then
 failed=0
 for name in "${cases[@]}"; do
  if bash "$0" "$name"; then :; else failed=1; fi
 done
 exit "$failed"
fi
name="$1"
tmpdir="$(make_temp_dir)"
LOCK_HOLDER_PID=""
trap 'if [ -n "$LOCK_HOLDER_PID" ]; then kill -9 "$LOCK_HOLDER_PID" 2>/dev/null || true; wait "$LOCK_HOLDER_PID" 2>/dev/null || true; fi; rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
# Pin to BusyBox even if the test image later installs util-linux flock.
ln -s /bin/busybox "$tmpdir/bin/flock"
export RUNTIME_LOCK_FILE="$tmpdir/runtime.flock"
run_ash() {
 ash -c '. "$MIHOWRT_LIB_DIR/helpers.sh"; . "$MIHOWRT_LIB_DIR/validate.sh"; eval "$1"' ash "$1"
}
holder() { start_runtime_lock_holder "$RUNTIME_LOCK_FILE" "$tmpdir/ready"; }
probe() { run_ash 'RUNTIME_LOCK_TIMEOUT=0 with_lock true'; }
case "$name" in
killed_holder)
 # Kill a holder using the runtime API, not just an independent flock fixture.
 ash -c '
  . "$MIHOWRT_LIB_DIR/helpers.sh"
  . "$MIHOWRT_LIB_DIR/validate.sh"
  lock_acquire || exit 1
  echo "$$" >"$1"
  exec sleep 300
 ' ash "$tmpdir/ready" &
 LOCK_HOLDER_PID=$!
 for i in {1..100}; do [ ! -f "$tmpdir/ready" ] || break; sleep 0.02; done
 assert_true "runtime holder ready" test -f "$tmpdir/ready"
 if busybox flock -n "$RUNTIME_LOCK_FILE" true; then fail "runtime holder must own a kernel flock"; fi
 kill -9 "$LOCK_HOLDER_PID"
 wait "$LOCK_HOLDER_PID" 2>/dev/null || true
 LOCK_HOLDER_PID=""
 # Diagnostic owner data must never determine whether the kernel lock is free.
 echo "$$" >"$RUNTIME_LOCK_FILE.owner"
 start=$(date +%s)
 RUNTIME_LOCK_TIMEOUT=2 run_ash 'with_lock true' || fail "killed holder must free the lock despite live unrelated owner"
 [ "$(( $(date +%s) - start ))" -lt 2 ] || fail "killed holder lock was not available immediately"
 ;;
busy_timeout)
 holder
 start=$(date +%s)
 if RUNTIME_LOCK_TIMEOUT=02 run_ash 'with_lock true' 2>"$tmpdir/err"; then fail "live holder must exclude another process"; fi
 elapsed=$(( $(date +%s) - start ))
 [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 3 ] || fail "timeout took ${elapsed}s instead of about 2s"
 assert_file_contains "$tmpdir/err" "Runtime is busy (process $LOCK_HOLDER_PID)" "timeout names actual holder"
 ;;
stop_abort)
 holder
 start=$(date +%s)
 if MIHOWRT_STOP=1 RUNTIME_LOCK_TIMEOUT=2 run_ash 'lock_acquire'; then fail "stop must abort lock wait"; fi
 [ "$(( $(date +%s) - start ))" -lt 2 ] || fail "stop did not abort immediately"
 ;;
reentrant)
 run_ash '
  nested() {
   [ -f "$RUNTIME_LOCK_FILE" ] && [ ! -L "$RUNTIME_LOCK_FILE" ] && [ -e /proc/$$/fd/9 ] || return 1
   busybox flock -n "$RUNTIME_LOCK_FILE" true && return 1
   with_lock true || return 1
   [ "$LOCK_DEPTH" = 1 ] || return 1
   x="$(with_lock echo ok)" || return 1
   [ "$x" = ok ] && [ "$LOCK_DEPTH" = 1 ] || return 1
   # A nested subshell release must not unlock the shared open description.
   ! busybox flock -n "$RUNTIME_LOCK_FILE" true
  }
  with_lock nested && [ "$LOCK_DEPTH" = 0 ]
 ' || fail "nested functions and command substitutions must be reentrant"
 probe || fail "outermost release must free lock immediately"
 ;;
children)
 run_ash '
  child() {
   [ -e /proc/$$/fd/9 ] || return 1
   busybox flock -n "$RUNTIME_LOCK_FILE" true && return 1
   sleep 5 9>&- >/dev/null 2>&1 &
  }
  with_lock child
 ' || fail "child spawn failed"
 probe || fail "background child must not retain lock after outer release"
 ;;
lock_busy)
 run_ash 'inside() { ! lock_busy; }; with_lock inside' || fail "lock_busy must be false inside own lock"
 holder
 run_ash 'lock_busy' || fail "lock_busy must detect another holder"
 kill -9 "$LOCK_HOLDER_PID"
 wait "$LOCK_HOLDER_PID" 2>/dev/null || true
 LOCK_HOLDER_PID=""
 run_ash '! lock_busy' || fail "lock_busy must be false after holder dies"
 ;;
failure_cleanup)
 holder
 run_ash '
  RUNTIME_LOCK_TIMEOUT=0 lock_acquire && exit 1
  [ "${LOCK_DEPTH:-0}" = 0 ] || exit 1
  [ ! -e /proc/$$/fd/9 ]
 ' 2>/dev/null || fail "failed acquisition must close fd 9 without changing depth"
 ;;
esac
pass "runtime lock: $name"
