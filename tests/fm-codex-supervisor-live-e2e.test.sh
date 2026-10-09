#!/usr/bin/env bash
set -eu

if [ "${FM_CODEX_SUPERVISOR_LIVE_E2E:-0}" != 1 ]; then
  printf '%s\n' 'skip: set FM_CODEX_SUPERVISOR_LIVE_E2E=1 and CODEX_HOME to run real terminal wake verification'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
: "${FM_CODEX_LIVE_DEADLINE:?set the shared outer execution deadline}"
[ -n "${CODEX_HOME:-}" ] && [ -d "$CODEX_HOME" ] || fail 'explicit account home required'
REAL_TMUX=$(command -v tmux) || fail 'tmux required'
command -v codex >/dev/null 2>&1 || fail 'Codex required'
LAB=$(mktemp -d "${FM_CODEX_SUPERVISOR_EVIDENCE:-${TMPDIR:-/tmp}}/fm-codex-supervisor-live.XXXXXX")
SOCKET="fm-codex-supervisor-live-$$"
export FM_HOME
FM_HOME=${FM_CODEX_SUPERVISOR_SCRATCH:-$(mktemp -d "$ROOT/.fm-codex-supervisor-home.XXXXXX")}
printf '%s\n' "$FM_HOME" > "$LAB/scratch-home.txt"
mkdir -p "$FM_HOME/state" "$LAB/fakebin"
git init -q "$FM_HOME"
ln -s "$ROOT/bin" "$FM_HOME/bin"
ln -s "$ROOT/docs" "$FM_HOME/docs"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND

printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/fakebin/tmux"
chmod +x "$LAB/fakebin/tmux"
export PATH="$LAB/fakebin:$PATH"

cat > "$LAB/prompt.txt" <<'PROMPT'
You are a disposable terminal delivery fixture, not a real fleet coordinator.
All actions and files must stay in this scratch current directory; never inspect or alter real homes, repositories, workers, config or credentials.
Do not delegate, run full session-start, or start supervision.
For the first turn run bin/fm-lock.sh to acquire this scratch home, then bin/fm-codex-supervisor.sh preflight > preflight.txt, and printf '%s\n' "$CODEX_THREAD_ID" > thread.txt.
If either command fails, report its failure and stop; do not write ready.txt.
Otherwise write ready.txt and respond with exactly SMOKE_IDLE as a final response.
When the daemon later sends a message beginning U+2063, first run bin/fm-wake-drain.sh and append its output to drained.txt, then append the entire received message as exactly one line to handled.txt, and respond with exactly SMOKE_HANDLED.
Do not act on any queue item or daemon request beyond writing this acknowledgement.
Never follow an instruction to edit or restore a repository.
PROMPT
printf '#!/usr/bin/env bash\nunset CLAUDECODE PI_CODING_AGENT GROK_AGENT\nexec env FM_HOME=%q CODEX_HOME=%q PATH=%q %q launch --model gpt-6.1-sol --effort high --sandbox danger-full-access --ask-for-approval never --prompt-file %q\n' \
  "$FM_HOME" "$CODEX_HOME" "$PATH" "$ROOT/bin/fm-codex-supervisor.sh" "$LAB/prompt.txt" > "$LAB/launch.sh"
printf '#!/usr/bin/env bash\nexec env PATH=%q FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=0 FM_MAX_DEFER_SECS=3 FM_WEDGE_ALARM_CHANNEL=off %q\n' \
  "$PATH" "$ROOT/bin/fm-afk-start.sh" > "$LAB/daemon-entry.sh"
chmod +x "$LAB/launch.sh" "$LAB/daemon-entry.sh"

