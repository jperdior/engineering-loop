#!/usr/bin/env bash
#
# Regression tests for loop/delivery-loop.sh.
#
# Run: bash tests/test-delivery-loop.sh
#
# Each case builds a throwaway repository with a real bare remote and puts stubbed `gh`, `claude`,
# `make` and `docker` first on PATH. Nothing here talks to GitHub, Docker or Anthropic.
#
# CRASHES ARE STAGED, NOT RACED. A test that kills the loop mid-flight asserts on whichever moment it
# happened to win, which is the opposite of a regression test. So each crash case instead CONSTRUCTS
# the on-disk and on-remote state a crash at that point leaves behind -- ticked phases on a branch
# with no closing session, a PR open with the ledger unticked -- and then asserts that one ordinary
# run converges from it. Recovery is what has to be correct; the kill itself is not.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd -P)"
STUBS="$REPO_ROOT/tests/stubs"

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

failures=0
CASE=""

fail() { printf 'FAIL %-56s %s\n' "$CASE" "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'ok   %s\n' "$CASE"; }

SPEC_REL=".ai/specs/fixture.md"

# One unit with three phases: the shape every spec has.
write_spec() {
  mkdir -p "$1/.ai/specs"
  cat > "$1/$SPEC_REL" <<'SPEC'
# Fixture spec

## Delivery

- [ ] **PR 1** — `feat-one` — the whole thing — est ~100

## Progress

- [ ] **Phase 1** — the port
- [ ] **Phase 2** — the adapter
- [ ] **Phase 3** — the wiring

_Notes:_ not started.
SPEC
}

fresh() {
  REPO="$TMP/$1"
  rm -rf "$REPO" "$TMP/$1.git"
  git init -q --bare "$TMP/$1.git"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.t
  git -C "$REPO" config user.name t
  git -C "$REPO" remote add origin "$TMP/$1.git"

  mkdir -p "$REPO/.loop"
  for s in delivery-loop parse-ledger unit-size comment-ratio reclaim-worktree; do
    cp "$REPO_ROOT/loop/$s.sh" "$REPO/.loop/"
  done
  cp "$REPO_ROOT/loop/loop.env.dist" "$REPO/.loop/"
  write_spec "$REPO"
  # The real repo ignores every path the loop writes to, so a driver tree stays clean while a run is
  # in flight. Without this the fixture reports the loop's own state as uncommitted work and the
  # dirty-tree refusal fires on every case -- a fixture unfaithfulness, not a defect.
  printf '.claude/worktrees/\n.loop/state/\n.loop/loop.env\n.claude/settings.local.json\n' \
    > "$REPO/.gitignore"
  echo "hello" > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm base
  git -C "$REPO" branch -M main
  git -C "$REPO" push -q -u origin main

  # BY PREFIX, NOT BY NAME. Listing them by hand has failed four times: each new knob is a leak
  # nobody notices until a later case fails for a reason belonging to an earlier one.
  #
  # The leak only happens under `sh`: in POSIX mode a prefix assignment on a FUNCTION call persists
  # after the call returns, while bash discards it. This suite runs under sh.
  #
  # `sed -E`, NOT a BRE with `\|`: alternation in a basic regex is a GNU extension that BSD sed does
  # not have, so on macOS that spelling matches nothing at all and the sweep silently does nothing.
  for __v in $(set | sed -nE 's/^(LOOP_[A-Za-z0-9_]*|DELIVERY_LOOP_[A-Za-z0-9_]*|MAX_[A-Za-z0-9_]*|UNIT_[A-Za-z0-9_]*|SESSION_[A-Za-z0-9_]*|CLAUDE_BIN)=.*/\1/p'); do
    unset "$__v"
  done
  export LOOP_TEST_DIR="$TMP/$1.state"
  mkdir -p "$LOOP_TEST_DIR"
  : > "$LOOP_TEST_DIR/prs.txt"
  : > "$LOOP_TEST_DIR/models.txt"
}

run_loop() {
  ( cd "$REPO" \
    && PATH="$STUBS:$PATH" \
       UNIT_TIMEOUT="${UNIT_TIMEOUT:-60}" \
       .loop/delivery-loop.sh "$SPEC_REL" "$@" ) >"$TMP/out" 2>"$TMP/err"
}

ticks()       { git -C "$REPO" show "$2:$SPEC_REL" 2>/dev/null | grep -c "^- \[x\] \*\*$1\*\*" || true; }
phase_ticks() { git -C "$REPO" show "$1:$SPEC_REL" 2>/dev/null | grep -c '^- \[x\] \*\*Phase ' || true; }
sessions()    { git -C "$REPO" show "$1:sessions-$1.txt" 2>/dev/null | wc -l | tr -d ' '; }
remote_has()  { git -C "$TMP/$(basename "$REPO").git" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- the plan

# THE SWEEP IS ITSELF A SILENT-FAILURE RISK. It replaced a hand-written unset list precisely because
# that list leaked; a sweep that matches nothing leaks identically while looking exhaustive, and the
# symptom lands in whatever case runs next. Pin it, and pin it FIRST.
CASE="fresh clears a knob leaked by a previous case"
LOOP_TEST_CLAUDE=silent MAX_SESSIONS=7 SESSION_CONTEXT_ALARM=1 fresh sweepguard
if [ -z "${LOOP_TEST_CLAUDE:-}" ] && [ -z "${MAX_SESSIONS:-}" ] && [ -z "${SESSION_CONTEXT_ALARM:-}" ]; then pass
else fail "the sweep left LOOP_TEST_CLAUDE=${LOOP_TEST_CLAUDE:-} MAX_SESSIONS=${MAX_SESSIONS:-}"; fi

# The stub extracts the branch, the run id, the phase and the sentinel path from the prompt itself,
# so a prompt edit that broke those would silently make every build case unreachable.
CASE="the prompts still carry a resolvable sentinel template"
fresh prompt
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "the prompt no longer yields a usable sentinel: $(tail -2 "$TMP/err")"; fi

CASE="--dry-run lists the unit, its phases and its models, and creates nothing"
fresh dry
if run_loop --dry-run && grep -q "PR 1 on feat-one" "$TMP/out" \
   && grep -q "Phase 1 — the port" "$TMP/out" && grep -q "Phase 3 — the wiring" "$TMP/out" \
   && grep -q "build sessions on opus, the PR session on sonnet" "$TMP/out" \
   && [ ! -d "$REPO/.claude/worktrees/feat-one" ] && ! remote_has feat-one; then pass
else fail "plan output or side effects wrong: $(tail -5 "$TMP/out")"; fi

CASE="--dry-run counts the sessions a unit will take"
if grep -q "phases: 3, one session each, then a closing session (MAX_SESSIONS=5)" "$TMP/out"; then pass
else fail "$(grep phases "$TMP/out")"; fi

# --------------------------------------------------------------------------- the happy path

CASE="the unit is built, ticked once and reclaimed"
fresh happy
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ] && remote_has feat-one \
   && [ ! -d "$REPO/.claude/worktrees/feat-one" ] \
   && [ ! -d "$REPO/.loop/state/lock" ]; then pass; else fail "$(tail -3 "$TMP/err")"; fi

# ONE PHASE PER SESSION. A session cannot observe its own context, so the loop bounds it by giving
# it exactly one phase and starting a fresh process for the next.
CASE="each phase gets its own session, and one more closes the unit"
if [ "$(sessions feat-one)" = 4 ] \
   && [ "$(git -C "$REPO" show feat-one:sessions-feat-one.txt | sed -n 1p)" = "session feat-one Phase 1" ] \
   && [ "$(git -C "$REPO" show feat-one:sessions-feat-one.txt | sed -n 4p)" = "session feat-one closing" ]; then pass
else fail "sessions: $(git -C "$REPO" show feat-one:sessions-feat-one.txt 2>/dev/null | tr '\n' ';')"; fi

CASE="every phase is ticked on the branch"
if [ "$(phase_ticks feat-one)" = 3 ]; then pass; else fail "$(phase_ticks feat-one) of 3 ticked"; fi

CASE="the base is where the unit started, in every session"
if [ "$(sort -u "$LOOP_TEST_DIR/bases.txt" | wc -l | tr -d ' ')" = 1 ] \
   && [ "$(sed -n 1p "$LOOP_TEST_DIR/bases.txt")" = "$(git -C "$REPO" rev-parse origin/main)" ]; then pass
else fail "bases: $(tr '\n' ' ' < "$LOOP_TEST_DIR/bases.txt")"; fi

# A resumed run must not take the branch TIP as the base, or the closing review sees only the
# phases built in the second invocation.
CASE="a resumed run keeps the base the unit started from"
fresh resumebase
LOOP_TEST_CLAUDE=quota run_loop || true
if run_loop && [ "$(sort -u "$LOOP_TEST_DIR/bases.txt" | wc -l | tr -d ' ')" = 1 ] \
   && [ "$(sed -n '$p' "$LOOP_TEST_DIR/bases.txt")" = "$(git -C "$REPO" rev-parse origin/main)" ]; then pass
else fail "bases: $(tr '\n' ' ' < "$LOOP_TEST_DIR/bases.txt")"; fi

CASE="the tick carries the measurement and the PR number"
if git -C "$REPO" show "feat-one:$SPEC_REL" | grep -E "^- \[x\] \*\*PR 1\*\*.*→ [0-9]+ lines \([0-9]+ impl \+ [0-9]+ test\), [0-9]+ files, [0-9]+% comments, [0-9]+ ctx \(#[0-9]+\)" >/dev/null; then pass; else fail "$(git -C "$REPO" show "feat-one:$SPEC_REL" | grep 'PR 1')"; fi

CASE="exactly one PR is opened"
if [ "$(grep -c '^feat-one|' "$LOOP_TEST_DIR/prs.txt")" = 1 ]; then pass
else fail "$(grep -c '^feat-one|' "$LOOP_TEST_DIR/prs.txt") PRs opened"; fi

# Peak context per session is the only evidence that a phase is cut to a size a session can hold.
CASE="telemetry has one row per session"
telem="$(git -C "$REPO" show "feat-one:.ai/telemetry/fixture/PR-1.md" 2>/dev/null || true)"
if [ "$(printf '%s\n' "$telem" | grep -c '^| Phase ')" = 3 ] \
   && printf '%s' "$telem" | grep -q '^| closing ' \
   && printf '%s' "$telem" | grep -q "peak context" \
   && printf '%s' "$telem" | grep -q "| PR | #"; then pass
else fail "telemetry: $telem; state: $(ls "$REPO/.loop/state/" | tr "\n" " "); sizes: $(wc -c "$REPO"/.loop/state/feat-one.s*.json | tr "\n" " ")"; fi

CASE="a session over the context alarm is reported, not stopped"
fresh alarm
if SESSION_CONTEXT_ALARM=5000 run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ] \
   && grep -q "Phase 1: peak context 9212 exceeds SESSION_CONTEXT_ALARM=5000" "$TMP/err"; then pass
