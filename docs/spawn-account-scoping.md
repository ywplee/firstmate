# Spawn account scoping

Firstmate launches every crewmate and secondmate agent inside a disposable worktree (a `~/.treehouse/...` pool path or an Orca-managed worktree), which is outside the operator's normal source tree.
An operator who selects an account per directory - for example a direnv rule that exports a per-account config dir only under `~/src/personal/` - never has that rule fire inside the worktree, so the spawned agent silently reverts to its harness default account.
When the default account routes through a billing or optimization proxy, that spends the wrong account.

`bin/fm-spawn.sh` closes this gap for `claude` by cascading the spawning firstmate's own account resolution to the launched agent.
The mechanism is owned by that script: the `claude` case in `launch_template()` carries a leading env prefix, and the substitution block resolves it from the spawner's live environment at spawn time.
It has two parts, both per-launch overrides that never touch the operator's global config:

- `CLAUDE_CONFIG_DIR` - set to the spawner's own value, defaulting to claude's own `$HOME/.claude` when unset. Selects the config dir, hence the login.
- `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` - mirrored from the spawner: each is passed through when the spawner has it set, and unset (`env -u`) when the spawner does not.

The second part is required because an exported `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` overrides whatever the config dir's `settings.json` resolves, and the tmux server environment can leak an account-selecting proxy into every pane it spawns.
Setting `CLAUDE_CONFIG_DIR` alone is a no-op for account selection whenever such a var is inherited: the config dir loses to the inherited value.
Mirroring the spawner makes the config dir authoritative for an operator whose own environment has no such var, and preserves a work-scoped or API-key spawner whose environment does.
The value is expanded at spawn time, not left as a literal that a fresh worktree pane's shell would re-resolve to nothing (or to the tmux server's stale copy).

Passing `ANTHROPIC_API_KEY` through on the command line (the pass-through branch) exposes it in `ps`, but only for a spawner that already exports it - the same value is already visible in the tmux server environment via `ps eww`, so there is no net-new exposure. The strip branch removes it entirely.

## Cross-harness compatibility

The gap is a general class: any harness whose account is selected by a directory-scoped convention, or by an env var the pane can inherit from a stale tmux server environment, would be affected the same way.
As of 2026-07-20, only `claude` needs the cascade in this fleet.

- `claude` - AFFECTED and fixed. `CLAUDE_CONFIG_DIR` selects the config dir; the operator has a direnv rule (`~/src/personal/.envrc` exports `CLAUDE_CONFIG_DIR=$HOME/.claude-personal`) that never fires in the worktree, and the tmux server leaks the default config's `ANTHROPIC_BASE_URL` proxy into every pane.
- `codex` - not affected in this fleet. `CODEX_HOME` (default `~/.codex`) is the analogous config-dir selector, but no directory-scoped convention sets it here. If one is added, apply the same env-prefix cascade to the `codex` template.
- `opencode` - not affected in this fleet. Its config/auth dir is the analogous selector; no directory-scoped convention sets it here.
- `pi` - not affected in this fleet. No directory-scoped credential convention in use.
- `grok` - not affected in this fleet. Its config dir is already pinned explicitly per spawn (`GROK_HOME`), and no directory-scoped convention selects a grok account here.

A related but separate leak: `~/src/personal/.envrc` also exports a personal `GH_TOKEN`, which likewise does not reach the worktree.
That is out of scope here because crewmates use `gh-axi` with the fleet's own GitHub auth rather than an inherited `GH_TOKEN`.

## Verification

Environment: 2026-07-20, claude 2.1.215 (Claude Code), spawn worktree `/Users/yewonlee/.treehouse/firstmate-7bab20/4/firstmate` (cwd outside `~/src/personal/`, so the direnv rule does not fire; the spawning firstmate's own scope is `CLAUDE_CONFIG_DIR=$HOME/.claude-personal` with no `ANTHROPIC_*` in its environment).

`~/.claude/settings.json` sets `env.ANTHROPIC_BASE_URL=http://127.0.0.1:8787` (the optimization proxy, which authenticates upstream as the work account), while `~/.claude-personal/settings.json` has no `env` block.

The tmux server environment carries the proxy vars, so every spawned pane inherits them:

```
$ tmux show-environment -g | grep -iE 'ANTHROPIC'
ANTHROPIC_API_KEY=sk-ant-…
ANTHROPIC_BASE_URL=http://127.0.0.1:8787
```

With those vars present (the real pane condition), setting the config dir alone does not change the account - the inherited proxy wins:

```
$ CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude auth status
...
  "apiKeySource": "ANTHROPIC_API_KEY",
  "email": null,
```

Stripping the inherited proxy (what the fix's strip branch emits) makes the personal config dir authoritative:

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

The exact prefix `fm-spawn.sh` emits for this spawner (`env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR='…'`) was confirmed to strip the vars and set the config dir even when both are exported in the pane:

```
$ export ANTHROPIC_BASE_URL='http://leak:8787' ANTHROPIC_API_KEY='sk-leaked-DUMMY'
$ env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR='/Users/yewonlee/.claude-personal' sh -c 'echo "$CLAUDE_CONFIG_DIR ${ANTHROPIC_BASE_URL:-<unset>} ${ANTHROPIC_API_KEY:-<unset>}"'
/Users/yewonlee/.claude-personal <unset> <unset>
```

The launch-string half of the fix - that `fm-spawn.sh` emits this prefix with the spawner's config dir (space-safe), the `$HOME/.claude` default when unset, the `ANTHROPIC_*` pass-through branch when the spawner has them set, and only for the `claude` template - is pinned by `tests/fm-spawn-dispatch-profile.test.sh`.

## Maintaining this file

Record empirical facts, not assumptions: include the date, versions, exact commands, and exact output.
The mechanism itself is owned by `bin/fm-spawn.sh`; keep this file to evidence and cross-harness findings, and point at the script rather than restating its logic.