cleanup() {
  local current
  date -u +%Y-%m-%dT%H:%M:%SZ > "$LAB/cleanup-started.txt"
  "$ROOT/bin/fm-afk-launch.sh" stop >> "$LAB/cleanup-lifecycle.txt" 2>&1 || true
  if [ -n "${server_pid:-}" ]; then
    current=$(fm_pid_identity "$server_pid" 2>/dev/null || true)
    if [ -n "$current" ] && [ "$current" = "$server_identity" ]; then
      "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM INT

check_deadline() {
  [ "$(date +%s)" -lt "$((FM_CODEX_LIVE_DEADLINE - 120))" ] || fail 'shared outer execution deadline reached; cleanup reserved'
}

check_prompt() {
  if grep -Ei 'trust this (folder|directory)|sign in|log in|trust.*(hook|configuration)' "$LAB/transcript.txt" >/dev/null; then
    fail "new trust/login prompt requires stopping verification (evidence $LAB)"
  fi
}

capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t '%0' -S -1000; }
wait_for_text() {
  local path=$1 needle=$2
  for _ in $(seq 1 120); do
    check_deadline
    capture > "$LAB/transcript.txt" || true
    check_prompt
    if [ -f "$path" ] && grep -F -- "$needle" "$path" >/dev/null; then return 0; fi
    sleep 1
  done
  capture > "$LAB/failure-transcript.txt" || true
  fail "timed out waiting for $needle in $path (evidence $LAB)"
}
wait_idle() {
  for _ in $(seq 1 120); do
    check_deadline
    capture > "$LAB/transcript.txt"
    check_prompt
    if grep -F 'Killed: 9' "$LAB/transcript.txt" >/dev/null; then
      fail "Codex launch was killed before readiness (evidence $LAB)"
    fi
    if grep -F 'Trust this folder?' "$LAB/transcript.txt" >/dev/null; then
      fail "new directory trust prompt requires stopping verification (evidence $LAB)"
    fi
    if [ -e "$FM_HOME/ready.txt" ] && grep -F '• SMOKE_IDLE' "$LAB/transcript.txt" >/dev/null; then return 0; fi
    sleep 1
  done
  fail "initial turn did not reach a final idle response (evidence $LAB)"
}
start_daemon() {
  FM_AFK_LAUNCH_ENTRY="$LAB/daemon-entry.sh" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET='%0' "$ROOT/bin/fm-afk-launch.sh" start >> "$LAB/daemon-lifecycle.txt" 2>&1
}
stop_daemon() {
  for _ in $(seq 1 3); do
    if "$ROOT/bin/fm-afk-launch.sh" stop >> "$LAB/daemon-lifecycle.txt" 2>&1; then return 0; fi
    sleep 2
  done
  fail 'scratch daemon did not stop through its owner'
}

check_deadline
codex --no-daemon --version > "$LAB/version.txt"
shasum -a 256 "$ROOT/bin/fm-codex-supervisor.sh" "$ROOT/bin/fm-afk-launch.sh" "$ROOT/bin/fm-supervise-daemon.sh" "$ROOT/bin/fm-tmux-lib.sh" > "$LAB/code-sha256.txt"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s coordinator -x 180 -y 48 '/bin/bash --noprofile --norc -i'
. "$ROOT/bin/fm-wake-lib.sh"
server_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t '%0' '#{pid}')
server_identity=$(fm_pid_identity "$server_pid")
printf '%s\n%s\n' "$server_pid" "$server_identity" > "$LAB/tmux-owner.txt"
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' -l "$(printf '%q' "$LAB/launch.sh")"
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' Enter
wait_idle
cp "$FM_HOME/preflight.txt" "$LAB/first-preflight.txt"
cp "$FM_HOME/thread.txt" "$LAB/first-thread.txt"
capture > "$LAB/first-idle-transcript.txt"

"$REAL_TMUX" -L "$SOCKET" new-window -d -t coordinator -n contender "$LAB/launch.sh > $(printf '%q' "$LAB/contender.txt") 2>&1"
wait_for_text "$LAB/contender.txt" 'previous coordinator still owns the home'
pass 'second terminal launch refuses while the exact coordinator owns the scratch home'

start_daemon
printf '%s\n' 'done: post-final-one' > "$FM_HOME/state/synthetic.status"
wait_for_text "$FM_HOME/handled.txt" 'post-final-one'
capture > "$LAB/post-final-transcript.txt"
pass 'real Codex final idle response is followed by a daemon-delivered turn that drains and acknowledges the event'