else fail "$(grep -c SESSION_CONTEXT_ALARM "$TMP/err") alarm lines: $(tail -2 "$TMP/err")"; fi

# A session cannot see its context, so telling it a budget is an instruction with nothing to
# measure against. The prompt names the phase and nothing else.
CASE="the prompt never tells a session a token budget"
if ! grep -qi 'CONTEXT BUDGET' loop/delivery-loop.sh \
   && ! grep -q 'UNIT_CONTEXT_LIMIT' loop/delivery-loop.sh; then pass
else fail "a token budget is still in the prompt"; fi

CASE="a second run finds nothing owed and touches nothing"
fresh idem
run_loop
before="$(git -C "$TMP/idem.git" rev-parse refs/heads/feat-one)"
# The tick reaches the checkout only when the PR merges; stage that.
git -C "$REPO" fetch origin --quiet
if ! git -C "$REPO" merge -q --ff-only origin/feat-one 2>/dev/null; then
  git -C "$REPO" reset -q --hard origin/feat-one
fi
git -C "$REPO" push -q origin main
if run_loop && grep -q "nothing is owed" "$TMP/out" \
   && [ "$(git -C "$TMP/idem.git" rev-parse refs/heads/feat-one)" = "$before" ]; then pass
else fail "not idempotent: $(tail -2 "$TMP/out")"; fi

