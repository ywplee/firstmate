#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-ephemeral)

make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/parent/state" "$CASE/parent/data" "$CASE/parent/config" \
    "$CASE/mate/state" "$CASE/mate/data" "$CASE/fakebin"
  fm_write_secondmate_meta "$CASE/parent/state/sm1.meta" "$CASE/mate" isolated:fm-sm1 alpha claude
  printf '%s\n' manual > "$CASE/parent/config/backlog-backend"
  printf '%s\n' '- sm1 home=unused' > "$CASE/parent/data/secondmates.md"
  cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message)
    case "$*" in *pane_current_command*) printf '%s\n' claude ;; esac ;;
  list-windows) [ -e "$FM_TEST_CASE/closed" ] || printf '%s\n' fm-sm1 ;;
  kill-window) touch "$FM_TEST_CASE/closed" ;;
esac
exit 0
SH
  cat > "$CASE/fakebin/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CASE/spawns"
sed '/^stopped=/d' "$FM_HOME/state/sm1.meta" > "$FM_HOME/state/sm1.meta.new"
mv "$FM_HOME/state/sm1.meta.new" "$FM_HOME/state/sm1.meta"
rm -f "$FM_TEST_CASE/closed"
SH
  cat > "$CASE/fakebin/send" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${FM_PENDING_REPLY_COLD_SPAWN:-0}" "$*" >> "$FM_TEST_CASE/sends"
SH
  chmod +x "$CASE/fakebin/"*
}

run_case() {
  FM_HOME="$CASE/parent" FM_ROOT_OVERRIDE="$ROOT" TASKS_AXI_BACKEND=markdown \
    FM_TEST_CASE="$CASE" PATH="$CASE/fakebin:$PATH" \
    FM_ROUTE_SPAWN_CMD="$CASE/fakebin/spawn" FM_ROUTE_SEND_CMD="$CASE/fakebin/send" \
    "$@"
}

probe_case() {
  # shellcheck disable=SC2016
  run_case bash -c '
    . "$1/bin/fm-secondmate-liveness-lib.sh"
    STATE="$FM_HOME/state"
    fm_backend_agent_state() { printf probe >> "$FM_TEST_CASE/probes"; printf missing; }
    fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll
    printf "%s\n" "$FM_SM_LIVE_STATUS"
  ' _ "$ROOT"
}

test_idle_and_stopped_do_not_probe() {
  make_case idle
  assert_equals silent "$(probe_case)" 'idle local home must stay down'
  assert_absent "$CASE/probes" 'idle home reached the backend'
  printf '%s\n' '- [ ] queued Work' > "$CASE/mate/data/backlog.md"
  assert_equals relaunchable "$(probe_case)" 'queued work must retain crash recovery'
  rm -f "$CASE/probes"
  printf '%s\n' stopped=1 >> "$CASE/parent/state/sm1.meta"
  assert_equals silent "$(probe_case)" 'intentional stop must outrank automatic recovery'
  assert_absent "$CASE/probes" 'intentional stop reached the backend'
  pass 'idle and intentionally stopped mates stay down; a work-bearing mate retains recovery'
}

test_route_starts_before_delivery() {
  make_case cold
  touch "$CASE/closed"
  printf '%s\n' stopped=1 >> "$CASE/parent/state/sm1.meta"
  run_case "$ROOT/bin/fm-route-secondmate.sh" sm1 'new work' || fail 'cold route failed'
  assert_grep 'sm1 --secondmate' "$CASE/spawns" 'cold route did not spawn'
  assert_grep '1|sm1 new work' "$CASE/sends" 'cold delivery did not carry the wider grace'
  assert_no_grep 'stopped=' "$CASE/parent/state/sm1.meta" 'successful spawn kept stopped marker'
  run_case "$ROOT/bin/fm-route-secondmate.sh" sm1 'more work' || fail 'warm route failed'
  [ "$(wc -l < "$CASE/spawns" | tr -d ' ')" = 1 ] || fail 'warm route spawned again'
  assert_grep '0|sm1 more work' "$CASE/sends" 'warm delivery changed'
  pass 'a cold route verifies its new agent before delivery and a warm route does not spawn'
}

test_stop_preserves_home_and_refuses_work() {
  make_case stop
  printf '%s\n' private > "$CASE/mate/data/canary"
  cp "$CASE/parent/data/secondmates.md" "$CASE/registry.before"
  run_case "$ROOT/bin/fm-teardown.sh" sm1 --stop > "$CASE/out" 2>&1 \
    || fail "idle stop failed: $(cat "$CASE/out")"
  assert_present "$CASE/closed" 'stop did not close its endpoint'
  assert_grep 'stopped=1' "$CASE/parent/state/sm1.meta" 'stop was not durable'
  assert_grep 'private' "$CASE/mate/data/canary" 'stop removed private material'
  cmp -s "$CASE/parent/data/secondmates.md" "$CASE/registry.before" || fail 'stop rewrote registry'
  make_case busy
  printf '%s\n' '- [ ] queued Work' > "$CASE/mate/data/backlog.md"
  if run_case "$ROOT/bin/fm-teardown.sh" sm1 --stop > "$CASE/out" 2>&1; then
    fail 'stop accepted queued work'
  fi
  assert_absent "$CASE/closed" 'refused stop closed the endpoint'
  pass 'idle stop preserves durable material and queued work refuses before endpoint closure'
}

test_force_stop_refuses_in_both_orders() {
  local args
  for args in '--stop --force' '--force --stop'; do
    make_case "force-${args// /-}"
    case "$args" in
      '--stop --force') set -- --stop --force ;;
      *) set -- --force --stop ;;
    esac
    if run_case "$ROOT/bin/fm-teardown.sh" sm1 "$@" > "$CASE/out" 2>&1; then
      fail 'force and stop combined'
    fi
    assert_absent "$CASE/closed" 'invalid options closed an endpoint'
  done
  pass 'force never widens the idle process-stop authority'
}

if [ -z "${FM_TEST_ONLY:-}" ] || [ "$FM_TEST_ONLY" = test_idle_and_stopped_do_not_probe ]; then test_idle_and_stopped_do_not_probe; fi
if [ -z "${FM_TEST_ONLY:-}" ] || [ "$FM_TEST_ONLY" = test_route_starts_before_delivery ]; then test_route_starts_before_delivery; fi
if [ -z "${FM_TEST_ONLY:-}" ] || [ "$FM_TEST_ONLY" = test_stop_preserves_home_and_refuses_work ]; then test_stop_preserves_home_and_refuses_work; fi
if [ -z "${FM_TEST_ONLY:-}" ] || [ "$FM_TEST_ONLY" = test_force_stop_refuses_in_both_orders ]; then test_force_stop_refuses_in_both_orders; fi
