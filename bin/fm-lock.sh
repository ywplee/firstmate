#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock (state/.lock).
# The lock file's first line is the harness (agent) process PID found by walking
# the shell's ancestry, which lives as long as the firstmate session - unlike the
# transient subshell PID of any one tool call, which is dead moments after it is
# written. Its second line records that process's identity (fm_pid_identity:
# process start time plus full command), so a PID the OS later recycles onto an
# unrelated live process - including another harness such as a crewmate - is
# proven stale instead of mistaken for a live session. A legacy single-line
# (plain PID) lock written by an older firstmate is still honored via a liveness
# plus harness-name check, and is rewritten with identity on the next acquire by
# the same session.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

pid_looks_like_harness() {
  local pid=$1 comm
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

HOLDER_STALE_REASON=
holder_live() {
  local pid=$1 identity=$2 legacy=$3
  HOLDER_STALE_REASON=
  case "$pid" in
    ''|*[!0-9]*) HOLDER_STALE_REASON="no pid recorded"; return 1 ;;
  esac
  if ! fm_pid_alive "$pid"; then
    HOLDER_STALE_REASON="pid $pid dead"
    return 1
  fi
  if [ -n "$legacy" ]; then
    if pid_looks_like_harness "$pid"; then
      return 0
    fi
    HOLDER_STALE_REASON="pid $pid not a harness"
    return 1
  fi
  if fm_session_lock_identity_live "$pid" "$identity"; then
    return 0
  fi
  HOLDER_STALE_REASON="pid $pid reused by a different process"
  return 1
}

if [ "${1:-}" = "status" ]; then
  if ! fm_session_lock_read "$LOCK"; then echo "lock: free"; exit 0; fi
  if holder_live "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_IDENTITY" "$FM_SESSION_LOCK_LEGACY"; then
    echo "lock: held by live harness pid $FM_SESSION_LOCK_PID"
  else
    echo "lock: stale ($HOLDER_STALE_REASON)"
  fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if fm_session_lock_read "$LOCK" \
  && [ "$FM_SESSION_LOCK_PID" != "$me" ] \
  && holder_live "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_IDENTITY" "$FM_SESSION_LOCK_LEGACY"; then
  echo "error: another live firstmate session holds the lock (pid $FM_SESSION_LOCK_PID); operate read-only until resolved" >&2
  exit 1
fi
fm_session_lock_body "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
