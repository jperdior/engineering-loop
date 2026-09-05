#!/usr/bin/env bash
#
# What percentage of a branch's added lines are prose comments. Prints one integer, nothing else.
# `unit-size.sh` shells out to this so the definition of "a prose comment" exists once.
#
# Scope: the common application languages (see the pathspecs below). Shell and Makefiles are left
# out because their comments are conventionally where the reasoning lives.
#
# The numerator is prose. It excludes `@param` / `@return` / `@var` / `@throws` lines, which are type
# information, and empty comment lines (`/**`, `*/`, a bare ` *` or `//`). `#[Attribute]` is not a
# comment; `#` followed by anything else is.
#
# The classifier is line-based on added lines without their surrounding file, because that is all a
# diff offers. A `//` inside a string literal at the start of a line counts; prose in the middle of a
# block whose opening line was not added does not. Both are rare and move the number by one line.
#
# Generated files (`*.gen.*`) are excluded, matching `unit-size.sh`, so the two scripts agree about
# which files the unit consists of.
#
# Usage: comment-ratio.sh [base]   -- base defaults to origin/main.
#
# Exit: 0 always, unless the base ref cannot be resolved (1).

set -euo pipefail

BASE="${1:-origin/main}"

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
