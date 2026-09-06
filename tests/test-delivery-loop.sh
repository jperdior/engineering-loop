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
SPEC2_REL=".ai/specs/fixture-two.md"

# One unit with three phases: the shape every spec has.
write_spec() {
  mkdir -p "$1/.ai/specs"
  cat > "$1/$SPEC_REL" <<'SPEC'
# Fixture spec

## Phasing

### Phase 1 — the port

- **Skills:** `scaffold-port`, `port-tests`

### Phase 2 — the adapter

No Skills line: the host has none that apply to this phase.

## Delivery

- [ ] **PR 1** — `feat-one` — the whole thing — est ~100

## Progress

- [ ] **Phase 1** — the port
- [ ] **Phase 2** — the adapter
- [ ] **Phase 3** — the wiring

_Notes:_ not started.
SPEC
}

# A second spec, because the lock is per unit. Two loops in one repository are only observable with
# two units to build. Committed and pushed by the case that wants it, not by `fresh`: every other
# case would otherwise carry a second unit it never builds.
write_spec2() {
  mkdir -p "$1/.ai/specs"
  cat > "$1/$SPEC2_REL" <<'SPEC'
# Fixture spec, the second unit

## Delivery

- [ ] **PR 1** — `feat-two` — the whole thing — est ~100

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
  cp "$REPO_ROOT/loop/loop.env.dist" "$REPO_ROOT/loop/host.env.dist" "$REPO/.loop/"
  # The host contract is committed, like a real host's: the gates the stubbed `make` answers to.
  printf 'LOOP_GATES=make lint;make test\n' > "$REPO/.loop/host.env"
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
  : > "$LOOP_TEST_DIR/session-ids.txt"
  : > "$LOOP_TEST_DIR/resumes.txt"
  : > "$LOOP_TEST_DIR/record-ids.txt"
  : > "$LOOP_TEST_DIR/skills.txt"
}

run_loop() {
  ( cd "$REPO" \
    && PATH="$STUBS:$PATH" \
       UNIT_TIMEOUT="${UNIT_TIMEOUT:-60}" \
       .loop/delivery-loop.sh "$SPEC_REL" "$@" ) >"$TMP/out" 2>"$TMP/err"
}

# Sets BG_PID rather than printing it: `pid=$(run_loop_bg …)` would background the loop inside a
# command-substitution subshell, and a process that is not this shell's child cannot be `wait`ed.
# Each run gets its own out/err, because two loops sharing $TMP/out would assert on each other.
run_loop_bg() {
  spec="$1"; tag="$2"; shift 2
  ( cd "$REPO" \
    && PATH="$STUBS:$PATH" \
       UNIT_TIMEOUT="${UNIT_TIMEOUT:-60}" \
       .loop/delivery-loop.sh "$spec" "$@" ) >"$TMP/out.$tag" 2>"$TMP/err.$tag" &
  BG_PID=$!
}

# The fixture of the in-place flow: a main checkout plus a linked worktree already on the unit's
# branch, with the spec committed THERE and not on main. That is what /ship leaves behind, and it is
# the state the loop has to recognise as "this tree is the unit". Sets WT beside REPO.
fresh_worktree() {
  fresh "$1"
  git -C "$REPO" rm -q "$SPEC_REL"
  git -C "$REPO" commit -qm "the spec rides on the unit's branch, not on main"
  git -C "$REPO" push -q origin main
  WT="$REPO/.claude/worktrees/feat-one"
  git -C "$REPO" worktree add -q -b feat-one "$WT" main
  write_spec "$WT"
  git -C "$WT" add -A
  git -C "$WT" commit -qm "spec: the unit to build"
}

# The loop invoked from the worktree rather than from the driver checkout. The script's ROOT comes
# from its own path, so running the worktree's copy is what makes the worktree the driver.
run_loop_wt() {
  ( cd "$WT" \
    && PATH="$STUBS:$PATH" \
       UNIT_TIMEOUT="${UNIT_TIMEOUT:-60}" \
       .loop/delivery-loop.sh "$SPEC_REL" "$@" ) >"$TMP/out" 2>"$TMP/err"
}

# Polls rather than sleeps: a fixed sleep long enough for a loaded runner is dead time on every
# other run, and one short enough is a flake.
await_dir() {
  i=0
  while [ ! -d "$1" ] && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

ticks()       { git -C "$REPO" show "$2:${3:-$SPEC_REL}" 2>/dev/null | grep -c "^- \[x\] \*\*$1\*\*" || true; }
phase_ticks() { git -C "$REPO" show "$1:$SPEC_REL" 2>/dev/null | grep -c '^- \[x\] \*\*Phase ' || true; }
sessions()    { git -C "$REPO" show "$1:sessions-$1.txt" 2>/dev/null | wc -l | tr -d ' '; }
closing_of()  { git -C "$REPO" show "$1:closing-$1.txt" 2>/dev/null | tr '\n' ';'; }
remote_has()  { git -C "$TMP/$(basename "$REPO").git" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }
remote_tip()  { git -C "$TMP/$(basename "$REPO").git" rev-parse "refs/heads/$1" 2>/dev/null || true; }
statedir()    { printf '%s/.loop/state' "$REPO"; }
lockdir()     { printf '%s/lock' "$(statedir)"; }
record()      { printf '%s/units/%s/session' "$(statedir)" "$1"; }
rec_field()   { sed -n "s/^$1=//p" "$(record "${2:-feat-one}")" 2>/dev/null || true; }
resumed()     { cat "$LOOP_TEST_DIR/resumes.txt" 2>/dev/null || true; }

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
if grep -q "phases: 3, one session each, then 3 closing sessions: docs, review, archive (MAX_SESSIONS=7)" "$TMP/out"; then pass
else fail "$(grep phases "$TMP/out")"; fi

# The skills a phase names are resolved at gate 1, where a human reads the spec; the plan shows them
# beside the phase so what the session will be told is visible before it is paid for.
CASE="--dry-run lists the skills each phase names"
if grep -q "skills: scaffold-port, port-tests" "$TMP/out" \
   && [ "$(grep -c 'skills:' "$TMP/out")" = 1 ]; then pass
else fail "$(grep -c 'skills:' "$TMP/out") skills lines: $(grep skills "$TMP/out")"; fi

# --------------------------------------------------------------------------- the happy path

CASE="the unit is built, ticked once and reclaimed"
fresh happy
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ] && remote_has feat-one \
   && [ ! -d "$REPO/.claude/worktrees/feat-one" ] \
   && [ ! -d "$(lockdir)/feat-one" ]; then pass; else fail "$(tail -3 "$TMP/err")"; fi

