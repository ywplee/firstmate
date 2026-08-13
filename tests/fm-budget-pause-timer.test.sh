#!/usr/bin/env bash
# Tests for bin/fm-budget-pause-timer.sh: arming the reserved fleet-level
# one-shot budget-pause resume check, reset-time resolution (explicit override
# and quota-axi auto-pick), and the refusal guarantees (no clobbering an armed
# check, no reserved-id collision with a real task or backlog item).
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
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" >/dev/null \
    || fail "arming with a future reset should succeed"
  assert_present "$home/state/budget-pause.check.sh" "check script was not generated"
  assert_present "$home/state/budget-pause.check-trust" "trust record was not registered"
  [ "$(file_mode "$home/state/budget-pause.check.sh")" = 700 ] || fail "check script is not mode 700"
  local out
  out=$(bash "$home/state/budget-pause.check.sh")
  [ -z "$out" ] || fail "check printed output before its reset instant: $out"
  assert_present "$home/state/budget-pause.check.sh" "check self-deleted before its reset instant"
  pass "armed check stays silent before its reset instant"
}

test_fires_once_and_self_deletes() {
  local home out
  home=$(make_home fires)
  FM_HOME="$home" "$TIMER" --reset "2020-01-01T00:00:00+00:00" >/dev/null \
    || fail "arming with a past reset should succeed"
  out=$(bash "$home/state/budget-pause.check.sh")
  assert_contains "$out" "budget pause window has reset" "wake line is not the expected fleet-level message"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "check printed more than one line: $out"
  assert_absent "$home/state/budget-pause.check.sh" "check did not self-delete after firing"
  assert_absent "$home/state/budget-pause.check-trust" "trust record did not self-delete after firing"
  pass "armed check prints exactly one line after its reset instant and self-deletes"
}

test_refuses_to_clobber_existing_armed_check() {
  local home status
  home=$(make_home clobber)
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" >/dev/null \
    || fail "first arm should succeed"
  status=0
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" >/dev/null 2>"$home/err.txt" \
    || status=$?
  expect_code 1 "$status" "re-arm exit code"
  assert_contains "$(cat "$home/err.txt")" "already armed" "re-arm did not explain the refusal"
  pass "refuses to clobber an already-armed check"
}

test_refuses_a_task_id_argument() {
  local home status
  home=$(make_home noid)
  status=0
  FM_HOME="$home" "$TIMER" some-task --reset "2099-01-01T00:00:00+00:00" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "task-id argument exit code"
  assert_contains "$(cat "$home/err.txt")" "unexpected argument" "task-id-argument refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was armed despite a rejected task-id argument"
  pass "refuses a caller-supplied task id - the reserved slot is not addressable by id"
}

test_refuses_when_the_reserved_id_has_a_task_record() {
  local home status
  home=$(make_home taskcollision)
  fm_write_meta "$home/state/budget-pause.meta" "worktree=$home"
  status=0
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "task-record collision exit code"
  assert_contains "$(cat "$home/err.txt")" "collides with an existing task record" \
    "task-record collision refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was armed despite a colliding task record"
  pass "refuses to arm when the reserved id already denotes a real task"
}

test_refuses_when_the_reserved_id_has_a_backlog_item() {
  local home status
  home=$(make_home backlogcollision)
  printf '## In flight\n\n## Queued\n- [ ] budget-pause - unrelated item (repo: sample) (kind: ship) (since 2026-08-01)\n\n## Done\n' \
    > "$home/data/backlog.md"
  status=0
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "backlog collision exit code"
  assert_contains "$(cat "$home/err.txt")" "collides with an existing backlog item" \
    "backlog collision refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was armed despite a colliding backlog item"
  pass "refuses to arm when the reserved id already denotes a real backlog item"
}

test_auto_picks_most_exhausted_window() {
  local home fakebin
  home=$(make_home auto)
  fakebin=$(fm_fakebin "$home")
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
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" >/dev/null \
    || fail "auto-pick arm should succeed"
  assert_grep "RESET_EPOCH=1906502400" "$home/state/budget-pause.check.sh" \
    "did not pick the exhausted window's reset instant"
  pass "auto-picks the provider's exhausted (0% remaining) window"
}

test_refuses_when_no_window_is_exhausted() {
  local home fakebin status
  home=$(make_home noexhausted)
  fakebin=$(fm_fakebin "$home")
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
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" >/dev/null 2>"$home/err.txt" \
    || status=$?
  expect_code 1 "$status" "no-exhausted-window exit code"
  assert_contains "$(cat "$home/err.txt")" "no exhausted window" "refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was generated with no exhausted window"
  pass "refuses to auto-arm when no window reads 0% remaining"
}

