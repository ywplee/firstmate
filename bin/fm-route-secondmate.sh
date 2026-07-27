#!/usr/bin/env bash
# fm-route-secondmate.sh - route work to a secondmate, spawning its resident
# agent first if it is stopped (the ephemeral-secondmate model).
# Usage: fm-route-secondmate.sh <secondmate-id> <text...>
#        fm-route-secondmate.sh <secondmate-id> --key <Key>
#
# bin/fm-send.sh fails closed on a dead endpoint by design, and that stays. This
# is the routing layer ABOVE it: for a stopped secondmate it spawns first, then
# sends; fm-send itself is never taught to paper over a missing spawn. Use it
# whenever the main firstmate routes work to a secondmate; for a live secondmate
# it is a transparent pass-through to fm-send.
#
# Liveness handling follows bin/fm-backend.sh's contract that an `unknown` probe
# NEVER licenses an action (some backends - pi-on-tmux, zellij, orca, cmux -
# always read unknown even for a healthy agent):
#   stopped=1 in meta  -> the secondmate was intentionally stopped: spawn it.
#   probe alive         -> live agent confirmed: transparent pass-through to fm-send.
#   probe dead          -> confidently a husk: kill it, spawn, verify, send.
#   probe unknown        -> unclassifiable: NEVER kill or spawn. Attempt delivery
#                          through fail-closed fm-send; if the endpoint is truly
#                          gone, fm-send errors and that surfaces, rather than
#                          killing a possibly-live agent and orphaning its crew.
#
# On the spawn path it waits (bounded, FM_ROUTE_SPAWN_WAIT_SECS, default 60) for a
# confident live reading; a confident DEAD reading after the wait is a hard
# failure (fm-send is never reached, nothing silently dropped), and a backend
# whose probe cannot confirm liveness is accepted only when the freshly spawned
# pane exists. A cold spawn sets FM_PENDING_REPLY_COLD_SPAWN=1 so the delivered
# request's pending-reply grace is widened for the cold start.
#
# The whole probe/kill/spawn/verify sequence is serialized per secondmate against
# a concurrent route or stop, so two routes cannot kill each other's fresh window.
# It never removes or mutates the home, lease, backlog, or registry entry, and
# never forces. FM_ROUTE_SPAWN_CMD / FM_ROUTE_SEND_CMD override the spawn and send
# commands for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-route-secondmate refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-route-secondmate cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

SPAWN_CMD="${FM_ROUTE_SPAWN_CMD:-$SCRIPT_DIR/fm-spawn.sh}"
SEND_CMD="${FM_ROUTE_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}"
SPAWN_WAIT_SECS="${FM_ROUTE_SPAWN_WAIT_SECS:-60}"
case "$SPAWN_WAIT_SECS" in ''|*[!0-9]*) SPAWN_WAIT_SECS=60 ;; esac

if [ "$#" -lt 1 ]; then
  echo "usage: fm-route-secondmate.sh <secondmate-id> <text...>" >&2
  exit 2
fi
ID=$1
shift
# Validate the id before it is interpolated into a grep regex or any path. Same
# rule as fm_task_id_path_safe (bin/fm-pr-lib.sh): no empties, no leading dot, no
# characters outside [A-Za-z0-9._-].
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*)
    echo "error: unsafe secondmate id '$ID'" >&2; exit 2 ;;
esac
if [ "$#" -lt 1 ]; then
  echo "error: no message to route to secondmate $ID" >&2
  exit 2
fi

