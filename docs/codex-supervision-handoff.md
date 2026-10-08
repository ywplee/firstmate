# Codex supervision support

A daemon-backed Codex CLI coordinator can receive post-final input through its native queue while retaining its current terminal and home owner.
The original environment was Warp Terminal with Codex CLI, not Codex Desktop; daemon ancestry alone does not identify the host.
An addressable tmux coordinator remains an alternative using the existing pane transport.
Neither route adds a worker-spawn runtime backend or a verified Desktop bridge.

## Native daemon queue

`bin/fm-codex-queue.py` owns binding, command syntax and private receipt fields.
Run its `bind` action from the owning coordinator's tool context with explicit `FM_HOME`, `CODEX_HOME` and the inherited exact `CODEX_THREAD_ID`.
The binding requires an identity-backed home lock, the same native thread's rollout working root and `danger-full-access/never` context, a live CLI and managed daemon, and a private Unix socket held by that daemon.
It captures executable hashes and process/socket identities and refuses replacement, ambiguous sockets, a different home/thread, legacy PID-only locks or unverified versions without clearing any lock.
An explicit-remote fixture must supply `FM_CODEX_QUEUE_CLI_PID` and `FM_CODEX_QUEUE_SOCKET`; the automatic CLI/daemon path uses the daemon's parent CLI and its unique owned socket.
No login, package installation, default endpoint or daemon startup is part of this helper.

After binding, the existing AFK launcher can select `codex-queue` from an explicit supervisor override or from the native thread/account environment when no supported pane marker takes precedence.
It hosts the existing supervisor in a detached tmux session, leaving the CLI, its daemon and home ownership unchanged.
Only the recorded supervisor singleton submits escalations; ordinary worker-spawn backends and pane transports retain their existing contracts.
The helper records a pending snapshot before one `codex queue --remote unix://PATH --thread UUID --message TEXT` invocation.
It requires a matching native user-input record, its turn start and the same turn's completion before consuming that snapshot's buffer prefix and recording a receipt.
Later buffered events survive that reconciliation.
Queue exit zero means acceptance, never handling.
An ambiguous timeout or failure remains pending and is not blindly resent after restart; existing bounded wedge alarms surface absent handling.
This provides at-most-once submission attempts with durable ambiguous outcomes, rather than claiming server-side exactly-once execution.

The native queue bypasses terminal keystrokes and the pane composer guard; its busy ordering and draft preservation require native fixture evidence for the supported version pair.
Normal return stops supervision first, forbids new native submissions once catch-up starts, and reconciles any outstanding handling receipt before closing the return gate.
A replaced daemon/CLI or unresolved pending submission requires explicit owner reconciliation, not automatic rebinding or lock deletion.
Archive a stale binding and pending evidence only after the owning Firstmate has classified the original event, retained its durable wake and confirmed that replay cannot duplicate already handled work.
The helper does not repair that ambiguity automatically.

### Native evidence and current limits

On 2026-10-08, native CLI `0.160.1` and managed app-server `0.161.0` handled an isolated post-final queue event on an owned Unix endpoint.
The actual Warp coordinator also received a distinct native turn at `13:44:04.547Z`, after its preceding turn completed at `13:44:04.535Z`, and acknowledged the marker.
Those probes establish native transport viability, not current integration readiness or overnight continuity.
The native app-server surface is experimental; other version pairs are refused until verified.

The integration's first bounded live fixture failed before binding because its scratch shell selected an asdf `python3` shim without a configured version.
A single command correction was accepted after the fixture's readiness deadline had already begun CLI cleanup; its binding correctly refused the departed CLI PID.
No current-helper post-final, busy, draft or restart handling result is claimed from that initial fixture.
A corrected fixture bound its native target and started the supervisor, but the normal90-second batching interval exceeded its idle handling deadline.
The exact current helper queued a real post-final event at14:19:59.033Z, with native completion at14:20:06.237Z and marker `HANDLED_idle` during cleanup.
The supervisor had stopped before completion, leaving its pending journal unreconciled; CLI and daemon exited0.
That partial handling observation does not convert the failed fixture to a pass or establish busy, draft, duplicate or restart handling.
The preserved source hashes, native rollout, true command results and cleanup evidence distinguish this failure from the earlier transport probes.
Run deterministic coverage with `bin/fm-test-run.sh tests/fm-codex-queue.test.sh`.
The opt-in native fixture is `tests/fm-codex-queue-live-e2e.test.sh`; its required environment is declared in that script.
Select a runnable Python interpreter in the fixture shell, including an explicit task-local `ASDF_PYTHON_VERSION` when using asdf.
Do not proceed through a new trust/login prompt or count acceptance as handling.
Current-source isolated handling proof and a later owner-controlled real-home readiness event remain required before production adoption.

