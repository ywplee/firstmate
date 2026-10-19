#!/usr/bin/env bash
# fm-budget-pause-timer.sh - arm the fleet-level one-shot watcher check that
# fires once a budget-pause quota window has reset.
#
# A Claude usage-limit pause does not self-resume when the window resets, and
# firstmate does not self-wake, so the whole fleet silently idles until the
# captain happens to send a message. A budget pause is a property of the fleet,
# not of any one task - one exhausted quota window stops every worker at once,
# and one reset un-stops all of them - so this arms a single reserved-slot
# timer, never a per-task one. It resolves the binding quota window's reset
# instant, writes a one-shot state/budget-pause.check.sh that stays silent
# until that instant has passed, then prints exactly one wake line and deletes
# itself and its trust file, and registers it with bin/fm-check-register.sh so
# the watcher is allowed to execute it.
#
# The generated check never steers or resumes anything itself: that judgment
# call stays with firstmate at wake time.
#
# Usage:
#   fm-budget-pause-timer.sh --reset <ISO8601-timestamp>
#   fm-budget-pause-timer.sh [--provider <provider>] [--window <window-id>]
#
#   --reset <timestamp> use this reset instant instead of asking quota-axi.
#                        Accepts any ISO 8601 timestamp quota-axi itself emits,
#                        e.g. 2026-08-13T21:09:59.624315+00:00. Mutually
#                        exclusive with --provider/--window.
#   --provider <name>   quota-axi provider to query (default: claude).
#   --window <id>       use this window's resetsAt directly instead of
#                        auto-picking among the exhausted windows. Window ids
#                        come from `quota-axi --provider <name> --json`
#                        (.providers[].windows[].id), e.g. five_hour,
#                        seven_day, model:fable.
#
# No task id is accepted. The timer always occupies the reserved slot
# state/budget-pause.check.sh (and state/budget-pause.check-trust) - a
# constant baked into this script, not caller-supplied, so no invocation can
# aim it at a real task's check slot and collide with that task's own armed
# check (for example a PR merge poll, which lives at the same
# state/<id>.check.sh path for its own id). Refuses loudly, before arming
# anything, if the reserved id is already in use for something real: a task
# record at state/budget-pause.meta, or a backlog item with that id in
# data/backlog.md.
#
# With no --reset, the binding window is auto-picked among the provider's own
# general (non model-scoped) windows with percentRemaining == 0: when more than
# one is exhausted, the fleet stays paused until the LAST of them resets, so the
# one with the latest resetsAt is picked, not the soonest. Candidates are
# compared as parsed instants rather than as strings, so a provider mixing UTC
# offsets or timestamp shapes across its windows cannot skew the choice. A
# non-exhausted window never influences the choice. If no window reads 0%
# remaining, quota-axi is treated as unable to answer and this refuses rather
# than guess, so pass --reset or --window explicitly instead.
#
# Refuses loudly, with no check armed, when: the reserved id already denotes a
# real task record or backlog item, data/backlog.md exists but cannot be read
# to rule that collision out, quota-axi is not on PATH (and no --reset
# was given), the reset time cannot be resolved or parsed, a reset instant
# resolved from quota-axi (auto-picked or --window; never the explicit --reset
# override, which stays the operator's own business) is already in the past
# (stale or wrong quota-axi data - arming on it would fire on the watcher's
# very next poll while the fleet is still paused), or
# state/budget-pause.check.sh or state/budget-pause.check-trust already exists
# (never silently clobbers an existing armed check - two live budget timers is
# a bug, so stop the existing one first if you intend to replace it). If
# registration itself fails, the generated check is removed again so the
# watcher never sees an unauthenticated leftover.
#
# On success prints the same "registered: state/budget-pause.check.sh" line
# bin/fm-check-register.sh prints; the watcher then executes the generated
# check on its normal poll cadence.
set -eu

RESERVED_ID=budget-pause

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
QUOTA_AXI_BIN="${FM_QUOTA_AXI_BIN:-quota-axi}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-budget-pause-timer: error: %s\n' "$*" >&2
  exit 1
}

