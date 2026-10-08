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
export FM_TEST_PROBE_CALLS="$TMP_ROOT/codex-probe-calls"
export FM_TEST_REAL_PS
FM_TEST_REAL_PS=$(command -v ps)
launch_args=(--model gpt-6.1-sol --effort high --sandbox danger-full-access --ask-for-approval never)

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
if [ "${1:-}" != --no-daemon ]; then exit 1; fi
if [ "${2:-}" = --help ]; then
  printf '%s\n' "$@" > "$FM_TEST_PROBE_CALLS"
  printf '%s\n' 'Codex --no-daemon'
else
  printf '%s\n' "$@" > "$FM_TEST_CALLS"
fi
MOCK
cat > "$TMP_ROOT/fakebin/ps" <<'MOCK'
#!/usr/bin/env bash
if [ -n "${FM_TEST_CODEX_ARGS:-}" ] && [ "${3:-}" = -p ] && [ "${4:-}" = "$FM_TEST_PANE_PID" ]; then
  case "${2:-}" in
    comm=) printf '%s\n' codex; exit 0 ;;
    args=) printf '%s\n' "$FM_TEST_CODEX_ARGS"; exit 0 ;;
  esac
fi
exec "$FM_TEST_REAL_PS" "$@"
MOCK
chmod +x "$TMP_ROOT/fakebin/"*
export PATH="$TMP_ROOT/fakebin:$PATH"

expect_refusal() {
  local message=$1 action=${2:-launch} out
  if [ "$action" = launch ]; then
    out=$("$SUPERVISOR" launch "${launch_args[@]}" 2>&1) && fail "expected refusal: $message"
  else
    out=$("$SUPERVISOR" "$action" 2>&1) && fail "expected refusal: $message"
  fi
  if [ -z "$out" ]; then fail "expected refusal: $message"; fi
  assert_contains "$out" "$message" "wrong refusal"
  [ ! -e "$FM_TEST_CALLS" ] || fail 'refused launch invoked Codex'
}

expect_argument_refusal() {
  local message=$1 out
  shift
  out=$("$SUPERVISOR" launch "$@" 2>&1) && fail "expected refusal: $message"
  assert_contains "$out" "$message" 'wrong argument refusal'
  [ ! -e "$FM_TEST_CALLS" ] && [ ! -e "$FM_TEST_PROBE_CALLS" ] || fail 'invalid arguments invoked Codex'
}

expect_argument_refusal 'authorized --model explicitly' --effort high --sandbox danger-full-access --ask-for-approval never
expect_argument_refusal 'authorized --effort explicitly' --model gpt-6.1-sol --sandbox danger-full-access --ask-for-approval never
expect_argument_refusal 'authorized --effort explicitly' --model gpt-6.1-sol --effort max --sandbox danger-full-access --ask-for-approval never
for sandbox in read-only workspace-write ''; do
  expect_argument_refusal 'requires explicit --sandbox danger-full-access' --model gpt-6.1-sol --effort high --sandbox "$sandbox" --ask-for-approval never
done
for approval in on-request ''; do
  expect_argument_refusal 'requires explicit --ask-for-approval never' --model gpt-6.1-sol --effort high --sandbox danger-full-access --ask-for-approval "$approval"
done
pass 'missing model or effort and unverified permission policies refuse before invoking Codex'

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
printf '%s\n' "$FM_HOME" > "$FM_HOME/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$FM_HOME/state/.watch.lock/watcher-path"
FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$$" > "$FM_HOME/state/.watch.lock/pid-identity"
expect_refusal 'previous supervision process is still live'
cp -R "$FM_HOME/state/.watch.lock" "$TMP_ROOT/watcher-before"
cmp "$TMP_ROOT/watcher-before/pid-identity" "$FM_HOME/state/.watch.lock/pid-identity" || fail 'refusal changed watcher identity'
ln -s "$ROOT" "$TMP_ROOT/source-link"
for watcher_path in "$TMP_ROOT/previous-checkout/bin/fm-watch.sh" "$TMP_ROOT/source-link/bin/fm-watch.sh"; do
  printf '%s\n' "$watcher_path" > "$FM_HOME/state/.watch.lock/watcher-path"
  snapshot=$(mktemp -d "$TMP_ROOT/watcher-records.XXXXXX")
  cp -R "$FM_HOME/state/.watch.lock" "$snapshot/before"
  expect_refusal 'previous supervision process is still live'
  [ ! -e "$FM_TEST_PROBE_CALLS" ] || fail 'live watcher from another source path allowed a Codex probe'
  diff -r "$snapshot/before" "$FM_HOME/state/.watch.lock" || fail 'refusal changed alternate-source watcher records'
  cmp "$TMP_ROOT/lock-before" "$FM_HOME/state/.lock" || fail 'refusal changed old coordinator ownership'
  cmp "$TMP_ROOT/queue-before" "$FM_HOME/state/.wake-queue" || fail 'refusal consumed pending wakes'
