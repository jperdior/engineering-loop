#!/usr/bin/env bash
#
# Run the host's per-worktree cleanup, then remove the worktree.
#
# The ORDER is the whole point. A host whose gates leave state named after the worktree's DIRECTORY
# (Docker Compose project names, caches keyed by path) can only clean it up from inside that
# directory while it still exists. LOOP_CLEAN_WORKTREE in the environment names that command; the
# delivery loop exports it from the spec's `_Cleanup:_` line, and a human reclaiming by hand passes
# it the same way. Unset, nothing runs before the removal.
#
# Usage: [LOOP_CLEAN_WORKTREE='make clean-worktree'] reclaim-worktree.sh <worktree-path> [--dry-run]
#
# Exit: 0 reclaimed, 1 the worktree could not be removed, 2 usage, 3 refused.

set -euo pipefail

WT_ARG="${1:-}"
MODE="${2:-run}"

if [ -z "$WT_ARG" ]; then
  echo "usage: reclaim-worktree.sh <worktree-path> [--dry-run]" >&2
  exit 2
fi

case "$MODE" in
  run) dry=0 ;;
  --dry-run) dry=1 ;;
  *) echo "reclaim-worktree: unknown option '$MODE' (expected --dry-run)" >&2; exit 2 ;;
esac

# The repository is the one this is run from; the script itself lives in the plugin, outside any.
if ! cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null; then
  echo "reclaim-worktree: run this from inside the repository that owns the worktree." >&2
  exit 3
fi

LOOP_CLEAN_WORKTREE="${LOOP_CLEAN_WORKTREE:-}"

if [ ! -d "$WT_ARG" ]; then
  echo "reclaim-worktree: no such directory: $WT_ARG" >&2
  exit 3
fi

WT="$(cd "$WT_ARG" && pwd -P)"

# A linked worktree has its own git dir under the shared common dir; the main checkout has the two
# equal. Resolving both through `cd`+`pwd -P` normalises the relative form git returns for the main
# checkout ('.git') against the absolute form it returns for a worktree.
if ! git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "reclaim-worktree: $WT is not inside a git repository -- refusing." >&2
  exit 3
fi

git_dir="$(cd "$WT" && cd "$(git rev-parse --git-dir)" && pwd -P)"
common_dir="$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"

if [ "$git_dir" = "$common_dir" ]; then
  echo "reclaim-worktree: $WT is a main checkout, not a linked worktree -- refusing." >&2
  echo "reclaim-worktree: the cleanup command there would drop that checkout's own caches." >&2
  exit 3
fi

# Reclaiming a worktree of some other repository would run the cleanup command there and remove it
# from its own repository, which is never what a caller in this tree means.
self_common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
if [ "$common_dir" != "$self_common_dir" ]; then
  echo "reclaim-worktree: $WT belongs to a different repository ($common_dir) -- refusing." >&2
  exit 3
fi

MAIN="$(dirname "$common_dir")"

if [ "$dry" = 1 ]; then
  echo "reclaim-worktree: would reclaim $WT"
  [ -z "$LOOP_CLEAN_WORKTREE" ] || echo "  ( cd $WT && $LOOP_CLEAN_WORKTREE )"
  echo "  git -C $MAIN worktree remove --force $WT"
  echo "  git -C $MAIN worktree prune"
  exit 0
fi

if [ -n "$LOOP_CLEAN_WORKTREE" ]; then
  echo "reclaim-worktree: running the host's cleanup in $WT"
  if ! ( cd "$WT" && bash -c "$LOOP_CLEAN_WORKTREE" ); then
    echo "reclaim-worktree: '$LOOP_CLEAN_WORKTREE' failed; whatever it owns survives for now." >&2
  fi
fi

echo "reclaim-worktree: removing $WT"
if ! git -C "$MAIN" worktree remove --force "$WT"; then
  echo "reclaim-worktree: could not remove $WT." >&2
  echo "reclaim-worktree: a gate that ran as root may have left files your user cannot delete." >&2
  echo "reclaim-worktree: Recover with:" >&2
  echo "  sudo rm -rf $WT && git -C $MAIN worktree prune" >&2
  exit 1
fi

git -C "$MAIN" worktree prune
echo "reclaim-worktree: reclaimed $WT"
