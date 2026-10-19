# Mobile simulator access

Mobile UI work must check the tools available on the host executing the worker's shell before declaring simulator access unavailable.
A disposable worktree alone does not establish a simulator or device access restriction.

On macOS with Xcode installed, inspect available simulators with `xcrun simctl list devices` and use the project's own build and install commands.
Capture the running UI with `xcrun simctl io <simulator-udid> screenshot <path>` before reporting a visual result.
Follow the task's simulator ownership and restoration requirements when starting or stopping a simulator.

A remote worker runs on its remote host, which may lack macOS, Xcode, or the operator's devices.
Report that host's observed limitation and the validation still needed instead of claiming a simulator result.
Physical phones require their own explicit device authorization and reservation; simulator access provides neither.

Android tooling depends on the executing host's SDK installation and the task's named device.
Report missing tooling accurately and keep any host installation or device action within the task's authorization.