# --------------------------------------------------------------------------- models

CASE="build sessions run on LOOP_MODEL and the PR session on sonnet"
fresh models
if run_loop && [ "$(grep -c '^opus$' "$LOOP_TEST_DIR/models.txt")" = 4 ] \
   && [ "$(sed -n '$p' "$LOOP_TEST_DIR/models.txt")" = "sonnet" ]; then pass
else fail "models: $(tr '\n' ' ' < "$LOOP_TEST_DIR/models.txt")"; fi

CASE="LOOP_MODEL overrides the build model"
fresh modelsov
if LOOP_MODEL=sonnet run_loop && [ "$(grep -c '^sonnet$' "$LOOP_TEST_DIR/models.txt")" = 5 ]; then pass
else fail "models: $(tr '\n' ' ' < "$LOOP_TEST_DIR/models.txt")"; fi

# --------------------------------------------------------------------------- resuming

# A session refused for the account's usage limit is a PAUSE: nothing is wrong with the unit, so it
# is not an escalation, and the next invocation reads the ticks on the branch and carries on from the
# first phase still owed. The stub refuses its second session.
CASE="a usage-limit refusal pauses the run, and a re-run continues from the branch's ticks"
fresh quota
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(sessions feat-one)" = 1 ] && [ "$(phase_ticks feat-one)" = 1 ] \
   && grep -q "paused: the usage limit is reached" "$TMP/out" && ! grep -q "ESCALATE" "$TMP/err"; then
  if run_loop && [ "$(sessions feat-one)" = 4 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
  else fail "the resumed run did not finish: $(tail -2 "$TMP/err")"; fi
else
  fail "exit $rc, sessions=$(sessions feat-one): $(tail -2 "$TMP/err")"
fi

CASE="there is no budget"
if ! grep -qE 'BUDGET_USD|max-budget-usd' loop/delivery-loop.sh loop/loop.env.dist; then pass
else fail "a budget knob is back"; fi

CASE="an open PR is recorded without a second PR"
fresh reopen
run_loop
# Roll the branch back to before the tick commit and drop the worktree: a crash between /open-pr and
# the record commit, which is the one kill point where recovery needs a worktree the loop no longer has.
git -C "$REPO" push -q -f origin "feat-one~1:refs/heads/feat-one"
git -C "$REPO" branch -f feat-one feat-one~1
if run_loop; then
  if [ "$(ticks 'PR 1' feat-one)" = 1 ] && grep -q "already has PR" "$TMP/out" \
     && [ "$(grep -c '^feat-one|' "$LOOP_TEST_DIR/prs.txt")" = 1 ]; then pass; else fail "$(tail -3 "$TMP/out")"; fi
else
  fail "$(tail -3 "$TMP/err")"
fi

# --------------------------------------------------------------------------- escalations

escalates() {
  CASE="$1"; shift
  fresh "esc$$"
  set +e
  ( for kv in "$@"; do export "${kv?}"; done; run_loop ); rc=$?
  set -e
  # The assertion is that nothing was RECORDED, not that nothing was ticked -- and the telemetry is
  # what separates them. The closing session ticks the ledger from inside /archive-spec, before the
  # PR exists, so an escalated unit can legitimately carry a tick on its branch. What only the loop
  # writes, and only after verify and prove have passed, is the telemetry file.
  if [ "$rc" = 4 ] && ! git -C "$REPO" ls-tree -r --name-only feat-one 2>/dev/null | grep -q '\.ai/telemetry/'; then
    pass
  else
    fail "exit $rc; telemetry: $(git -C "$REPO" ls-tree -r --name-only feat-one 2>/dev/null | grep -c '\.ai/telemetry/')"
  fi
}

escalates "a silent session escalates"                   LOOP_TEST_CLAUDE=silent
escalates "an ESCALATE sentinel escalates"               LOOP_TEST_CLAUDE=escalate
escalates "a permission denial escalates"                LOOP_TEST_CLAUDE=denied
escalates "denials are named even with no sentinel"      LOOP_TEST_CLAUDE=denied-silent
escalates "is_error true with subtype success escalates" LOOP_TEST_CLAUDE=apierror
escalates "a sentinel naming another run escalates"      LOOP_TEST_CLAUDE=stale
escalates "gates that stay red escalate"                 LOOP_TEST_MAKE=fail

# THE TICK IS THE PROOF. A session that says CONTINUE has not handed over anything unless the phase
# it was given is ticked on origin; taking its word would let a unit "converge" on sessions that
# built nothing.
CASE="a handover that ticked nothing escalates"
fresh noticks
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=noticks; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "without ticking Phase 1" "$TMP/err" && [ "$(sessions feat-one)" = 1 ]; then pass
else fail "exit $rc, sessions=$(sessions feat-one): $(tail -2 "$TMP/err")"; fi

CASE="OK from a phase session escalates"
fresh okphase
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=okphase; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "a phase session wrote OK" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="OK with a phase still unticked escalates"
fresh untick
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=untick; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "still unticked" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="CONTINUE from the closing session escalates"
fresh contclose
# Three good phase sessions, then a closing session that hands over instead of finishing.
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=continueclose; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "closing session handed over" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# Without a backstop a unit that never converges spends the night going nowhere.
CASE="a unit that never converges is escalated, not spun"
fresh nevercv
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=continueclose MAX_SESSIONS=3; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && [ "$(sessions feat-one)" = 3 ]; then pass
else fail "exit $rc, sessions=$(sessions feat-one): $(tail -2 "$TMP/err")"; fi

# A checklist that does not parse must never read as "no phase is unticked": a session that writes
# a `- [ ] remember to …` note beneath the phases breaks the grammar, and an OK on top of that
# would pass with nothing checked at all.
CASE="a closing session that breaks the checklist escalates, not passes"
fresh notebox
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=notebox; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "no longer parses" "$TMP/err" \
   && ! git -C "$REPO" ls-tree -r --name-only feat-one 2>/dev/null | grep -q '\.ai/telemetry/'; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="a denial reports as a denial, not as a missing sentinel"
fresh denialmsg
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=denied-silent; run_loop ) ; rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "permission denials" "$TMP/err" \
   && ! grep -q "no sentinel was written" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="a gh failure aborts before any session"