## Alternative terminal launch and preflight

`bin/fm-codex-supervisor.sh --help` owns the command syntax.
Run `launch` from a dedicated existing tmux shell with explicit `FM_HOME`, `CODEX_HOME`, model, reasoning effort, sandbox mode and approval policy.
For example, after the previous owner has exited:

```sh
FM_HOME="$OPERATIONAL_HOME" CODEX_HOME="$ACCOUNT_HOME" \
  bin/fm-codex-supervisor.sh launch \
  --model "$AUTHORIZED_MODEL" --effort "$AUTHORIZED_EFFORT" \
  --sandbox danger-full-access --ask-for-approval never
```

This route requires unrestricted filesystem access and `never` approval; other permission policies are refused.
The helper requires an explicit model and effort rather than inheriting account defaults or pinning a model in the shared template.
The helper supplies root `--no-daemon` on both its capability probe and launch, and uses the installed CLI without installing configuration or changing credentials.
Its default prompt tells the successor to run normal session-start, reconcile recorded work, run `preflight`, and enter the existing AFK skill.
A custom prompt must preserve those duties; the disposable verification prompt deliberately uses only scratch lock acquisition and acknowledgement.

Launch refuses an existing agent pane, another socket or pane, an unrelated process ancestry, a live coordinator lock, a live daemon, and an unfinished away-mode lifecycle.
It also refuses an identity-matched live watcher for the same home, even from another checkout or symlink path.
Recycled supervision PIDs and a standalone stale daemon pidfile do not establish live ownership.
It leaves old lock and queue records for normal session-start recovery.
Preflight verifies the exact pane/socket, the live lock identity in its process ancestry, and a Codex process launched with `--no-daemon`, an explicit model and an explicit reasoning effort.
For the authorized personal rollout, its output must identify `/Users/yewonlee/.codex-personal`, `model=gpt-6.1-sol` and `effort=high`.
It reports process and ownership checks, never delivery readiness.
The permission context must allow `ps` and tmux inspection; a tested macOS `workspace-write` context denied `ps`, so that context could not pass ownership verification.
During scratch verification, stop immediately on any new directory, configuration or hook trust dialog or login prompt, and retain the evidence without accepting it.
For operational trust handling, the owning Firstmate follows `harness-adapters`; trust waiting is a distinct startup state.

## Orderly transfer

The owning Firstmate controls production rollout and merge authority.
Keep its foreground checkpoint loop running while preparing the transfer.

1. Persist the current authority, pending decisions, tasks and dependency pointers in the operational home.
   Quiesce coordinator actions while preserving worker endpoints and unlanded work.
2. Have the current owner close its away-mode lifecycle through the existing return/catch-up owner when applicable, and finish its foreground checkpoint.
   Confirm its recorded watcher and daemon have stopped before transfer.
3. Arrange an orderly exit of the exact process named by the old lock.
   Desktop may use a shared app-server process: closing one thread or window does not establish process exit, and exiting the shared host requires human coordination with its other sessions.
   If that process remains alive, stop the migration and keep the successor read-only.
   Never delete the lock, manufacture a thread-only release, or kill a shared server to get past this boundary.
4. Launch one successor in the dedicated tmux shell with the same operational home, account, explicitly authorized model and effort, permissions and decision authority.
   Its normal session-start must acquire the home and reconcile the durable queue before it performs fleet actions.
   A competing launch or failed preflight stops the transfer; do not launch a second contender to repair it.
5. In the successor, run preflight and follow the AFK skill's terminal launch path, pinned to this exact coordinator.
   Let the existing daemon own the watcher rather than arming another one.
6. After the coordinator reaches a final idle response, submit a uniquely identified harmless event through the home's ordinary status/queue path.
   Require a new turn in the same coordinator and its durable handling acknowledgement, plus the exact target and lock identity, before claiming unattended delivery for this rollout.
   A live PID, heartbeat, empty composer or empty queue does not establish handling.