# ONE PHASE PER SESSION. A session cannot observe its own context, so the loop bounds it by giving
# it exactly one phase and starting a fresh process for the next. The closing work is split the same
# way: the docs, the review and the archive each get a fresh session, in that order.
CASE="each phase gets its own session, and three more close the unit in order"
if [ "$(sessions feat-one)" = 6 ] \
   && [ "$(git -C "$REPO" show feat-one:sessions-feat-one.txt | sed -n 1p)" = "session feat-one Phase 1" ] \
   && [ "$(git -C "$REPO" show feat-one:sessions-feat-one.txt | sed -n 4p)" = "session feat-one closing:docs" ] \
   && [ "$(git -C "$REPO" show feat-one:sessions-feat-one.txt | sed -n 5p)" = "session feat-one closing:review" ] \
   && [ "$(git -C "$REPO" show feat-one:sessions-feat-one.txt | sed -n 6p)" = "session feat-one closing:archive" ]; then pass
else fail "sessions: $(git -C "$REPO" show feat-one:sessions-feat-one.txt 2>/dev/null | tr '\n' ';')"; fi

CASE="every phase is ticked on the branch"
if [ "$(phase_ticks feat-one)" = 3 ]; then pass; else fail "$(phase_ticks feat-one) of 3 ticked"; fi

CASE="the base is where the unit started, in every session"
if [ "$(sort -u "$LOOP_TEST_DIR/bases.txt" | wc -l | tr -d ' ')" = 1 ] \
   && [ "$(sed -n 1p "$LOOP_TEST_DIR/bases.txt")" = "$(git -C "$REPO" rev-parse origin/main)" ]; then pass
else fail "bases: $(tr '\n' ' ' < "$LOOP_TEST_DIR/bases.txt")"; fi

# The host's skills reach the session through the prompt, not through its skill list: a fresh
# session invokes what it is told to, and a phase whose section names none is told none.
CASE="a phase session is told the skills its section names, and only those"
if grep -qx 'Phase 1|scaffold-port, port-tests' "$LOOP_TEST_DIR/skills.txt" \
   && grep -qx 'Phase 2|' "$LOOP_TEST_DIR/skills.txt" \
   && grep -qx 'closing:docs|' "$LOOP_TEST_DIR/skills.txt"; then pass
else fail "skills: $(tr '\n' ' ' < "$LOOP_TEST_DIR/skills.txt")"; fi

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
fresh telem
run_loop
telem="$(git -C "$REPO" show "feat-one:.ai/telemetry/fixture/PR-1.md" 2>/dev/null || true)"
# shellcheck disable=SC2012
if [ "$(printf '%s\n' "$telem" | grep -c '^| Phase ')" = 3 ] \
   && [ "$(printf '%s\n' "$telem" | grep -c '^| closing:')" = 3 ] \
   && printf '%s' "$telem" | grep -q "peak context" \
   && printf '%s' "$telem" | grep -q "| PR | #"; then pass
else fail "telemetry: $telem; state: $(ls "$REPO/.loop/state/" | tr "\n" " ")"; fi

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
if run_loop && [ "$(grep -c '^opus$' "$LOOP_TEST_DIR/models.txt")" = 6 ] \
   && [ "$(sed -n '$p' "$LOOP_TEST_DIR/models.txt")" = "sonnet" ]; then pass
else fail "models: $(tr '\n' ' ' < "$LOOP_TEST_DIR/models.txt")"; fi

CASE="LOOP_MODEL overrides the build model"
fresh modelsov
if LOOP_MODEL=sonnet run_loop && [ "$(grep -c '^sonnet$' "$LOOP_TEST_DIR/models.txt")" = 7 ]; then pass
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
  if run_loop && [ "$(sessions feat-one)" = 6 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
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

# The closing steps are read from the branch like the phases: the docs and review steps each leave a
# commit, and the archive step's tick is what the loop believes.
CASE="the closing steps land on the branch in order, and the archive is last"
fresh closingorder
run_loop
closing="$(git -C "$REPO" show feat-one:closing-feat-one.txt 2>/dev/null | tr '\n' ';')"
if [ "$closing" = "closing step docs;closing step review;" ] && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "closing steps: $closing"; fi

# --------------------------------------------------------------------------- the local branch

# A local branch that never reached origin may be someone's work. Only an empty one -- what a session
# that never committed leaves behind -- is dropped; one carrying commits stops the run.
CASE="a local branch with unpushed commits is kept, and the run escalates"
fresh localbranch
git -C "$REPO" worktree add -q -b feat-one "$TMP/lb" origin/main
echo mine > "$TMP/lb/mine.txt"
git -C "$TMP/lb" add -A && git -C "$TMP/lb" commit -qm "unpushed work"
git -C "$REPO" worktree remove --force "$TMP/lb"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "never reached origin" "$TMP/err" \
   && [ "$(git -C "$REPO" rev-list --count origin/main..feat-one)" = 1 ]; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="an empty local branch is dropped and the unit is built"
fresh emptybranch
git -C "$REPO" branch feat-one origin/main
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "$(tail -2 "$TMP/err")"; fi

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

# /archive-spec moves the spec to .ai/specs/implemented/ when it ticks the last unit. A loop that then
# looks for it at the old path finds the driver checkout's copy, with nothing ticked, and escalates
# "OK with N phases still unticked" against a unit that is finished. Hit live closing PR 5 of a spec.
CASE="a closing session that archives the spec is read from implemented/, and the unit is recorded there"
fresh archived
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=archived; run_loop ); rc=$?
set -e
archived_ledger="$(git -C "$REPO" show feat-one:.ai/specs/implemented/fixture.md 2>/dev/null | grep '^- \[x\] \*\*PR 1\*\*' || true)"
if [ "$rc" = 0 ] && ! grep -q "ESCALATE" "$TMP/err" \
   && [ -n "$archived_ledger" ] && printf '%s' "$archived_ledger" | grep -q ' → .* (#'; then pass
else fail "exit $rc, ledger: ${archived_ledger:-<none at implemented/>}: $(tail -2 "$TMP/err")"; fi

