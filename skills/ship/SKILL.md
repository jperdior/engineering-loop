---
name: ship
description: Take a feature from a sentence to a merged PR — interview, spec, audit, spec PR, then the unattended loop, which builds one spec phase per fresh session until the feature is built. Two human gates: the spec, and the PR. Triggers on "ship", "build me", "let's build", "I want a feature that", "take this from idea to PRs".
---

# Ship

The front door. One command from *"I want X"* to a merged PR, with the human as an
approval gate at exactly two points and everything between automated.

```
  you describe it
        ↓
  A. interview → spec → audit → revise
        ↓
  ▣ GATE 1 — the spec PR. You read it, you merge it.
        ↓
  B. the loop: one fresh session per spec phase → a closing session
     (review, ledger tick, archive) → one PR
        ↓
  ▣ GATE 2 — the PR. You read it, you merge it.
```

**One feature, one branch, one PR.** The spec's phases are its commits, and each phase is
built by its own session. A session cannot observe its own context, so the loop bounds it
by scope instead: it hands the session exactly one phase, and starts a fresh process for
the next one.

**The spec ships first, alone, and is merged before any code is built.** The loop creates
the worktree from `main` and copies in nothing but `settings.local.json`, so a spec that is
not on `main` is not in the worktree, and the session is told to implement a file that
does not exist.

## Which phase am I in?

Do not ask. Derive it:

```sh
git fetch origin --quiet
git cat-file -e "origin/main:.ai/specs/{file}.md" 2>/dev/null && echo BUILD || echo SPEC
```

- The spec is **not** on `origin/main` → **Phase A**.
- The spec **is** on `origin/main` → **Phase B**. Report what remains and carry
  on; do not re-spec.

If the user gave no spec path, search `.ai/specs/*.md` for one matching their
description before assuming Phase A. Resuming a half-finished feature is the
common case, not the exception.

## Phase A — from a sentence to a merged spec

1. **Interview.** Invoke `superpowers:brainstorming`. This is the one place the
   user's attention is worth most, so spend it here: scope, the decisions with
   more than one defensible answer, what is explicitly out. Ask questions in
   batches, not one at a time.

   **Ask about the product, never about the delivery mechanics.** How the work is
   cut, how many PRs it becomes — none of these are questions for the user. The
   answer is fixed: **one unit**, phases as commits, one PR. A deployment seam can
   force a second (a migration that must land and settle before its reader; a
   contract another team is waiting on) — that is a fact you establish from the
   work, state in the ledger, and mention in your Phase A report. It is not a menu.
2. **Worktree.** `/new-feature feat-<slug>-spec`. The `-spec` suffix keeps this
   branch distinguishable from the branch the loop builds on.
3. **Draft.** `/spec-writing`. Two things the loop reads: the `## Delivery`
   ledger — **one unit**, whose backticked branch is the branch the loop builds
   on — and the phase checklist under `## Progress`, which is what the loop
   hands to each session and checks when it exits. The phases are the sessions:
   cut each one to what a single fresh session can read and build.
4. **Audit.** `/pre-implement-spec .ai/specs/{file}.md`. Four parallel agents.
5. **Revise until the verdict is "ready".** Fix what it found; re-run it if the
   findings were structural. Do not carry Critical or High findings into a PR.
6. **Open the spec PR.** `/open-pr`. It applies only labels the repository already defines;
   a documentation label fits if there is one.
7. **STOP.** Report the ledger, the phase list and the audit verdict. Say plainly
   that nothing is built yet and that merging is the gate.

Nothing gates on lines: `.loop/unit-size.sh` reports and always exits 0. What
bounds a session is the phase it is given.

## Phase B — the loop

0. **Drive from a tree nobody else is editing.** The loop reads the spec and the
   settings from the tree you invoke it in, and the session it starts commits with
   `git add -A`, so someone else's uncommitted work there is swept into the unit.
   Pre-flight refuses a dirty tree and a tree behind `origin/main`; commit, stash
   or pull first. Do **not** create a worktree for this: the sandbox mounts
   `$ROOT/.git`, which in a linked worktree is a file pointing into the main repo,
   and the container would not resolve the repository at all.

