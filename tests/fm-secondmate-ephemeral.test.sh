#!/usr/bin/env bash
# tests/fm-secondmate-ephemeral.test.sh - the ephemeral-secondmate process
# lifecycle: process-stop (bin/fm-teardown.sh --stop) and spawn-before-route
# (bin/fm-route-secondmate.sh).
#
# The model: a secondmate's structural value (home, treehouse lease, per-home
# backlog, registry entry, in-flight records) all lives on disk and is free at
# rest; only the resident agent process is pure cost. So a stop ends the process
# and keeps every durable trace, and a later routed request spawns it back.
#
# Coverage:
#   Process-stop (fm-teardown.sh --stop, kind=secondmate):
#     - stops the endpoint and keeps home, lease, backlog, registry, and meta
#       byte-intact
#     - refuses (never forces, never strands) while an in-flight crewmate exists
#     - refuses while a routed request is still awaiting a reply
#     - rejects a non-secondmate target
#     - is distinct from retirement: plain teardown still removes the home + route
#   Spawn-before-route (fm-route-secondmate.sh):
#     - a live secondmate is a transparent pass-through to fm-send (no spawn)
#     - a stopped secondmate is killed, spawned, verified live, then sent - with
#       the cold-spawn grace flag set on delivery
#     - a spawn that never produces a live agent fails closed; fm-send is never
#       reached (nothing silently dropped)
#     - an unconfirmable (unknown) probe is accepted only when the pane exists
#     - a registered secondmate whose meta was lost is still routable (spawned
#       from the registry)
#     - a non-secondmate target is refused (ordinary steers use fm-send directly)
#
# Secondmate homes are laid out as SIBLINGS of the parent FM_HOME (never inside
# it), exactly as fm-spawn requires and as retirement's removal guard enforces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
ROUTE="$ROOT/bin/fm-route-secondmate.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-ephemeral)
fm_git_identity fmtest fmtest@example.com

# --- fixtures ---------------------------------------------------------------

# make_eph_tmux <dir>: a tmux stub driven by three files whose paths the caller
# exports: $PANECMD_FILE (the #{pane_current_command} answer), $PANE_PRESENT_FILE
# (present => the pane exists for #{pane_id}/target_exists), and $TMUX_LOG (every
# kill/new/send call, so the test can assert what the endpoint did).
make_eph_tmux() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "${PANECMD_FILE:?}" 2>/dev/null || printf 'zsh\n'; exit 0 ;;
        *pane_id*) if [ -f "${PANE_PRESENT_FILE:-/nonexistent}" ]; then printf '%%1\n'; exit 0; else exit 1; fi ;;
      esac
    done
    exit 0 ;;
  kill-window|new-window|send-keys|has-session)
    printf '%s\n' "$*" >> "${TMUX_LOG:?}"; exit 0 ;;
  list-windows) exit 0 ;;
  capture-pane) printf 'idle\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # A treehouse stub that records every invocation to $TH_LOG, so a test can
  # prove a stop never returns (releases) the secondmate's lease.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${TH_LOG:-/dev/null}"
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then printf 'Usage: treehouse get [--lease]\n'; fi
exit 0
SH
  chmod +x "$fb/treehouse"
  printf '%s\n' "$fb"
}

# make_fake_spawn <dir>: a fake fm-spawn for FM_ROUTE_SPAWN_CMD. It records the
# call to $SPAWN_LOG and, from env, simulates the spawn's observable effects:
#   FAKE_SPAWN_PANECMD  - write this to $PANECMD_FILE (flip the probe reading)
#   FAKE_SPAWN_PRESENT  - touch $PANE_PRESENT_FILE (the pane now exists)
#   FAKE_SPAWN_META     - write a fresh secondmate meta to $META_FILE
#   FAKE_SPAWN_FAIL     - exit non-zero (spawn failed)
make_fake_spawn() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/fake-spawn" <<'SH'
#!/usr/bin/env bash
set -u
printf 'spawn %s\n' "$*" >> "${SPAWN_LOG:?}"
[ -z "${FAKE_SPAWN_FAIL:-}" ] || exit 1
[ -z "${FAKE_SPAWN_PANECMD:-}" ] || printf '%s\n' "$FAKE_SPAWN_PANECMD" > "${PANECMD_FILE:?}"
[ -z "${FAKE_SPAWN_PRESENT:-}" ] || : > "${PANE_PRESENT_FILE:?}"
if [ -n "${FAKE_SPAWN_META:-}" ]; then
  { printf 'window=%s\n' "${FAKE_SPAWN_WINDOW:-firstmate:fm-sm1}"
    printf 'kind=secondmate\nbackend=tmux\nharness=claude\n'
    printf 'home=%s\n' "${FAKE_SPAWN_HOME:-}"; } > "${META_FILE:?}"