# The same state a crash between the closing session's push and the record stage leaves behind: the
# ledger is ticked on the branch, the PR may or may not exist, the measurement is not recorded. The
# next run must not review the unit again; it proves, opens or finds the PR, and records.
CASE="a unit whose ledger is ticked on the branch is not closed again"
before="$(sessions feat-one)"
if run_loop && [ "$(sessions feat-one)" = "$before" ] && grep -q "the unit is closed" "$TMP/out"; then pass
else fail "sessions $before -> $(sessions feat-one): $(tail -2 "$TMP/err")"; fi

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
# The head this PR merged is what the branch now points at, which is what makes it THIS unit's PR
# rather than a name it reuses. Without the sha the row proves nothing either way.
merged_sha="$(git -C "$REPO" rev-parse feat-one)"
printf 'feat-one|MERGED|7|APPROVED|2026-09-01T00:00:00Z|%s\n' "$merged_sha" > "$LOOP_TEST_DIR/prs.txt"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 4 ] && grep -q "merged but the ledger is unticked" "$TMP/err"; then pass; else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# A NAME OUTLIVES THE UNIT THAT USED IT. A spec delivered over several passes reuses branch names,
# and `gh pr list --state all` keeps answering with the PR that already merged under one. The
# branch existing on origin does not separate the two cases once a run has pushed its first phase,
# which it does within the hour -- so the retired PR reads as this run's, and hours of built work
# escalate instead of continuing.
CASE="a merged PR whose head is not on the branch is a reused name, not this unit"
fresh stalename
git -C "$REPO" checkout -q -b stale-head main
git -C "$REPO" commit -q --allow-empty -m "the head a retired unit merged"
stale_sha="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b feat-one main
git -C "$REPO" commit -q --allow-empty -m "a phase this run already pushed"
git -C "$REPO" push -q -u origin feat-one
git -C "$REPO" checkout -q main
printf 'feat-one|MERGED|7|APPROVED|2026-09-01T00:00:00Z|%s\n' "$stale_sha" > "$LOOP_TEST_DIR/prs.txt"
set +e
run_loop; rc=$?
set -e
if grep -q "merged but the ledger is unticked" "$TMP/err"; then
  fail "escalated on a retired PR's name (exit $rc)"
elif [ "$(phase_ticks feat-one)" -gt 0 ]; then pass
else fail "exit $rc, no phase built: $(tail -2 "$TMP/err")"; fi

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

# --------------------------------------------------------------------------- the unit directory

# The stub writes the sentinel to the path the PROMPT names; the loop reads the path IT chose. A run
# that converges at all is therefore the proof that both name units/<branch>/status -- half a move
# escalates on "no sentinel was written". The absent old path is what pins which half moved.
CASE="the sentinel is read from the unit directory"
fresh unitdir
if run_loop \
   && [ -f "$(statedir)/units/feat-one/status" ] \
   && [ -d "$(statedir)/units/feat-one/claude-config" ] \
   && [ ! -f "$(statedir)/feat-one.status" ]; then pass
else fail "$(tail -3 "$TMP/err")"; fi

# `units/<branch>` is one path segment, and so is the unit's worktree directory. A branch with a `/`
# in it would put the unit's state a level down from where everything else looks for it.
CASE="a branch name containing / is refused"
fresh slashbranch
sed 's|feat-one|feat/one|' "$REPO/$SPEC_REL" > "$REPO/$SPEC_REL.tmp" && mv "$REPO/$SPEC_REL.tmp" "$REPO/$SPEC_REL"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a branch name with a slash in it"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "may not contain" "$TMP/err" \
   && ! remote_has "feat/one" && [ ! -d "$(statedir)/units/feat" ]; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# --------------------------------------------------------------------------- what a stop keeps

# A pause is not an ending. The refused session left its half-built phase in the worktree, and the
# next invocation resumes into it -- so a run that stops for the usage limit must keep both the
# worktree and the record of what was being built in it.
CASE="a paused run leaves the worktree and a record naming the phase"
fresh paused
rec="$(record feat-one)"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
if [ "$rc" = 5 ] && [ -d "$REPO/.claude/worktrees/feat-one" ] && [ -f "$rec" ] \
   && grep -q '^phase=Phase 2$' "$rec" \
   && grep -qE '^session_id=[0-9a-f-]+$' "$rec" \
   && [ -n "$(remote_tip feat-one)" ] \
   && grep -q "^origin_tip=$(remote_tip feat-one)$" "$rec" \
   && grep -q "^host_pid=[0-9]" "$rec" \
   && grep -q "worktree kept at" "$TMP/out"; then pass
else fail "exit $rc, record: $(tr '\n' ' ' < "$rec" 2>/dev/null): $(tail -2 "$TMP/err")"; fi

# A session that stopped to ask a question wrote no sentinel, and whatever it had done is only in
# the worktree. The answer to the question is worthless if the work was thrown away on the way out.
CASE="an escalated run with no sentinel leaves them"
fresh escleaves
rec="$(record feat-one)"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=silent; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && [ -d "$REPO/.claude/worktrees/feat-one" ] \
   && grep -q '^phase=Phase 1$' "$rec"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# The case this design exists for. SIGKILL leaves no sentinel and no JSON: the exit code and the
# worktree are the whole trace, so the record is the only thing that can name the phase in flight.
CASE="a killed session leaves them"
fresh killedsess
rec="$(record feat-one)"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=killed; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && [ -d "$REPO/.claude/worktrees/feat-one" ] \
   && grep -q '^phase=Phase 1$' "$rec"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# A session that WROTE a sentinel reported on itself, so there is nothing to resume.
CASE="a sentinel-bearing escalation drops the record"
fresh escdrop
rec="$(record feat-one)"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=escalate; run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] && [ -d "$REPO/.claude/worktrees/feat-one" ] && [ ! -f "$rec" ]; then pass
else fail "exit $rc, record: $(tr '\n' ' ' < "$rec" 2>/dev/null): $(tail -2 "$TMP/err")"; fi

CASE="the done path reclaims the worktree and leaves no record"
fresh donepath
rec="$(record feat-one)"
if run_loop && [ ! -d "$REPO/.claude/worktrees/feat-one" ] && [ ! -f "$rec" ]; then pass
else fail "$(tail -3 "$TMP/err")"; fi

