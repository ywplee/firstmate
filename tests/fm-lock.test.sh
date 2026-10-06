#!/usr/bin/env bash
# tests/fm-lock.test.sh - the per-home session lock's PID-reuse-proof identity
# and the bounded lock-acquire wait. A recorded pid that the OS later recycles
# onto an unrelated live process must be proven stale (not mistaken for a live
# session), a matching identity must stay held, a legacy plain-pid lock must keep
# working, and no acquire wait may hang forever on a recycled-pid holder.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LOCK_SH="$ROOT/bin/fm-lock.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

# Spawn a live process whose command line looks like a verified harness, so the
# legacy name-only fallback would classify it as a held session. The identity
# check must still reject it when the recorded identity does not match. Backing
# it in the caller's own shell (not a command substitution) keeps the test as the
# direct parent, so its pid stays reliably live and reapable.
HARNESS_PID=
spawn_harness_like() {  # <dir>; sets HARNESS_PID
  local dir=$1 script
  script="$dir/claude"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$script"
  "$script" >/dev/null 2>&1 &
  HARNESS_PID=$!
}

new_state() {  # <name>
  local state="$TMP_ROOT/$1"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

test_recycled_pid_is_reported_stale() {
  local state live out
  state=$(new_state recycled)
  spawn_harness_like "$state"; live=$HARNESS_PID
  {
    printf '%s\n' "$live"
    printf 'identity=%s\n' "linux-starttime=1 cmdline-hex=deadbeef original holder identity"
  } > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status 2>&1)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"stale (pid $live reused by a different process)"*) ;;
    *) fail "recycled harness-looking pid was not reported as reused-and-stale: $out" ;;
  esac
  pass "fm-lock: a live pid whose identity differs is reported as a reused, stale holder"
}

test_matching_identity_stays_held() {
  local state live identity out
  state=$(new_state matching)
  spawn_harness_like "$state"; live=$HARNESS_PID
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not read live identity"
  [ -n "$identity" ] || fail "fm_pid_identity produced no identity for the live holder"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_session_lock_body "$2"' _ "$LIB" "$live" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status 2>&1)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"held by live harness pid $live"*) ;;
    *) fail "matching-identity lock was not reported as held: $out" ;;
  esac
  pass "fm-lock: a lock whose recorded identity matches the live holder stays held"
}

test_legacy_plain_pid_lock_still_works() {
  local state live dead held stale
  state=$(new_state legacy-held)
  spawn_harness_like "$state"; live=$HARNESS_PID
  printf '%s\n' "$live" > "$state/.lock"
  held=$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status 2>&1)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$held" in
    *"held by live harness pid $live"*) ;;
    *) fail "legacy plain-pid lock with a live harness was not held: $held" ;;
  esac

  state=$(new_state legacy-stale)
  dead=$(dead_pid)
  printf '%s\n' "$dead" > "$state/.lock"
  stale=$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status 2>&1)
  case "$stale" in
    *"stale (pid $dead dead)"*) ;;
    *) fail "legacy plain-pid lock with a dead pid was not reported stale: $stale" ;;
  esac
  pass "fm-lock: a legacy single-line pid lock is honored when live and stale when dead"
}

test_session_lock_body_roundtrips_and_reads_legacy() {
  local state live out
  state=$(new_state roundtrip)
  spawn_harness_like "$state"; live=$HARNESS_PID
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$3/.lock"
    fm_session_lock_body "$2" > "$lock"
    fm_session_lock_read "$lock" || exit 2
    printf "identity-pid=%s legacy=%s identity-present=%s\n" \
      "$FM_SESSION_LOCK_PID" "${FM_SESSION_LOCK_LEGACY:-no}" "$([ -n "$FM_SESSION_LOCK_IDENTITY" ] && echo yes || echo no)"
    printf "%s\n" "$FM_SESSION_LOCK_PID" > "$lock"
    fm_session_lock_read "$lock" || exit 3
    printf "legacy-pid=%s legacy=%s identity-present=%s\n" \
      "$FM_SESSION_LOCK_PID" "${FM_SESSION_LOCK_LEGACY:-no}" "$([ -n "$FM_SESSION_LOCK_IDENTITY" ] && echo yes || echo no)"
  ' _ "$LIB" "$live" "$state") || fail "session-lock body/read round-trip failed: $out"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"identity-pid=$live legacy=no identity-present=yes"*) ;;
    *) fail "identity-form lock did not round-trip through read: $out" ;;
  esac
  case "$out" in
    *"legacy-pid=$live legacy=1 identity-present=no"*) ;;
    *) fail "single-line lock was not read as legacy: $out" ;;
  esac
  pass "fm-lock: an identity lock round-trips and a single-line lock reads as legacy"
}

test_acquire_wait_times_out_on_recycled_pid_holder() {
  local state lockdir live waiter status
  state=$(new_state acquire-wait-timeout)
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  touch -t 200001010000 "$lockdir"
  FM_STATE_OVERRIDE="$state" FM_LOCK_ACQUIRE_WAIT_TIMEOUT=2 bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
  ' _ "$LIB" "$lockdir" 2>/dev/null &
  waiter=$!
  wait_for_exit "$waiter" 150
  status=$?
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$status" -ne 124 ] || fail "fm_lock_acquire_wait hung on a live recycled-pid holder instead of timing out"
  [ "$status" -ne 0 ] || fail "fm_lock_acquire_wait reported success for a live recycled-pid holder"
  pass "fm-lock: a bounded acquire wait times out on a recycled-pid holder instead of hanging"
}

test_acquire_wait_reclaims_dead_pid_holder() {
  local state lockdir dead out status
  state=$(new_state acquire-wait-reclaim)
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  touch -t 200001010000 "$lockdir"
  status=0
  out=$(FM_STATE_OVERRIDE="$state" FM_LOCK_ACQUIRE_WAIT_TIMEOUT=10 bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" && cat "$2/pid"
  ' _ "$LIB" "$lockdir" 2>/dev/null) || status=$?
  [ "$status" -eq 0 ] || fail "bounded acquire wait failed to reclaim a dead-pid holder (status $status)"
  [ "$out" != "$dead" ] || fail "reclaimed lock still records the dead pid"
  pass "fm-lock: a bounded acquire wait still reclaims a dead-pid holder promptly"
}

test_recycled_pid_is_reported_stale
test_matching_identity_stays_held
test_legacy_plain_pid_lock_still_works
test_session_lock_body_roundtrips_and_reads_legacy
test_acquire_wait_times_out_on_recycled_pid_holder
test_acquire_wait_reclaims_dead_pid_holder