fi
exit 0
SH
  chmod +x "$fb/fake-spawn"
  printf '%s\n' "$fb/fake-spawn"
}

# make_fake_send <dir>: a fake fm-send for FM_ROUTE_SEND_CMD, recording the
# cold-spawn env flag and its arguments to $SEND_LOG.
make_fake_send() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/fake-send" <<'SH'
#!/usr/bin/env bash
set -u
printf 'COLD=%s|args=%s\n' "${FM_PENDING_REPLY_COLD_SPAWN:-}" "$*" >> "${SEND_LOG:?}"
exit 0
SH
  chmod +x "$fb/fake-send"
  printf '%s\n' "$fb/fake-send"
}

# seed_home <home> <id>: a real seeded secondmate home at <home> plus a per-home
# backlog. <home> is a sibling of the parent FM_HOME, never inside it.
seed_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '# backlog for %s\n\n## Queued\n\n## Done\n' "$id" > "$home/data/backlog.md"
}

# write_parent <phome> <id> <home> [kind] [window]: parent state/<id>.meta and a
# data/secondmates.md route for <id> under FM_HOME <phome>.
write_parent() {
  local phome=$1 id=$2 home=$3 kind=${4:-secondmate} window=${5:-firstmate:fm-sm1}
  mkdir -p "$phome/state" "$phome/data"
  { printf 'window=%s\n' "$window"
    printf 'worktree=%s\n' "$home"
    printf 'backend=tmux\nharness=claude\n'
    printf 'kind=%s\n' "$kind"
    printf 'home=%s\n' "$home"; } > "$phome/state/$id.meta"
  printf '%s\n' "- $id - $id domain (home: $home; scope: $id from brief; projects: alpha; added 2026-07-26)" \
    > "$phome/data/secondmates.md"
}

# --- process-stop (fm-teardown.sh --stop) -----------------------------------

test_stop_keeps_home_lease_backlog_registry() {
  local parent phome home fb tmux_log th_log panecmd out reg_before backlog_before
  parent="$TMP_ROOT/stop-keep"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent")
  tmux_log="$parent/tmux.log"; : > "$tmux_log"
  th_log="$parent/th.log"; : > "$th_log"
  panecmd="$parent/panecmd"; printf 'claude\n' > "$panecmd"
  reg_before=$(cksum < "$phome/data/secondmates.md")
  backlog_before=$(cksum < "$home/data/backlog.md")

  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' \
    PANECMD_FILE="$panecmd" TMUX_LOG="$tmux_log" TH_LOG="$th_log" \
    "$TEARDOWN" sm1 --stop 2>&1) \
    || fail "stop should succeed on an idle secondmate: $out"

  assert_contains "$out" "stopped secondmate sm1" "stop should report the process was stopped"
  assert_grep "kill-window" "$tmux_log" "stop must end the resident endpoint"
  assert_present "$home" "stop must keep the secondmate home"
  assert_present "$home/data/backlog.md" "stop must keep the per-home backlog"
  assert_present "$phome/state/sm1.meta" "stop must keep the task meta so it stays routable"
  assert_grep "kind=secondmate" "$phome/state/sm1.meta" "the stopped task must stay a routable secondmate record"
  assert_grep "stopped=1" "$phome/state/sm1.meta" \
    "stop must record a durable stopped marker so it is not byte-identical to a crash"
  assert_grep "- sm1 " "$phome/data/secondmates.md" "stop must keep the registry route"
  assert_no_grep "return" "$th_log" "stop must never return (release) the treehouse lease"
  [ "$(cksum < "$phome/data/secondmates.md")" = "$reg_before" ] \
    || fail "stop must leave the registry entry byte-intact"
  [ "$(cksum < "$home/data/backlog.md")" = "$backlog_before" ] \
    || fail "stop must leave the backlog byte-intact"
  pass "stop: ends the process, keeps home + lease + backlog + registry byte-intact (meta gains only stopped=1)"
}

