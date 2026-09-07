---
name: implement-spec
description: "Implement an approved spec from .ai/specs/, phase by phase — a fresh implementer per phase, the verification gate as the per-phase review rubric, and a single code review once all phases are done. Triggers on \"implement spec\", \"build from spec\", \"code the spec\", \"implement phase X\"."
---

# Implement Spec

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.
> **Names.** The engine's skills are invoked as `/engineering-loop:<name>`; a bare `/<name>` in this
> text means that one, never a host skill sharing the name.

Execute an approved spec under `.ai/specs/{date}-{slug}.md`, one phase at a time, each phase by an
implementer that starts with no inherited context. This skill owns the *mapping* — what a task is,
who builds it, and what the reviewer's rubric is.

## Two ways in

**Interactive** — a human runs `/implement-spec` in a worktree. This session is the **controller**:
it dispatches a fresh implementer subagent per phase, reviews each against the gate rubric, and
after the last phase runs the final review, `/archive-spec` and `/open-pr`.

**Driven by the delivery loop** — the session's prompt names one `Phase:`. Then **this session
is the implementer** of that one phase: it dispatches no implementer subagent, runs neither
`/archive-spec` nor `/open-pr`, and ends by writing the sentinel the prompt names. A fresh
process per phase is what keeps the loop's context small, and a controller-plus-implementer
layer inside it would double the context for nothing. The per-phase rubric below is the same on
both paths.

## Method

Where this skill needs a way of working, it takes, in order: the skill the host's root `AGENTS.md` /
`CLAUDE.md` routes that job to; else a skill in your own skill list that does it, whichever plugin
provides it; else the steps written here. Nothing outside this plugin is required.

- **Test first.** Write the failing test the phase's section names, run it and watch it fail for the
  reason expected, write the minimum code that passes, refactor with the test green. No production
  code lands before a failing test that wants it.
- **Verify before claiming done.** Read the complete gate output. DONE means every gate exited 0
  and you read zero errors; a summary line or a green-looking tail is not evidence.
- **Debug systematically** when a failure spans several files: reproduce it, read the whole
  failure, form one hypothesis, test that hypothesis before changing code, and change one thing
  at a time. Never patch the symptom to turn the gate green.
- **There is no separate plan.** The spec phase IS the task brief. A phase too coarse to hand a
  blind implementer — several independent files with non-obvious interfaces between them — is split
  in the dispatch brief into ordered sub-tasks, each with its files and its test, and built in that
  order by the same implementer; the spec's phase stays the unit that is ticked.

## The execution model — one spec phase = one task

A spec is one **delivery unit** — one branch, one PR — named by the checklist line in its
`## Delivery` section, and its **phases are the tasks**, listed as the checklist that opens
`## Progress`. `<loop>/parse-ledger.sh` reads both.

Each phase is built with **zero inherited session context**: interactively by a fresh
implementer subagent briefed from the phase text plus the interfaces earlier phases produced,
under the loop by a fresh process. Either way a phase cannot drift on half-remembered
conversation, and the record survives compaction: the spec's own `## Progress` checklist and
`git log` are the ledger, and there is no other.

**The per-phase review rubric IS the host's verification gate.** The per-phase review runs
`/sync-context-docs` → `/run-gates` as its pass/fail criteria. `/code-review` is **not** part of
the per-phase rubric — it runs once, over the whole branch, so review reasons about the finished
feature instead of re-reviewing churn each phase.

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
   <loop>/parse-ledger.sh <spec-file>            # done|unit|branch
   <loop>/parse-ledger.sh <spec-file> --phases   # done|phase|title
   ```
   Exit 3 means a section is malformed or absent — a failed precondition, not something to work
   around. The unit whose **`branch` field** equals the current branch is this run's scope; a
   unit already ticked `- [x]` means this branch's work is claimed as delivered: stop and ask. A
   ledger that names no unit for this branch is a failed precondition too.
4. **Read the host's rules**: the root `AGENTS.md` / `CLAUDE.md`, and the nearest one to the
   code this spec touches. They are the build rules — this skill does not restate them. The
   host's **skills** the phase must use are named in the phase's own section:
   ```sh
   <loop>/parse-ledger.sh <spec-file> --skills "Phase N"   # one host skill per line
   ```
   Under the loop the prompt repeats them as a `Skills:` line.
5. Interactively: the first unticked phase under `## Progress` is where work resumes. There is no
   scratch ledger to consult; a phase is done when its line is ticked and its commit is on the
   branch, and `git log` confirms the second.
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
— do **not** paste prior-phase summaries or session history. The dispatch is one subagent with
`model: "opus"`, and it carries: one line on where the phase fits; the phase's deliverables,
files and tests verbatim; the interfaces earlier phases produced (exact signatures the fresh
subagent cannot otherwise know); the spec's Global Constraints; the host's skills the phase
names; and the build rules below. It ends by asking for a one-word report — `DONE`,
`DONE_WITH_CONCERNS` followed by the concerns, `NEEDS_CONTEXT` followed by the question, or
`BLOCKED` followed by the reason. Under the loop, you are the implementer and the rules bind you
directly:

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
- **Test first, always** — the Method above, or the host's own test-first skill where its
  `AGENTS.md` names one: the failing test the phase's section names, watched to fail, then the
  minimum code, then the refactor with the test green.
