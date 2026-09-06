---
name: implement-spec
description: Implement an approved spec from .ai/specs/, phase by phase, on the subagent-driven-development engine with the verification gate enforced as the per-phase review rubric and a single code review once all phases are done. Triggers on "implement spec", "build from spec", "code the spec", "implement phase X".
---

# Implement Spec

Execute an approved spec under `.ai/specs/{date}-{slug}.md`. This skill is an **overlay on
`superpowers:subagent-driven-development` (SDD)**: SDD owns the execution *machinery*
(per-task fresh implementer, ledger, review package, fix loop); this skill owns the *mapping* —
what a task is, and what the reviewer's rubric is.

## Two ways in

**Interactive** — a human runs `/implement-spec` in a worktree. This session is the SDD
controller: it dispatches a fresh implementer subagent per phase, reviews each against the gate
rubric, and after the last phase runs the final review, `/archive-spec` and `/open-pr`.

**Driven by the delivery loop** — the session's prompt names one `Phase:`. Then **this session
is the implementer** of that one phase: it dispatches no implementer subagent, runs neither
`/archive-spec` nor `/open-pr`, and ends by writing the sentinel the prompt names. A fresh
process per phase is what keeps the loop's context small, and a controller-plus-implementer
layer inside it would double the context for nothing. The per-phase rubric below is the same on
both paths.

## The execution model — one spec phase = one task

A spec is one **delivery unit** — one branch, one PR — named by the checklist line in its
`## Delivery` section, and its **phases are the tasks**, listed as the checklist that opens
`## Progress`. `.loop/parse-ledger.sh` reads both.

Each phase is built with **zero inherited session context**: interactively by a fresh
implementer subagent briefed from the phase text plus the interfaces earlier phases produced,
under the loop by a fresh process. Either way a phase cannot drift on half-remembered
conversation, and the ledger survives compaction.

You do **not** need a separate `writing-plans` pass. The spec phase IS the task brief. Reach
for `superpowers:writing-plans` only when a single phase is too coarse to hand a blind subagent
— it spans several independent files with non-obvious interfaces between them. Then decompose
that one phase into `writing-plans` tasks and run them as SDD sub-tasks; the rest of the spec
still runs phase-as-task.

## Superpowers integration

**Primary engine (interactive) — invoke and follow it:**
- `superpowers:subagent-driven-development` — owns the task loop. Use its `sdd-workspace` and
  `task-brief` scripts, its ledger (`<workspace>/progress.md`), its 5-round fix loop with model
  escalation, and its final whole-branch review. **Do not re-implement any of that here.**
  Under the loop, skip the engine: the loop is the controller.

**Invoked by whoever implements a phase — the subagent interactively, this session under the loop:**
- `superpowers:test-driven-development` — Red → Green → Refactor within the phase; no
  production code before a failing test.
- `superpowers:verification-before-completion` — read full gate output, confirm 0 errors before
  reporting DONE.

**Two overlays this skill contributes to the SDD loop:**

1. **Task mapping** — one spec phase = one task. The interactive implementer subagent runs with
   `model: "opus"`.
2. **The per-task review rubric IS the host's verification gate.** Where vanilla SDD dispatches
   a generic `task-reviewer`, here the per-phase review runs `/sync-context-docs` →
   `/run-gates` as its pass/fail criteria. `/code-review` is **not** part of the per-phase
   rubric — it runs once, over the whole branch, so review reasons about the finished feature
   instead of re-reviewing churn each phase.

## Prerequisites

- The spec exists under `.ai/specs/` — committed on this branch when driven by hand, already on
  `main` under the loop.
- The spec's `## Delivery` ledger names this branch as an unticked unit, and its `## Progress`
  section opens with the phase checklist.
- The spec passed `/pre-implement-spec` with verdict = ready.
- An isolated worktree on a `feat-<slug>` branch exists under `.claude/worktrees/`. Never
  implement on `main`.

If any precondition fails, stop and inform the user — under the loop, write
`ESCALATE:<reason>` to the sentinel.

## Setup

1. Confirm you are inside the worktree on the `feat-<slug>` branch — never on `main`.
2. **Read `## Progress` before the phases**, always. The checklist says which phases are built;
   the notes beneath it are what the sessions before you learned, and without them you will
   redo their work or contradict it.
3. **Resolve this run's unit and phases:**
   ```sh
   .loop/parse-ledger.sh <spec-file>            # done|unit|branch
   .loop/parse-ledger.sh <spec-file> --phases   # done|phase|title
   ```
   Exit 3 means a section is malformed or absent — a failed precondition, not something to work
   around. The unit whose **`branch` field** equals the current branch is this run's scope; a
   unit already ticked `- [x]` means this branch's work is claimed as delivered: stop and ask. A
   ledger that names no unit for this branch is a failed precondition too.
