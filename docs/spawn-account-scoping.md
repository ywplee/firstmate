# Spawn account scoping

Firstmate launches every crewmate and secondmate agent inside a disposable worktree (a `~/.treehouse/...` pool path or an Orca-managed worktree), which is outside the operator's normal source tree.
An operator who selects an account per directory - for example a direnv rule that exports a per-account config dir only under `~/src/personal/` - never has that rule fire inside the worktree, so the spawned agent silently reverts to its harness default account.
When the default account routes through a billing or optimization proxy, that spends the wrong account.

`bin/fm-spawn.sh` closes this gap for `claude` by cascading the spawning firstmate's own account resolution to the launched agent.
The mechanism is owned by that script: the `claude` case in `launch_template()` carries a leading env prefix, resolved in the substitution block at spawn time.
It has two parts, both per-launch overrides that never touch the operator's global config:

- `CLAUDE_CONFIG_DIR` - set to the spawner's own value (captured from the spawner's environment and expanded at spawn time, not left as a literal a fresh worktree pane would re-resolve to nothing), defaulting to claude's own `$HOME/.claude` when unset. Selects the config dir, hence the login. This is the sole account selector.
- `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` - always stripped with a static `-u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY`, never read from any environment.

The second part is required because an exported `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` overrides whatever the config dir's `settings.json` resolves, and the tmux server environment can leak an account-selecting proxy into every pane it spawns.
Setting `CLAUDE_CONFIG_DIR` alone is a no-op for account selection whenever such a var is inherited: the config dir loses to the inherited value, so the stale copy must be cleared for the config dir to win.
Since the operator's stated policy is subscription-only (no API key in use), stripping both unconditionally is correct and makes the config dir authoritative in every case.
Because the prefix never reproduces a real key value on the command line, it also removes the `ps`-visibility exposure the earlier pass-through branch carried.

## Why the earlier conditional pass-through was abandoned

The first version of this fix (commits `a42f264`, `9b5a253`, `c7906ea`) did not strip unconditionally.
It mirrored the spawner: pass each var through when the spawner's shell had it set, `-u` it when the spawner's shell did not.
That reads the environment of whatever shell is executing `fm-spawn.sh` - and that reading is not trustworthy.

When firstmate (or a secondmate) invokes `fm-spawn.sh` through Claude Code's Bash tool, that shell is a fresh, non-interactive `/bin/zsh -c '...'`.
zsh unconditionally sources `~/.zshenv` on every invocation regardless of interactivity, and the operator's `~/.zshenv` unconditionally exports a work-scoped `ANTHROPIC_API_KEY`.
Claude Code's Bash tool also replays a shell snapshot that restores variables present in the original top-level session (e.g. a correctly-personal-scoped `CLAUDE_CONFIG_DIR`), but that snapshot does not proactively clear a variable that was absent in the original session yet gets freshly re-injected by `~/.zshenv`'s own export in the nested shell.

Net effect, reproduced live: even when the genuine top-level firstmate/secondmate process is clean (`ps eww` on it shows only `CLAUDE_CONFIG_DIR`, no `ANTHROPIC_API_KEY`), a plain `fm-spawn.sh ... ` run through that agent's own Bash tool sees `ANTHROPIC_API_KEY` as set - re-injected by the nested shell's own `~/.zshenv` - and the conditional pass-through cascaded the work key to the child, silently defeating the fix.
The re-injected value is indistinguishable from a real setting, so no per-var read can be trusted.
Stripping both unconditionally removes the dependency on reading those two vars from any shell, which is why the conditional design was dropped.

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

The exact prefix `fm-spawn.sh` emits (`env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR='…'`) was confirmed to strip the vars and set the config dir even when both are exported in the pane:

```
$ export ANTHROPIC_BASE_URL='http://leak:8787' ANTHROPIC_API_KEY='sk-leaked-DUMMY'
$ env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR='/Users/yewonlee/.claude-personal' sh -c 'echo "$CLAUDE_CONFIG_DIR ${ANTHROPIC_BASE_URL:-<unset>} ${ANTHROPIC_API_KEY:-<unset>}"'
/Users/yewonlee/.claude-personal <unset> <unset>
```

The launch-string half of the fix - that `fm-spawn.sh` emits the static `-u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY` strip prefix and the spawner's config dir (space-safe, `$HOME/.claude` default when unset), carries neither `ANTHROPIC_*` value regardless of the spawner's shell state, and only for the `claude` template - is pinned by `tests/fm-spawn-dispatch-profile.test.sh`.

### End-to-end verification of the unconditional strip

Environment: 2026-07-20, claude 2.1.215 (Claude Code), tmux backend. This is the false-negative-resistant test: a plain, unwrapped `bin/fm-spawn.sh` run through the agent's own Bash tool (the exact nested-shell path that motivated the fix), inspected via `ps eww` on the real spawned process - not a `claude auth status` call inside the spawned agent, which suffers the identical nested-shell contamination and would mislead.

The invoking Bash-tool shell was contaminated exactly as described above - `ANTHROPIC_API_KEY` re-injected by `~/.zshenv`, `CLAUDE_CONFIG_DIR` correctly personal:

```
$ echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+<SET>} CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
ANTHROPIC_API_KEY=<SET> CLAUDE_CONFIG_DIR=/Users/yewonlee/.claude-personal
```

A plain scout spawn (no `env -u` wrapper, no `direnv exec`) into an isolated scratch home launched a real claude, whose actual environment shows both `ANTHROPIC_*` vars stripped and only the personal config dir set:

```
$ FM_HOME="$SCRATCH" bin/fm-spawn.sh envtest-scout-z9 /Users/yewonlee/src/personal/firstmate claude --scout
spawned envtest-scout-z9 harness=claude kind=scout ... worktree=/Users/yewonlee/.treehouse/firstmate-7bab20/5/firstmate

$ ps eww -p <spawned-claude-pid> | tr ' ' '\n' | grep -E '^(ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|CLAUDE_CONFIG_DIR)='
CLAUDE_CONFIG_DIR=/Users/yewonlee/.claude-personal
# ANTHROPIC_API_KEY: ABSENT
# ANTHROPIC_BASE_URL: ABSENT
```

Under the abandoned conditional pass-through, the same contaminated invoking shell would have emitted `ANTHROPIC_API_KEY='sk-…'` into the launch and the child would have carried the work key; the static strip makes the child clean regardless.

Note (2026-07-20): tearing the test scout down with `treehouse return` triggered a treehouse pool-wide reconciliation that detached and reset every sibling pool worktree, including an unrelated active worktree, discarding its uncommitted edits. `treehouse return` (and therefore `bin/fm-teardown.sh`, which calls it) is not safe to run while any sibling pool worktree has unlanded work. This is a treehouse behavior, outside firstmate's own tracked scripts.

## Maintaining this file

Record empirical facts, not assumptions: include the date, versions, exact commands, and exact output.
The mechanism itself is owned by `bin/fm-spawn.sh`; keep this file to evidence and cross-harness findings, and point at the script rather than restating its logic.