fresh ghfail
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_GH=fail; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && ! remote_has feat-one && grep -q "aborting rather than risking" "$TMP/err"; then pass; else fail "exit $rc"; fi

CASE="a closed unmerged PR escalates"
fresh closed
printf 'feat-one|CLOSED|7|NONE|\n' > "$LOOP_TEST_DIR/prs.txt"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "a human rejected this unit" "$TMP/err"; then pass; else fail "exit $rc"; fi

CASE="a merged PR with an unticked ledger escalates"
fresh mergedopen
run_loop
git -C "$REPO" push -q -f origin "feat-one~1:refs/heads/feat-one"
git -C "$REPO" branch -f feat-one feat-one~1
printf 'feat-one|MERGED|7|APPROVED|2026-09-01T00:00:00Z\n' > "$LOOP_TEST_DIR/prs.txt"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "merged but the ledger is unticked" "$TMP/err"; then pass; else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# THE ONE FAILURE THIS DESIGN EXISTS TO PREVENT: reporting success for work that was not done. A
# session can exit 0 having opened nothing; the loop asks origin.
CASE="a PR that was not opened is an escalation, not a clean exit"
fresh noprattest
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_NOPR=1; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "origin has none for this branch" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# --------------------------------------------------------------------------- the ledger and the phases

