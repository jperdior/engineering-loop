#!/usr/bin/env bash
#
# Parse a spec's checklists into one machine-readable row per entry.
#
#   parse-ledger.sh <spec>                     the `## Delivery` ledger:  done|unit|branch
#   parse-ledger.sh <spec> --phases            the `## Progress` checklist: done|phase|title
#   parse-ledger.sh <spec> --skills "Phase N"  the host skills that phase names, one per line
#   parse-ledger.sh <spec> --gates             the `## Gates` commands, one per line
#   parse-ledger.sh <spec> --host <key>        one `## Gates` detail: cleanup | excludes | denials
#
# Called by /implement-spec, /archive-spec and the delivery loop. One grammar, one implementation.
#
# `## Gates` is the host contract, written into every spec by /spec-writing from the repository's own
# docs and read by the loop from the branch, like the phases. Each unindented `- `command`` line is
# one gate, run from the repo root in that order; a list item with no backticked command is
# malformed. Three optional italic-labelled lines carry the rest, each a list of backticked values:
# `_Cleanup:_` (a command run inside a worktree before it is removed), `_Excludes:_` (generated
# paths left out of the size), `_Denials:_` (tools a session may never run). `--gates` exits 3 when
# the section is absent or names none: a spec without gates is a spec the loop must not build.
# `--host` prints nothing and exits 0 when the line is absent.
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
GATES=0
HOST_KEY=""

usage() { echo "usage: parse-ledger.sh <spec-file> [--phases | --skills \"Phase N\" | --gates | --host cleanup|excludes|denials]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --phases) SECTION="Progress"; LABEL="Phase" ;;
    --skills) [ -n "${2:-}" ] || usage; SKILLS_OF="$2"; shift ;;
    --gates)  GATES=1 ;;
    --host)   case "${2:-}" in cleanup|excludes|denials) HOST_KEY="$2" ;; *) usage ;; esac; shift ;;
    -*)       echo "parse-ledger: unknown option '$1'" >&2; exit 2 ;;
    *)        [ -z "$SPEC" ] || usage; SPEC="$1" ;;
  esac
  shift
done

[ -n "$SPEC" ] || usage

if [ ! -f "$SPEC" ]; then
  echo "parse-ledger: no such spec: $SPEC" >&2
  exit 3
fi

if [ "$GATES" = 1 ] || [ -n "$HOST_KEY" ]; then
  awk -v want_gates="$GATES" -v host_key="$HOST_KEY" '
    BEGIN {
      open_re = "^[[:space:]]*##[[:space:]]+Gates"
      gate_re = "^- "
      if (host_key == "cleanup")  label = "Cleanup"
      if (host_key == "excludes") label = "Excludes"
      if (host_key == "denials")  label = "Denials"
      host_re = "^[[:space:]]*(_|\\*\\*)" label ":?(_|\\*\\*):?"
    }
    /^[[:space:]]*```+[^`]*$/        { infence = !infence; next }
    infence                          { next }
    $0 ~ open_re                     { seen = 1; f = 1; next }
    /^[[:space:]]*#{1,4}[[:space:]]/ { f = 0 }
    !f                               { next }

    want_gates && $0 ~ gate_re {
      rest = $0
      if (!match(rest, /`[^`]+`/)) {
        printf "parse-ledger: a ## Gates item names no backticked command: %s\n", $0 > "/dev/stderr"
        exit 3
      }
      print substr(rest, RSTART + 1, RLENGTH - 2)
      gates++
      next
    }
    host_key != "" && $0 ~ host_re {
      rest = $0
      sub(host_re, "", rest)
      while (match(rest, /`[^`]+`/)) {
        print substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
      }
      exit 0
    }

    END {
      if (!want_gates) exit 0
      if (!seen) {
        print "parse-ledger: no ## Gates section" > "/dev/stderr"
        exit 3
      }
      if (gates == 0) {
        print "parse-ledger: the ## Gates section names no gate; each is one line: - `command`" > "/dev/stderr"
        exit 3
      }
    }
  ' "$SPEC"
  exit $?
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
