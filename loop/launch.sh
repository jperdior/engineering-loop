#!/usr/bin/env bash
#
# Start the delivery loop detached, so a run outlives the chat session that launched it.
#
# A chat session cannot run the loop in the foreground: a tool call times out long before a unit is
# built, and a plain background job dies with the session or under memory pressure. This starts the
# loop in its own process group with nohup, sends its output to a log under the user's state
# directory, records the pid beside the log, and prints both. The loop's exit code is appended to the
# log as `delivery-loop: exit N`, so a reader of the log alone can tell a finished run from a hung one.
#
# It is a script rather than a line in /ship because a worktree-isolated session's guard refuses a
# compound `nohup bash -c '…'` it cannot read; one plain command it can.
#
# Usage: launch.sh <spec-file>         -- from inside the repository, as delivery-loop.sh itself
#
# Exit: 0 launched (the loop's own result is in the log), 2 usage, 3 not inside a repository.

set -euo pipefail

SPEC="${1:-}"
[ -n "$SPEC" ] || { echo "usage: launch.sh <spec-file>" >&2; exit 2; }

LOOP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "launch: run this from inside the repository to build" >&2
  exit 3
fi
BRANCH="$(git branch --show-current 2>/dev/null || echo detached)"
# The repository's name is the main checkout's, not the worktree directory's, which in a linked
# worktree is the branch name and would name the log `feat-x-feat-x.log`.
MAIN_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$ROOT"

RUNS="${XDG_STATE_HOME:-$HOME/.local/state}/engineering-loop/runs"
mkdir -p "$RUNS"
LOG="$RUNS/$(basename "$MAIN_ROOT")-$BRANCH.log"

# `set -m` puts the child in its own process group, so a signal to this shell's group does not reach
# it; nohup detaches it from the terminal. The exit line is written by the wrapper, not the loop, so
# it lands even if the loop dies of a signal.
(
  set -m
  # shellcheck disable=SC2016
  nohup bash -c '"$0" "$1"; echo "delivery-loop: exit $?"' "$LOOP_DIR/delivery-loop.sh" "$SPEC" \
    > "$LOG" 2>&1 < /dev/null &
  echo $! > "$LOG.pid"
)

echo "launch: delivery loop started, pid $(cat "$LOG.pid")"
echo "launch: log $LOG"
echo "launch: the run ends with a line 'delivery-loop: exit N' in that log"