- **Follow the host's conventions.** The root `AGENTS.md` / `CLAUDE.md` and the nearest one to
  the code being touched are binding: layout, naming, layering, dependency rules, whatever they
  declare. Where they are silent, follow the shape of the surrounding code.
- **Tests as the host's conventions name them** — the framework, the location and the level the
  host documents, not a convention imported from elsewhere. Every behaviour this phase adds is
  covered.
- **Build only this phase.** Work belonging to a later phase is out of scope, however small it
  looks; the next phase gets its own fresh implementer.

### 2. Handle the report

Interactively: `DONE` → review; `DONE_WITH_CONCERNS` → read the concerns before anything else, and
treat one that names a spec contradiction as `BLOCKED`; `NEEDS_CONTEXT` → answer it from the spec
and the tree and re-dispatch the same implementer; `BLOCKED` → decide which it is — missing context
(provide it), a phase too large for one brief (split it, per the Method), or a spec that is wrong
(stop, update the spec, re-run `/pre-implement-spec`, then resume at this phase). Never build the
phase yourself in the controller session.

### 3. Per-phase review — the gate IS the rubric

Every phase must pass before its line is ticked:

1. **`/sync-context-docs`** — update the docs for every directory the phase touched, and the
   spec's Changelog.
2. **`/run-gates <base>`** — `origin/main`, or the `Base:` the loop's prompt names. It runs
   every gate the spec's `## Gates` section declares, each as a parallel subagent. **Every gate
   MUST report PASS.**

**Do not run `/code-review` here.** It runs once over the whole branch after all phases. A gate
failure opens the fix loop.

### 4. Fix loop

Interactively, at most **five rounds**. Rounds 1–3 resume the same implementer with the failing
gate's complete output and nothing else added; rounds 4–5 dispatch a fresh implementer on the most
capable model available, briefed with the phase and the failure. Every round ends with a scoped
re-check: re-run the failing gate on the fix diff. Never fix findings yourself in the controller
session — the implementer that has the context fixes them. At the cap, stop: report the failing
gate, the five attempts and what each changed, and hand the decision to the user. Under the loop,
fix and re-run the failing gate yourself; a gate you cannot turn green is an `ESCALATE`.

### 5. Complete the phase

- **Commit**: one commit per phase, message
  `feat(<scope>): Phase {N} — {title} (spec: {file})`.
- **Tick the phase** in the spec's `## Progress` checklist and rewrite the notes beneath it:
  what you learned that the spec does not say, what the next phase must know. Commit that with
  the phase or as a docs commit. Under the loop the tick is read from origin, so push it.
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
- `<loop>/reclaim-worktree.sh .claude/worktrees/<name>` from the main repo — it removes the
  worktree and prunes.
- `git branch -d feat-<slug>`.

## When things go wrong

- A gate fails on the current phase → routes into the fix loop. When the root cause spans several
  files, debug systematically (the Method above) before touching code.
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
   2. <loop>/reclaim-worktree.sh .claude/worktrees/<name>
   3. git branch -d feat-<slug>
```

Report `clean` only when **no** unresolved findings remain. Anything parked at the fix loop's cap
is listed by count and severity, never folded into `clean`.

If autonomous (the user said "implement all phases without stopping"), proceed without asking.
Autonomous mode skips **routine confirmations only** (the end-of-phase "proceed?" pause). It does
**not** suppress an escalation: a failed precondition, an unresolved cross-phase conflict from the
pre-flight scan, a BLOCKED implementer report, or a fix loop that hits its round cap still stops the
run and goes to the user.