CASE="a ledger with two unticked units is refused"
fresh twounits
# shellcheck disable=SC2016
awk '{ print } /^- \[ \] \*\*PR 1\*\*/ { print "- [ ] **PR 2** — `feat-two` — a second unit — est ~100" }' \
  "$REPO/$SPEC_REL" > "$REPO/$SPEC_REL.tmp" && mv "$REPO/$SPEC_REL.tmp" "$REPO/$SPEC_REL"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "two units"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "unticked units; this loop builds exactly one" "$TMP/err" && ! remote_has feat-one; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="a spec with no phase checklist is refused"
fresh nophases
# shellcheck disable=SC2016
printf '# Fixture\n\n## Delivery\n\n- [ ] **PR 1** — `feat-one` — the whole thing — est ~100\n\n## Progress\n\n_Not started._\n' > "$REPO/$SPEC_REL"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "no phases"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "no phase checklist" "$TMP/err" && ! remote_has feat-one; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# A ledger that parses to nothing is the worst case an unattended tool has: `done < <(parse-ledger …)`
# cannot see the parser's exit status, so without an explicit check the run would report success
# having built nothing.
CASE="a ledger naming no units refuses, rather than succeeding silently"
fresh nounits
# shellcheck disable=SC2016
printf '# Fixture\n\n## Delivery — four PRs\n\n### PR 1 — `feat-one` — prose, not a checklist\n' > "$REPO/$SPEC_REL"
git -C "$REPO" add -A && git -C "$REPO" commit -qm prose
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && ! remote_has feat-one && grep -q "does not parse" "$TMP/err"; then pass
else fail "exit $rc"; fi

# --------------------------------------------------------------------------- the lock

CASE="a live loop's lock is respected"
fresh lock1
mkdir -p "$REPO/.loop/state/lock"
sleep 120 & sleeper=$!
echo "$sleeper" > "$REPO/.loop/state/lock/pid"
set +e
run_loop --dry-run >/dev/null 2>&1   # dry-run takes no lock
( cd "$REPO" && PATH="$STUBS:$PATH" .loop/delivery-loop.sh "$SPEC_REL" ) >"$TMP/out" 2>"$TMP/err"; rc=$?
set -e
kill "$sleeper" 2>/dev/null || true
# The PID is alive but is not a delivery loop: a recycled PID, which must NOT be trusted OR reclaimed.
if [ "$rc" = 3 ] && grep -q "recycled PID" "$TMP/err"; then pass; else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="--force-unlock takes a recycled-PID lock"
sleep 120 & sleeper=$!
echo "$sleeper" > "$REPO/.loop/state/lock/pid"
if run_loop --force-unlock; then pass; else fail "$(tail -3 "$TMP/err")"; fi
kill "$sleeper" 2>/dev/null || true

CASE="a dead holder's lock is reclaimed"
fresh lock2
mkdir -p "$REPO/.loop/state/lock"
echo "999999" > "$REPO/.loop/state/lock/pid"
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass; else fail "$(tail -3 "$TMP/err")"; fi

