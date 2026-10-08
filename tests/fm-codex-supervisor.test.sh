#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-supervisor)
SUPERVISOR="$ROOT/bin/fm-codex-supervisor.sh"
export FM_HOME="$TMP_ROOT/home" CODEX_HOME="$TMP_ROOT/account"
export TMUX='scratch-socket,1,0' TMUX_PANE='%27'
export FM_TEST_PANE_PID=$$ FM_TEST_PANE_COMMAND=bash FM_TEST_SOCKET=scratch-socket
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET
mkdir -p "$FM_HOME/state" "$CODEX_HOME" "$TMP_ROOT/fakebin"
export FM_TEST_CALLS="$TMP_ROOT/codex-calls"

cat > "$TMP_ROOT/fakebin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${*: -1}" in
  '#{pane_id}') printf '%s\n' "${FM_TEST_PANE_ID:-%27}" ;;
  '#{pane_pid}') printf '%s\n' "$FM_TEST_PANE_PID" ;;
  '#{pane_current_command}') printf '%s\n' "$FM_TEST_PANE_COMMAND" ;;
  '#{socket_path}') printf '%s\n' "$FM_TEST_SOCKET" ;;
  *) exit 1 ;;
esac
MOCK
cat > "$TMP_ROOT/fakebin/codex" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Codex --no-daemon'
else
  printf '%s\n' "$@" > "$FM_TEST_CALLS"
fi
MOCK
chmod +x "$TMP_ROOT/fakebin/"*
export PATH="$TMP_ROOT/fakebin:$PATH"

expect_refusal() {
  local message=$1 action=${2:-launch} out
  if [ "$action" = launch ]; then
    out=$("$SUPERVISOR" launch --sandbox danger-full-access --ask-for-approval never 2>&1) && fail "expected refusal: $message"
  else
    out=$("$SUPERVISOR" "$action" 2>&1) && fail "expected refusal: $message"
  fi
  if [ -z "$out" ]; then fail "expected refusal: $message"; fi
  assert_contains "$out" "$message" "wrong refusal"
  [ ! -e "$FM_TEST_CALLS" ] || fail 'refused launch invoked Codex'
}

printf '1791441000\t1\tsignal\tpending.status\tsignal: pending\n' > "$FM_HOME/state/.wake-queue"
cp "$FM_HOME/state/.wake-queue" "$TMP_ROOT/queue-before"

sleep 300 &
LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null || true; fm_test_cleanup || true' EXIT
FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_session_lock_body "$2"' _ "$ROOT" "$LIVE_PID" > "$FM_HOME/state/.lock"
cp "$FM_HOME/state/.lock" "$TMP_ROOT/lock-before"
expect_refusal 'previous coordinator still owns the home'
cmp "$TMP_ROOT/lock-before" "$FM_HOME/state/.lock" || fail 'refusal changed old ownership'
expect_refusal 'another coordinator owns this home' preflight
pass 'live exact owner blocks launch and preflight without changing its lock'

FM_TEST_PANE_PID=$LIVE_PID expect_refusal 'target pane is not an ancestor'
FM_TEST_PANE_ID='%28' expect_refusal 'target identity differs'
FM_TEST_SOCKET=other-socket expect_refusal 'socket differs'
FM_SUPERVISOR_TARGET='%28' expect_refusal 'override differs'
FM_SUPERVISOR_BACKEND=herdr expect_refusal 'tmux primary only'
FM_TEST_PANE_COMMAND=node expect_refusal 'outside an existing agent'
TMUX='' TMUX_PANE='' expect_refusal 'Desktop has no verified post-turn wake route'
pass 'wrong process, pane, socket, override, host and agent context cannot launch'

kill "$LIVE_PID"
wait "$LIVE_PID" 2>/dev/null || true
mkdir -p "$FM_HOME/state/.watch.lock"
printf '%s\n' "$$" > "$FM_HOME/state/.watch.lock/pid"
expect_refusal 'previous supervision process is still live'
rm "$FM_HOME/state/.watch.lock/pid"
printf '%s\n' "$$" > "$FM_HOME/state/.supervise-daemon.pid"
expect_refusal 'previous supervision process is still live'
rm "$FM_HOME/state/.supervise-daemon.pid"
: > "$FM_HOME/state/.afk"
expect_refusal 'previous away-mode lifecycle is not closed'
rm "$FM_HOME/state/.afk"
: > "$FM_HOME/state/.afk-return-catchup"
expect_refusal 'previous away-mode lifecycle is not closed'
rm "$FM_HOME/state/.afk-return-catchup"
pass 'dead coordinator cannot transfer while old supervision or catch-up remains'

"$SUPERVISOR" launch --sandbox danger-full-access --ask-for-approval never > "$TMP_ROOT/launch.out"
assert_contains "$(cat "$FM_TEST_CALLS")" '--no-daemon' 'launch did not use a private Codex process'
assert_contains "$(cat "$FM_TEST_CALLS")" 'danger-full-access' 'launch changed authorized filesystem policy'
assert_contains "$(cat "$FM_TEST_CALLS")" 'never' 'launch changed authorized approval policy'
assert_contains "$(cat "$FM_TEST_CALLS")" "$FM_HOME" 'launch lost exact operational home'
assert_contains "$(cat "$FM_TEST_CALLS")" 'Run bin/fm-session-start.sh exactly once' 'successor was not instructed to acquire normally'
cmp "$TMP_ROOT/lock-before" "$FM_HOME/state/.lock" || fail 'launch released or rewrote old lock'
cmp "$TMP_ROOT/queue-before" "$FM_HOME/state/.wake-queue" || fail 'launch consumed durable pending wakes'
rm "$FM_TEST_CALLS"
pass 'process-exit handoff launches no-daemon successor and preserves lock and queue for session-start'

FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_session_lock_body "$2"' _ "$ROOT" "$$" > "$FM_HOME/state/.lock"
expect_refusal 'not a verified Codex --no-daemon coordinator' preflight
printf '%s\nidentity=wrong-process\n' "$$" > "$FM_HOME/state/.lock"
expect_refusal 'lock process identity differs' preflight
pass 'shell ancestry and recycled process identity do not certify Codex readiness'