This is a serialized process-exit transfer using the existing lock contract.
It does not support simultaneous authority in Desktop and terminal sessions or atomic concurrent launch arbitration.
No production transfer was performed during implementation.

## Rollback

Have the terminal owner run the existing AFK return/catch-up procedure and persist any pending decisions and queued work.
Once its daemon and watcher have stopped, exit the terminal Codex process and confirm the exact lock holder is dead.
The Desktop coordinator may then run normal session-start to acquire and reconcile the home and resume its foreground checkpoint loop.
If the terminal process remains alive, the Desktop coordinator stays read-only.
Retain the queue, lock identity and task records throughout rollback; no manual lock deletion or worker teardown is part of this procedure.

## Verification and limits

On 2026-10-08, personal Codex CLI `0.160.1` with `--no-daemon --sandbox danger-full-access --ask-for-approval never` and tmux `3.6a` handled real events through the original helper in an isolated home and private socket.
The tested helper SHA-256 was `2ae727933efa21bdfa4891981509bc0044fa2cd2c46ddaebb5dd8e3e6c582803`.
The launcher SHA-256 was `e3cd692fcf146c81e45b59bc4ff97fe03d8d69d13b24d50cf1712405b16b8645`.
The model's handling files and native TUI transcripts establish these results:

| Property | Observed result |
| --- | --- |
| Post-final wake | Native owner PID `36671`, pane `%0`: final `SMOKE_IDLE`, event `current-helper-post-final-20261008`, new turn, handling file, final `SMOKE_HANDLED` |
| Composer safety | Partial draft preserved; event buffered; durable wedge reported `3s undelivered`; clearing the draft led to handling |
| Busy safety | A real foreground `sleep 12` deferred the event while busy; its handling file appeared after the turn completed |
| Exclusive transfer | A contender refused while PID `36671` owned the lock; only after its normal exit did successor PID `87966` acquire and pass preflight |
| Recovery | Queue record and status written with the old coordinator and daemon stopped; successor thread handled `current-helper-recovered-20261008` after restart |

These original-helper results are separate from an earlier manual terminal wake proof and from failed automated startup fixtures.
The opt-in one-shot fixture repeatedly displayed `Killed: 9` before inference, including when resolving the same CLI installation directly.
An external process sample observed the owned launch PID already dead at 2.542 seconds while the fixture was still alive; cleanup followed its failure, and neither the 120-second readiness deadline nor the 150-second external deadline was reached.
Recreating its saved launcher independently reached native directory trust and then the successful original-helper checks above.
The automated server creation/startup discrepancy remains unresolved, and that complete fixture is not reported as passing.
macOS policy warnings occurred on both failed and successful launches and do not establish the kill source.
Private task evidence retains source hashes, launch arguments, process ancestry, lock records, queue records, handling files and both successful and failed transcripts.
Review corrections changed the helper's launch arguments, preflight and ownership checks after that recorded source hash.
Fresh live proof using the corrected helper and the authorized personal `gpt-6.1-sol`/`high` launch is required before readiness claims; the original-helper observations do not establish corrected-source delivery.

Run the deterministic helper test with `bin/fm-test-run.sh tests/fm-codex-supervisor.test.sh`.
The credentialed opt-in fixture is `FM_CODEX_SUPERVISOR_LIVE_E2E=1 CODEX_HOME=/Users/yewonlee/.codex-personal bin/fm-test-run.sh tests/fm-codex-supervisor-live-e2e.test.sh`; it launches `gpt-6.1-sol` with `high` effort, creates disposable homes and a private tmux socket, retains evidence, and must fail when startup or handling is not proven.
The existing checkpoint, wake lifecycle, daemon and composer suites provide additional isolated coverage; simulated composers are not current Codex delivery proof.

The new helper supports tmux primary hosting only.
Existing tmux and Herdr AFK launch paths and the Claude, Codex, OpenCode, Pi and Grok foreground/native protocols retain their behavior.
Zellij, Orca and cmux remain outside the existing daemon's supported supervisor backends, regardless of their worker-spawn support.
Desktop remains without a verified same-coordinator post-final wake route in this environment.
No Desktop unattended claim, overnight-duration proof, operating-system sleep/wake guarantee or live-home rollout follows from these scratch results.