# The host mints the id and hands it to the session; the session never invents one. Six build
# sessions and the PR session: seven ids, all distinct.
CASE="every session is launched with an id of its own"
fresh sessionids
if run_loop && [ "$(wc -l < "$LOOP_TEST_DIR/session-ids.txt" | tr -d ' ')" = 7 ] \
   && [ "$(sort -u "$LOOP_TEST_DIR/session-ids.txt" | wc -l | tr -d ' ')" = 7 ]; then pass
else fail "ids: $(tr '\n' ' ' < "$LOOP_TEST_DIR/session-ids.txt")"; fi

# ------------------------------------------------------------------- what the next run picks up

# The phase is not rebuilt, the session is continued. A session commits once, at the END of its
# phase, so a refusal at minute 25 of a 28-minute phase has committed nothing: all of it is
# uncommitted in the worktree. A fresh session on top of that finds half its own work as a
# stranger's and pays for the whole phase again.
CASE="a re-run after a pause resumes the recorded id and the phase is not rebuilt"
fresh resumepause
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
paused_id="$(rec_field session_id)"
if [ "$rc" = 5 ] && [ -n "$paused_id" ] && run_loop \
   && [ "$(resumed)" = "$paused_id" ] \
   && [ "$(sessions feat-one)" = 6 ] && [ "$(phase_ticks feat-one)" = 3 ] \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc, resumed '$(resumed)' want '$paused_id': $(tail -2 "$TMP/err")"; fi

CASE="a re-run after a sentinel-less escalation resumes"
fresh resumesilent
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=silent; run_loop ); rc=$?
set -e
kept_id="$(rec_field session_id)"
kept_tip="$(rec_field origin_tip)"
if [ "$rc" = 4 ] && [ -n "$kept_id" ] && run_loop && [ "$(resumed)" = "$kept_id" ] \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc, resumed '$(resumed)' want '$kept_id': $(tail -2 "$TMP/err")"; fi

# Reads the run above. That session was interrupted before its first push, so the branch was not on
# origin at all and the recorded tip is empty -- and a decision that asked origin about it anyway
# would answer "the branch is gone" and escalate the very first phase.
CASE="an empty recorded tip skips both remote checks"
if [ -z "$kept_tip" ] && ! grep -q "gone from origin" "$TMP/err" \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "recorded tip '$kept_tip': $(tail -2 "$TMP/err")"; fi

# An origin that could not be read is not a branch that was never pushed. This pins the read side
# only, and the tip is injected by hand: `git` is the one binary these suites do not stub.
CASE="a tip the launching run could not read escalates rather than resuming"
fresh tipunknown
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
rec="$(record feat-one)"
[ -f "$rec" ] && sed -e 's/^origin_tip=.*/origin_tip=unknown/' "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec"
set +e
run_loop; rc2=$?
set -e
if [ "$rc" = 5 ] && [ "$rc2" = 4 ] && grep -q "could not read origin" "$TMP/err" \
   && [ -z "$(resumed)" ] && [ -d "$REPO/.claude/worktrees/feat-one" ]; then pass
else fail "exit $rc2, resumed '$(resumed)': $(tail -2 "$TMP/err")"; fi

# A closing step is resumable by the same mechanism. The fourth launch is the docs step.
CASE="an interrupted closing step is resumed"
fresh resumeclose
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota LOOP_TEST_QUOTA_AT=3; run_loop ); rc=$?
set -e
closing_id="$(rec_field session_id)"
if [ "$rc" = 5 ] && [ "$(rec_field phase)" = closing:docs ] && run_loop \
   && [ "$(resumed)" = "$closing_id" ] && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc, phase '$(rec_field phase)', resumed '$(resumed)': $(tail -2 "$TMP/err")"; fi

# Resuming the review must not redo the docs. A run that forgot which closing steps preceded the
# interrupted one would sync the docs a second time, and the review a second time after that.
CASE="resuming a later closing step does not repeat the earlier ones"
fresh resumereview
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota LOOP_TEST_QUOTA_AT=4; run_loop ); rc=$?
set -e
review_id="$(rec_field session_id)"
if [ "$rc" = 5 ] && [ "$(rec_field phase)" = closing:review ] && run_loop \
   && [ "$(resumed)" = "$review_id" ] \
   && [ "$(closing_of feat-one)" = "closing step docs;closing step review;" ] \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc, phase '$(rec_field phase)', closing '$(closing_of feat-one)': $(tail -2 "$TMP/err")"; fi

# A session can push its tick and die before the loop hears it. Its conversation is over -- the work
# is on origin -- so the record describes nothing and resuming it would redo a finished phase.
CASE="a record whose phase is ticked is dropped and the run proceeds"
fresh recticked
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
rec="$(record feat-one)"
sed 's/^phase=.*/phase=Phase 1/' "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec"
if [ "$rc" = 5 ] && run_loop && [ -z "$(resumed)" ] \
   && grep -q "is ticked on origin" "$TMP/out" && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc, resumed '$(resumed)': $(tail -2 "$TMP/err")"; fi

# Someone else advanced the branch while the unit sat paused. A human decides that, and decides it
# before a session is paid for.
CASE="a branch whose tip is not a descendant of the recorded one escalates without a session"
fresh moved
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
launched="$(wc -l < "$LOOP_TEST_DIR/models.txt" | tr -d ' ')"
git -C "$REPO" push -q -f origin "main:refs/heads/feat-one"
set +e
run_loop; rc2=$?
set -e
if [ "$rc" = 5 ] && [ "$rc2" = 4 ] && grep -q "moved under an interrupted session" "$TMP/err" \
   && [ "$(wc -l < "$LOOP_TEST_DIR/models.txt" | tr -d ' ')" = "$launched" ]; then pass
else fail "exit $rc2: $(tail -2 "$TMP/err")"; fi

CASE="a branch gone from origin escalates"
fresh branchgone
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
git -C "$TMP/branchgone.git" update-ref -d refs/heads/feat-one
set +e
run_loop; rc2=$?
set -e
if [ "$rc" = 5 ] && [ "$rc2" = 4 ] && grep -q "gone from origin" "$TMP/err" \
   && [ -d "$REPO/.claude/worktrees/feat-one" ]; then pass
else fail "exit $rc2: $(tail -2 "$TMP/err")"; fi

# A resume into a worktree that still has a writer is worse than rebuilding the phase. The holder is
# a pid whose command line is the recorded snapshot -- `sleep` alone is a recycled PID.
CASE="a record for a live holder escalates"
fresh liveholder
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
printf '#!/bin/sh\nsleep 120\n' > "$TMP/delivery-loop.sh"
chmod +x "$TMP/delivery-loop.sh"
"$TMP/delivery-loop.sh" & holder=$!
rec="$(record feat-one)"
sed -e "s/^host_pid=.*/host_pid=$holder/" -e "s|^snapshot=.*|snapshot=$TMP/delivery-loop.sh|" \
  "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec"
