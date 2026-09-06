#!/usr/bin/env bash
#
# Measure a delivery unit. Reports, never gates.
#
# Prints the tick's measurement fields in the order the ledger records them:
#
#     L lines (I impl + T test), F files, C% comments, K ctx
#
#   L  reviewable lines: insertions + deletions, minus generated files nobody reads.
#   F  files, after the same exclusions.
#   C  the comment ratio, from comment-ratio.sh.
#   K  context-bearing lines: additions to `.ai/**` and any `AGENTS.md`. Every agent loads those on
#      every run, so they cost context forever rather than once. They are not excluded from L.
#
# No number here bounds anything. What drives a session's cost is how much of the tree it must read,
# and the delivery loop bounds that by handing each session one phase.
#
# The exclusions are `:(top,exclude)` pathspecs: a plain `:(exclude)` is cwd-relative and silently
# stops matching when the script is called from a subdirectory.
#
# Usage: unit-size.sh [base]   -- base defaults to origin/main.
#
# Exit: 0 whatever the size, 1 the base ref cannot be resolved.

set -euo pipefail

BASE="${1:-origin/main}"

LOOP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$(git rev-parse --show-toplevel)"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "unit-size: cannot resolve base ref '$BASE' -- fetch it first (CI needs fetch-depth: 0)." >&2
  exit 1
fi

# The diff is BASE...HEAD, so uncommitted work is invisible to it. Mid-phase that is the normal
# state, and a silent "0 lines" would read as "nothing was built" at exactly the checkpoint meant to
# catch a unit growing.
if [ -n "$(git status --porcelain)" ]; then
  echo "unit-size: the working tree is dirty; only committed work is measured (${BASE}...HEAD)." >&2
fi

# Lockfiles, generated files and the spec itself are never reviewable lines. The host adds its own
# generated paths through LOOP_SIZE_EXCLUDES (space-separated pathspecs, in the committed
# .loop/host.env, or failing that .loop/loop.env).
EXCLUDES=(
  ':(top,exclude)*.lock'
  ':(top,exclude)*-lock.json'
  ':(top,exclude)*-lock.yaml'
  ':(top,exclude)*.gen.*'
  ':(top,exclude).ai/specs/**.md'
)
for env_file in "$LOOP_DIR/host.env" "$LOOP_DIR/loop.env"; do
  [ -n "${LOOP_SIZE_EXCLUDES:-}" ] && break
  [ -f "$env_file" ] || continue
  LOOP_SIZE_EXCLUDES="$(sed -n 's/^LOOP_SIZE_EXCLUDES=//p' "$env_file" | head -1)"
done
for g in ${LOOP_SIZE_EXCLUDES:-}; do
  EXCLUDES+=(":(top,exclude)$g")
done

# A binary file reports `-` for both counts. It contributes a file and no lines.
read -r LINES FILES <<EOF
$(git diff --numstat "$BASE...HEAD" -- ':(top)' "${EXCLUDES[@]}" \
  | awk '{ files++; if ($1 != "-") lines += $1 + $2 } END { printf "%d %d\n", lines + 0, files + 0 }')
EOF

CTX="$(git diff --numstat "$BASE...HEAD" -- ':(top).ai/*' ':(top)*AGENTS.md' \
  | awk '{ if ($1 != "-") ctx += $1 } END { printf "%d\n", ctx + 0 }')"

# Implementation and test lines are reported apart because a reviewer does not read them the same
# way: implementation is followed line by line, a suite is read for whether it covers the right
# things. Neither bounds anything.
TESTS="$(git diff --numstat "$BASE...HEAD" -- \
    ':(top)tests' ':(top)*/tests/*' ':(top)*/test/*' ':(top)*Test.*' ':(top)*_test.*' \
    ':(top)*__tests__/*' ':(top)*.test.*' ':(top)*.spec.*' \
  | awk '{ if ($1 != "-") t += $1 + $2 } END { printf "%d\n", t + 0 }')"
IMPL=$((LINES - TESTS))

COMMENTS="$("$LOOP_DIR/comment-ratio.sh" "$BASE")"

printf '%d lines (%d impl + %d test), %d files, %d%% comments, %d ctx\n' \
  "$LINES" "$IMPL" "$TESTS" "$FILES" "$COMMENTS" "$CTX"

