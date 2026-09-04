#!/usr/bin/env bash
#
# Regression tests for loop/reclaim-worktree.sh.
#
# Run: sh tests/test-reclaim-worktree.sh
#
# Only the refusals and the dry run are covered, and that is deliberate: the destructive path drops
# Docker volumes and removes a directory, so a test that exercised it would need a daemon and would
# leave the repository's worktree list as its assertion surface. What must not regress is the set of
# paths on which this script does NOTHING -- a caller that passes it a main checkout, or a path in
# another repository, is a caller about to destroy the wrong tree, and the loop's reclaim step runs
# unattended with no one to read a warning.

set -euo pipefail

cd "$(dirname "$0")/.."

RECLAIM="loop/reclaim-worktree.sh"
TMP="$(mktemp -d)"
PROBE="$TMP/wt-probe"

cleanup() {
  git worktree remove --force "$PROBE" >/dev/null 2>&1 || true
  git worktree prune
  rm -rf "$TMP"
}
trap cleanup EXIT

failures=0

check() {
  name="$1"; expected_exit="$2"; shift 2
  set +e
  "$RECLAIM" "$@" >/dev/null 2>&1
  actual_exit=$?
  set -e
  if [ "$actual_exit" != "$expected_exit" ]; then
    printf 'FAIL %-44s exit %s, wanted %s\n' "$name" "$actual_exit" "$expected_exit" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'ok   %s\n' "$name"
}

check "no argument is a usage error" 2
check "an unknown option is a usage error" 2 "." "--nope"
check "an absent path is refused" 3 "$TMP/does-not-exist"
check "a path outside any repository is refused" 3 "$TMP"
check "this main checkout is refused" 3 "."

git worktree add --detach "$PROBE" HEAD >/dev/null 2>&1
check "a linked worktree passes --dry-run" 0 "$PROBE" "--dry-run"

if [ ! -d "$PROBE" ]; then
  echo "FAIL --dry-run removed the worktree it was only supposed to describe" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d test(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nOK -- reclaim-worktree.sh\n'
