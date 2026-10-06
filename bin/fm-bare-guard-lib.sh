#!/usr/bin/env bash
# Detect, classify, safely repair, and capture evidence for a project clone whose
# core.bare was silently flipped to true. The contract lives in docs/architecture.md
# "core.bare tripwire"; this library is its single owner.
# Sourced by fm-bootstrap.sh (detect-only), fm-fleet-sync.sh (detect + repair),
# and fm-watch.sh (periodic detect + wake).

FM_BARE_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BARE_INCIDENT_COOLDOWN=${FM_BARE_INCIDENT_COOLDOWN:-3600}
FM_BARE_INCIDENT_MAX_TASKS=${FM_BARE_INCIDENT_MAX_TASKS:-20}
FM_BARE_INCIDENT_PANE_LINES=${FM_BARE_INCIDENT_PANE_LINES:-15}
FM_BARE_INCIDENT_PS_LINES=${FM_BARE_INCIDENT_PS_LINES:-40}
FM_BARE_INCIDENT_LINE_WIDTH=${FM_BARE_INCIDENT_LINE_WIDTH:-400}

fm_bare_is_true() {
  [ "$(git -C "$1" config --bool core.bare 2>/dev/null)" = true ]
}

fm_bare_stat() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%N size=%z mtime=%Sm' "$1" 2>/dev/null
  else
    stat -c '%n size=%s mtime=%y' "$1" 2>/dev/null
  fi
}

fm_bare_age_of() {
  local f=$1 now mt
  now=$(date +%s)
  if [ "$(uname)" = Darwin ]; then
    mt=$(stat -f %m "$f" 2>/dev/null) || { echo 999999; return; }
  else
    mt=$(stat -c %Y "$f" 2>/dev/null) || { echo 999999; return; }
  fi
  [ -n "$mt" ] || { echo 999999; return; }
  echo $(( now - mt ))
}

fm_bare_default_branch() {
  local clone=$1 ref branch
  ref=$(git -C "$clone" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_bare_classify() {
  local clone=$1 cur def status_out
  if [ ! -d "$clone/.git" ]; then
    printf 'refuse: .git is not a directory (genuine bare repo or gitfile, left untouched)\n'
    return 0
  fi
  cur=$(git -C "$clone" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$cur" ]; then
    printf 'refuse: detached HEAD\n'
    return 0
  fi
  def=$(fm_bare_default_branch "$clone") || {
    printf 'refuse: cannot determine default branch\n'
    return 0
  }
  if [ "$cur" != "$def" ]; then
    printf 'refuse: HEAD on %s, not default branch %s\n' "$cur" "$def"
    return 0
  fi
  if ! git -C "$clone" rev-parse --verify --quiet "refs/remotes/origin/$def^{commit}" >/dev/null 2>&1; then
    printf 'refuse: cannot verify against origin/%s\n' "$def"
    return 0
  fi
  if ! git -C "$clone" merge-base --is-ancestor HEAD "origin/$def" 2>/dev/null; then
    printf 'refuse: local commits not present on origin/%s\n' "$def"
    return 0
  fi
  if [ -z "$(git -C "$clone" ls-tree --name-only HEAD 2>/dev/null | head -1)" ]; then
    printf 'refuse: no tracked files in HEAD\n'
    return 0
  fi
  if ! status_out=$(git --work-tree="$clone" --git-dir="$clone/.git" status --porcelain 2>/dev/null); then
    printf 'refuse: work tree unreadable\n'
    return 0
  fi
  if [ -n "$status_out" ]; then
    printf 'refuse: uncommitted changes in work tree\n'
    return 0
  fi
  printf 'repairable\n'
  return 0
}

fm_bare_repair() {
  local clone=$1 data=$2 ts
  git -C "$clone" config core.bare false 2>/dev/null || return 1
  [ "$(git -C "$clone" rev-parse --is-bare-repository 2>/dev/null)" = false ] || return 1
  mkdir -p "$data" 2>/dev/null || true
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\trepaired\t%s\tcore.bare true->false (clean populated work tree)\n' \
    "$ts" "$clone" >> "$data/project-bare-repairs.log" 2>/dev/null || true
  return 0
}

_fm_bare_meta_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

fm_bare_live_task_panes() {
  local state=$1 meta id wt win n=0
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    win=$(_fm_bare_meta_field "$meta" window)
    [ -n "$win" ] || continue
    [ "$n" -ge "$FM_BARE_INCIDENT_MAX_TASKS" ] && break
    id=$(basename "$meta" .meta)
    wt=$(_fm_bare_meta_field "$meta" worktree)
    echo "### task $id (worktree: ${wt:-unknown})"
    FM_STATE_OVERRIDE="$state" "$FM_BARE_GUARD_DIR/fm-peek.sh" "$id" "$FM_BARE_INCIDENT_PANE_LINES" 2>/dev/null \
      | head -n "$FM_BARE_INCIDENT_PANE_LINES" | cut -c "1-$FM_BARE_INCIDENT_LINE_WIDTH" || echo "(pane unavailable)"
    echo
    n=$((n + 1))
  done
}

fm_bare_capture_incident() {
  local clone=$1 data=$2 state=$3 hash marker ts file
  hash=$(printf '%s' "$clone" | tr '/.:' '___')
  marker="$state/.bare-incident-$hash"
  if [ -e "$marker" ] && [ "$(fm_bare_age_of "$marker")" -lt "$FM_BARE_INCIDENT_COOLDOWN" ]; then
    return 0
  fi
  mkdir -p "$data/incidents" 2>/dev/null || return 0
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  file="$data/incidents/project-bare-$ts.md"
  (
    set +e
    echo "# project-bare tripwire incident"
    echo
    echo "captured_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "clone: $clone"
    echo
    echo "## .git/config"
    fm_bare_stat "$clone/.git/config" || echo "(unavailable)"
    echo
    echo "## git processes"
    # shellcheck disable=SC2009
    ps -axo pid,ppid,lstart,command 2>/dev/null | grep -iE '[g]it' | head -n "$FM_BARE_INCIDENT_PS_LINES" | cut -c "1-$FM_BARE_INCIDENT_LINE_WIDTH"
    echo
    echo "## live tasks"
    fm_bare_live_task_panes "$state"
  ) > "$file" 2>/dev/null || true
  : > "$marker" 2>/dev/null || true
  printf '%s\n' "$file"
}

fm_bare_clear_incident_marker() {
  local clone=$1 state=$2 hash
  hash=$(printf '%s' "$clone" | tr '/.:' '___')
  rm -f "$state/.bare-incident-$hash" 2>/dev/null || true
}
