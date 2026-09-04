#!/usr/bin/env bash
#
# Parse a spec's checklists into one machine-readable row per entry.
#
#   parse-ledger.sh <spec>            the `## Delivery` ledger:  done|unit|branch
#   parse-ledger.sh <spec> --phases   the `## Progress` checklist: done|phase|title
#
# Called by: /implement-spec and /archive-spec (which unit is this branch, is anything still owed),
# and the delivery loop (which unit to build, which phase to hand the next session). One grammar,
# one implementation, so the three cannot drift.
#
# `done` is `x` or a space. A ledger row's `unit` is the PR label (`PR 1`) and `branch` the unit's
# branch -- the first backticked name after the label. A phase row's `phase` is the label
# (`Phase 2`) and `title` the text after it, with the leading dash stripped.
#
# The grammar is fussy for reasons that are all real specs seen in this repo:
#
#   - The section is bounded on `#{1,4}` AFTER tolerating leading whitespace: a live spec has a
#     ` ## New business rules` heading with a leading space, which a `/^## /` bound never resets on,
#     so the section ran to the end of the file.
#   - Fenced blocks are skipped. Specs demonstrate this very grammar inside markdown fences, and an
#     example parsed as a real entry becomes a phantom branch somebody tries to build. A fence
#     delimiter is backticks plus an optional language tag and NOTHING else: a prose line containing
#     an inline code span has a second run of backticks on it, and treating that as a delimiter flips
#     the fence state for the rest of the file.
#   - An entry must carry its bold label (`**PR `, `**Phase `), so a checkbox inside a `### PR N`
#     prose subsection is not an entry, and a free-form `- [ ] remember to …` note is not a phase.
#
# Every UNINDENTED checkbox inside the section is counted against the rows emitted. A one-character
# typo -- `* [ ]` for `- [ ]`, a missing label -- would otherwise drop an entry silently, and an
# unattended caller would simply never build it. Indented checkboxes are exempt: a nested sub-item
# under an entry is ordinary markdown.
#
# A section that yields NO entries at all is the same failure one step further on: exit 0 with no
# output would leave the delivery loop iterating an empty list and reporting success having built
# nothing -- silence read as "there was nothing to do". So zero entries in a section that exists is
# exit 3, like any other malformed section.
#
# Exit: 0 parsed, 2 usage, 3 the section is malformed or absent.

set -euo pipefail

SPEC=""
SECTION="Delivery"
LABEL="PR"

while [ $# -gt 0 ]; do
  case "$1" in
    --phases) SECTION="Progress"; LABEL="Phase" ;;
    -*)       echo "parse-ledger: unknown option '$1'" >&2; exit 2 ;;
    *)        [ -z "$SPEC" ] || { echo "usage: parse-ledger.sh <spec-file> [--phases]" >&2; exit 2; }; SPEC="$1" ;;
  esac
  shift
done

[ -n "$SPEC" ] || { echo "usage: parse-ledger.sh <spec-file> [--phases]" >&2; exit 2; }

if [ ! -f "$SPEC" ]; then
  echo "parse-ledger: no such spec: $SPEC" >&2
  exit 3
fi

awk -v section="$SECTION" -v label="$LABEL" '
  BEGIN {
    open_re  = "^[[:space:]]*##[[:space:]]+" section
    entry_re = "^- \\[[ xX]\\][[:space:]]+\\*\\*" label " "
  }
  /^[[:space:]]*```+[^`]*$/        { infence = !infence; next }
  infence                          { next }
  $0 ~ open_re                     { seen_section = 1; f = 1; next }
  /^[[:space:]]*#{1,4}[[:space:]]/ { f = 0 }
  !f                               { next }

  /^[-*][[:space:]]*\[/            { boxes++ }
  $0 !~ entry_re                   { next }

  {
    done_flag = ($0 ~ /^- \[[xX]\]/) ? "x" : " "

    match($0, /\*\*[^*]*\*\*/)
    name = substr($0, RSTART + 2, RLENGTH - 4)
    rest = substr($0, RSTART + RLENGTH)

    if (label == "PR") {
      value = ""
      if (match(rest, /`[^`]+`/)) {
        value = substr(rest, RSTART + 1, RLENGTH - 2)
      }
      if (value == "") {
        printf "parse-ledger: unit %s names no branch\n", name > "/dev/stderr"
        malformed++
        next
      }
    } else {
      value = rest
      sub(/^[[:space:]]*([-—–][[:space:]]*)?/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == "") {
        printf "parse-ledger: %s has no title\n", name > "/dev/stderr"
        malformed++
        next
      }
    }

    rows++
    printf "%s|%s|%s\n", done_flag, name, value
  }

  END {
    if (!seen_section) {
      print "parse-ledger: no ## " section " section" > "/dev/stderr"
      exit 3
    }
    if (rows == 0) {
      print "parse-ledger: the ## " section " section names no entries" > "/dev/stderr"
      if (label == "PR") {
        print "parse-ledger: each unit is one line: - [ ] **PR 1** - `branch` - description - est ~N" > "/dev/stderr"
      } else {
        print "parse-ledger: each phase is one line: - [ ] **Phase N** - title" > "/dev/stderr"
      }
      exit 3
    }
    if (malformed || boxes != rows) {
      printf "parse-ledger: %d checkbox(es) in the section, %d parsed as entries\n", boxes, rows > "/dev/stderr"
      exit 3
    }
  }
' "$SPEC"