# Render a value as a single-quoted shell word safe to bake into the generated
# check, escaping any embedded single quote.
squote() {
  local value=${1//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

# Reports whether data/backlog.md has a "- [ ] <key>" or "- [x] <key>" item
# header for the given key. Mirrors the id-parsing convention
# bin/fm-backlog-handoff.sh uses (an item header's id is the first
# whitespace-delimited token after the checkbox); a missing backlog file is not
# a collision. Exits 0 on a match, 1 on a clean no-match, and 2 when the
# backlog exists but could not be read, so the caller can tell "no collision"
# apart from "could not tell" instead of arming on a parser failure.
backlog_has_id() {
  local file=$1 key=$2 status=0
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file" || status=$?
  case "$status" in
    0|1) return "$status" ;;
    *) return 2 ;;
  esac
}

# Resolve one or more ISO 8601 reset timestamps to the latest of them, printing
# its epoch seconds and then a normalized single-line rendering. Comparing
# parsed instants rather than raw strings keeps the choice chronological even
# when a provider mixes UTC offsets or timestamp shapes across its windows.
resolve_latest_reset() {
  python3 -c '
import datetime, sys

latest = None
for raw in sys.argv[1:]:
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(text)
    except ValueError:
        sys.exit(1)
    if dt.tzinfo is None:
        sys.exit(1)
    if latest is None or dt > latest:
        latest = dt
if latest is None:
    sys.exit(1)
print(int(latest.timestamp()))
print(latest.isoformat())
' "$@"
}

RESET_OVERRIDE=
PROVIDER=claude
PROVIDER_SET=0
WINDOW=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --reset)
      [ "$#" -ge 2 ] || fail "--reset requires a value"
      RESET_OVERRIDE=$2
      shift 2
      ;;
    --provider)
      [ "$#" -ge 2 ] || fail "--provider requires a value"
      PROVIDER=$2
      PROVIDER_SET=1
      shift 2
      ;;
    --window)
      [ "$#" -ge 2 ] || fail "--window requires a value"
      WINDOW=$2
      shift 2
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      fail "unexpected argument: $1 (this timer takes no task id - it always arms the reserved '$RESERVED_ID' slot)"
      ;;
  esac
done

if [ -n "$RESET_OVERRIDE" ] && [ -n "$WINDOW" ]; then
  fail "--reset and --window are mutually exclusive"
fi
if [ -n "$RESET_OVERRIDE" ] && [ "$PROVIDER_SET" = 1 ]; then
  fail "--reset and --provider are mutually exclusive"
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
STATE=$(cd "$STATE" && pwd) || fail "state directory is unavailable"
META="$STATE/$RESERVED_ID.meta"
[ ! -e "$META" ] \
  || fail "reserved check id '$RESERVED_ID' collides with an existing task record at state/$RESERVED_ID.meta; rename or remove that task before arming the budget-pause timer"
BACKLOG_STATUS=0
backlog_has_id "$DATA/backlog.md" "$RESERVED_ID" || BACKLOG_STATUS=$?
case "$BACKLOG_STATUS" in
  0) fail "reserved check id '$RESERVED_ID' collides with an existing backlog item in data/backlog.md; rename or remove it before arming the budget-pause timer" ;;
  1) ;;
  *) fail "could not read data/backlog.md to rule out a '$RESERVED_ID' backlog collision; resolve its access permissions before arming the budget-pause timer" ;;
esac

CHECK="$STATE/$RESERVED_ID.check.sh"
TRUST="$STATE/$RESERVED_ID.check-trust"
[ ! -e "$CHECK" ] || fail "the budget-pause timer is already armed at state/$RESERVED_ID.check.sh; stop or remove it before re-arming"
[ ! -e "$TRUST" ] || fail "the budget-pause timer's trust record already exists at state/$RESERVED_ID.check-trust; stop or remove it before re-arming"

# --- resolve the reset instant ---------------------------------------------

CANDIDATES=()
AUTO_RESOLVED=0
if [ -n "$RESET_OVERRIDE" ]; then
  CANDIDATES=("$RESET_OVERRIDE")
