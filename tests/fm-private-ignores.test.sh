#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-private-ignores)
git -C "$TMP_ROOT" init -q
cp "$ROOT/.gitignore" "$TMP_ROOT/.gitignore"
failed=0
for path in .env data/probe state/probe config/probe projects/probe .no-mistakes/probe \
  treehouse.toml .claude/settings.local.json; do
  if ! git -C "$TMP_ROOT" -c core.excludesFile=/dev/null check-ignore --no-index -q "$path"; then
    printf 'unprotected: %s\n' "$path"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || fail 'shared ignore rules expose private paths in a new checkout'
pass 'shared ignore rules protect private home paths and local tool settings in a new checkout'