1. **Plan first, always.**
   ```sh
   .loop/delivery-loop.sh .ai/specs/{file}.md --dry-run
   ```
   Show the user the plan: the unit, its branch, its phases with their ticks, the
   models, the bounds. It creates nothing.
2. **Build.**
   ```sh
   .loop/delivery-loop.sh .ai/specs/{file}.md
   ```
   The loop creates one worktree and runs one fresh `claude -p` per unticked
   phase, on `LOOP_MODEL` (default `opus`). Each session implements its phase
   directly, runs the gates, commits, ticks the phase under `## Progress`,
   rewrites the notes beneath the checklist, pushes and writes `CONTINUE`. The
   loop reads the tick from origin — a `CONTINUE` whose phase is not ticked is an
   escalation, not progress. When no phase is left, a closing session runs
   `/sync-context-docs`, `/code-review`, `/archive-spec`, pushes and writes `OK`;
   the loop then runs `LOOP_GATES` **itself** rather than trusting the session's
   report, opens one PR on `sonnet`, attests it on origin, and records the tick
   with the measurements and the PR number.
3. **Report and stop.** The PR, what the loop verified, and — from
   `.ai/telemetry/<spec>/` — one row per session: turns, cost, peak context
   against `SESSION_CONTEXT_ALARM`, wall clock, model. Then wait; merging is the
   user's gate.

**The gates are the host's own.** `LOOP_GATES` in `.loop/loop.env` is a
semicolon-separated list of shell commands run from the repo root, in order
(default `make lint;make test`). The loop runs them, and so does `/run-gates`.

**If the loop pauses (exit 5), the account's usage limit is reached.** Nothing is
wrong with the unit. Say so, and when the user says to continue, re-run the same
command: the loop reads the ticks on the branch and carries on from the first
unticked phase.

**Read the telemetry, every time.** A session's peak context is the only evidence
that its phase was cut to a size one session can hold. A row over the alarm means
the phase was too large; the fix is in the spec's phasing, not in the session.
`SESSION_CONTEXT_ALARM` is a reading on the telemetry, never something a session
is told — a session cannot observe its own context.

## When the loop escalates (exit 4)

It stopped because the unit is **finished and wrong**, which is not the same as
unfinished. Never retry it blindly. Read `.loop/state/<branch>.json` — the last
session's whole result is there, and it is the only thing that can explain a
failure the one-line sentinel cannot. Every session's result is beside it as
`<branch>.s<run>-<n>.json`.

| Sentinel / signal | What actually happened |
|---|---|
| no sentinel written | the session stopped to ask something, and exited 0 doing it |
| `ESCALATE:<reason>` | the session knew it was blocked and said so |
| `permission_denials` non-empty | a tool was denied; it reports as success everywhere else |
| `is_error: true` | a hard API error, reported alongside `subtype: "success"` |
| "handed over without ticking Phase N" | the session pushed but did not finish its phase |
| "a phase session wrote OK" | the session skipped to the closing sentinel; nothing was reviewed |
| "OK was written with N phase(s) still unticked" | the closing session ran with work still owed |
| "the ## Progress checklist no longer parses" | a session broke the checklist it was told to tick |
| still not finished after `MAX_SESSIONS` | it is not converging — the spec is probably contradictory |
| a closed, unmerged PR | a human rejected the unit |
| a `LOOP_GATES` command red | the loop's own gate, on the host, not the session's claim |

## Never

- **Never** run Phase B before the spec is on `origin/main`. The worktree will
  not contain it.
- **Never** skip the `--dry-run`.
- **Never** merge anything on the user's behalf. Both gates are theirs.
- **Never** open a PR per phase. The phases are commits on one branch behind one PR.
- **Never** retry an escalated unit without reading the persisted JSON first.
- **Never** report a run as verified without saying whether the gates actually
  ran. Under `LOOP_SANDBOX=1` pre-flight refuses when the container cannot reach
  the Docker daemon; on the host the gates run as you. Either way the loop's own
  host-side `LOOP_GATES` run is the check that counts, never the session's claim.
