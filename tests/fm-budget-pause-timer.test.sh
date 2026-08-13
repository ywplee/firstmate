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

test_auto_pick_ignores_other_providers_and_model_windows() {
  local home fakebin
  home=$(make_home crossprovider)
  fakebin=$(fm_fakebin "$home")
  fm_write_meta "$home/state/t6.meta" "worktree=$home"
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"codex","windows":[
    {"id":"five_hour","percentRemaining":0,"resetsAt":"2030-01-01T00:00:00+00:00"}
  ]},
  {"provider":"claude","windows":[
    {"id":"model:fable","kind":"model","percentRemaining":0,"resetsAt":"2030-03-01T00:00:00+00:00"},
    {"id":"five_hour","percentRemaining":0,"resetsAt":"2030-06-01T00:00:00+00:00"}
  ]}
]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" t6 >/dev/null \
    || fail "auto-pick arm should succeed"
  assert_grep "RESET_EPOCH=1906502400" "$home/state/t6.check.sh" \
    "auto-pick did not ignore other providers and model-scoped windows"
  pass "auto-pick ignores other providers' windows and model-scoped windows"
}

test_window_lookup_is_scoped_to_the_provider() {
  local home fakebin status
  home=$(make_home windowscope)
  fakebin=$(fm_fakebin "$home")
  fm_write_meta "$home/state/t7.meta" "worktree=$home"
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"codex","windows":[
    {"id":"weekly","percentRemaining":0,"resetsAt":"2030-01-01T00:00:00+00:00"}
  ]},
  {"provider":"claude","windows":[
    {"id":"five_hour","percentRemaining":0,"resetsAt":"2030-06-01T00:00:00+00:00"}
  ]}
]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  status=0
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" t7 --window weekly \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "cross-provider window exit code"
  assert_contains "$(cat "$home/err.txt")" "has no window 'weekly'" \
    "cross-provider window refusal did not explain itself"
  assert_absent "$home/state/t7.check.sh" "check was armed against another provider's window"
  pass "--window only matches windows belonging to the queried provider"
}

test_rejects_reset_combined_with_provider() {
  local home status
  home=$(make_home exclusive)
  fm_write_meta "$home/state/t8.meta" "worktree=$home"
  status=0
  FM_HOME="$home" "$TIMER" t8 --reset "2099-01-01T00:00:00+00:00" --provider codex \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "--reset with --provider exit code"
  assert_contains "$(cat "$home/err.txt")" "mutually exclusive" \
    "--reset with --provider refusal did not explain itself"
  assert_absent "$home/state/t8.check.sh" "check was armed despite conflicting options"
  pass "refuses --reset combined with --provider"
}

test_rolls_back_the_check_when_registration_fails() {
  local home fakebin status
  home=$(make_home rollback)
  fakebin=$(fm_fakebin "$home")
  fm_write_meta "$home/state/t9.meta" "worktree=$home"
  fm_fake_exit0 "$fakebin" shasum sha256sum
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$TIMER" t9 --reset "2099-01-01T00:00:00+00:00" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "failed-registration exit code"
  assert_absent "$home/state/t9.check.sh" "failed registration left an unregistered check behind"
  assert_absent "$home/state/t9.check-trust" "failed registration left a trust record behind"
  pass "removes the generated check when registration fails"
}

test_bakes_absolute_self_delete_paths() {
  local home fakebin python_bin out
  home=$(make_home relpath)
  fakebin=$(fm_fakebin "$home")
  fm_write_meta "$home/state/t10.meta" "worktree=$home"
  # Pin the interpreter by absolute path so a version manager that resolves
  # python3 per working directory cannot decide the outcome of this test.
  python_bin=$(python3 -c 'import sys; print(sys.executable)') || fail "python3 is unavailable"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$python_bin" > "$fakebin/python3"
  chmod +x "$fakebin/python3"
  ( cd "$home" && PATH="$fakebin:$PATH" FM_HOME=. FM_STATE_OVERRIDE=./state "$TIMER" t10 \
      --reset "2020-01-01T00:00:00+00:00" >/dev/null ) \
    || fail "arming from a relative state path should succeed"
  assert_grep "CHECK_PATH='/" "$home/state/t10.check.sh" \
    "self-delete path was not baked as an absolute path"
  out=$(cd / && bash "$home/state/t10.check.sh")
  assert_contains "$out" "t10" "wake line does not name the task"
  assert_absent "$home/state/t10.check.sh" "check did not self-delete when run from another directory"
  assert_absent "$home/state/t10.check-trust" "trust record did not self-delete"
  pass "bakes absolute self-delete paths that work from any directory"
}

test_arms_silent_before_reset
test_fires_once_and_self_deletes
test_refuses_to_clobber_existing_armed_check
test_refuses_without_task_record
test_auto_picks_most_exhausted_window
test_refuses_when_no_window_is_exhausted
test_auto_pick_ignores_other_providers_and_model_windows
test_window_lookup_is_scoped_to_the_provider
test_rejects_reset_combined_with_provider
test_rolls_back_the_check_when_registration_fails
test_bakes_absolute_self_delete_paths