set +e
run_loop; rc2=$?
set -e
kill "$holder" 2>/dev/null || true
if [ "$rc" = 5 ] && [ "$rc2" = 4 ] && grep -q "is still running" "$TMP/err" && [ -f "$rec" ]; then pass
else fail "exit $rc2, record: $([ -f "$rec" ] && echo kept || echo dropped): $(tail -2 "$TMP/err")"; fi

# The transcript the resume names can be gone: pruned, wiped, or never persisted by a container. The
# work is still in the worktree, uncommitted, so the answer is a fresh session told exactly that.
CASE="an unresumable transcript falls back to a fresh session in the kept worktree"
fresh noresume
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
paused_id="$(rec_field session_id)"
ids="$LOOP_TEST_DIR/session-ids.txt"
recids="$LOOP_TEST_DIR/record-ids.txt"
before="$(wc -l < "$ids" | tr -d ' ')"
# Dropped into the kept worktree, uncommitted, the way an interrupted session's half-built phase
# sits there. This file reaching the branch is the proof that the fallback ran in that tree.
echo carried > "$REPO/.claude/worktrees/feat-one/carried-over.txt"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=noresume; run_loop ); rc2=$?
set -e
fallback_id="$(sed -n "$((before + 1))p" "$ids")"
if [ "$rc" = 5 ] && [ "$rc2" = 0 ] && [ "$(resumed)" = "$paused_id" ] \
   && [ -n "$fallback_id" ] && [ "$fallback_id" != "$paused_id" ] \
   && grep -q "could not be resumed" "$TMP/err" \
   && git -C "$REPO" show feat-one:carried-over.txt >/dev/null 2>&1 \
   && [ "$(sessions feat-one)" = 6 ] && [ "$(phase_ticks feat-one)" = 3 ] \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc2, fallback id '$fallback_id' vs paused '$paused_id': $(tail -2 "$TMP/err")"; fi

# A second interruption has to reach the fallback, not the conversation it replaced.
CASE="the fallback rewrites the record with the id it minted"
if [ -n "$fallback_id" ] && [ "$(sed -n 3p "$recids")" = "$paused_id" ] \
   && [ "$(sed -n 4p "$recids")" = "$fallback_id" ]; then pass
else fail "record named '$(sed -n 3p "$recids")' then '$(sed -n 4p "$recids")'"; fi

# A dry run inspecting a paused unit must not destroy the resume it is inspecting.
CASE="--dry-run prints the resume decision and changes nothing"
fresh dryresume
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
paused_id="$(rec_field session_id)"
rec="$(record feat-one)"
set +e
run_loop --dry-run; rc2=$?
set -e
if [ "$rc" = 5 ] && [ "$rc2" = 0 ] \
   && grep -q "resume: Phase 2 from session $paused_id" "$TMP/out" \
   && [ -f "$rec" ] && [ ! -d "$(lockdir)/feat-one" ] \
   && [ -d "$REPO/.claude/worktrees/feat-one" ] && [ -z "$(resumed)" ]; then pass
else fail "exit $rc2, record $([ -f "$rec" ] && echo kept || echo dropped): $(tail -3 "$TMP/out")"; fi

# Reads the run above. The same state the run path escalates on is a line of report here.
CASE="--dry-run reports an escalating resume without escalating"
git -C "$REPO" push -q -f origin "main:refs/heads/feat-one"
set +e
run_loop --dry-run; rc3=$?
set -e
if [ "$rc3" = 0 ] && grep -q "resume: none (feat-one moved under an interrupted session" "$TMP/out" \
   && ! grep -q ESCALATE "$TMP/err" && [ -f "$rec" ]; then pass
else fail "exit $rc3: $(tail -3 "$TMP/out") / $(tail -2 "$TMP/err")"; fi

# --------------------------------------------------------------------------- the lock

CASE="a live loop's lock is respected"
fresh lock1
mkdir -p "$(lockdir)/feat-one"
sleep 120 & sleeper=$!
echo "$sleeper" > "$(lockdir)/feat-one/pid"
set +e
run_loop --dry-run >/dev/null 2>&1   # dry-run takes no lock
( cd "$REPO" && PATH="$STUBS:$PATH" .loop/delivery-loop.sh "$SPEC_REL" ) >"$TMP/out" 2>"$TMP/err"; rc=$?
set -e
kill "$sleeper" 2>/dev/null || true
# The PID is alive but is not a delivery loop: a recycled PID, which must NOT be trusted OR reclaimed.
if [ "$rc" = 3 ] && grep -q "recycled PID" "$TMP/err"; then pass; else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="--force-unlock takes a recycled-PID lock"
sleep 120 & sleeper=$!
mkdir -p "$(lockdir)/feat-one"
echo "$sleeper" > "$(lockdir)/feat-one/pid"
if run_loop --force-unlock; then pass; else fail "$(tail -3 "$TMP/err")"; fi
kill "$sleeper" 2>/dev/null || true

# The holder runs from a snapshot, and the snapshot is not named `.sh`: `mktemp -t
# delivery-loop.XXXXXX` yields `delivery-loop.aB3xYz`, so a liveness check that greps the holder's
# command line for `delivery-loop.sh` reads a LIVE loop as stale and hands its lock to the next run.
CASE="a live holder whose command line is the snapshot path is respected"
fresh locksnap
snap="$TMP/delivery-loop.aB3xYz"
printf '#!/bin/sh\nsleep 120\n' > "$snap"
chmod +x "$snap"
"$snap" & holder=$!
mkdir -p "$(lockdir)/feat-one"
echo "$holder" > "$(lockdir)/feat-one/pid"
echo "$snap"   > "$(lockdir)/feat-one/snapshot"
set +e
run_loop; rc=$?
set -e
kill "$holder" 2>/dev/null || true
if [ "$rc" = 3 ] && grep -q "another delivery loop is running" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="a dead holder's lock is reclaimed, and only its own branch's"
fresh lock2
mkdir -p "$(lockdir)/feat-one" "$(lockdir)/feat-two"
echo "999999" > "$(lockdir)/feat-one/pid"
echo "999998" > "$(lockdir)/feat-two/pid"
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ] && [ -f "$(lockdir)/feat-two/pid" ]; then pass
else fail "$(tail -3 "$TMP/err")"; fi

