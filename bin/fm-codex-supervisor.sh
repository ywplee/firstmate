#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: FM_HOME=<home> CODEX_HOME=<account-home> fm-codex-supervisor.sh launch --sandbox <mode> --ask-for-approval <policy> [--prompt-file <path>]
       FM_HOME=<home> CODEX_HOME=<account-home> fm-codex-supervisor.sh preflight

launch starts Codex --no-daemon from an existing tmux shell only after the
previous coordinator process and its supervision cycle have stopped.
It never releases a lock, stops a process, drains wakes, or installs config.
The new coordinator must acquire the home through normal session-start.
preflight verifies that this exact terminal Codex process owns the home lock
and is the addressable supervisor pane before entering existing AFK supervision.
Neither command proves event handling or enables Desktop wake transport.
See docs/codex-supervision-handoff.md for rollout, rollback, and delivery proof.
EOF
}

fail() { printf 'fm-codex-supervisor: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  launch|preflight) action=$1 ;;
  *) usage >&2; exit 2 ;;
esac
launch_sandbox=
launch_approval=
launch_prompt='Run bin/fm-session-start.sh exactly once and read the complete digest. Refuse all fleet mutations if the lock is not acquired. Reconcile only recorded work; never invent tasks. Read docs/codex-supervision-handoff.md, run bin/fm-codex-supervisor.sh preflight, then enter existing AFK supervision through its skill. Preserve all approval and merge authority. Do not claim unattended supervision until an exact-target event is handled and recorded.'
shift
while [ "$#" -gt 0 ]; do
  [ "$action" = launch ] && [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  case "$1" in
    --sandbox) launch_sandbox=$2 ;;
    --ask-for-approval) launch_approval=$2 ;;
    --prompt-file)
      launch_prompt=$(cat "$2") || fail 'cannot read launch prompt file'
      [ -n "$launch_prompt" ] || fail 'launch prompt file is empty'
      ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
if [ "$action" = launch ]; then
  case "$launch_sandbox" in read-only|workspace-write|danger-full-access) ;; *) fail 'supply the authorized --sandbox mode explicitly' ;; esac
  case "$launch_approval" in on-request|never) ;; *) fail 'supply the authorized --ask-for-approval policy explicitly' ;; esac
fi
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ] || fail 'FM_HOME must explicitly name an existing operational home with state/'
[ -n "${CODEX_HOME:-}" ] && [ -d "$CODEX_HOME" ] || fail 'CODEX_HOME must explicitly select the intended account home'
[ -z "${FM_STATE_OVERRIDE:-}" ] && [ -z "${FM_ROOT_OVERRIDE:-}" ] || fail 'home overrides are not supported for coordinator handoff'
STATE="$FM_HOME/state"
. "$CODE_ROOT/bin/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
. "$CODE_ROOT/bin/fm-wake-lib.sh"

in_ancestry() {
  local wanted=$1 pid=$$
  for _ in $(seq 1 32); do
    [ "$pid" = "$wanted" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  done
  return 1
}

terminal_target() {
  local socket current
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || fail 'a terminal-hosted tmux coordinator is required; Desktop has no verified post-turn wake route'
  case "$TMUX_PANE" in %*[!0-9]*|%|'') fail 'TMUX_PANE must be an exact pane id' ;; %*) ;; *) fail 'TMUX_PANE must be an exact pane id' ;; esac
  target=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}') || fail 'cannot resolve the exact supervisor pane'
  [ "$target" = "$TMUX_PANE" ] || fail 'supervisor target identity differs from this pane'
  socket=$(tmux display-message -p -t "$target" '#{socket_path}') || fail 'cannot resolve tmux socket identity'
  [ "$socket" = "${TMUX%%,*}" ] || fail 'tmux socket differs from this terminal'
  pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}') || fail 'cannot resolve supervisor process'
  in_ancestry "$pane_pid" || fail 'target pane is not an ancestor of this caller; refusing an unrelated endpoint'
  [ "${FM_SUPERVISOR_BACKEND:-tmux}" = tmux ] || fail 'this route supports a tmux primary only'
  [ "${FM_SUPERVISOR_TARGET:-$target}" = "$target" ] || fail 'supervisor override differs from this exact coordinator'
  if [ "$action" = launch ]; then
    current=$(tmux display-message -p -t "$target" '#{pane_current_command}') || fail 'cannot read current pane command'
    case "$current" in bash|zsh|sh|fish|dash) ;; *) fail 'launch must run in a dedicated shell, outside an existing agent' ;; esac
  fi
}

launch() {
  local status pid help_text
  status=$("$SCRIPT_DIR/fm-lock.sh" status) || fail 'cannot inspect coordinator ownership'
  case "$status" in
    'lock: free'|'lock: stale ('*) ;;
    *) fail 'previous coordinator still owns the home; quiesce it and wait for its exact process to exit (shared Desktop requires human app exit)' ;;
  esac
  [ ! -e "$STATE/.afk" ] && [ ! -e "$STATE/.afk-return-catchup" ] || fail 'previous away-mode lifecycle is not closed; its owner must finish return/catch-up first'
  for pid in "$STATE/.watch.lock/pid" "$STATE/.supervise-daemon.lock/pid" "$STATE/.supervise-daemon.pid"; do
    if fm_pid_alive "$(cat "$pid" 2>/dev/null || true)"; then
      fail 'previous supervision process is still live; its owner must stop it before transfer'
    fi
  done
  command -v codex >/dev/null 2>&1 || fail 'Codex CLI is unavailable'
  help_text=$(codex --help) || fail 'cannot inspect Codex CLI capabilities'
  printf '%s' "$help_text" | grep -q -- '--no-daemon' || fail 'installed Codex does not support --no-daemon'
  printf 'launch: tmux pane=%s account-home=%s; successor must acquire through session-start\n' "$target" "$CODEX_HOME"
  exec codex --no-daemon --sandbox "$launch_sandbox" --ask-for-approval "$launch_approval" --cd "$FM_HOME" "$launch_prompt"
}

preflight() {
  local pid=$$ comm args no_daemon=0 holder
  fm_session_lock_read "$STATE/.lock" || fail 'no coordinator lock; run normal session-start first'
  holder=$FM_SESSION_LOCK_PID
  fm_pid_alive "$holder" || fail 'coordinator lock holder is dead'
  if [ -z "$FM_SESSION_LOCK_LEGACY" ]; then
    fm_session_lock_identity_live "$holder" "$FM_SESSION_LOCK_IDENTITY" || fail 'coordinator lock process identity differs'
  fi
  in_ancestry "$holder" || fail 'another coordinator owns this home; remain read-only'
  for _ in $(seq 1 32); do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || fail 'cannot verify Codex process ancestry'
    args=$(ps -o args= -p "$pid" 2>/dev/null) || fail 'cannot verify Codex launch arguments'
    case "$(basename "$comm")" in
      *codex*|node*)
        if printf '%s' "$args" | grep -qE 'codex[^[:space:]]*[[:space:]].*--no-daemon([[:space:]]|$)'; then no_daemon=1; fi
        ;;
    esac
    [ "$pid" != "$pane_pid" ] || break
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*|0|1) break ;; esac
  done
  [ "$no_daemon" -eq 1 ] || fail 'this pane is not a verified Codex --no-daemon coordinator'
  printf 'preflight: tmux pane=%s holder=%s account-home=%s; process and ownership verified, event handling still requires acknowledgement\n' "$target" "$holder" "$CODEX_HOME"
}

terminal_target
"$action"
