#!/usr/bin/env bash
# Opt-in native Codex queue proof on one disposable daemon and exact task pane.
set -eu
if [ "${FM_CODEX_QUEUE_LIVE_E2E:-0}" != 1 ]; then
  printf 'skip - set FM_CODEX_QUEUE_LIVE_E2E=1 with explicit personal CLI/daemon binaries and source account home\n'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FM_CODEX_QUEUE_LIVE_CLI:?select the exact native CLI}"
: "${FM_CODEX_QUEUE_LIVE_DAEMON:?select the exact native daemon}"
: "${CODEX_HOME:?select the personal account home}"
: "${FM_CODEX_QUEUE_LIVE_EVIDENCE:?select an evidence directory}"
python3 "$ROOT/tests/fm-codex-queue-live-e2e.py" "$ROOT"
