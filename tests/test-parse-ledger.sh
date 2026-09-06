#!/usr/bin/env bash
#
# Regression tests for loop/parse-ledger.sh.
#
# Run: bash tests/test-parse-ledger.sh
#
# Every case here is a shape that was observed in a real spec or that broke an earlier draft of the
# parser. The exit-3 cases are the ones that matter most: a section a caller cannot parse must stop
# an unattended run, because the alternative is silently building the wrong branch or skipping a
# phase nobody notices is missing.

set -euo pipefail

cd "$(dirname "$0")/.."

PARSE="loop/parse-ledger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

check() {
  name="$1"; expected_exit="$2"; input="$3"; expected_out="$4"; shift 4
  set +e
  actual_out="$($PARSE "$input" "$@" 2>/dev/null)"
  actual_exit=$?
  set -e
  if [ "$actual_exit" != "$expected_exit" ]; then
    printf 'FAIL %-44s exit %s, wanted %s\n' "$name" "$actual_exit" "$expected_exit" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$actual_out" != "$expected_out" ]; then
    printf 'FAIL %-44s output differs\n' "$name" >&2
    printf '%s\n' "$actual_out" | sed 's/^/  got:    /' >&2
    printf '%s\n' "$expected_out" | sed 's/^/  wanted: /' >&2
    failures=$((failures + 1))
    return
  fi
  printf 'ok   %s\n' "$name"
}

check "adversarial fixture: the ledger" 0 tests/fixtures/adversarial-ledger.md \
"x|PR 1|feat-first
x|PR 2a|feat-second-a
 |PR 2b|feat-second-b
 |PR 3|feat-third"

check "adversarial fixture: the phases" 0 tests/fixtures/adversarial-ledger.md \
"x|Phase 1|the port, with \`Inline\` code
 |Phase 2|the adapter - a plain dash and a nested note
 |Phase 3|the wiring" --phases

# The backticks below are literal ledger syntax, not command substitution — hence SC2016 is expected.
# shellcheck disable=SC2016
printf '## Delivery\n\n- [ ] **PR 1** - `feat-ok` - fine\n* [ ] **PR 2** - `feat-typo` - a star, not a dash\n' > "$TMP/typo.md"
check "a top-level typo fails loudly" 3 "$TMP/typo.md" " |PR 1|feat-ok"

printf '## Delivery\n\n- [ ] **PR 1** - no branch at all\n' > "$TMP/nobranch.md"
check "a unit with no branch fails" 3 "$TMP/nobranch.md" ""

# The shape every spec written before this grammar has: a `## Delivery — four PRs` heading followed by
# `### PR 1 — …` prose subsections, which the `#{1,4}` bound closes the section on. Exit 0 with no rows
# would leave the delivery loop building nothing and calling it success.
# shellcheck disable=SC2016
printf '## Delivery — four PRs\n\n### PR 1 — `feat-x` — prose, not a checklist\n' > "$TMP/prose.md"
check "a section naming no units fails" 3 "$TMP/prose.md" ""

printf '# A spec with no ledger\n\nNothing here.\n' > "$TMP/noledger.md"
check "a missing ## Delivery section fails" 3 "$TMP/noledger.md" ""

# A `## Progress` holding only prose is the shape a spec has before its first session: the ledger
# still parses, and only a caller asking for phases is refused.
# shellcheck disable=SC2016
printf '## Delivery\n\n- [ ] **PR 1** - `feat-ok` - fine\n\n## Progress\n\n_Not started._\n' > "$TMP/noph.md"
check "prose under ## Progress still parses the ledger" 0 "$TMP/noph.md" " |PR 1|feat-ok"
check "prose under ## Progress names no phases" 3 "$TMP/noph.md" "" --phases

printf '## Progress\n\n- [ ] **Phase 1** —\n' > "$TMP/notitle.md"
check "a phase with no title fails" 3 "$TMP/notitle.md" "" --phases

printf '## Progress\n\n- [x] **Phase 1** — done\n- [ ] remember to write the notes\n' > "$TMP/note.md"
check "an unlabelled checkbox among the phases fails" 3 "$TMP/note.md" "x|Phase 1|done" --phases

check "a missing file fails" 3 "$TMP/does-not-exist.md" ""

# --skills reads a phase's own section. The fixture carries every decoy: a Skills line in prose
# before any phase, one inside a fence, a `Phase 10` whose label starts with `Phase 1`, and trailing
# prose on the line that is not a skill.
check "the skills of a phase, from its own section" 0 tests/fixtures/adversarial-ledger.md \
"scaffold-port
port-tests" --skills "Phase 1"

check "a label is matched whole, not as a prefix" 0 tests/fixtures/adversarial-ledger.md \
"tenth-skill" --skills "Phase 10"

check "a level-four heading opens a phase section too, and a Skills line naming nothing fails" 3 \
  tests/fixtures/adversarial-ledger.md "" --skills "Phase 2"

check "a phase with no Skills line has no skills" 0 tests/fixtures/adversarial-ledger.md "" --skills "Phase 3"

check "a phase with no section has no skills" 0 tests/fixtures/adversarial-ledger.md "" --skills "Phase 4"

# shellcheck disable=SC2016
printf '## Delivery\n\n- [ ] **PR 1** - `feat-ok` - fine\n' > "$TMP/nophasing.md"
check "a spec with no per-phase sections has no skills" 0 "$TMP/nophasing.md" "" --skills "Phase 1"

set +e
$PARSE tests/fixtures/adversarial-ledger.md --skills >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 2 ]; then printf 'ok   %s\n' "--skills without a phase is a usage error"
else printf 'FAIL %-44s exit %s, wanted 2\n' "--skills without a phase is a usage error" "$rc" >&2; failures=$((failures + 1)); fi

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d test(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nOK — parse-ledger.sh\n'