4. **Read the host's rules**: the root `AGENTS.md` / `CLAUDE.md`, and the nearest one to the
   code this spec touches. They are the build rules — this skill does not restate them. The
   host's **skills** the phase must use are named in the phase's own section:
   ```sh
   .loop/parse-ledger.sh <spec-file> --skills "Phase N"   # one host skill per line
   ```
   Under the loop the prompt repeats them as a `Skills:` line.
5. Interactively: resolve the SDD workspace with `scripts/sdd-workspace <spec-file>` and check
   for an existing ledger at `<workspace>/progress.md`. A ledger whose first line names **this
   spec file** means work is resumable — phases with a `Task <N>: complete` line are DONE;
   resume at the first phase without one. The spec's own `## Progress` checklist is the record
   that survives across sessions and machines; the SDD ledger is this session's scratch.
6. Read the spec once. Note its Global Constraints (version floors, naming and copy rules, the
   rules that bind every phase). Scan for cross-phase conflicts and batch them to the user
   before dispatching phase 1. This batch is an **escalation, not a routine confirmation** — it
   happens even in autonomous mode, and phase 1 waits until the conflicts are resolved.
7. **If earlier phases are already ticked, the spec may be describing a tree that has moved.**
   Re-verify the spec's **Current State** section and any `path/to/file:123` references it leans
   on against `origin/main` before dispatching — line numbers rot fastest, and a fresh
   implementer briefed on a stale line number writes against code that is not there.

## Per-phase loop

For each unticked phase, in order.

### 1. Dispatch the implementer

Interactively, record BASE (`git rev-parse HEAD`) first and build the brief from the phase text
— do **not** paste prior-phase summaries or session history. The dispatch carries: one line on
where the phase fits; the phase's deliverables, files and tests verbatim; the interfaces earlier
phases produced (exact signatures the fresh subagent cannot otherwise know); the spec's Global
Constraints; and the build rules below. Under the loop, you are the implementer and the rules
bind you directly:

- **Resolve before writing.** Every type, field, class and file the phase names must resolve
  against the spec and the tree. A contradiction is an escalation, never something to improvise
  past — the spec is a human's gate, and amending it to match what you would rather build
  removes the gate.
- **The phase's skills first.** Invoke every skill the phase's `- **Skills:**` line names — the
  loop's prompt repeats them as `Skills:` — before writing any code, and build through them. They
  are the host's own scaffolds, test runners and checks for exactly this kind of change, resolved
  when the spec was approved; a session that hand-rolls what the host has a skill for produces
  code the host's conventions do not recognise. Interactively, the list goes into the dispatch
  brief verbatim. A named skill that does not exist is an escalation, not something to skip.
- **Test first, always.** Invoke `superpowers:test-driven-development` and follow it: write the
  failing test the phase's section names, watch it fail, write the minimum code that passes,
  refactor with the test green. No production code lands before a failing test that wants it.
- **Follow the host's conventions.** The root `AGENTS.md` / `CLAUDE.md` and the nearest one to
  the code being touched are binding: layout, naming, layering, dependency rules, whatever they
  declare. Where they are silent, follow the shape of the surrounding code.
- **Tests as the host's conventions name them** — the framework, the location and the level the
  host documents, not a convention imported from elsewhere. Every behaviour this phase adds is
  covered.
- **Build only this phase.** Work belonging to a later phase is out of scope, however small it
  looks; the next phase gets its own fresh implementer.

### 2. Handle the report

Interactively, per SDD: DONE → review; DONE_WITH_CONCERNS → read concerns first; NEEDS_CONTEXT
→ provide and re-dispatch; BLOCKED → assess (context vs. model vs. too-large vs.
plan-wrong→escalate). If the spec proves wrong mid-phase, stop, update the spec, re-run
`/pre-implement-spec`, then resume.

### 3. Per-phase review — the gate IS the rubric

This replaces SDD's generic `task-reviewer`. Every phase must pass before its line is ticked:

1. **`/sync-context-docs`** — update the docs for every directory the phase touched, and the
   spec's Changelog.
2. **`/run-gates <base>`** — `origin/main`, or the `Base:` the loop's prompt names. It runs
   every gate the host declares in its committed `.loop/host.env`, each as a parallel subagent.
   **Every gate MUST report PASS.**

**Do not run `/code-review` here.** It runs once over the whole branch after all phases. A gate
failure opens the fix loop.

### 4. Fix loop