CASE="the lock is released on the way out"
if [ ! -d "$(lockdir)/feat-one" ]; then pass; else fail "lock left behind"; fi

CASE="--force-unlock takes one branch's lock and not another's"
fresh lockforce
sleep 120 & sleeper=$!
mkdir -p "$(lockdir)/feat-one" "$(lockdir)/feat-two"
echo "$sleeper" > "$(lockdir)/feat-one/pid"
echo "$sleeper" > "$(lockdir)/feat-two/pid"
if run_loop --force-unlock && [ ! -d "$(lockdir)/feat-one" ] \
   && [ "$(cat "$(lockdir)/feat-two/pid")" = "$sleeper" ]; then pass
else fail "$(tail -3 "$TMP/err")"; fi
kill "$sleeper" 2>/dev/null || true

# --force-unlock is the hammer, and this is the one thing it must not reach: the unit's own record
# says a SESSION is running, holding the worktree a resume would reuse.
CASE="--force-unlock refuses while the unit's own session is live"
fresh lockforcelive
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
printf '#!/bin/sh\nsleep 120\n' > "$TMP/delivery-loop.sh"
chmod +x "$TMP/delivery-loop.sh"
"$TMP/delivery-loop.sh" & holder=$!
rec="$(record feat-one)"
sed -e "s/^host_pid=.*/host_pid=$holder/" -e "s|^snapshot=.*|snapshot=$TMP/delivery-loop.sh|" \
  "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec"
set +e
run_loop --force-unlock; rc2=$?
set -e
kill "$holder" 2>/dev/null || true
if [ "$rc" = 5 ] && [ "$rc2" = 3 ] && grep -q "is still running" "$TMP/err" && [ -f "$rec" ]; then pass
else fail "exit $rc2: $(tail -2 "$TMP/err")"; fi

# One loop per unit, several per repository. Two specs, two branches, two worktrees, two unit
# directories: nothing a run writes is shared.
CASE="two loops on two units run at the same time and both exit 0"
fresh twoloops
write_spec2 "$REPO"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "a second unit"
git -C "$REPO" push -q origin main
LOOP_TEST_CLAUDE=slow LOOP_TEST_SLEEP=1 run_loop_bg "$SPEC_REL" one;  one=$BG_PID
LOOP_TEST_CLAUDE=slow LOOP_TEST_SLEEP=1 run_loop_bg "$SPEC2_REL" two; two=$BG_PID
set +e
wait "$one"; rc=$?
wait "$two"; rc2=$?
set -e
# Two exit codes alone would be satisfied by a repository-wide lock the second loop RECLAIMED off
# the first. The reclaim warning is what separates "they never contended" from "one took the
# other's lock and neither noticed".
if [ "$rc" = 0 ] && [ "$rc2" = 0 ] \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ] && [ "$(ticks 'PR 1' feat-two "$SPEC2_REL")" = 1 ] \
   && ! grep -q "reclaiming a stale lock" "$TMP/err.one" "$TMP/err.two"; then pass
else fail "exit $rc / $rc2: $(tail -2 "$TMP/err.one") / $(tail -2 "$TMP/err.two")"; fi

CASE="a second loop on the same unit is refused while the first runs"
fresh lockbusy
LOOP_TEST_CLAUDE=slow LOOP_TEST_SLEEP=2 run_loop_bg "$SPEC_REL" first; first=$BG_PID
set +e
await_dir "$(lockdir)/feat-one"
run_loop; rc=$?
wait "$first"; rc2=$?
set -e
if [ "$rc" = 3 ] && [ "$rc2" = 0 ] && grep -q "another delivery loop is running" "$TMP/err"; then pass
else fail "exit $rc / $rc2: $(tail -2 "$TMP/err")"; fi

# The lock a loop from before this change holds is `lock/` itself, with a `lock/pid` inside it. It
# is repository-wide, and it is respected as such.
CASE="a pre-change repository-wide lock with a live pid is refused"
fresh locklegacylive
printf '#!/bin/sh\nsleep 120\n' > "$TMP/delivery-loop.sh"
chmod +x "$TMP/delivery-loop.sh"
"$TMP/delivery-loop.sh" & holder=$!
mkdir -p "$(lockdir)"
echo "$holder" > "$(lockdir)/pid"
set +e
run_loop; rc=$?
set -e
kill "$holder" 2>/dev/null || true
if [ "$rc" = 3 ] && grep -q "another delivery loop is running" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="a pre-change repository-wide lock with a dead pid is swept"
fresh locklegacydead
mkdir -p "$(lockdir)"
echo "999999" > "$(lockdir)/pid"
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ] && [ ! -f "$(lockdir)/pid" ]; then pass
else fail "$(tail -3 "$TMP/err")"; fi

# The parent is never rmdir'd -- an rmdir would race a sibling loop's mkdir -p -- so every run after
# the first meets one. It carries no pid and no branch, and it means nothing at all.
CASE="an empty lock/ parent left by an earlier run blocks nothing"
fresh lockparent
mkdir -p "$(lockdir)"
if run_loop && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass; else fail "$(tail -3 "$TMP/err")"; fi

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
# worktrees/<name>`, an absolute path. Without the common .git mounted there is no repository inside
# the container at all -- and in place there is no `$ROOT/.git` directory to fall back on, which is
# why the mount is resolved rather than spelled.
CASE="the sandbox mounts the main repo gitdir a worktree points at"
# shellcheck disable=SC2016
if [ "$(grep -c -- '-v "$GIT_COMMON:$GIT_COMMON"' loop/delivery-loop.sh)" = 2 ]; then pass
else fail "a sandboxed unit would have no repository"; fi

CASE="a sandboxed unit is probed for a working repo before a session is paid for"
# shellcheck disable=SC2016
if grep -q 'sandbox_sees_repo "$wt"' loop/delivery-loop.sh \
   && grep -q 'rev-parse --git-dir' loop/delivery-loop.sh; then pass
else fail "no pre-session repo probe"; fi

# --------------------------------------------------------------------- the container the loop owns