META="$STATE/$ID.meta"
# Exact-match by string equality, not a regex: a `.` in an id is a regex wildcard,
# so grep -E "^- $id" would let a typo like `sm.1` match `sm-1`'s entry and spawn a
# second agent onto the wrong home. Id validation above stops injection but not
# that false match.
registry_has_secondmate() {  # <id>
  local reg="$DATA/secondmates.md" line rid
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        rid=${line#- }
        rid=${rid%% *}
        [ "$rid" = "$1" ] && return 0
        ;;
    esac
  done < "$reg"
  return 1
}

# Confirm this id names a registered secondmate. A live/stopped one has a
# kind=secondmate meta; a crash that lost the meta is still routable from the
# registry (fm-spawn resolves the home from data/secondmates.md).
IS_SECONDMATE=0
if [ -f "$META" ] && [ "$(fm_meta_get "$META" kind)" = secondmate ]; then
  IS_SECONDMATE=1
elif registry_has_secondmate "$ID"; then
  IS_SECONDMATE=1
fi
if [ "$IS_SECONDMATE" -ne 1 ]; then
  echo "error: $ID is not a registered secondmate in $FM_HOME; route ordinary steers with fm-send.sh directly" >&2
  exit 2
fi

endpoint_alive() {  # -> prints alive|dead|unknown for the current recorded endpoint
  local backend target
  [ -f "$META" ] || { printf 'dead'; return 0; }
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  [ -n "$target" ] || target=$(fm_meta_get "$META" window)
  [ -n "$target" ] || { printf 'dead'; return 0; }
  # A recorded endpoint whose pane/window is entirely GONE (the common shape after
  # a reboot that took the tmux server with it) is positively DEAD, not unknown:
  # target-absence is a confident negative that fm_backend_target_exists answers
  # directly. Without this the router could not revive a rebooted secondmate,
  # which is the case it will meet most often.
  fm_backend_target_exists "$backend" "$target" "fm-$ID" 2>/dev/null || { printf 'dead'; return 0; }
  fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf 'unknown'
}

# Serialize the whole decision against a concurrent route/stop on this secondmate.
LOCK="$STATE/.secondmate-$ID.lifecycle.lock"
LOCK_HELD=0
release_lock() { [ "$LOCK_HELD" = 1 ] && fm_lock_release "$LOCK" 2>/dev/null || true; LOCK_HELD=0; }
trap release_lock EXIT
lock_wait=0
until fm_lock_try_acquire "$LOCK"; do
  lock_wait=$((lock_wait + 1))
  [ "$lock_wait" -lt "$SPAWN_WAIT_SECS" ] || {
    echo "error: could not acquire routing lock for secondmate $ID; another route or stop is in progress" >&2
    exit 1
  }
  sleep 1
done
LOCK_HELD=1

send_and_exit() {  # <cold> <args...>
  local cold=$1; shift
  release_lock
  if [ "$cold" = 1 ]; then
    exec env FM_PENDING_REPLY_COLD_SPAWN=1 "$SEND_CMD" "$ID" "$@"
  fi
  exec "$SEND_CMD" "$ID" "$@"
}

# Decide the path. stopped=1 and a confident dead are the only licenses to
# kill/spawn; alive is a pass-through; unknown never acts. The alive and unknown
# cases exec fm-send and never return, so only stopped=1 / dead falls through to
# the cold path below.
if ! { [ -f "$META" ] && [ "$(fm_meta_get "$META" stopped)" = 1 ]; }; then
  verdict=$(endpoint_alive)
  case "$verdict" in
    alive) send_and_exit 0 "$@" ;;
    dead) : ;;
    *)
      echo "note: secondmate $ID endpoint liveness is unconfirmable (probe: unknown); attempting fail-closed delivery without spawn or kill" >&2
      send_and_exit 0 "$@"
      ;;
  esac
fi

# Cold path: kill any stale endpoint (licensed by stopped=1 or a confident dead
# reading, never by unknown), spawn, then verify a genuinely live agent.
if [ -f "$META" ]; then
  stale_backend=$(fm_backend_of_meta "$META")
  stale_target=$(fm_backend_target_of_meta "$META")
  [ -n "$stale_target" ] || stale_target=$(fm_meta_get "$META" window)
  if [ -n "$stale_target" ]; then
    fm_backend_kill "$stale_backend" "$stale_target" "$(fm_meta_get "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
  fi
fi
if ! FM_SPAWN_NO_GUARD=1 "$SPAWN_CMD" "$ID" --secondmate >&2; then
  echo "error: could not spawn stopped secondmate $ID; not routing the request (fm-send is never reached)" >&2
  exit 1
fi
waited=0
verdict=$(endpoint_alive)
while [ "$verdict" != alive ] && [ "$waited" -lt "$SPAWN_WAIT_SECS" ]; do
  sleep 1
  waited=$((waited + 1))
  verdict=$(endpoint_alive)
done
if [ "$verdict" != alive ]; then
  pane_backend=$(fm_backend_of_meta "$META")
  pane_target=$(fm_backend_target_of_meta "$META")
  [ -n "$pane_target" ] || pane_target=$(fm_meta_get "$META" window)
  if [ "$verdict" = dead ] || [ -z "$pane_target" ] \
    || ! fm_backend_target_exists "$pane_backend" "$pane_target" "fm-$ID" 2>/dev/null; then
    echo "error: secondmate $ID was spawned but no live agent could be confirmed (reading: $verdict); not routing the request" >&2
    exit 1
  fi
  echo "note: secondmate $ID spawned; its backend cannot positively confirm agent liveness (reading: $verdict), proceeding on the confirmed pane" >&2
fi
send_and_exit 1 "$@"