test_stop_then_route_round_trip() {
  local parent phome home fb spawn send panecmd out
  parent="$TMP_ROOT/stop-route-rt"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  panecmd="$parent/pc"; printf 'claude\n' > "$panecmd"

  # 1. Stop the idle secondmate (real teardown --stop).
  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$panecmd" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 --stop 2>&1) || fail "stop should succeed: $out"
  assert_grep "stopped=1" "$phome/state/sm1.meta" "the round-trip stop must mark the meta stopped"

  # 2. Route work to it (real router). The stopped marker forces a spawn even
  #    though the pane still reads 'claude'; the fake spawn stands in for a real
  #    relaunch and the request is then delivered cold.
  : > "$parent/spawn.log"; : > "$parent/send.log"
  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" "FAKE_SPAWN_PANECMD=claude" "FAKE_SPAWN_PRESENT=1" -- sm1 "resume the work") \
    || fail "routing to a stopped secondmate should bring it back and deliver: $out"
  assert_grep "spawn sm1 --secondmate" "$parent/spawn.log" "the stopped secondmate must be spawned on route"
  assert_grep "COLD=1|args=sm1 resume the work" "$parent/send.log" "the revived secondmate must receive the routed request cold"
  pass "round-trip: stop an idle secondmate, then route work - it comes back and does the work"
}

test_stop_refuses_with_in_flight_crewmate() {
  local parent phome home fb tmux_log out rc
  parent="$TMP_ROOT/stop-inflight"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  printf 'kind=ship\nwindow=firstmate:fm-child\n' > "$home/state/child.meta"
  fb=$(make_eph_tmux "$parent")
  tmux_log="$parent/tmux.log"; : > "$tmux_log"

  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$tmux_log" \
    "$TEARDOWN" sm1 --stop 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "stop must refuse while a crewmate is in flight"
  assert_contains "$out" "REFUSED" "stop refusal should be explicit"
  assert_present "$home/state/child.meta" "stop must not touch the in-flight crewmate"
  [ ! -s "$tmux_log" ] || fail "a refused stop must never touch the endpoint: $(cat "$tmux_log")"
  pass "stop: refuses (never forces) while an in-flight crewmate exists"
}

test_stop_refuses_with_open_pending_reply() {
  local parent phome home fb out rc prdir
  parent="$TMP_ROOT/stop-pending"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  prdir="$phome/state/pending-replies"; mkdir -p "$prdir"
  printf 'task_id=sm1\nphase=awaiting_report\n' > "$prdir/abcdef0123456789"
  fb=$(make_eph_tmux "$parent")

  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 --stop 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "stop must refuse while a routed request is awaiting a reply"
  assert_contains "$out" "awaiting a reply" "stop refusal should name the pending reply"
  pass "stop: refuses while a routed request is still awaiting a reply"
}

test_stop_refuses_with_queued_backlog() {
  local parent phome home fb out rc
  parent="$TMP_ROOT/stop-backlog"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  # A queued backlog item is domain work: routed work lives in the home's own
  # backlog and outlives any crewmate, so stopping here would strand it.
  printf '# backlog\n\n## Queued\n- [ ] some-task - do a thing (repo: x) (kind: ship)\n\n## Done\n' \
    > "$home/data/backlog.md"
  fb=$(make_eph_tmux "$parent")

  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 --stop 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "stop must refuse while the secondmate's backlog has queued work"
  assert_contains "$out" "queued or in-flight work in its backlog" "stop refusal should name the backlog work"
  pass "stop: refuses while the secondmate's own backlog has queued/in-flight work"
}

test_stop_rejects_force_and_stop_combined() {
  local parent phome home fb out rc
  parent="$TMP_ROOT/stop-force"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent")

  # Both orders must be rejected outright - never letting an unparsed extra arg
  # turn a stop into a forced retirement.
  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 --force --stop 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "'--force --stop' must be rejected, not silently retire the home"
  assert_present "$home" "a rejected --force --stop must not remove the home"
  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 --stop --force 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "'--stop --force' must be rejected too"
  assert_present "$home" "a rejected --stop --force must not remove the home"
  # An unknown extra option is also rejected.
  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 --bogus 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown teardown option must be rejected"
  pass "stop: --force and --stop are rejected together in either order; unknown options rejected"
}