done
pass 'live same-home watcher from another checkout or symlink path refuses launch without changing records'

printf '%s\n' "$TMP_ROOT/other-home" > "$FM_HOME/state/.watch.lock/fm-home"
cp -R "$FM_HOME/state/.watch.lock" "$TMP_ROOT/other-home-watcher-before"
"$SUPERVISOR" launch "${launch_args[@]}" > "$TMP_ROOT/other-home-launch.out"
[ -s "$FM_TEST_CALLS" ] || fail 'watcher belonging to another home blocked launch'
diff -r "$TMP_ROOT/other-home-watcher-before" "$FM_HOME/state/.watch.lock" || fail 'launch changed other-home watcher records'
cmp "$TMP_ROOT/lock-before" "$FM_HOME/state/.lock" || fail 'launch changed old coordinator ownership'
cmp "$TMP_ROOT/queue-before" "$FM_HOME/state/.wake-queue" || fail 'launch consumed pending wakes'
rm "$FM_TEST_CALLS" "$FM_TEST_PROBE_CALLS"
printf '%s\n' "$FM_HOME" > "$FM_HOME/state/.watch.lock/fm-home"
pass 'other-home watcher identity remains isolated even when its source path differs'

printf '%s\n' 'recycled-watcher-identity' > "$FM_HOME/state/.watch.lock/pid-identity"
cp -R "$FM_HOME/state/.watch.lock" "$TMP_ROOT/stale-watcher-before"
mkdir -p "$FM_HOME/state/.supervise-daemon.lock"
printf '%s\n' "$$" > "$FM_HOME/state/.supervise-daemon.lock/pid"
FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$$" > "$FM_HOME/state/.supervise-daemon.lock/pid-identity"
printf '%s\n' "$$" > "$FM_HOME/state/.supervise-daemon.pid"
expect_refusal 'previous supervision process is still live'
mv "$FM_HOME/state/.supervise-daemon.lock" "$FM_HOME/state/daemon-owner"
ln -s daemon-owner "$FM_HOME/state/.supervise-daemon.lock"
expect_refusal 'previous supervision process is still live'
printf '%s\n' 'recycled-daemon-identity' > "$FM_HOME/state/.supervise-daemon.lock/pid-identity"
cp -R "$FM_HOME/state/daemon-owner" "$TMP_ROOT/stale-daemon-before"
: > "$FM_HOME/state/.afk"
expect_refusal 'previous away-mode lifecycle is not closed'
rm "$FM_HOME/state/.afk"
: > "$FM_HOME/state/.afk-return-catchup"
expect_refusal 'previous away-mode lifecycle is not closed'
rm "$FM_HOME/state/.afk-return-catchup"
pass 'dead coordinator cannot transfer while old supervision or catch-up remains'

"$SUPERVISOR" launch "${launch_args[@]}" > "$TMP_ROOT/launch.out"
printf '%s\n' --no-daemon --model gpt-6.1-sol -c 'model_reasoning_effort="high"' --sandbox danger-full-access --ask-for-approval never --cd "$FM_HOME" > "$TMP_ROOT/expected-args"
head -n 11 "$FM_TEST_CALLS" > "$TMP_ROOT/actual-args"
cmp "$TMP_ROOT/expected-args" "$TMP_ROOT/actual-args" || fail 'launch changed explicit account model, effort, permissions or home arguments'
printf '%s\n' --no-daemon --help > "$TMP_ROOT/expected-probe"
cmp "$TMP_ROOT/expected-probe" "$FM_TEST_PROBE_CALLS" || fail 'capability probe did not use root --no-daemon'
assert_contains "$(cat "$FM_TEST_CALLS")" 'Run bin/fm-session-start.sh exactly once' 'successor was not instructed to acquire normally'
cmp "$TMP_ROOT/lock-before" "$FM_HOME/state/.lock" || fail 'launch released or rewrote old lock'
cmp "$TMP_ROOT/queue-before" "$FM_HOME/state/.wake-queue" || fail 'launch consumed durable pending wakes'
diff -r "$TMP_ROOT/stale-watcher-before" "$FM_HOME/state/.watch.lock" || fail 'launch changed stale watcher records'
diff -r "$TMP_ROOT/stale-daemon-before" "$FM_HOME/state/daemon-owner" || fail 'launch changed stale daemon records'
[ "$(readlink "$FM_HOME/state/.supervise-daemon.lock")" = daemon-owner ] || fail 'launch changed daemon ownership link'
[ "$(cat "$FM_HOME/state/.supervise-daemon.pid")" = "$$" ] || fail 'launch changed standalone stale daemon pidfile'
rm "$FM_TEST_CALLS"
pass 'recycled supervision PIDs permit explicit personal rollout while all ownership and queue records survive'