CASE="the lock is released on the way out"
if [ ! -d "$REPO/.loop/state/lock" ]; then pass; else fail "lock left behind"; fi

# --------------------------------------------------------------------------- arguments

CASE="an absolute spec path outside the repo is refused"
set +e
( cd "$REPO" && PATH="$STUBS:$PATH" .loop/delivery-loop.sh /etc/hosts ) >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 2 ]; then pass; else fail "exit $rc"; fi

CASE="a missing spec fails pre-flight"
set +e
( cd "$REPO" && PATH="$STUBS:$PATH" .loop/delivery-loop.sh .ai/specs/nope.md ) >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 3 ]; then pass; else fail "exit $rc"; fi

# --------------------------------------------------------------------------- the notifier

# The notifier is what tells a human a long run has landed, so a broken one must never be able to
# lose a finished unit -- it runs after the work, detached from the run's exit status.
CASE="the notifier fires on a completed unit"
fresh notify
# Both expansions belong to the generated notifier, resolved when the LOOP runs it, not now.
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$1" >> "$LOOP_TEST_DIR/notified"\n' > "$TMP/notify.sh"
chmod +x "$TMP/notify.sh"
if DELIVERY_LOOP_BELL=0 DELIVERY_LOOP_NOTIFY="$TMP/notify.sh" run_loop \
   && grep -q "open and waiting for review" "$LOOP_TEST_DIR/notified"; then pass
else fail "no notification: $(cat "$LOOP_TEST_DIR/notified" 2>/dev/null)"; fi

CASE="the notifier fires on an escalation"
fresh notifyesc
if DELIVERY_LOOP_BELL=0 DELIVERY_LOOP_NOTIFY="$TMP/notify.sh" LOOP_TEST_CLAUDE=silent run_loop; then
  fail "should have escalated"
elif grep -q "escalated" "$LOOP_TEST_DIR/notified"; then pass
else fail "no escalation notification"; fi

CASE="a broken notifier never fails the run"
fresh notifybad
if DELIVERY_LOOP_BELL=0 DELIVERY_LOOP_NOTIFY=/nonexistent-notifier run_loop \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "a missing notifier lost the unit: $(tail -2 "$TMP/err")"; fi

# --------------------------------------------------------------------------- the denials

# Each dangerous verb must be denied by EVERY route to it, not just its most obvious name. The match
# is exact up to a wildcard, so `Bash(git push --force*)` never matches `git push -f`. This pins the
# routes; it cannot test enforcement, which belongs to Claude Code.
CASE="every dangerous verb is denied by every route to it"
missing=""
for pat in 'gh pr merge' 'gh api' 'git push --force' 'git push -f' 'Bash(ssh ' 'Bash(scp ' \
           'docker volume rm' 'docker volume prune' 'kubectl' 'helm'; do
  grep -qF -- "$pat" loop/delivery-loop.sh || missing="$missing $pat"
done
if [ -z "$missing" ]; then pass; else fail "not denied:$missing"; fi

CASE="both session paths share one denial list"
# The pattern is the script's literal text, not something to expand here.
# shellcheck disable=SC2016
shared="$(grep -c 'disallowedTools "${LOOP_DENIALS\[@\]}"' loop/delivery-loop.sh || true)"
if [ "$shared" = 2 ]; then pass; else fail "expected 2 sites sharing LOOP_DENIALS, found $shared"; fi

CASE="the model is passed on both paths"
# shellcheck disable=SC2016
modelled="$(grep -c -- '--model "$model"' loop/delivery-loop.sh || true)"
if [ "$modelled" = 2 ]; then pass
else fail "the model is not passed on both paths"; fi

# --------------------------------------------------------------------------- the sandbox

# A sandbox run that cannot authenticate fails INSIDE the container, where the only evidence is a
# denied session and a sentinel nobody could write. Pre-flight has to refuse it here, where the
# message is the reason.
CASE="sandbox mode refuses without a claude credential"
fresh sandboxnocreds
set +e
# The subshell is the POINT: these knobs must not leak into later cases.
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 GH_TOKEN=x; unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; run_loop ); rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "inherits no login" "$TMP/err"; then pass; else fail "exit $rc"; fi

CASE="sandbox mode refuses without a repo-scoped GH_TOKEN"
fresh sandboxnogh
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x; unset GH_TOKEN; run_loop ); rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "GH_TOKEN is unset" "$TMP/err"; then pass; else fail "exit $rc"; fi