# `docker run` is the client, not the container. A kill -9 of the driver leaves a container running
# with the worktree, the common `.git` and GH_TOKEN mounted -- and the next run resumes INTO that
# worktree. These cases build a whole unit through the sandbox path, which the `docker` stub makes
# possible by running `stubs/claude` with the container's own arguments in its own workdir.
CASE="the sandbox mounts the unit's directory and nothing else of the state dir"
fresh sbmounts
# Resolved, because the loop mounts `pwd -P` paths and macOS's mktemp answers through a symlink.
SD="$(cd "$REPO" && pwd -P)/.loop/state"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=ok; run_loop ); rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ] \
   && grep -qx -- "$SD/units/feat-one:$SD/units/feat-one" "$LOOP_TEST_DIR/mounts.txt" \
   && grep -qx -- "$SD/units/feat-one/claude-config:/loop-config" "$LOOP_TEST_DIR/mounts.txt" \
   && ! grep -qx -- "$SD:$SD" "$LOOP_TEST_DIR/mounts.txt"; then pass
else fail "exit $rc, mounts: $(tr '\n' ' ' < "$LOOP_TEST_DIR/mounts.txt" 2>/dev/null)$(tail -2 "$TMP/err")"; fi

# Reads the run above. `--name` is what a human greps for; `--init` is what reaps the CLI's children
# when the container is killed; the cid is what the loop itself kills by. Seven containers: six
# sessions and the PR launch.
CASE="every session container is named, init'd and writes its id"
if grep -q '^delivery-loop-feat-one-' "$LOOP_TEST_DIR/names.txt" \
   && [ "$(sort -u "$LOOP_TEST_DIR/names.txt" | wc -l | tr -d ' ')" = 7 ] \
   && grep -q -- ' --init ' "$LOOP_TEST_DIR/docker-run.txt" \
   && grep -q "^$SD/units/feat-one/cid " "$LOOP_TEST_DIR/cids.txt"; then pass
else fail "names: $(tr '\n' ' ' < "$LOOP_TEST_DIR/names.txt"), cids: $(tr '\n' ' ' < "$LOOP_TEST_DIR/cids.txt")"; fi

CASE="a session that exits 137 leaves a cid the teardown kills and removes"
fresh sbkilled
SD="$(cd "$REPO" && pwd -P)/.loop/state"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=ok LOOP_TEST_CLAUDE=killed
  run_loop ); rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(awk '{ print $2 }' "$LOOP_TEST_DIR/cids.txt")" = "$(cat "$LOOP_TEST_DIR/kills.txt" 2>/dev/null)" ] \
   && [ -s "$LOOP_TEST_DIR/kills.txt" ] \
   && [ ! -f "$SD/units/feat-one/cid" ] \
   && [ -d "$REPO/.claude/worktrees/feat-one" ]; then pass
else fail "exit $rc, killed: $(tr '\n' ' ' < "$LOOP_TEST_DIR/kills.txt" 2>/dev/null)$(tail -2 "$TMP/err")"; fi

# `--rm` does not delete the cid file and docker refuses to start when it already exists -- so the
# launch after a kill would fail before a token is spent.
CASE="a cid file left behind does not block the next launch"
fresh sbstalecid
mkdir -p "$(statedir)/units/feat-one"
echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  > "$(statedir)/units/feat-one/cid"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=ok; run_loop ); rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ]; then pass
else fail "exit $rc: $(tail -3 "$TMP/err")"; fi

# A kept worktree outlives the run that created it. Copying the driver's settings only where the
# worktree is created pins a resumed unit to whatever permissions were current the night it started.
CASE="a reused worktree gets the driver's current settings"
fresh reusesettings
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop )
mkdir -p "$REPO/.claude"
echo '{"permissions":{"allow":["Bash(make gate)"]}}' > "$REPO/.claude/settings.local.json"
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=silent; run_loop )
set -e
if grep -q 'make gate' "$REPO/.claude/worktrees/feat-one/.claude/settings.local.json" 2>/dev/null; then pass
else fail "the settings the driver has now never reached the worktree the run reused"; fi

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

# --------------------------------------------------------------------------- the host contract

# The gates are a fact about the repository, committed in host.env, and a developer's gitignored
# loop.env cannot quietly change them: host.env is read first, and first writer wins.
CASE="the gates come from the committed host.env, over loop.env"
fresh hostenv
printf 'LOOP_GATES=make nothing-of-the-sort\n' > "$REPO/.loop/loop.env"
if run_loop --dry-run && grep -q "gates:  make lint;make test (.loop/host.env)" "$TMP/out"; then pass
else fail "$(grep gates "$TMP/out")"; fi

# There is no default gate. A repository that declares none has not been read yet, and building a
# unit against a gate nobody chose is worse than refusing.
CASE="a repository that declares no gates is refused, naming the file"
fresh nogates
git -C "$REPO" rm -q .loop/host.env
git -C "$REPO" commit -qm "no contract"
set +e
run_loop; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "no gates declared" "$TMP/err" && grep -q "host.env" "$TMP/err" \
   && ! remote_has feat-one; then pass
else fail "exit $rc: $(tail -3 "$TMP/err")"; fi

CASE="a shell override of the gates is reported as such"
fresh shellgates
if LOOP_GATES="make lint" run_loop --dry-run && grep -q "gates:  make lint (the shell)" "$TMP/out"; then pass
else fail "$(grep gates "$TMP/out")"; fi

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
if LOOP_MODEL=sonnet run_loop && [ "$(grep -c '^sonnet$' "$LOOP_TEST_DIR/models.txt")" = 7 ] \
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

# The contract is the host's, so its template carries the gates and its real file is NOT ignored;
# the personal template carries no gate at all.
CASE="the host contract template names the gates, and the real file is committed"
if grep -q '^LOOP_GATES=' loop/host.env.dist \
   && ! grep -q '^LOOP_GATES=' loop/loop.env.dist \
   && ! git check-ignore -q .loop/host.env; then pass
else fail "host.env.dist lacks LOOP_GATES, loop.env.dist still carries it, or host.env is ignored"; fi

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

# --------------------------------------------------------------------------- building in place
#
# One worktree, one branch, one PR. The spec is written in the unit's own worktree and never merged
# on its own, so by the time the loop runs, the tree it is driven from IS the unit. Building a
# second worktree of the same branch beside it is not merely wasteful -- git refuses to check the
# branch out twice, so a loop that cannot build in place escalates instead of building anything.