rm "$FM_HOME/state/.supervise-daemon.lock"
"$SUPERVISOR" launch "${launch_args[@]}" --model alternate-model --effort medium > "$TMP_ROOT/alternate-launch.out"
assert_grep alternate-model "$FM_TEST_CALLS" 'shared launch route hard-coded a model'
assert_grep 'model_reasoning_effort="medium"' "$FM_TEST_CALLS" 'shared launch route ignored explicit effort'
rm "$FM_TEST_CALLS"
pass 'standalone stale daemon pidfile does not own the home and explicit model selection is retained'

FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_session_lock_body "$2"' _ "$ROOT" "$$" > "$FM_HOME/state/.lock"
expect_refusal 'not a verified Codex --no-daemon coordinator' preflight
FM_TEST_CODEX_ARGS='codex --no-daemon -c model_reasoning_effort="high"' expect_refusal 'requires an explicit launch model' preflight
FM_TEST_CODEX_ARGS='codex --no-daemon --model gpt-6.1-sol' expect_refusal 'requires an explicit launch reasoning effort' preflight
FM_TEST_CODEX_ARGS='codex --no-daemon --model gpt-6.1-sol -c model_reasoning_effort="high" --sandbox danger-full-access --ask-for-approval never' "$SUPERVISOR" preflight > "$TMP_ROOT/preflight.out"
assert_contains "$(cat "$TMP_ROOT/preflight.out")" 'model=gpt-6.1-sol effort=high' 'preflight did not identify the explicit rollout model and effort'
cmp "$TMP_ROOT/queue-before" "$FM_HOME/state/.wake-queue" || fail 'preflight consumed pending wakes'
pass 'preflight refuses inherited model or effort and reports the explicit personal rollout'
printf '%s\nidentity=wrong-process\n' "$$" > "$FM_HOME/state/.lock"
expect_refusal 'lock process identity differs' preflight
pass 'shell ancestry and recycled process identity do not certify Codex readiness'

mkdir -p "$TMP_ROOT/trust-fixture/bin" "$TMP_ROOT/trust-fixture/tmp" "$TMP_ROOT/trust-fixture/evidence"
export FM_TEST_TRUST_KEYS="$TMP_ROOT/trust-fixture/keys"
cat > "$TMP_ROOT/trust-fixture/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
shift 2
case "$1" in
  capture-pane) printf '%s\n' 'Trust this folder?' ;;
  send-keys)
    if [ "${*: -1}" = Enter ]; then
      printf '%s\n' Enter >> "$FM_TEST_TRUST_KEYS"
      [ "$(wc -l < "$FM_TEST_TRUST_KEYS")" -eq 1 ] || exit 1
    fi
    ;;
esac
exit 0
MOCK
cat > "$TMP_ROOT/trust-fixture/bin/codex" <<'MOCK'
#!/usr/bin/env bash
[ "$1" = --no-daemon ] && [ "$2" = --version ] || exit 1
printf '%s\n' 'codex test fixture'
MOCK
chmod +x "$TMP_ROOT/trust-fixture/bin/"*
if out=$(PATH="$TMP_ROOT/trust-fixture/bin:$PATH" TMPDIR="$TMP_ROOT/trust-fixture/tmp" FM_CODEX_SUPERVISOR_EVIDENCE="$TMP_ROOT/trust-fixture/evidence" FM_CODEX_SUPERVISOR_LIVE_E2E=1 bash "$ROOT/tests/fm-codex-supervisor-live-e2e.test.sh" 2>&1); then
  fail 'live fixture accepted an unexpected directory trust prompt'
fi
assert_contains "$out" 'new directory trust prompt requires stopping verification' 'live fixture did not explain its trust refusal'
[ "$(wc -l < "$FM_TEST_TRUST_KEYS")" -eq 1 ] || fail 'live fixture sent an approval to the directory trust dialog'
pass 'live fixture stops on a new directory trust prompt without sending approval'