else
  AUTO_RESOLVED=1
  command -v "$QUOTA_AXI_BIN" >/dev/null 2>&1 \
    || fail "quota-axi is not on PATH; pass --reset <timestamp> to arm without it"
  command -v jq >/dev/null 2>&1 \
    || fail "jq is required to parse quota-axi output; pass --reset <timestamp> to arm without it"

  QUOTA_JSON=$("$QUOTA_AXI_BIN" --provider "$PROVIDER" --json 2>/dev/null) \
    || fail "quota-axi could not report on provider '$PROVIDER'"

  if [ -n "$WINDOW" ]; then
    CANDIDATE_LIST=$(printf '%s' "$QUOTA_JSON" \
      | jq -r --arg p "$PROVIDER" --arg w "$WINDOW" \
        '[.providers[]? | select(.provider == $p) | .windows[]?
          | select(.id == $w)][0].resetsAt // empty') \
      || fail "could not parse quota-axi output"
    [ -n "$CANDIDATE_LIST" ] || fail "provider '$PROVIDER' has no window '$WINDOW' to arm against"
  else
    CANDIDATE_LIST=$(printf '%s' "$QUOTA_JSON" \
      | jq -r --arg p "$PROVIDER" \
        '.providers[]? | select(.provider == $p) | .windows[]?
          | select(.percentRemaining == 0 and (.kind? // "") != "model")
          | .resetsAt // empty') \
      || fail "could not parse quota-axi output"
    [ -n "$CANDIDATE_LIST" ] || fail "no exhausted window found for provider '$PROVIDER'; pass --reset <timestamp> or --window <id> to arm explicitly"
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    CANDIDATES+=("$candidate")
  done <<< "$CANDIDATE_LIST"
  [ "${#CANDIDATES[@]}" -gt 0 ] || fail "provider '$PROVIDER' reported no usable reset timestamp"
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse the reset timestamp"
RESOLVED=$(resolve_latest_reset "${CANDIDATES[@]}") \
  || fail "could not parse reset timestamp: ${CANDIDATES[*]}"
RESET_EPOCH=${RESOLVED%%$'\n'*}
RESET_TIME=${RESOLVED#*$'\n'}
case "$RESET_EPOCH" in
  ''|*[!0-9]*) fail "resolved reset epoch is not a plain integer: $RESET_EPOCH" ;;
esac
# The normalized timestamp is baked into the generated check's comment, so hold
# it to a strict single-line character set: anything else would let a crafted
# reset value inject bytes into the generated script body.
case "$RESET_TIME" in
  ''|*[!0-9A-Za-z:.+-]*) fail "resolved reset timestamp is not a plain timestamp: $RESET_TIME" ;;
esac

if [ "$AUTO_RESOLVED" = 1 ]; then
  NOW_EPOCH=$(date +%s)
  if [ "$RESET_EPOCH" -lt "$NOW_EPOCH" ]; then
    fail "resolved reset time $RESET_TIME is $((NOW_EPOCH - RESET_EPOCH))s in the past (stale or wrong quota-axi data); refusing to arm a check that would fire immediately - pass --reset to arm explicitly"
  fi
fi

# --- generate and register the one-shot check -------------------------------

STATE_DEVICE=$(fm_pr_file_device "$STATE") || fail "could not stat state directory"
CHECK_QUOTED=$(squote "$CHECK")
TRUST_QUOTED=$(squote "$TRUST")

TMP=$(mktemp "$STATE/.fm-budget-pause-check.XXXXXX") || fail "could not create temp file"
cleanup() { [ -z "$TMP" ] || rm -f -- "$TMP"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

cat > "$TMP" <<CHECKSH
#!/usr/bin/env bash
# Generated by fm-budget-pause-timer.sh. Fleet-level one-shot budget-pause
# resume check. Stays silent until $RESET_TIME (epoch $RESET_EPOCH UTC seconds)
# has passed, then prints exactly one wake line and deletes itself plus its
# trust file so it never fires twice.
set -eu
RESET_EPOCH=$RESET_EPOCH
CHECK_PATH=$CHECK_QUOTED
TRUST_PATH=$TRUST_QUOTED
NOW=\$(date +%s)
if [ "\$NOW" -ge "\$RESET_EPOCH" ]; then
  printf 'budget pause window has reset\n'
  rm -f -- "\$CHECK_PATH" "\$TRUST_PATH"
fi
CHECKSH
bash -n "$TMP" 2>/dev/null \
  || fail "generated check is not valid bash; refusing to arm a check the watcher could only fail silently on"
chmod 0700 "$TMP" || fail "could not set check script permissions"
fm_pr_private_file_valid "$TMP" 700 "$STATE_DEVICE" || fail "generated check failed validation"
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || fail "check destination is unavailable"
mv -f -- "$TMP" "$CHECK" || fail "could not install generated check"
TMP=

REGISTER_STATUS=0
"$SCRIPT_DIR/fm-check-register.sh" "$RESERVED_ID" || REGISTER_STATUS=$?
if [ "$REGISTER_STATUS" -ne 0 ]; then
  rm -f -- "$CHECK" "$TRUST"
  fail "could not register the generated check; removed state/$RESERVED_ID.check.sh (nothing is armed)"
fi
