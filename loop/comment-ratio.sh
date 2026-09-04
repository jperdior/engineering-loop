#!/usr/bin/env bash
#
# What percentage of a branch's ADDED lines are prose comments. Prints one integer, nothing else.
#
# `unit-size.sh` shells out to this rather than carrying its own copy of the classifier, so the
# definition of "a prose comment" exists once.
#
# Scope is `*.php`, `*.ts` and `*.tsx` -- the languages the no-prose convention actually binds. Shell
# and the Makefile are excluded on purpose: their comments are carved out of that convention entirely,
# and counting them would penalise a unit for comments it is meant to write. Every script in this
# directory would otherwise score near 100%.
#
# The numerator is prose. It is NOT:
#
#   - `@param` / `@return` / `@var` / `@throws` lines. Those are type information, and a number that
#     treats a PHPStan array shape as narration measures the wrong thing.
#   - A comment line with no content: `/**`, `*/`, a bare ` *`, a bare `//`.
#
# It IS a one-line `// see RULE-ID` pointer, deliberately. A host may permit that form, but this is a report
# rather than a gate, and a rule that excluded it would need to know which identifiers are real.
#
# The classifier is line-based, on added lines seen without their surrounding file, because that is all
# a diff offers. A `//` inside a string literal at the start of a line counts as a comment; a run of
# prose in the middle of a block whose opening line was not added does not. Both are rare and both move
# the number by one line.
#
# `#[Attribute]` is not a comment. `#` followed by anything else is.
#
# The generated TS client is excluded, the one file `unit-size.sh` excludes that is also in scope
# here. It is thousands of lines carrying neither prose nor reviewable code, so leaving it in the
# denominator drives the ratio to zero on exactly the units large enough for it to matter -- any unit
# that regenerates the client. The two scripts then disagree about which files the unit consists of.
#
# Usage: comment-ratio.sh [base]   -- base defaults to origin/main.
#
# Exit: 0 always, unless the base ref cannot be resolved (1).

set -euo pipefail

BASE="${1:-origin/main}"

LOOP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$(git rev-parse --show-toplevel)"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "comment-ratio: cannot resolve base ref '$BASE' -- fetch it first (CI needs fetch-depth: 0)." >&2
  exit 1
fi

git diff "$BASE...HEAD" -- \
  ':(top)*.php' ':(top)*.ts' ':(top)*.tsx' ':(top)*.js' ':(top)*.jsx' ':(top)*.py' ':(top)*.go' \
  ':(top)*.rs' ':(top)*.java' ':(top)*.kt' ':(top)*.swift' ':(top)*.rb' ':(top)*.cs' \
  ':(top,exclude)*.gen.*' | awk '
  /^\+\+\+/ { next }
  !/^\+/    { next }

  {
    line = substr($0, 2)
    sub(/^[[:space:]]+/, "", line)
    if (line == "") next
    added++

    if (line !~ /^(\/\/|\/\*|\*|#[^[])/ && line != "#") next

    content = line
    sub(/^[\/*]+/, "", content)
    sub(/^#/, "", content)
    sub(/\*\/[[:space:]]*$/, "", content)
    sub(/^[[:space:]]+/, "", content)
    sub(/[[:space:]]+$/, "", content)

    if (content == "") next
    if (content ~ /^@(param|return|var|throws)([[:space:]]|$)/) next
    prose++
  }

  END {
    if (added == 0) { print 0; exit }
    printf "%d\n", int(prose * 100 / added)
  }
'