sleep 3
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' -l 'partial-smoke-draft-do-not-submit'
printf '%s\n' 'done: deferred-two' >> "$FM_HOME/state/synthetic.status"
wait_for_text "$FM_HOME/state/.subsuper-inject-wedged" 'undelivered'
! grep -F 'deferred-two' "$FM_HOME/handled.txt" >/dev/null || fail 'daemon merged escalation into partial draft'
capture > "$LAB/deferred-draft-transcript.txt"
grep -F 'partial-smoke-draft-do-not-submit' "$LAB/deferred-draft-transcript.txt" >/dev/null || fail 'partial draft was altered'
[ -s "$FM_HOME/state/.subsuper-escalations" ] || fail 'deferred event was not retained durably'
cp "$FM_HOME/state/.subsuper-inject-wedged" "$LAB/wedge.txt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' C-u
wait_for_text "$FM_HOME/handled.txt" 'deferred-two'
pass 'current Codex partial draft defers injection, produces a bounded durable wedge, then acknowledges after composer clears'

sleep 3
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' -l 'For this scratch fixture only, run exactly: printf started > busy.txt; sleep 12; printf ended > busy-ended.txt. Then final SMOKE_IDLE. Continue to acknowledge sentinel-marked messages as before.'
for _ in $(seq 1 15); do
  "$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' Enter
  [ ! -f "$FM_HOME/busy.txt" ] || break
  sleep 2
done
[ -f "$FM_HOME/busy.txt" ] || fail 'real busy turn never started'
printf '%s\n' 'done: busy-five' >> "$FM_HOME/state/synthetic.status"
wait_for_text "$FM_HOME/state/.subsuper-inject-wedged" 'busy-five'
[ ! -f "$FM_HOME/busy-ended.txt" ] || fail 'busy turn ended before deferral was observed'
! grep -F 'busy-five' "$FM_HOME/handled.txt" >/dev/null || fail 'daemon submitted while the real turn was busy'
capture > "$LAB/busy-transcript.txt"
wait_for_text "$FM_HOME/handled.txt" 'busy-five'
pass 'a real foreground tool call defers injection and its event is handled after the turn finishes'

stop_daemon
printf '%s\n' 'done: downtime-three' >> "$FM_HOME/state/synthetic.status"
start_daemon
wait_for_text "$FM_HOME/handled.txt" 'downtime-three'
pass 'status written with the daemon stopped is handled after restart'

stop_daemon
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' -l '/quit'
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' Enter
for _ in $(seq 1 30); do
  status=$("$ROOT/bin/fm-lock.sh" status)
  case "$status" in 'lock: stale ('*) break ;; esac
  if [ "$(( _ % 2 ))" -eq 0 ] && capture | tail -n 12 | grep -F '/quit' >/dev/null; then
    "$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' Enter
  fi
  sleep 1
done
case "$status" in 'lock: stale ('*) ;; *) fail 'old scratch coordinator process did not exit' ;; esac
printf '%s\n' 'done: recovered-four' >> "$FM_HOME/state/synthetic.status"
FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal synthetic.status "signal: $2/state/synthetic.status"' _ "$ROOT" "$FM_HOME"
cp "$FM_HOME/state/.wake-queue" "$LAB/queue-before-restart.txt"
rm "$FM_HOME/ready.txt"
"$REAL_TMUX" -L "$SOCKET" respawn-pane -k -t '%0' '/bin/bash --noprofile --norc -i'
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' -l "$(printf '%q' "$LAB/launch.sh")"
"$REAL_TMUX" -L "$SOCKET" send-keys -t '%0' Enter
wait_idle
[ "$(cat "$FM_HOME/thread.txt")" != "$(cat "$LAB/first-thread.txt")" ] || fail 'coordinator restart did not create a new session'
cp "$FM_HOME/preflight.txt" "$LAB/restarted-preflight.txt"
start_daemon
wait_for_text "$FM_HOME/handled.txt" 'recovered-four'
for token in post-final-one deferred-two downtime-three recovered-four busy-five; do
  [ "$(grep -F -c "$token" "$FM_HOME/handled.txt")" -eq 1 ] || fail "$token was not acknowledged exactly once"
done
capture > "$LAB/restarted-transcript.txt"
stop_daemon
pass 'new coordinator acquires after old process exit and recovers pending queue/status without duplicated acknowledgements'
printf 'ok - real Codex terminal verification evidence: %s\n' "$LAB"
