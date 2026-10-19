#!/usr/bin/env bash
# Shared GitHub CI reader, sourced by fm-pr-merge.sh and fm-contributions.sh.
#
# GitHub check data is not readable with a fine-grained personal access token,
# so the checks at one head commit are read from GitHub Actions and commit
# statuses instead. Each workflow's latest run contributes its latest attempt's
# jobs as check runs named by job name, so callers judge them by the same rules
# as any check run. A run not yet completed, or completed with no job,
# contributes itself under its workflow name so it cannot read as green.
# Commit statuses are added as status contexts.
#
# github_read_checks <owner> <repo> <head> sets FM_PR_GITHUB_CHECKS to a JSON
# array of {__typename, name|context, id, status, conclusion|state, startedAt}
# entries and FM_PR_GITHUB_JOB_NAMES to the job names; any unreadable or
# mismatched read fails. Reads go through FM_GITHUB_CHECKS_GH (default gh) so a
# caller can run them under its own time budget.

FM_PR_GITHUB_CHECKS=
# shellcheck disable=SC2034
FM_PR_GITHUB_JOB_NAMES=
github_read_checks() {
  local owner=$1 repo=$2 head=$3 gh_cmd=${FM_GITHUB_CHECKS_GH:-gh}
  local runs_json runs run_id jobs_json run_entries entries='' statuses_json statuses
  FM_PR_GITHUB_CHECKS=
  # shellcheck disable=SC2034
  FM_PR_GITHUB_JOB_NAMES=
  runs_json=$("$gh_cmd" api --paginate "repos/$owner/$repo/actions/runs?head_sha=$head&per_page=100" 2>/dev/null) \
    && [ -n "$runs_json" ] || return 1
  runs=$(printf '%s' "$runs_json" | jq -c -s --arg head "$head" '
    [ .[] | if (.workflow_runs | type) == "array" then .workflow_runs[] else error("invalid runs") end
      | if (.id | type) == "number" and (.workflow_id | type) == "number"
           and (.status | type) == "string" and .head_sha == $head
        then . else error("invalid run") end ]
    | group_by(.workflow_id) | map(max_by(.id))' 2>/dev/null) || return 1
  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue
    jobs_json=$("$gh_cmd" api --paginate "repos/$owner/$repo/actions/runs/$run_id/jobs?per_page=100" 2>/dev/null) \
      && [ -n "$jobs_json" ] || return 1
    run_entries=$(printf '%s' "$jobs_json" | jq -c -s --arg head "$head" --argjson run_id "$run_id" --argjson runs "$runs" '
      def check_run(id; name; status; conclusion; started):
        {__typename: "CheckRun", name: name, id: id, status: (status | ascii_upcase),
         conclusion: (if conclusion == null then null else (conclusion | ascii_upcase) end),
         startedAt: started};
      ($runs[] | select(.id == $run_id)) as $run
      | [ .[] | if (.jobs | type) == "array" then .jobs[] else error("invalid jobs") end
          | if (.name | type) == "string" and (.status | type) == "string" and .head_sha == $head
            then check_run(.id; .name; .status; .conclusion; .started_at) else error("invalid job") end ]
      | if $run.status != "completed" or length == 0 then
          . + [check_run($run.id; ($run.name // "") | tostring; $run.status; $run.conclusion; $run.run_started_at)]
        else . end' 2>/dev/null) || return 1
    entries="$entries$run_entries"
  done <<EOF2
$(printf '%s' "$runs" | jq -r '.[].id')
EOF2
  statuses_json=$("$gh_cmd" api --paginate "repos/$owner/$repo/commits/$head/status?per_page=100" 2>/dev/null) \
    && [ -n "$statuses_json" ] || return 1
  statuses=$(printf '%s' "$statuses_json" | jq -c -s --arg head "$head" '
    [ .[] | if .sha == $head and (.statuses | type) == "array" then .statuses[] else error("invalid status") end
      | if (.context | type) == "string" and (.state | type) == "string"
        then {__typename: "StatusContext", context, id, startedAt: .created_at, state: (.state | ascii_upcase)}
        else error("invalid status") end ]' 2>/dev/null) || return 1
  FM_PR_GITHUB_CHECKS=$(printf '%s\n%s\n' "$entries" "$statuses" | jq -c -s 'add // []') || return 1
  # shellcheck disable=SC2034
  FM_PR_GITHUB_JOB_NAMES=$(printf '%s' "$FM_PR_GITHUB_CHECKS" | jq -c '[.[] | select(.__typename == "CheckRun") | .name]')
}
