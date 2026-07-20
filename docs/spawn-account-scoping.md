# Spawn account scoping

Firstmate launches every crewmate and secondmate agent inside a disposable worktree (a `~/.treehouse/...` pool path or an Orca-managed worktree), which is outside the operator's normal source tree.
An operator who selects an account per directory - for example a direnv rule that exports a per-account config dir only under `~/src/personal/` - never has that rule fire inside the worktree, so the spawned agent silently reverts to its harness default account.
When the default account routes through a billing or optimization proxy, that spends the wrong account.

`bin/fm-spawn.sh` closes this gap for `claude` by cascading the spawning firstmate's own account scope to the launched agent.
The mechanism is owned by that script: the `claude` case in `launch_template()` carries a `CLAUDE_CONFIG_DIR=__CLAUDECONFIGDIR__` per-launch env prefix, and the substitution block resolves the value from the spawner's live `CLAUDE_CONFIG_DIR` (defaulting to claude's own `$HOME/.claude` when unset).
The value is expanded at spawn time, not left as a literal `$CLAUDE_CONFIG_DIR` that a fresh worktree pane's shell would re-resolve to nothing.
This is the same per-launch env-prefix pattern, on the same line, as `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`: scoped to the launched agent, never touching the operator's global config.

## Cross-harness compatibility

The gap is a general class: any harness whose credentials are selected by a directory-scoped convention would lose that selection inside the worktree the same way.
As of 2026-07-20, only `claude` needs the cascade in this fleet.

- `claude` - AFFECTED and fixed. `CLAUDE_CONFIG_DIR` selects the config dir (hence the login and the account), and the operator has a direnv rule (`~/src/personal/.envrc` exports `CLAUDE_CONFIG_DIR=$HOME/.claude-personal`) that never fires in the worktree.
- `codex` - not affected in this fleet. `CODEX_HOME` (default `~/.codex`) is the analogous config-dir selector, but no directory-scoped convention sets it here. If one is ever added, apply the same one-line env-prefix cascade to the `codex` template.
- `opencode` - not affected in this fleet. Its config/auth dir is the analogous selector; no directory-scoped convention sets it here.
- `pi` - not affected in this fleet. No directory-scoped credential convention in use.
- `grok` - not affected in this fleet. Its config dir is already pinned explicitly per spawn (`GROK_HOME`), and no directory-scoped convention selects a grok account here.

A related but separate leak: `~/src/personal/.envrc` also exports a personal `GH_TOKEN`, which likewise does not reach the worktree.
That is out of scope here because crewmates use `gh-axi` with the fleet's own GitHub auth rather than an inherited `GH_TOKEN`.

## Verification

Environment: 2026-07-20, claude 2.1.215 (Claude Code), spawn worktree `/Users/yewonlee/.treehouse/firstmate-7bab20/4/firstmate` (cwd outside `~/src/personal/`, so the direnv rule does not fire; the spawning firstmate's own scope is `CLAUDE_CONFIG_DIR=$HOME/.claude-personal`).

The account resolution depends only on `CLAUDE_CONFIG_DIR`, which is exactly what the fix injects.
`~/.claude/settings.json` sets `env.ANTHROPIC_BASE_URL=http://127.0.0.1:8787` (the optimization proxy, which authenticates upstream as the work account), while `~/.claude-personal/settings.json` has no `env` block.

A crewmate spawned by the pre-fix launcher inherits the proxy's `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL` in its own environment (the proxy's hooks run under the default config), and those exported vars override any config dir in child processes.
So to reproduce a clean pane spawned from a personal-scoped primary, the check strips those inherited vars and varies only the config dir.

Buggy default config resolves the work/proxy account:

```
$ env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR="$HOME/.claude" claude auth status
...
{
  "loggedIn": false,
  ...
```

With the proxy env present (a real pre-fix crewmate), the same default config resolved `"apiKeySource": "ANTHROPIC_API_KEY", "email": null` - the proxy-injected work credential, not a personal login.

The fix's injected value resolves the operator's personal account, matching the primary firstmate session:

```
$ env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude auth status
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "email": "ywplee@gmail.com",
  "orgId": "9d1ddd63-bc6e-4dc0-8145-7c211dfdaaa2",
  "orgName": "ywplee@gmail.com's Organization",
  "subscriptionType": "pro"
}
```

The launch-string half of the fix (that `fm-spawn.sh` actually emits this prefix, with the spawner's value, space-safe, and only for the `claude` template) is pinned by `tests/fm-spawn-dispatch-profile.test.sh`.

## Maintaining this file

Record empirical facts, not assumptions: include the date, versions, exact commands, and exact output.
The mechanism itself is owned by `bin/fm-spawn.sh`; keep this file to evidence and cross-harness findings, and point at the script rather than restating its logic.