test_auto_pick_ignores_other_providers_and_model_windows() {
  local home fakebin
  home=$(make_home crossprovider)
  fakebin=$(fm_fakebin "$home")
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
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" >/dev/null \
    || fail "auto-pick arm should succeed"
  assert_grep "RESET_EPOCH=1906502400" "$home/state/budget-pause.check.sh" \
    "auto-pick did not ignore other providers and model-scoped windows"
  pass "auto-pick ignores other providers' windows and model-scoped windows"
}

test_auto_pick_prefers_the_latest_reset_when_multiple_windows_are_exhausted() {
  local home fakebin
  home=$(make_home multiexhausted)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":0,"resetsAt":"2030-07-01T00:00:00+00:00"},
  {"id":"seven_day","percentRemaining":0,"resetsAt":"2030-08-01T00:00:00+00:00"}
]}]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" >/dev/null \
    || fail "auto-pick arm should succeed"
  assert_grep "RESET_EPOCH=1911772800" "$home/state/budget-pause.check.sh" \
    "auto-pick did not arm off the later of two exhausted windows"
  local out
  out=$(bash "$home/state/budget-pause.check.sh")
  [ -z "$out" ] || fail "check fired before the later exhausted window's reset: $out"
  assert_present "$home/state/budget-pause.check.sh" "check self-deleted before the later exhausted window's reset"
  pass "auto-pick arms off the latest reset when more than one window is exhausted"
}

test_refuses_a_stale_reset_already_in_the_past() {
  local home fakebin status
  home=$(make_home stale)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":0,"resetsAt":"2020-01-01T00:00:00+00:00"}
]}]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  status=0
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "stale-reset exit code"
  assert_contains "$(cat "$home/err.txt")" "in the past" "stale-reset refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was armed against a stale, already-past reset"
  assert_absent "$home/state/budget-pause.check-trust" "trust record was armed against a stale, already-past reset"
  pass "refuses to auto-arm a reset that quota-axi already reports as past"
}

test_auto_pick_compares_reset_instants_not_strings() {
  local home fakebin
  home=$(make_home mixedoffsets)
  fakebin=$(fm_fakebin "$home")
  # 2030-05-31T20:00:00-08:00 is 2030-06-01T04:00:00Z: later than the other
  # window, but earlier under a plain string sort of the raw timestamps.
  cat > "$fakebin/fake-quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":0,"resetsAt":"2030-06-01T00:00:00Z"},
  {"id":"seven_day","percentRemaining":0,"resetsAt":"2030-05-31T20:00:00-08:00"}
]}]}
JSON
SH
  chmod +x "$fakebin/fake-quota-axi"
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" >/dev/null \
    || fail "auto-pick arm should succeed"
  assert_grep "RESET_EPOCH=1906516800" "$home/state/budget-pause.check.sh" \
    "auto-pick compared timestamps as strings instead of as instants"
  pass "auto-pick arms off the latest instant when windows mix UTC offsets"
}

test_a_ragged_reset_cannot_corrupt_the_generated_check() {
  local home out
  home=$(make_home ragged)
  # An armed check that is not valid bash fails silently on every watcher poll
  # instead of ever firing, so no reset value may reach the generated bytes
  # unnormalized.
  FM_HOME="$home" "$TIMER" --reset "$(printf '\n2099-01-01T00:00:00+00:00')" >/dev/null \
    || fail "arming with a stray-newline reset should normalize, not fail"
  bash -n "$home/state/budget-pause.check.sh" \
    || fail "a reset with a stray newline produced an armed check that is not valid bash"
  out=$(bash "$home/state/budget-pause.check.sh") \
    || fail "the armed check exited non-zero instead of staying silent"
  [ -z "$out" ] || fail "check printed output before its reset instant: $out"
  assert_grep "RESET_EPOCH=4070908800" "$home/state/budget-pause.check.sh" \
    "the stray-newline reset did not resolve to its normalized instant"
  pass "a reset timestamp carrying stray whitespace cannot corrupt the generated check"
}