CASE="driven from a worktree on the unit's branch, the loop builds in place"
fresh_worktree inplace
before_wts="$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"
set +e
run_loop_wt; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ] && [ "$(phase_ticks feat-one)" = 3 ] \
   && grep -q "building in place" "$TMP/out" \
   && [ -d "$WT" ] && [ -f "$WT/sessions-feat-one.txt" ] \
   && [ ! -d "$WT/.claude/worktrees" ] \
   && [ "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" = "$before_wts" ]; then pass
else fail "exit $rc, ticks $(ticks 'PR 1' feat-one), worktrees $(git -C "$REPO" worktree list | tr '\n' ' '): $(tail -3 "$TMP/err")"; fi

# The driver IS the unit, so the only reclaim there has ever been would now delete the human's own
# tree. `rc` and the sessions file are re-asserted from the run above, which is what stops this being
# vacuous: on a script that cannot build in place, the run escalates before the first session, and a
# case that asked only "does $WT still exist" would be green for a unit that was never built.
CASE="a finished unit built in place is never reclaimed"
if [ "$rc" = 0 ] && [ -f "$WT/sessions-feat-one.txt" ] \
   && [ -d "$WT" ] && [ -f "$WT/.ai/specs/fixture.md" ] \
   && ! grep -q "worktree kept at" "$TMP/out" \
   && ! grep -q "reclaim of" "$TMP/err"; then pass
else fail "the driver worktree did not survive its own run: $(tail -3 "$TMP/out")"; fi

# The pause this whole design exists for, on the path that is the default one. In place the dirty
# tree is the driver's own, and a dirty-tree refusal that cannot tell the loop's own half-phase from
# a human's editing makes the resume unreachable. The session record is what tells them apart.
CASE="a paused in-place unit re-runs into its own uncommitted work"
fresh_worktree inplacepaused
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop_wt ); rc=$?
set -e
paused_id="$(rec_field session_id)"
echo "half a phase, uncommitted" > "$WT/carried-over.txt"
set +e
run_loop_wt; rc2=$?
set -e
if [ "$rc" = 5 ] && [ -n "$paused_id" ] && [ "$rc2" = 0 ] \
   && [ "$(resumed)" = "$paused_id" ] \
   && [ "$(ticks 'PR 1' feat-one)" = 1 ] \
   && git -C "$REPO" ls-tree -r --name-only feat-one | grep -q '^carried-over\.txt$'; then pass
else fail "paused $rc, re-run $rc2, resumed '$(resumed)' want '$paused_id': $(tail -3 "$TMP/err")"; fi

# The loop's own settings and its two credentials live in a gitignored file, so a worktree never has
# one of its own -- and in place the driver IS a worktree.
CASE="in place, the env file is read from the main checkout"
fresh_worktree inplaceenv
printf 'LOOP_MODEL=haiku\n' > "$REPO/.loop/loop.env"
if run_loop_wt --dry-run && grep -q "build sessions on haiku" "$TMP/out"; then pass
else fail "the main checkout's env file was not read in place: $(tail -3 "$TMP/out")"; fi
rm -f "$REPO/.loop/loop.env"

# The loop's state hangs off the main checkout, not the driver: a transcript inside the built tree
# would be bind-mounted into every gate's container, and two drivers of one unit would take two locks.
CASE="in place, the unit directory and the lock live under the main checkout"
fresh_worktree inplacestate
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop_wt ); rc=$?
set -e
if [ "$rc" = 5 ] && [ -f "$(record feat-one)" ] && [ ! -d "$WT/.loop/state" ]; then pass
else fail "exit $rc, record at main: $([ -f "$(record feat-one)" ] && echo yes || echo no), state in worktree: $([ -d "$WT/.loop/state" ] && echo yes || echo no)"; fi

CASE="the dirty-tree refusal still applies in place"
fresh_worktree inplacedirty
echo "someone else was editing this" > "$WT/half-finished.txt"
set +e
run_loop_wt; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "uncommitted changes" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

# A feature branch is behind main the moment main moves, so the behind-main refusal would refuse
# every in-place run the day after the branch was cut.
CASE="a branch behind origin/main but level with its own upstream runs in place"
fresh_worktree inplacebehind
git -C "$REPO" commit -q --allow-empty -m "main moved on"
git -C "$REPO" push -q origin main
set +e
run_loop_wt; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ] && ! grep -q "behind origin/main" "$TMP/err"; then pass
else fail "exit $rc: $(tail -3 "$TMP/err")"; fi

CASE="a worktree behind its own upstream is refused in place"
fresh_worktree inplacestale
git -C "$WT" commit -q --allow-empty -m "another run pushed this"
git -C "$WT" push -q origin feat-one
git -C "$WT" reset -q --hard HEAD~1
set +e
run_loop_wt; rc=$?
set -e
if [ "$rc" = 3 ] && grep -q "behind origin/feat-one" "$TMP/err"; then pass
else fail "exit $rc: $(tail -2 "$TMP/err")"; fi

CASE="driven from main, the unit still gets a worktree of its own"
fresh frommain
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_TEST_CLAUDE=quota; run_loop ); rc=$?
set -e
if [ "$rc" = 5 ] && [ -d "$REPO/.claude/worktrees/feat-one" ] \
   && ! grep -q "building in place" "$TMP/out" \
   && grep -q "worktree kept at .*/\.claude/worktrees/feat-one" "$TMP/out"; then pass
else fail "exit $rc: $(tail -3 "$TMP/out")"; fi

# A linked worktree's `.git` is a FILE naming an absolute path into the main repository, so a
# container given only that file has no repository at all -- and in place there is no `$ROOT/.git`
# directory to mount instead.
CASE="the common git directory is what the sandbox mounts"
fresh_worktree inplacesb
COMMON="$(cd "$REPO/.git" && pwd -P)"
WTP="$(cd "$WT" && pwd -P)"
set +e
# shellcheck disable=SC2030,SC2031
( export LOOP_SANDBOX=1 CLAUDE_CODE_OAUTH_TOKEN=x GH_TOKEN=x LOOP_TEST_DOCKER=ok; run_loop_wt ); rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(ticks 'PR 1' feat-one)" = 1 ] \
   && grep -qx -- "$COMMON:$COMMON" "$LOOP_TEST_DIR/mounts.txt" \
   && ! grep -q -- "$WTP/.git:" "$LOOP_TEST_DIR/mounts.txt"; then pass
else fail "exit $rc, mounts: $(tr '\n' ' ' < "$LOOP_TEST_DIR/mounts.txt" 2>/dev/null)$(tail -2 "$TMP/err")"; fi

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
