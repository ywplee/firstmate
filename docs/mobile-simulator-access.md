# iOS Simulator access from a crewmate worktree

Empirical record showing that an ordinary crewmate shell, spawned the normal way through `bin/fm-spawn.sh`, already has full access to the host's iOS Simulator.
This was investigated after a mobile crewmate reported "this environment has no iOS simulator, Android emulator, or physical device/EAS access" and skipped real visual verification of a UI change, which a later captain review caught as a completely unstyled placeholder screen shipped as done.

## Finding

There is no sandboxing boundary, PATH gap, or worktree-provisioning difference that blocks simulator access.
A crewmate's shell is a normal child process of the operator's own macOS user session, not a container or a separate sandbox: every verified harness firstmate spawns runs with its own approval/sandbox gate turned off (`claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`; `bin/fm-spawn.sh`), so a crewmate's tool calls execute unsandboxed, in the same GUI session as the primary firstmate session, on the same host.
`xcrun simctl`, `open -a Simulator`, and screenshot capture all work out of the box, with no fix needed to the spawn mechanism itself.
This holds for every backend (tmux, herdr, zellij, cmux, Orca) because none of them run the crewmate's shell inside a container, VM, or remote sandbox - see each backend's own doc under `docs/`.

The reported gap was a knowledge gap, not an environment gap: nothing told the crewmate that this access exists, so it assumed (or gave up after one failed attempt) rather than trying `xcrun simctl` the way it would try `chrome-devtools-axi` for a browser.
The fix is documentation plus a one-line pointer in every crewmate brief (`bin/fm-brief.sh`), not a code or sandboxing change.

## Verification

Run 2026-07-21, from inside a real disposable crewmate worktree spawned by `bin/fm-spawn.sh` (task `crewmate-simulator-access`, `claude` harness, `--dangerously-skip-permissions`), not the primary firstmate checkout.

Host: macOS 26.5.1 (build 25F80), Xcode 26.5 (build 17F42), `xcrun` version 72.

List devices:

```
$ xcrun simctl list devices booted
== Devices ==
-- iOS 26.5 --
    iPhone 17 Pro (26.5) (DD74554E-AC18-4B02-838A-9F0038C3F6E5) (Booted)
```

Screenshot an already-booted simulator:

```
$ xcrun simctl io DD74554E-AC18-4B02-838A-9F0038C3F6E5 screenshot sim-screenshot-repro.png
Wrote screenshot to: sim-screenshot-repro.png
$ file sim-screenshot-repro.png
sim-screenshot-repro.png: PNG image data, 1206 x 2622, 8-bit/color RGBA, non-interlaced
```

Boot a previously shutdown device from scratch (not reusing a device the primary session had already booted), screenshot it, then shut it back down:

```
$ xcrun simctl boot 46150402-91F0-42AA-8FE5-1E90196A73E0
$ xcrun simctl list devices | grep 46150402
    iPhone 16e (46150402-91F0-42AA-8FE5-1E90196A73E0) (Booted)
$ xcrun simctl io 46150402-91F0-42AA-8FE5-1E90196A73E0 screenshot sim-fresh-boot.png
Wrote screenshot to: sim-fresh-boot.png
$ xcrun simctl shutdown 46150402-91F0-42AA-8FE5-1E90196A73E0
$ xcrun simctl list devices | grep 46150402
    iPhone 16e (46150402-91F0-42AA-8FE5-1E90196A73E0) (Shutdown)
```

Every step above ran with no elevated permission, no host-level setup, and no PATH adjustment beyond what the crewmate shell already inherits.

## Android: not verified, host tooling absent

This host has no Android SDK installed at all: `adb`, `emulator`, and `avdmanager` are all missing from `PATH`, and `~/Library/Android/sdk` does not exist.
This is a host-level tooling gap that predates and is unrelated to crewmate spawning - the primary firstmate session has the identical gap, since the reasoning above (unsandboxed child process, shared GUI session) applies equally to Android tooling once it is installed.
Installing the Android SDK is a substantial, disk-heavy host change; treat it as a separate captain decision rather than something to silently provision from a task.

## Guidance for crewmates doing mobile UI work

Do not assume simulator or device access is unavailable.
Boot or reuse a simulator with `xcrun simctl`, install and launch the app through the project's own tooling (for example `expo run:ios` or `xcodebuild`), and capture a real screenshot with `xcrun simctl io <device> screenshot <path>` before reporting UI work done - the same expectation `chrome-devtools-axi` sets for web UI work.
`bin/fm-brief.sh`'s generated Rules section points every ship/scout crewmate back to this document.