test_refuses_a_reset_with_an_interior_newline() {
  local home status
  home=$(make_home interior)
  status=0
  FM_HOME="$home" "$TIMER" --reset "$(printf '2099-01-01\nT00:00:00+00:00')" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "interior-newline reset exit code"
  assert_contains "$(cat "$home/err.txt")" "could not parse reset timestamp" \
    "interior-newline refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "a reset with an interior newline armed a check anyway"
  assert_absent "$home/state/budget-pause.check-trust" "a reset with an interior newline registered a trust record"
  pass "refuses a reset timestamp with an interior newline"
}

test_generated_check_is_syntax_checked_before_install() {
  local home
  home=$(make_home syntax)
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" >/dev/null \
    || fail "arming with a future reset should succeed"
  bash -n "$home/state/budget-pause.check.sh" \
    || fail "an armed check that is not valid bash was installed"
  pass "the installed check parses as valid bash"
}

test_window_lookup_is_scoped_to_the_provider() {
  local home fakebin status
  home=$(make_home windowscope)
  fakebin=$(fm_fakebin "$home")
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
  FM_HOME="$home" FM_QUOTA_AXI_BIN="$fakebin/fake-quota-axi" "$TIMER" --window weekly \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "cross-provider window exit code"
  assert_contains "$(cat "$home/err.txt")" "has no window 'weekly'" \
    "cross-provider window refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was armed against another provider's window"
  pass "--window only matches windows belonging to the queried provider"
}

test_rejects_reset_combined_with_provider() {
  local home status
  home=$(make_home exclusive)
  status=0
  FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" --provider codex \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "--reset with --provider exit code"
  assert_contains "$(cat "$home/err.txt")" "mutually exclusive" \
    "--reset with --provider refusal did not explain itself"
  assert_absent "$home/state/budget-pause.check.sh" "check was armed despite conflicting options"
  pass "refuses --reset combined with --provider"
}

test_rolls_back_the_check_when_registration_fails() {
  local home fakebin status
  home=$(make_home rollback)
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" shasum sha256sum
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$TIMER" --reset "2099-01-01T00:00:00+00:00" \
    >/dev/null 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "failed-registration exit code"
  assert_absent "$home/state/budget-pause.check.sh" "failed registration left an unregistered check behind"
  assert_absent "$home/state/budget-pause.check-trust" "failed registration left a trust record behind"
  pass "removes the generated check when registration fails"
}

test_bakes_absolute_self_delete_paths() {
  local home fakebin python_bin out
  home=$(make_home relpath)
  fakebin=$(fm_fakebin "$home")
  # Pin the interpreter by absolute path so a version manager that resolves
  # python3 per working directory cannot decide the outcome of this test.
  python_bin=$(python3 -c 'import sys; print(sys.executable)') || fail "python3 is unavailable"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$python_bin" > "$fakebin/python3"
  chmod +x "$fakebin/python3"
  ( cd "$home" && PATH="$fakebin:$PATH" FM_HOME=. FM_STATE_OVERRIDE=./state "$TIMER" \
      --reset "2020-01-01T00:00:00+00:00" >/dev/null ) \
    || fail "arming from a relative state path should succeed"
  assert_grep "CHECK_PATH='/" "$home/state/budget-pause.check.sh" \
    "self-delete path was not baked as an absolute path"
  out=$(cd / && bash "$home/state/budget-pause.check.sh")
  assert_contains "$out" "budget pause window has reset" "wake line is not the expected fleet-level message"
  assert_absent "$home/state/budget-pause.check.sh" "check did not self-delete when run from another directory"
  assert_absent "$home/state/budget-pause.check-trust" "trust record did not self-delete"
  pass "bakes absolute self-delete paths that work from any directory"
}

test_arms_silent_before_reset
test_fires_once_and_self_deletes
test_refuses_to_clobber_existing_armed_check
test_refuses_a_task_id_argument
test_refuses_when_the_reserved_id_has_a_task_record
test_refuses_when_the_reserved_id_has_a_backlog_item
test_auto_picks_most_exhausted_window
test_refuses_when_no_window_is_exhausted
test_auto_pick_ignores_other_providers_and_model_windows
test_auto_pick_prefers_the_latest_reset_when_multiple_windows_are_exhausted
test_refuses_a_stale_reset_already_in_the_past
test_auto_pick_compares_reset_instants_not_strings
test_a_ragged_reset_cannot_corrupt_the_generated_check
test_refuses_a_reset_with_an_interior_newline
test_generated_check_is_syntax_checked_before_install
test_window_lookup_is_scoped_to_the_provider
test_rejects_reset_combined_with_provider
test_rolls_back_the_check_when_registration_fails
test_bakes_absolute_self_delete_paths
