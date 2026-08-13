#!/usr/bin/env bash
# Tests for bin/fm-budget-pause-timer.sh: arming a one-shot budget-pause resume
# check, reset-time resolution (explicit override and quota-axi auto-pick), and
# the refusal guarantees (no clobbering an armed check, no task record).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMER="$ROOT/bin/fm-budget-pause-timer.sh"
TMP_ROOT=$(fm_test_tmproot fm-budget-pause-timer)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_arms_silent_before_reset() {
  local home
  home=$(make_home before)
  fm_write_meta "$home/state/t1.meta" "worktree=$home"
  FM_HOME="$home" "$TIMER" t1 --reset "2099-01-01T00:00:00+00:00" >/dev/null \
    || fail "arming with a future reset should succeed"
  assert_present "$home/state/t1.check.sh" "check script was not generated"
  assert_present "$home/state/t1.check-trust" "trust record was not registered"
  [ "$(file_mode "$home/state/t1.check.sh")" = 700 ] || fail "check script is not mode 700"
  local out
  out=$(bash "$home/state/t1.check.sh")
  [ -z "$out" ] || fail "check printed output before its reset instant: $out"
  assert_present "$home/state/t1.check.sh" "check self-deleted before its reset instant"
  pass "armed check stays silent before its reset instant"
}

test_fires_once_and_self_deletes() {
  local home out
  home=$(make_home fires)
  fm_write_meta "$home/state/t2.meta" "worktree=$home"
  FM_HOME="$home" "$TIMER" t2 --reset "2020-01-01T00:00:00+00:00" >/dev/null \
    || fail "arming with a past reset should succeed"
  out=$(bash "$home/state/t2.check.sh")
  assert_contains "$out" "t2" "wake line does not name the task"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "check printed more than one line: $out"
  assert_absent "$home/state/t2.check.sh" "check did not self-delete after firing"
  assert_absent "$home/state/t2.check-trust" "trust record did not self-delete after firing"
  pass "armed check prints exactly one line after its reset instant and self-deletes"
}

test_refuses_to_clobber_existing_armed_check() {
  local home status
  home=$(make_home clobber)
  fm_write_meta "$home/state/t3.meta" "worktree=$home"
  FM_HOME="$home" "$TIMER" t3 --reset "2099-01-01T00:00:00+00:00" >/dev/null \
    || fail "first arm should succeed"
  status=0
  FM_HOME="$home" "$TIMER" t3 --reset "2099-01-01T00:00:00+00:00" >/dev/null 2>"$home/err.txt" \
    || status=$?
  expect_code 1 "$status" "re-arm exit code"
  assert_contains "$(cat "$home/err.txt")" "already exists" "re-arm did not explain the refusal"
  pass "refuses to clobber an already-armed check"
}

test_refuses_without_task_record() {
  local home status
  home=$(make_home norecord)
  status=0
  FM_HOME="$home" "$TIMER" ghost --reset "2099-01-01T00:00:00+00:00" >/dev/null 2>"$home/err.txt" \
    || status=$?
  expect_code 1 "$status" "no-task-record exit code"
  assert_contains "$(cat "$home/err.txt")" "no task record" "missing-record refusal did not explain itself"
  assert_absent "$home/state/ghost.check.sh" "check was generated despite missing task record"
  pass "refuses to arm without a matching task record"
}

test_auto_picks_most_exhausted_window() {
  local home fakebin
  home=$(make_home auto)
  fakebin=$(fm_fakebin "$home")
  fm_write_meta "$home/state/t4.meta" "worktree=$home"
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":0,"resetsAt":"2030-06-01T00:00:00+00:00"},
  {"id":"seven_day","percentRemaining":18,"resetsAt":"2030-06-05T00:00:00+00:00"}
]}]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" t4 >/dev/null \
    || fail "auto-pick arm should succeed"
  assert_grep "RESET_EPOCH=1906502400" "$home/state/t4.check.sh" \
    "did not pick the exhausted window's reset instant"
  pass "auto-picks the provider's exhausted (0% remaining) window"
}

test_refuses_when_no_window_is_exhausted() {
  local home fakebin status
  home=$(make_home noexhausted)
  fakebin=$(fm_fakebin "$home")
  fm_write_meta "$home/state/t5.meta" "worktree=$home"
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":50,"resetsAt":"2030-06-01T00:00:00+00:00"}
]}]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  status=0
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" t5 >/dev/null 2>"$home/err.txt" \
    || status=$?
  expect_code 1 "$status" "no-exhausted-window exit code"
  assert_contains "$(cat "$home/err.txt")" "no exhausted window" "refusal did not explain itself"
  assert_absent "$home/state/t5.check.sh" "check was generated with no exhausted window"
  pass "refuses to auto-arm when no window reads 0% remaining"
}

test_arms_silent_before_reset
test_fires_once_and_self_deletes
test_refuses_to_clobber_existing_armed_check
test_refuses_without_task_record
test_auto_picks_most_exhausted_window
test_refuses_when_no_window_is_exhausted