test_stop_rejects_non_secondmate() {
  local parent phome fb out rc
  parent="$TMP_ROOT/stop-nonsm"; phome="$parent/home"; mkdir -p "$phome/state"
  { printf 'window=firstmate:fm-t1\nbackend=tmux\nkind=ship\nworktree=%s\n' "$parent/wt"; } > "$phome/state/t1.meta"
  fb=$(make_eph_tmux "$parent")

  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" t1 --stop 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "stop must reject a non-secondmate target"
  assert_contains "$out" "applies only to a secondmate" "the rejection should explain --stop's scope"
  pass "stop: rejects a non-secondmate target"
}

test_plain_teardown_still_retires() {
  local parent phome home fb out
  parent="$TMP_ROOT/retire"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent")

  # Plain teardown (no --stop) retires: removes the home and the registry route,
  # exactly as before - proving --stop is a distinct, non-destructive path.
  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    "$TEARDOWN" sm1 2>&1) || fail "plain retirement of an idle home should succeed: $out"
  assert_absent "$home" "retirement must remove the secondmate home"
  assert_no_grep "- sm1 " "$phome/data/secondmates.md" "retirement must remove the registry route"
  pass "retire: plain teardown still removes home + route (unchanged, distinct from --stop)"
}

# --- spawn-before-route (fm-route-secondmate.sh) ----------------------------

# run_route <phome> <parent> <fb> <panecmd> <env=val...> -- <route-args...>
run_route() {
  local phome=$1 parent=$2 fb=$3 panecmd=$4; shift 4
  local env_args=()
  while [ "$1" != "--" ]; do env_args+=("$1"); shift; done
  shift
  PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' \
    PANECMD_FILE="$panecmd" TMUX_LOG="$parent/tmux.log" \
    SPAWN_LOG="$parent/spawn.log" SEND_LOG="$parent/send.log" \
    PANE_PRESENT_FILE="$parent/present" META_FILE="$phome/state/sm1.meta" \
    env "${env_args[@]}" "$ROUTE" "$@" 2>&1
}

test_route_live_is_pass_through() {
  local parent phome home fb panecmd spawn send out
  parent="$TMP_ROOT/route-live"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  panecmd="$parent/pc"; printf 'claude\n' > "$panecmd"
  : > "$parent/present"   # a live secondmate's pane exists
  : > "$parent/spawn.log"; : > "$parent/send.log"

  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" -- sm1 "do the thing") \
    || fail "routing to a live secondmate should succeed: $out"
  [ ! -s "$parent/spawn.log" ] || fail "a live secondmate must not be spawned: $(cat "$parent/spawn.log")"
  assert_grep "COLD=|args=sm1 do the thing" "$parent/send.log" "a live route must send warm (no cold flag)"
  pass "route: a live secondmate is a transparent warm pass-through to fm-send"
}

test_route_stopped_spawns_verifies_and_sends_cold() {
  local parent phome home fb panecmd spawn send out
  parent="$TMP_ROOT/route-stopped"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  panecmd="$parent/pc"; printf 'zsh\n' > "$panecmd"   # husk: pane present, agent gone
  : > "$parent/present"
  : > "$parent/spawn.log"; : > "$parent/send.log"; : > "$parent/tmux.log"

  # The husk reads confident-dead (bare shell); the spawn brings the agent up by
  # flipping the probe reading to a live harness on the still-present pane.
  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" "FAKE_SPAWN_PANECMD=claude" -- sm1 "resume phase 7") \
    || fail "routing to a stopped secondmate should spawn then send: $out"
  assert_grep "spawn sm1 --secondmate" "$parent/spawn.log" "a stopped secondmate must be spawned first"
  assert_grep "kill-window" "$parent/tmux.log" "the stale endpoint must be killed before respawn"
  assert_grep "COLD=1|args=sm1 resume phase 7" "$parent/send.log" "a cold spawn must set the cold-spawn grace flag on delivery"
  pass "route: a stopped secondmate is killed, spawned, verified live, then sent with the cold-spawn flag"
}