Interactively, exactly SDD's loop — 5 rounds max, rounds 1-3 resume the implementer, rounds 4-5
a fresh implementer on a more capable model, every round ending with a scoped re-review (re-run
the failing gate on the fix diff). Never fix findings yourself in the controller session. At the
cap, adjudicate per SDD's breaker (park with a ruling, or STOP + BLOCKED on load-bearing
findings). Under the loop, fix and re-run the failing gate yourself; a gate you cannot turn
green is an `ESCALATE`.

### 5. Complete the phase

- **Commit**: one commit per phase, message
  `feat(<scope>): Phase {N} — {title} (spec: {file})`.
- **Tick the phase** in the spec's `## Progress` checklist and rewrite the notes beneath it:
  what you learned that the spec does not say, what the next phase must know. Commit that with
  the phase or as a docs commit. Under the loop the tick is read from origin, so push it.
- Interactively, append the SDD ledger line:
  `Task <N>: complete (commits <base7>..<head7>, gates green)`.
- Interactively, **pause** and confirm with the user before the next phase — **unless** they
  said "implement all without stopping", in which case run continuously. Under the loop, write
  `CONTINUE` to the sentinel and exit; the next phase is another session's.

## After all phases

Interactively, once every phase is ticked. Under the loop, each numbered step below is its own
fresh session and the prompt names the step; run only that step, push, and write the sentinel:

1. **Final doc sync**: `/sync-context-docs` once more to catch anything from the last phase;
   commit doc changes.
2. **Code review gate (once, over the whole branch)** — the *only* code review in the flow.
   Package the diff with `git diff $(git merge-base "$BASE" HEAD)...HEAD` (never `HEAD~1`),
   where `$BASE` is `origin/main` or the `Base:` the loop's prompt names. Then dispatch
   `/code-review` (reviewers on opus) over that diff, pointed at any parked lines. Resolve every
   Critical and High finding — one fix wave max, one scoped re-review, then adjudicate
   residuals. Commit the fixes.
3. **Delivery ledger + archival**: run `/archive-spec <spec-file>`. It ticks this branch's unit
   and, with every unit ticked, archives the spec into `.ai/specs/implemented/` in this same PR;
   with a unit still owed, only the tick is committed. Nothing archives specs on merge.
4. Push: `git push -u origin $(git rev-parse --abbrev-ref HEAD)`.
5. Interactively, open the PR via `/open-pr`. Under the loop, **do not**: the loop opens it
   after re-running the gates itself. Write `OK` to the sentinel and exit.

## Cleanup — after the PR merges

- Exit the worktree (`ExitWorktree` tool if available, otherwise `cd` to the main repo root).
- `.loop/reclaim-worktree.sh .claude/worktrees/<name>` from the main repo — it removes the
  worktree and prunes.
- `git branch -d feat-<slug>`.
- The SDD workspace (`.superpowers/sdd/<spec-basename>/`) is git-ignored scratch; delete it once
  the final review is clean — git history is the record.

## When things go wrong

- A gate fails on the current phase → routes into the fix loop. When the root cause spans several
  files, invoke `superpowers:systematic-debugging` before touching code.
- The spec proves wrong mid-implementation → stop, update the spec, re-run
  `/pre-implement-spec`, then resume at the current phase. Under the loop, `ESCALATE` instead:
  the spec is a human's gate.
- The controller lost its place after compaction → trust the `## Progress` checklist and
  `git log` over recollection; resume at the first unticked phase.

## Output

End of each phase:

```
✅ Phase {N}: {Title}
   Files:   {count} touched, {count} tests added
   Gates:   {N}/{N} PASS
   Progress: {N}/{total} phases ticked
   Next:    Phase {N+1}: {Title} — proceed?
```

After all phases:

```
✅ All phases complete on branch `feat-<slug>`.
   Final whole-branch code review: {clean | {count} parked minor findings}
   Delivery: {done}/{total} units ticked
             {spec archived to .ai/specs/implemented/
              | spec stays open, still owed: {unit} — `{branch}`}
   Next step: /open-pr

   Cleanup after merge:
   1. Exit worktree
   2. .loop/reclaim-worktree.sh .claude/worktrees/<name>
   3. git branch -d feat-<slug>
```

Report `clean` only when **no** unresolved findings remain. Anything parked or deferred by SDD's
breaker is listed by count and severity, never folded into `clean`.

If autonomous (the user said "implement all phases without stopping"), proceed without asking —
per SDD's continuous-execution rule. Autonomous mode skips **routine confirmations only** (the
end-of-phase "proceed?" pause). It does **not** suppress an escalation: a failed precondition,
an unresolved cross-phase conflict from the pre-flight scan, a BLOCKED implementer report, or a
fix loop that hits its round cap still stops the run and goes to the user.
