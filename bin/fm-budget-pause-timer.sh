#!/usr/bin/env bash
# fm-budget-pause-timer.sh - arm a one-shot watcher check that fires once a
# budget-pause quota window has reset.
#
# A Claude usage-limit pause does not self-resume when the window resets, and
# firstmate does not self-wake, so the whole fleet silently idles until the
# captain happens to send a message. This script arms the fix: it resolves the
# binding quota window's reset instant, writes a one-shot state/<id>.check.sh
# that stays silent until that instant has passed, then prints exactly one wake
# line and deletes itself and its trust file, and registers it with
# bin/fm-check-register.sh so the watcher is allowed to execute it.
#
# The generated check never steers or resumes anything itself: that judgment
# call stays with firstmate at wake time.
#
# Usage:
#   fm-budget-pause-timer.sh <id> --reset <ISO8601-timestamp>
#   fm-budget-pause-timer.sh <id> [--provider <provider>] [--window <window-id>]
#
#   <id>                the task id to arm the timer under; state/<id>.meta
#                        must already exist.
#   --reset <timestamp> use this reset instant instead of asking quota-axi.
#                        Accepts any ISO 8601 timestamp quota-axi itself emits,
#                        e.g. 2026-08-13T21:09:59.624315+00:00. Mutually
#                        exclusive with --provider/--window.
#   --provider <name>   quota-axi provider to query (default: claude).
#   --window <id>       use this window's resetsAt directly instead of
#                        auto-picking the most-exhausted window. Window ids
#                        come from `quota-axi --provider <name> --json`
#                        (.providers[].windows[].id), e.g. five_hour,
#                        seven_day, model:fable.
#
# With no --reset, the binding window is auto-picked as the provider's window
# with percentRemaining == 0 whose reset comes soonest; if no window reads 0%
# remaining, quota-axi is treated as unable to answer and this refuses rather
# than guess, so pass --reset or --window explicitly instead.
#
# Refuses loudly, with no check armed, when: quota-axi is not on PATH (and no
# --reset was given), the reset time cannot be resolved or parsed, <id> has no
# state/<id>.meta task record, or state/<id>.check.sh or
# state/<id>.check-trust already exists (never silently clobbers an existing
# armed check - stop it first if you intend to replace it).
#
# On success prints the same "registered: state/<id>.check.sh" line
# bin/fm-check-register.sh prints; the watcher then executes the generated
# check on its normal poll cadence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUOTA_AXI_BIN="${FM_QUOTA_AXI_BIN:-quota-axi}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

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

ID=
RESET_OVERRIDE=
PROVIDER=claude
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
      if [ -z "$ID" ]; then
        ID=$1
        shift
      else
        fail "unexpected argument: $1"
      fi
      ;;
  esac
done

[ -n "$ID" ] || fail "usage: fm-budget-pause-timer.sh <id> [--reset <timestamp>] [--provider <name>] [--window <id>]"
fm_pr_task_id_valid "$ID" || fail "invalid task id: $ID"
if [ -n "$RESET_OVERRIDE" ] && [ -n "$WINDOW" ]; then
  fail "--reset and --window are mutually exclusive"
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || fail "no task record for '$ID' (state/$ID.meta is missing)"

CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ ! -e "$CHECK" ] || fail "an armed check already exists at state/$ID.check.sh; stop or remove it before re-arming"
[ ! -e "$TRUST" ] || fail "an armed check trust record already exists at state/$ID.check-trust; stop or remove it before re-arming"

# --- resolve the reset instant ---------------------------------------------

RESET_TIME=$RESET_OVERRIDE
if [ -z "$RESET_TIME" ]; then
  command -v "$QUOTA_AXI_BIN" >/dev/null 2>&1 \
    || fail "quota-axi is not on PATH; pass --reset <timestamp> to arm without it"
  command -v jq >/dev/null 2>&1 \
    || fail "jq is required to parse quota-axi output; pass --reset <timestamp> to arm without it"

  QUOTA_JSON=$("$QUOTA_AXI_BIN" --provider "$PROVIDER" --json 2>/dev/null) \
    || fail "quota-axi could not report on provider '$PROVIDER'"

  if [ -n "$WINDOW" ]; then
    RESET_TIME=$(printf '%s' "$QUOTA_JSON" \
      | jq -r --arg w "$WINDOW" \
        '[.providers[]?.windows[]? | select(.id == $w)][0].resetsAt // empty') \
      || fail "could not parse quota-axi output"
    [ -n "$RESET_TIME" ] || fail "provider '$PROVIDER' has no window '$WINDOW' to arm against"
  else
    RESET_TIME=$(printf '%s' "$QUOTA_JSON" \
      | jq -r '[.providers[]?.windows[]? | select(.percentRemaining == 0)]
                | sort_by(.resetsAt) | .[0].resetsAt // empty') \
      || fail "could not parse quota-axi output"
    [ -n "$RESET_TIME" ] || fail "no exhausted window found for provider '$PROVIDER'; pass --reset <timestamp> or --window <id> to arm explicitly"
  fi
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse the reset timestamp"
RESET_EPOCH=$(python3 -c '
import datetime, sys
raw = sys.argv[1].strip()
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
try:
    dt = datetime.datetime.fromisoformat(raw)
except ValueError:
    sys.exit(1)
if dt.tzinfo is None:
    sys.exit(1)
print(int(dt.timestamp()))
' "$RESET_TIME") || fail "could not parse reset timestamp: $RESET_TIME"
case "$RESET_EPOCH" in
  ''|*[!0-9]*) fail "resolved reset epoch is not a plain integer: $RESET_EPOCH" ;;
esac

# --- generate and register the one-shot check -------------------------------

STATE_DEVICE=$(fm_pr_file_device "$STATE") || fail "could not stat state directory"

TMP=$(mktemp "$STATE/.fm-budget-pause-check.XXXXXX") || fail "could not create temp file"
cleanup() { [ -z "$TMP" ] || rm -f -- "$TMP"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

cat > "$TMP" <<CHECKSH
#!/usr/bin/env bash
# Generated by fm-budget-pause-timer.sh. One-shot budget-pause resume check for
# task '$ID'. Stays silent until $RESET_TIME (epoch $RESET_EPOCH UTC seconds)
# has passed, then prints exactly one wake line and deletes itself plus its
# trust file so it never fires twice.
set -eu
RESET_EPOCH=$RESET_EPOCH
CHECK_PATH='$CHECK'
TRUST_PATH='$TRUST'
NOW=\$(date +%s)
if [ "\$NOW" -ge "\$RESET_EPOCH" ]; then
  printf 'budget pause window for %s has reset\n' '$ID'
  rm -f -- "\$CHECK_PATH" "\$TRUST_PATH"
fi
CHECKSH
chmod 0700 "$TMP" || fail "could not set check script permissions"
fm_pr_private_file_valid "$TMP" 700 "$STATE_DEVICE" || fail "generated check failed validation"
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || fail "check destination is unavailable"
mv -f -- "$TMP" "$CHECK" || fail "could not install generated check"
TMP=

"$SCRIPT_DIR/fm-check-register.sh" "$ID"