test_route_fails_closed_when_no_live_agent() {
  local parent phome home fb panecmd spawn send out rc
  parent="$TMP_ROOT/route-fail"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  panecmd="$parent/pc"; printf 'zsh\n' > "$panecmd"
  : > "$parent/present"
  : > "$parent/spawn.log"; : > "$parent/send.log"

  # Spawn "succeeds" but the endpoint stays a bare shell (dead): fm-send must
  # never be reached, so nothing is silently dropped.
  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" "FM_ROUTE_SPAWN_WAIT_SECS=1" -- sm1 "do it") \
    && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn that never produces a live agent must fail closed"
  assert_grep "spawn sm1 --secondmate" "$parent/spawn.log" "the spawn should have been attempted"
  [ ! -s "$parent/send.log" ] || fail "fm-send must never be reached when liveness cannot be confirmed"
  pass "route: a spawn that never comes up fails closed; fm-send is never reached"
}

test_route_accepts_unknown_probe_when_pane_present() {
  local parent phome home fb panecmd spawn send out
  parent="$TMP_ROOT/route-unknown"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  panecmd="$parent/pc"; printf 'zsh\n' > "$panecmd"
  : > "$parent/spawn.log"; : > "$parent/send.log"; rm -f "$parent/present"

  # A backend whose probe can only report "unknown" (e.g. pi -> node) is accepted
  # only when the freshly spawned pane exists.
  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" "FM_ROUTE_SPAWN_WAIT_SECS=1" \
    "FAKE_SPAWN_PANECMD=node" "FAKE_SPAWN_PRESENT=1" -- sm1 "go") \
    || fail "an unknown probe with a present pane should be accepted: $out"
  assert_grep "COLD=1|args=sm1 go" "$parent/send.log" "an accepted unknown-probe spawn should still send cold"
  pass "route: an unconfirmable (unknown) probe is accepted only when the pane exists"
}

test_route_spawns_from_registry_when_meta_lost() {
  local parent phome home fb panecmd spawn send out
  parent="$TMP_ROOT/route-nometa"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  rm -f "$phome/state/sm1.meta"   # crash lost the runtime meta; registry survives
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  panecmd="$parent/pc"; printf 'zsh\n' > "$panecmd"
  : > "$parent/spawn.log"; : > "$parent/send.log"

  # The fake spawn writes a fresh meta (as a real spawn would) and brings it up.
  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" \
    "FAKE_SPAWN_META=1" "FAKE_SPAWN_HOME=$home" "FAKE_SPAWN_PANECMD=claude" "FAKE_SPAWN_PRESENT=1" -- sm1 "revive") \
    || fail "a registered secondmate with no meta should still be routable: $out"
  assert_grep "spawn sm1 --secondmate" "$parent/spawn.log" "a registry-only secondmate must be spawned"
  assert_grep "COLD=1|args=sm1 revive" "$parent/send.log" "the revived secondmate should receive the routed request cold"
  pass "route: a registered secondmate whose meta was lost is still routable from the registry"
}

test_route_unknown_live_endpoint_not_killed() {
  local parent phome home fb panecmd spawn send out
  parent="$TMP_ROOT/route-unknown-live"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  # 'node' is the always-unknown reading (pi-on-tmux, and the same class as
  # zellij/orca/cmux). A live secondmate here must NOT be killed or spawned - per
  # bin/fm-backend.sh's contract that unknown never licenses an action - or a
  # healthy agent would be destroyed and its crewmates orphaned. Delivery goes
  # through fail-closed fm-send instead.
  panecmd="$parent/pc"; printf 'node\n' > "$panecmd"
  : > "$parent/present"   # the pane exists; only the AGENT reading is unconfirmable
  : > "$parent/spawn.log"; : > "$parent/send.log"; : > "$parent/tmux.log"

  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" -- sm1 "steer it") \
    || fail "an unknown-but-live endpoint should be delivered to, not killed: $out"
  [ ! -s "$parent/spawn.log" ] || fail "an unknown reading must never spawn (would duplicate a live agent): $(cat "$parent/spawn.log")"
  assert_no_grep "kill-window" "$parent/tmux.log" \
    "an unknown reading must never kill the endpoint (would destroy a possibly-live agent)"
  assert_grep "COLD=|args=sm1 steer it" "$parent/send.log" "an unknown reading falls through to fail-closed fm-send (warm)"
  pass "route: an unknown probe never kills or spawns; it delivers through fail-closed fm-send"
}

