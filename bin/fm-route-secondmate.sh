#!/usr/bin/env bash
# Route work to a local secondmate, starting a stopped or confidently dead agent.
# Usage: fm-route-secondmate.sh <secondmate-id> <text...>
#        fm-route-secondmate.sh <secondmate-id> --key <Key>
# Holds the shared liveness lock through delivery; ambiguous probes never spawn.
# Remote routes keep upstream fm-send and owning-host recovery semantics.
# FM_ROUTE_SPAWN_CMD and FM_ROUTE_SEND_CMD override commands for isolated tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FM_HOME:?FM_HOME must name the owning home}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

[ "$#" -ge 2 ] || { echo "usage: fm-route-secondmate.sh <id> <message...>" >&2; exit 2; }
ID=$1
shift
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: unsafe secondmate id" >&2; exit 2 ;; esac
META="$STATE/$ID.meta"
[ -f "$META" ] && [ "$(fm_meta_get "$META" kind)" = secondmate ] \
  || { echo "error: $ID has no secondmate record in $FM_HOME" >&2; exit 1; }
SEND_CMD="${FM_ROUTE_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}"
SPAWN_CMD="${FM_ROUTE_SPAWN_CMD:-$SCRIPT_DIR/fm-spawn.sh}"
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  exec "$SEND_CMD" "$ID" "$@"
fi
fm_secondmate_liveness_lock "$ID" \
  || { echo "error: another lifecycle action owns secondmate $ID" >&2; exit 1; }
trap 'fm_secondmate_liveness_unlock "$ID"' EXIT
fm_secondmate_liveness_probe "$META" "$ID" route
if [ "$(fm_meta_get "$META" stopped)" = 1 ]; then
  case "$FM_SM_LIVE_STATE" in
    alive) echo "error: stopped secondmate $ID still has a live agent; reconcile its record" >&2; exit 1 ;;
    dead|missing) ;;
    *) echo "error: stopped secondmate $ID has an unverified endpoint; not spawning" >&2; exit 1 ;;
  esac
elif [ "$FM_SM_LIVE_STATUS" != relaunchable ]; then
  "$SEND_CMD" "$ID" "$@"
  exit $?
fi
if [ "$FM_SM_LIVE_KILL" = 1 ]; then
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  fm_backend_kill "$backend" "$target" || exit 1
fi
FM_SPAWN_NO_GUARD=1 "$SPAWN_CMD" "$ID" --secondmate >&2 \
  || { echo "error: secondmate spawn failed; request was not sent" >&2; exit 1; }
waited=0
wait_secs=${FM_ROUTE_SPAWN_WAIT_SECS:-60}
case "$wait_secs" in ''|*[!0-9]*) wait_secs=60 ;; esac
while :; do
  fm_secondmate_liveness_probe "$META" "$ID" route
  [ "$FM_SM_LIVE_STATUS" != alive ] || break
  [ "$waited" -lt "$wait_secs" ] \
    || { echo "error: spawned secondmate has no verified live agent; request was not sent" >&2; exit 1; }
  sleep 1
  waited=$((waited + 1))
done
FM_PENDING_REPLY_COLD_SPAWN=1 "$SEND_CMD" "$ID" "$@"