CASE="sandbox mode refuses when its image is absent"
fresh sandboxnoimage
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_IMAGE=no-such-image:nope
  run_loop ); rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "sandbox image" "$TMP/err"; then pass; else fail "exit $rc"; fi

# A SANDBOX THAT CANNOT REACH THE DAEMON RUNS NO GATE AT ALL. Every gate here is `docker compose`.
# The socket is mounted, but the container runs as the host user's uid, which is in no group inside
# it -- so `make` never starts and the phase is built entirely unverified.
CASE="the sandbox refuses when the session could not run a gate"
fresh nosock
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=nosock
  run_loop ); rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "cannot reach the Docker daemon" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="the sandbox refuses without buildx"
fresh nobuildx
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=nobuildx
  run_loop ); rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "no buildx" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# The container mounts no ssh keys ON PURPOSE. So an ssh origin must be rewritten to https with
# GH_TOKEN, or the unit builds its work and cannot push it.
CASE="the sandbox refuses when git inside cannot reach origin"
fresh noorigin
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=noorigin
  run_loop ); rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "cannot reach origin" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="an ssh origin is rewritten to https for the session, not left to fail"
# shellcheck disable=SC2016
if grep -q 'GIT_CONFIG_KEY_0=url.https://x-access-token' loop/delivery-loop.sh \
   && grep -q 'sandbox_git_env' loop/delivery-loop.sh; then pass
else fail "the ssh remote is not rewritten inside the sandbox"; fi

CASE="the sandbox reports the socket gid it will run sessions with"
fresh sockok
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=ok
  run_loop --dry-run ); rc=$?
set -e
if [ "$rc" = 0 ] && grep -q "can reach the Docker daemon (socket gid 999)" "$TMP/out"; then pass
else fail "exit $rc: $(tail -2 "$TMP/out")"; fi

# Probing with the gid and then starting sessions without it would pass the check and still deny
# every gate.
CASE="the session container is given the socket group"
# shellcheck disable=SC2016
if grep -q 'group-add "$LOOP_SOCK_GID"' loop/delivery-loop.sh; then pass
else fail "sessions do not receive the socket gid"; fi

# A linked worktree is NOT self-contained: its `.git` is a file reading `gitdir: <main repo>/.git/
# worktrees/<name>`, an absolute path. Without the main repo's .git mounted there is no repository
# inside the container at all.
CASE="the sandbox mounts the main repo gitdir a worktree points at"
# shellcheck disable=SC2016
if grep -q -- '-v "$ROOT/.git:$ROOT/.git"' loop/delivery-loop.sh; then pass
else fail "a sandboxed unit would have no repository"; fi

CASE="a sandboxed unit is probed for a working repo before a session is paid for"
# shellcheck disable=SC2016
if grep -q 'sandbox_sees_repo "$wt"' loop/delivery-loop.sh \
   && grep -q 'rev-parse --git-dir' loop/delivery-loop.sh; then pass
else fail "no pre-session repo probe"; fi

CASE="--dry-run says whether the sandbox is on"
fresh sandboxoff
if run_loop --dry-run && grep -q "sandbox: OFF" "$TMP/out"; then pass
else fail "$(grep -c sandbox "$TMP/out") sandbox lines"; fi

CASE="--dry-run names the image when the sandbox is on"
fresh sandboxon
printf 'LOOP_SANDBOX=1\n' > "$REPO/.loop/loop.env"
if run_loop --dry-run && grep -q "sandbox: ON" "$TMP/out"; then pass
else fail "$(tail -2 "$TMP/out")"; fi

CASE="the bounds line reports the sessions, the timeout and the alarm"
if grep -qE "MAX_SESSIONS=[0-9]+ UNIT_TIMEOUT=[0-9]+s SESSION_CONTEXT_ALARM=[0-9]+" "$TMP/out"; then pass
else fail "$(grep bounds "$TMP/out")"; fi

# --------------------------------------------------------------------------- the env file

CASE="the env file sets values the shell has not"
fresh envfile
# DELIVERY_LOOP_NOTIFY precisely because run_loop never exports it -- a variable the harness sets
# would be testing the harness, and would pass whether the file was read or not.
printf '# a comment\n\nDELIVERY_LOOP_BELL=0\nDELIVERY_LOOP_NOTIFY=%s\n' "$TMP/notify.sh" \
  > "$REPO/.loop/loop.env"
if run_loop && grep -q "open and waiting" "$LOOP_TEST_DIR/notified" 2>/dev/null; then pass
else fail "the file's DELIVERY_LOOP_NOTIFY never applied"; fi