test_route_revives_after_pane_gone() {
  local parent phome home fb panecmd spawn send out
  parent="$TMP_ROOT/route-pane-gone"; phome="$parent/home"; home="$parent/sm1"; mkdir -p "$phome"
  seed_home "$home" sm1; write_parent "$phome" sm1 "$home"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  # The most common crash shape: the meta still records a window= but the pane is
  # entirely GONE (a reboot took the tmux server). On tmux that reads unknown from
  # the agent probe, but target-absence is positively dead - the router must map
  # it to dead and revive, or an idle secondmate is unrevivable after a reboot.
  panecmd="$parent/pc"; printf 'zsh\n' > "$panecmd"
  rm -f "$parent/present"   # pane gone: fm_backend_target_exists is false
  : > "$parent/spawn.log"; : > "$parent/send.log"

  out=$(run_route "$phome" "$parent" "$fb" "$panecmd" \
    "FM_ROUTE_SPAWN_CMD=$spawn" "FM_ROUTE_SEND_CMD=$send" "FAKE_SPAWN_PANECMD=claude" "FAKE_SPAWN_PRESENT=1" -- sm1 "after reboot") \
    || fail "a rebooted secondmate whose pane is gone should be revived: $out"
  assert_grep "spawn sm1 --secondmate" "$parent/spawn.log" "a gone pane (target-absent) must be treated as dead and respawned"
  assert_grep "COLD=1|args=sm1 after reboot" "$parent/send.log" "the revived secondmate should receive the routed request cold"
  pass "route: a rebooted secondmate whose pane is entirely gone is revived (target-absence is dead, not unknown)"
}

test_route_rejects_non_secondmate() {
  local parent phome fb spawn send out rc
  parent="$TMP_ROOT/route-nonsm"; phome="$parent/home"; mkdir -p "$phome/state" "$phome/data"
  { printf 'window=firstmate:fm-t1\nbackend=tmux\nkind=ship\n'; } > "$phome/state/t1.meta"
  fb=$(make_eph_tmux "$parent"); spawn=$(make_fake_spawn "$parent"); send=$(make_fake_send "$parent")
  : > "$parent/spawn.log"; : > "$parent/send.log"; printf 'claude\n' > "$parent/pc"

  out=$(PATH="$fb:$PATH" FM_HOME="$phome" TMUX='' PANECMD_FILE="$parent/pc" TMUX_LOG="$parent/t.log" \
    SPAWN_LOG="$parent/spawn.log" SEND_LOG="$parent/send.log" PANE_PRESENT_FILE="$parent/present" META_FILE="$phome/state/t1.meta" \
    FM_ROUTE_SPAWN_CMD="$spawn" FM_ROUTE_SEND_CMD="$send" \
    "$ROUTE" t1 "steer" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "the router must refuse a non-secondmate target"
  assert_contains "$out" "not a registered secondmate" "the refusal should point back to fm-send"
  [ ! -s "$parent/spawn.log" ] || fail "a non-secondmate target must never spawn"
  [ ! -s "$parent/send.log" ] || fail "a non-secondmate target must never send"
  pass "route: a non-secondmate target is refused (ordinary steers use fm-send directly)"
}

test_stop_keeps_home_lease_backlog_registry
test_stop_then_route_round_trip
test_stop_refuses_with_in_flight_crewmate
test_stop_refuses_with_open_pending_reply
test_stop_refuses_with_queued_backlog
test_stop_rejects_non_secondmate
test_stop_rejects_force_and_stop_combined
test_plain_teardown_still_retires
test_route_live_is_pass_through
test_route_stopped_spawns_verifies_and_sends_cold
test_route_fails_closed_when_no_live_agent
test_route_accepts_unknown_probe_when_pane_present
test_route_unknown_live_endpoint_not_killed
test_route_revives_after_pane_gone
test_route_spawns_from_registry_when_meta_lost
test_route_rejects_non_secondmate

echo "# all fm-secondmate-ephemeral tests passed"
