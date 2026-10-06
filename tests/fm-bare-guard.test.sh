#!/usr/bin/env bash
# Behavior tests for the core.bare tripwire, auto-repair, and attribution audit
# (bin/fm-bare-guard-lib.sh, wired into fm-fleet-sync.sh, fm-bootstrap.sh, and
# fm-watch.sh). Covers the deterministic production flip (GIT_DIR of a worktree
# git-dir exported, plain `git init` run from another directory), the safe repair
# of a clean populated work tree, the refusals (dirty, unique commits, detached
# HEAD, genuine bare repo), the surfaced-and-logged outputs, idempotency, and
# that no state outside the isolated home is written.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-bare-guard-tests)

new_home() {
  local h
  h="$TMP_ROOT/home-$$-$RANDOM$RANDOM"
  mkdir -p "$h/projects" "$h/data" "$h/state"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

build_clone() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"
  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

flip_bare() {
  local clone=$1 wt gd d
  wt="$TMP_ROOT/flipwt-$$-$RANDOM$RANDOM"
  git -C "$clone" worktree add -q --detach "$wt" >/dev/null 2>&1
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  d="$TMP_ROOT/flipcwd-$$-$RANDOM$RANDOM"; mkdir -p "$d"
  ( cd "$d" && GIT_DIR="$gd" git init -q >/dev/null 2>&1 )
  rm -rf "$wt"
  git -C "$clone" worktree prune >/dev/null 2>&1 || true
}

is_bare() { git -C "$1" rev-parse --is-bare-repository 2>/dev/null; }

run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

test_deterministic_flip_via_gitdir_worktree() {
  local home clone
  home=$(new_home)
  clone=$(build_clone "$home" repro)
  [ "$(is_bare "$clone")" = false ] || fail "clone started bare"
  flip_bare "$clone"
  [ "$(is_bare "$clone")" = true ] \
    || fail "GIT_DIR=worktree-gitdir + plain git init from another dir did not flip core.bare to true"
  pass "the production flip (exported worktree git-dir + plain git init elsewhere) reproduces core.bare=true"
}

test_flipped_clean_clone_is_repaired_and_sync_continues() {
  local home clone out
  home=$(new_home)
  clone=$(build_clone "$home" repair)
  advance_origin "$home" repair C1
  flip_bare "$clone"
  out=$(run_sync "$home" repair)
  assert_contains "$out" "repair: repaired: core.bare was flipped to true" "repair line was not printed"
  assert_contains "$out" "continuing sync" "repair did not continue the sync"
  assert_contains "$out" "repair: synced" "sync did not fast-forward after repair"
  [ "$(is_bare "$clone")" = false ] || fail "core.bare was not reset to false"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "repair disturbed the work tree"
  pass "a flipped clean populated clone is repaired and the sync continues"
}

test_repair_appends_durable_record() {
  local home clone
  home=$(new_home)
  clone=$(build_clone "$home" record)
  flip_bare "$clone"
  run_sync "$home" record >/dev/null
  assert_present "$home/data/project-bare-repairs.log" "repair log was not created"
  assert_grep "repaired" "$home/data/project-bare-repairs.log" "repair log has no repaired record"
  assert_grep "$clone" "$home/data/project-bare-repairs.log" "repair log does not name the clone"
  pass "a repair appends a durable record under data/"
}

test_tripwire_captures_bounded_incident() {
  local home clone incident bytes
  home=$(new_home)
  clone=$(build_clone "$home" incident)
  flip_bare "$clone"
  run_sync "$home" incident >/dev/null
  incident=$(find "$home/data/incidents" -name 'project-bare-*.md' 2>/dev/null | head -1)
  [ -n "$incident" ] || fail "no incident file was captured"
  assert_grep "clone: $clone" "$incident" "incident file does not record the clone path"
  assert_grep "## git processes" "$incident" "incident file has no git-process section"
  assert_grep "## .git/config" "$incident" "incident file has no .git/config stat section"
  bytes=$(wc -c < "$incident")
  [ "$bytes" -le 65536 ] || fail "incident file is not bounded in size: $bytes bytes"
  pass "the tripwire captures a timestamped, bounded attribution incident under data/"
}

test_dirty_clone_is_refused() {
  local home clone out
  home=$(new_home)
  clone=$(build_clone "$home" dirty)
  advance_origin "$home" dirty C1
  printf '%s\n' "local edit" > "$clone/file.txt"
  flip_bare "$clone"
  out=$(run_sync "$home" dirty)
  assert_contains "$out" "dirty: STUCK: core.bare flipped to true but refuse: uncommitted changes" "dirty clone was not refused loudly"
  [ "$(is_bare "$clone")" = true ] || fail "dirty clone must be left flipped, not silently repaired"
  assert_contains "$out" "dirty: STUCK" "refusal was not reported as STUCK"
  assert_not_contains "$out" "dirty: synced" "a refused dirty clone must not be synced"
  pass "a dirty flipped clone is refused loudly and left untouched"
}

test_unique_commit_clone_is_refused() {
  local home clone out
  home=$(new_home)
  clone=$(build_clone "$home" unique)
  commit_file "$clone" file.txt localonly "local only commit"
  flip_bare "$clone"
  out=$(run_sync "$home" unique)
  assert_contains "$out" "unique: STUCK: core.bare flipped to true but refuse: local commits not present on origin" "unique-commit clone was not refused"
  [ "$(is_bare "$clone")" = true ] || fail "a clone with unique commits must be left flipped"
  pass "a flipped clone with unique local commits is refused"
}

test_detached_clone_is_refused() {
  local home clone out
  home=$(new_home)
  clone=$(build_clone "$home" detached)
  git -C "$clone" checkout -q --detach HEAD
  flip_bare "$clone"
  out=$(run_sync "$home" detached)
  assert_contains "$out" "detached: STUCK: core.bare flipped to true but refuse: detached HEAD" "detached clone was not refused"
  [ "$(is_bare "$clone")" = true ] || fail "a detached clone must be left flipped"
  pass "a flipped clone on a detached HEAD is refused"
}

test_genuine_bare_repo_is_left_alone() {
  local home bare out
  home=$(new_home)
  bare="$home/projects/truly-bare"
  git init -q --bare "$bare"
  out=$(run_sync "$home" truly-bare)
  assert_not_contains "$out" "repaired" "a genuine bare repo must never be repaired"
  assert_contains "$out" "truly-bare: STUCK: core.bare flipped to true but refuse: .git is not a directory" "a genuine bare repo was not refused as by-design"
  [ "$(is_bare "$bare")" = true ] || fail "a genuine bare repo must stay bare"
  pass "a genuine by-design bare repo is detected but left alone"
}

test_repair_is_idempotent() {
  local home clone first second
  home=$(new_home)
  clone=$(build_clone "$home" idem)
  flip_bare "$clone"
  first=$(run_sync "$home" idem)
  assert_contains "$first" "idem: repaired" "first run did not repair"
  second=$(run_sync "$home" idem)
  assert_not_contains "$second" "repaired" "second run repaired again on an already-healthy clone"
  assert_not_contains "$second" "STUCK" "second run reported a problem on a healthy clone"
  pass "a second sync on a repaired clone is a no-op (idempotent)"
}

test_no_writes_outside_the_home() {
  local home clone canary touched
  home=$(new_home)
  clone=$(build_clone "$home" nowrite)
  flip_bare "$clone"
  canary="$TMP_ROOT/canary-outside"
  : > "$canary"
  run_sync "$home" nowrite >/dev/null
  touched=$(find "$TMP_ROOT" -path "$home" -prune -o -type f -newer "$canary" -print 2>/dev/null | grep -v "^$canary$" || true)
  [ -z "$touched" ] || fail "fleet-sync wrote outside the isolated home:"$'\n'"$touched"
  pass "repair writes only inside the isolated home"
}

test_bootstrap_detect_reports_project_bare_line() {
  local home clone out
  home=$(new_home)
  clone=$(build_clone "$home" btline)
  flip_bare "$clone"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PROJECT_BARE: btline: core.bare=true on a populated work tree clone" "bootstrap did not print the PROJECT_BARE detect line"
  [ "$(is_bare "$clone")" = true ] || fail "detect-only bootstrap must not repair the flip"
  pass "bootstrap detect-only emits a stable PROJECT_BARE line and does not repair"
}

test_watcher_scan_surfaces_flip_once() {
  local home clone out
  home=$(new_home)
  clone=$(build_clone "$home" wscan)
  flip_bare "$clone"
  out="$home/wscan.out"
  (
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT"
    export FM_HOME FM_ROOT_OVERRIDE
    # shellcheck source=bin/fm-watch.sh disable=SC1091
    . "$ROOT/bin/fm-watch.sh"
    rec=$(bare_scan_find_flip) || { echo "NOFLIP"; exit 0; }
    reason=${rec#*	}; reason=${reason#*	}
    case "$reason" in
      "check: project-bare: wscan: core.bare=true"*) : ;;
      *) echo "BADREASON:$reason"; exit 0 ;;
    esac
    sig=${rec#*	}; sig=${sig%%	*}
    clone_field=${rec%%	*}
    printf '%s' "$sig" > "$(_bare_surfaced_path "$clone_field")"
    if bare_scan_find_flip >/dev/null; then echo "RESURFACED"; else echo "OK"; fi
  ) > "$out" 2>/dev/null
  assert_grep "OK" "$out" "watcher scan did not surface the flip exactly once (dedup failed)"
  assert_no_grep "NOFLIP" "$out" "watcher scan missed the flip"
  assert_no_grep "BADREASON" "$out" "watcher scan reason was not in the check vocabulary"
  assert_no_grep "RESURFACED" "$out" "watcher scan re-surfaced an already-surfaced flip"
  pass "the watcher periodic scan surfaces a flip as a check wake, once per unchanged flip"
}

test_watcher_scan_silent_on_healthy_fleet() {
  local home out
  home=$(new_home)
  out="$home/healthy.out"
  build_clone "$home" healthy >/dev/null
  (
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT"
    export FM_HOME FM_ROOT_OVERRIDE
    # shellcheck source=bin/fm-watch.sh disable=SC1091
    . "$ROOT/bin/fm-watch.sh"
    if bare_scan_find_flip >/dev/null; then echo "FLIP"; else echo "CLEAN"; fi
  ) > "$out" 2>/dev/null
  assert_grep "CLEAN" "$out" "watcher scan reported a flip on a healthy fleet"
  pass "the watcher periodic scan is silent on a healthy fleet"
}

test_deterministic_flip_via_gitdir_worktree
test_flipped_clean_clone_is_repaired_and_sync_continues
test_repair_appends_durable_record
test_tripwire_captures_bounded_incident
test_dirty_clone_is_refused
test_unique_commit_clone_is_refused
test_detached_clone_is_refused
test_genuine_bare_repo_is_left_alone
test_repair_is_idempotent
test_no_writes_outside_the_home
test_bootstrap_detect_reports_project_bare_line
test_watcher_scan_surfaces_flip_once
test_watcher_scan_silent_on_healthy_fleet