# The file is where the settings LIVE, not something that fights the command line.
CASE="the shell wins over the env file"
fresh envwins
printf 'LOOP_MODEL=haiku\n' > "$REPO/.loop/loop.env"
if LOOP_MODEL=sonnet run_loop && [ "$(grep -c '^sonnet$' "$LOOP_TEST_DIR/models.txt")" = 5 ] \
   && ! grep -q '^haiku$' "$LOOP_TEST_DIR/models.txt"; then pass
else fail "the file overrode an explicit LOOP_MODEL: $(tr '\n' ' ' < "$LOOP_TEST_DIR/models.txt")"; fi

CASE="a malformed line in the env file is skipped, not executed"
fresh envjunk
printf 'not a pair\nrm -rf /tmp/should-not-run\nDELIVERY_LOOP_BELL=0\n' > "$REPO/.loop/loop.env"
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "$(tail -2 "$TMP/err")"; fi

CASE="the committed template names both credentials and the model"
if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' loop/loop.env.dist \
   && grep -q '^GH_TOKEN=' loop/loop.env.dist \
   && grep -q 'LOOP_MODEL' loop/loop.env.dist \
   && git check-ignore -q .loop/loop.env; then pass
else fail "template incomplete, or the real file is not gitignored"; fi

# --------------------------------------------------------------------------- the harness itself

# Bash reads a script incrementally, so editing it mid-run makes it read a TORN file -- whatever the
# editor left at the byte offset it next reaches. The loop runs from a snapshot.
CASE="a run survives the script being rewritten under it"
fresh tornread
( sleep 1; printf 'this is not valid bash (((\n' > "$REPO/.loop/delivery-loop.sh" ) &
clobber=$!
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "a mid-run edit tore the script: $(tail -2 "$TMP/err")"; fi
wait "$clobber" 2>/dev/null || true
cp "$REPO_ROOT/loop/delivery-loop.sh" "$REPO/.loop/delivery-loop.sh"

CASE="the snapshot is cleaned up afterwards"
if [ "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'delivery-loop.*' -newermt '-2 minutes' 2>/dev/null | wc -l | tr -d ' ')" = 0 ]; then pass
else fail "snapshots left behind in ${TMPDIR:-/tmp}"; fi

# The closing session ticks its own ledger line with a measurement. A "recorded?" check that asked
# only about the ledger would skip the telemetry, which is the only evidence the phases are cut to
# a size a session can hold.
CASE="telemetry is written even when the session ticked its own line"
fresh telemtick
if run_loop && git -C "$REPO" ls-tree -r --name-only feat-one | grep -q '\.ai/telemetry/'; then pass
else fail "no telemetry on the branch: $(git -C "$REPO" ls-tree -r --name-only feat-one | tr '\n' ' ')"; fi

# The loop reads the spec from this tree, copies settings out of it, and the session commits with
# `git add -A` -- so someone else's uncommitted work here would be swept into the unit.
CASE="a dirty driver tree is refused, not swept into the unit"
fresh dirtytree
echo "someone else was editing this" > "$REPO/half-finished.txt"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "uncommitted changes" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="--dry-run says the tree is dirty rather than refusing"
if run_loop --dry-run && grep -q "uncommitted changes" "$TMP/err"; then pass
else fail "a dry run should report it and still print the plan"; fi
rm -f "$REPO/half-finished.txt"

CASE="a tree behind origin/main is refused, not silently rebuilt"
fresh behind
git -C "$REPO" commit -q --allow-empty -m "moved on"
git -C "$REPO" push -q origin main
git -C "$REPO" reset -q --hard HEAD~1
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "behind origin/main" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="--dry-run says the tree is behind rather than refusing"
if run_loop --dry-run && grep -q "behind origin/main" "$TMP/err"; then pass
else fail "a dry run should report it and still print the plan"; fi

# A TOOLCHAIN THAT FELL OVER AND A UNIT THAT IS WRONG LOOK IDENTICAL FROM AN EXIT CODE. Re-running
# the gate costs one `make` and no tokens; escalating falsely costs the rest of an unattended night.
CASE="a gate that fails once and then passes is not an escalation"
fresh flakygate
if LOOP_TEST_MAKE=flaky run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "a flaky gate lost the unit: $(tail -2 "$TMP/err")"; fi

CASE="the retry is the gate's, never the session's"
if [ "$(grep -c 'attempt in 1 2' loop/delivery-loop.sh)" = 1 ] \
   && ! grep -q 'run_claude.*retry' loop/delivery-loop.sh; then pass
else fail "the retry is not confined to prove_unit"; fi

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d test(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nOK -- delivery-loop.sh\n'
