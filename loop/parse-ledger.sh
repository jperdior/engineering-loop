#!/usr/bin/env bash
#
# Parse a spec's checklists into one machine-readable row per entry.
#
#   parse-ledger.sh <spec>                     the `## Delivery` ledger:  done|unit|branch
#   parse-ledger.sh <spec> --phases            the `## Progress` checklist: done|phase|title
#   parse-ledger.sh <spec> --skills "Phase N"  the host skills that phase names, one per line
#
# Called by /implement-spec, /archive-spec and the delivery loop. One grammar, one implementation.
#
# `done` is `x` or a space. A ledger row's `unit` is the label (`PR 1`) and `branch` the first
# backticked name after it. A phase row's `phase` is the label (`Phase 2`) and `title` the text after
# it, with the leading dash stripped.
#
# The grammar is strict on purpose, because an unattended caller cannot ask what a line meant:
#
#   - A section ends at the next `#{1,4}` heading, tolerating leading whitespace.
#   - Fenced code blocks are skipped, so a spec can document this grammar without creating a phantom
#     unit. A fence delimiter is backticks plus an optional language tag and nothing else.
#   - An entry must carry its bold label (`**PR `, `**Phase `). A checkbox without one is not an entry.
#   - Every unindented checkbox in the section is counted against the rows emitted, so a typo
#     (`* [ ]`, a missing label) fails loudly instead of dropping an entry. Indented checkboxes are
#     ordinary nested markdown and exempt.
#   - A section with no entries is exit 3, like any malformed section: exit 0 with no output would
#     leave the loop building nothing and reporting success.
#
# `--skills` reads a phase's own section: the `### Phase N — title` (or `####`) heading whose label
# is exactly the one asked for, closed by the next `#{1,4}` heading. Inside it, one line of the form
# `- **Skills:** `name`, `name`` names the host's skills the phase must use; the backticked names
# are printed one per line. Skills are optional: a phase with no section or no Skills line prints
# nothing and exits 0. A Skills line naming nothing is exit 3, because a session cannot ask what an
# empty list meant.
#
# Exit: 0 parsed, 2 usage, 3 the section is malformed or absent.

set -euo pipefail

SPEC=""
SECTION="Delivery"
LABEL="PR"
SKILLS_OF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --phases) SECTION="Progress"; LABEL="Phase" ;;
    --skills) [ -n "${2:-}" ] || { echo "usage: parse-ledger.sh <spec-file> --skills \"Phase N\"" >&2; exit 2; }
              SKILLS_OF="$2"; shift ;;
    -*)       echo "parse-ledger: unknown option '$1'" >&2; exit 2 ;;
    *)        [ -z "$SPEC" ] || { echo "usage: parse-ledger.sh <spec-file> [--phases | --skills \"Phase N\"]" >&2; exit 2; }; SPEC="$1" ;;
  esac
  shift
done

[ -n "$SPEC" ] || { echo "usage: parse-ledger.sh <spec-file> [--phases | --skills \"Phase N\"]" >&2; exit 2; }

if [ ! -f "$SPEC" ]; then
  echo "parse-ledger: no such spec: $SPEC" >&2
  exit 3
fi

if [ -n "$SKILLS_OF" ]; then
  awk -v phase="$SKILLS_OF" '
    BEGIN {
      # The label, then a word boundary: `Phase 1` must not open on `Phase 10`.
      open_re   = "^[[:space:]]*#{3,4}[[:space:]]+" phase "([^0-9A-Za-z]|$)"
      skills_re = "^[[:space:]]*([-*][[:space:]]+)?\\*\\*Skills:?\\*\\*:?"
    }
    /^[[:space:]]*```+[^`]*$/        { infence = !infence; next }
    infence                          { next }
    $0 ~ open_re && !found           { found = 1; f = 1; next }
    /^[[:space:]]*#{1,4}[[:space:]]/ { f = 0 }
    !f                               { next }
    $0 !~ skills_re                  { next }
    {
      rest = $0
      sub(skills_re, "", rest)
      n = 0
      while (match(rest, /`[^`]+`/)) {
        print substr(rest, RSTART + 1, RLENGTH - 2)
        n++
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (n == 0) {
        printf "parse-ledger: the Skills line of %s names no skill; each is a backticked name\n", phase > "/dev/stderr"
        exit 3
      }
      exit 0
    }
  ' "$SPEC"
  exit $?
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
