---
name: ship
description: "Take a feature from a sentence to a merged PR — interview, spec, audit, the user's OK, then the unattended loop, which builds one spec phase per fresh session in that same worktree until the feature is built. Two human gates: the spec, and the PR. Triggers on \"ship\", \"build me\", \"let's build\", \"I want a feature that\", \"take this from idea to PRs\"."
---

# Ship

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill
> loads; installed, that is under `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/cache/`. `<state>` is
> `~/.local/state/engineering-loop/<repo>/`, the loop's state for this repository; `--dry-run`
> prints the exact path. Nothing of either lives in the repository.
>
> **Names.** The engine's skills are invoked by their namespaced name, `/engineering-loop:<name>`
> (`/engineering-loop:spec-writing`, `/engineering-loop:new-feature`, …). A bare `/<name>` in this
> text means that one, never a host skill that happens to share the name.

The front door. One command from *"I want X"* to a merged PR, with the human as an
approval gate at exactly two points and everything between automated.

```
  you describe it
        ↓
  A. worktree → interview → spec → audit → revise
        ↓
  ▣ GATE 1 — the spec. You read it, you say OK. Nothing runs until you do.
        ↓
  B. the loop, in that same worktree: one fresh session per spec phase →
     three closing sessions (docs, review, archive) → one PR
        ↓
  ▣ GATE 2 — the PR. You read it, you merge it.
```

**One feature, one worktree, one branch, one PR.** The spec is committed on that branch as
its first commit and reaches `main` in the same PR as the code it describes. The spec's
phases are its commits, and each phase is built by its own session. A session cannot
observe its own context, so the loop bounds it by scope instead: it hands the session
exactly one phase, and starts a fresh process for the next one.

**Gate 1 is a sentence, not a merge.** The user reads the spec in the worktree and says to
go ahead; nothing is built before they do. There is no spec-only PR and no `-spec` branch —
the PR's own history shows what was approved and when, because the spec's commits precede
the code's on the branch.

## Which phase am I in?

Do not ask. Derive it, from inside the feature's worktree:

```sh
git branch --show-current                     # feat-<slug>, or main if there is no worktree yet
<loop>/parse-ledger.sh .ai/specs/{file}.md --phases 2>/dev/null
```

- No worktree, or no spec on this branch → **Phase A**.
- The spec is on this branch and the user has approved it → **Phase B**. Report what
  remains and carry on; do not re-spec.

If the user gave no spec path, search `.ai/specs/*.md` for one matching their
description before assuming Phase A. Resuming a half-finished feature is the
common case, not the exception.

## Phase A — from a sentence to an approved spec

0. **Tools and credentials, before anything else.** A loop that fails on these fails hours in,
   with nobody watching. Check, and stop on the first that fails:
   - `gh auth status`. If it fails, tell the user to run `gh auth login` — or `gh auth switch
     --user <account>` when the repository belongs to another of their accounts — in their
     terminal.
   - `gh api repos/<owner>/<repo> --silent`, with the name from `git remote get-url origin`. If it
     fails while `gh auth status` passed, the token cannot see this repository, and every PR read
     the loop makes later would be a 404. Say it in one line: *the `GH_TOKEN=` line in
     `~/.config/engineering-loop/loop.env` names a token without access to this repository; widen
     it, or run `<loop>/setup-loop.sh` in a terminal and paste one that has it.* Nothing else.
   - `jq`, and `timeout` or `gtimeout`, on PATH. Name the install line otherwise
     (`brew install coreutils jq` on macOS).
   - **Where the sessions run is the user's decision, made once.** Run `<loop>/setup-loop.sh
     --show`: it lists every key in `~/.config/engineering-loop/loop.env` as `set` or `EMPTY`
     without printing a value. The loop refuses to start, dry run included, while `LOOP_SANDBOX`
     is EMPTY or the file is absent, so settle it here rather than discover it in the plan.

     If `LOOP_SANDBOX` is EMPTY or absent, **stop and ask** before anything else, as one question
     with two options (`AskUserQuestion` where the tool exists, otherwise plain text and wait):

     - **In a container (recommended).** Each session sees only the worktree and two tokens of its
       own: the one `claude setup-token` prints, which also decides which Claude account the run
       bills, and a fine-grained GitHub PAT scoped to this repository with *Contents: read and
       write* and *Pull requests: read and write*. Both last about a year. Needs Docker.
     - **On this host.** Each session runs as the user, with their ssh keys, their `gh` login,
       and the Claude account this shell's `CLAUDE_CONFIG_DIR` is logged into. Name that account
       in the option: `claude auth status` prints its `email` and `orgName`.

     Container: tell the user to run `<loop>/setup-loop.sh` in their own terminal, say what it
     asks for so they have both tokens ready, then wait. When they say it is done, run `--show`
     again and stop while either token is EMPTY; then `<loop>/sandbox/build.sh` once if the image
     is missing. Host: run `<loop>/setup-loop.sh --host` yourself; it records `LOOP_SANDBOX=0`
     and asks nothing. Either way, say in one line which mode is recorded and which account will
     be billed. The question never comes back: the file holds the answer for every later run.

     If `LOOP_SANDBOX` is already `1`, stop only while either token is EMPTY, with the same
     instruction to run the script.

   **Never ask for a token value in the chat**, and never accept one pasted there: a token in a
   message lands in the transcript. The script exists so the values never pass through a
   conversation.

1. **Interview.** A design conversation before anything is written. Use the skill the
   host's `AGENTS.md` routes design or brainstorming to; else one in your own skill list
   that does it; else this: read the brief and the code it touches, list the decisions
   with more than one defensible answer, ask them **in one batch** with a recommended
   option each, and end with a short written summary the user confirms. This is the one
   place the user's attention is worth most, so spend it here: scope, the open decisions,
   what is explicitly out. Never one question at a time.

   **Ask about the product, never about the delivery mechanics.** How the work is
   cut, how many PRs it becomes — none of these are questions for the user. The
   answer is fixed: **one unit**, phases as commits, one PR. A deployment seam can
   force a second (a migration that must land and settle before its reader; a
   contract another team is waiting on) — that is a fact you establish from the
   work, state in the ledger, and mention in your Phase A report. It is not a menu.
2. **Worktree.** `/new-feature feat-<slug>`. This is the branch the loop builds
   on and the tree it builds in — no suffix, and no second worktree later.
3. **Draft.** `/engineering-loop:spec-writing`, **always the engine's**, even when the host has
   a spec skill of its own. The loop reads a grammar only this one writes: the `## Delivery`
   ledger line, the `## Progress` checklist, the `## Gates` block, each phase's `Skills:` line.
   When the host's `AGENTS.md` routes spec writing to a skill of its own, read that skill first
   and honour what it says about the host — where specs live, which catalogue of rules to cite,
   what sections the host expects — as input to ours; then say in the Phase A report which
   skill wrote the spec and why. A host spec skill never replaces this step.

   Three things the loop reads: the `## Delivery`
   ledger — **one unit**, whose backticked branch must be **this** branch; the
   phase checklist under `## Progress`, which is what the loop hands to each
   session and checks when it exits; and the `## Gates` section, the host's own
   validation commands derived from its `AGENTS.md` / `CLAUDE.md` for this spec,
   which every session runs and the loop re-runs on the host. The phases are the
   sessions: cut each one to what a single fresh session can read and build. Each
   phase's section names the **host's skills** it must use, resolved from the
   repository's skill index. The user reads all of it at gate 1.

   **The spec is sized to the change**, and `/spec-writing` says which size it is in the
   TLDR: **bounded** (one module, no new contract or table, one or two phases) or **full**.
   A bounded spec is the minimal sections only. A forty-line change does not get a
   four-hundred-line spec; the user has to read it at gate 1, and its length is the
   cost of that gate.
4. **Audit.** `/pre-implement-spec .ai/specs/{file}.md`. It reads the size from the TLDR:
   one audit agent for a bounded spec, four in parallel for a full one.
5. **Revise until the verdict is "ready".** Fix what it found. Re-run the audit only when
   the spec is full and the findings were structural; a bounded spec is fixed and goes to
   the user. Never build anything to check the spec — no scratch implementation, no
   trial run. Do not carry Critical or High findings forward.
6. **Commit the spec** on this branch. Do **not** open a PR for it: it rides in
   the unit's one PR, beside the code.
7. **STOP and wait for the user's OK.** Report the ledger, the phase list and the
   audit verdict, name the worktree, and say plainly that nothing is built yet.
   **Nothing runs until they say so** — not the dry run, not the loop.

Nothing gates on lines: `<loop>/unit-size.sh` reports and always exits 0. What
bounds a session is the phase it is given.

## Phase B — the loop

0. **Run it from the feature's own worktree.** The tree is already on the unit's
   branch and already holds the spec, so the loop builds **in place**: no second
   worktree, no checkout, and no reclaim on any path — the tree was there before
   the run and outlives it. `--dry-run` says `building in place` and names the
   tree; if it does not, the branch does not match the ledger's and you are in the
   wrong tree.

   While a run is in flight the worktree is the loop's. A session commits with
   `git add -A`, so anything left uncommitted there is swept into the unit —
   pre-flight refuses a dirty tree for exactly that reason, and refuses one behind
   the branch's own upstream. Being behind `origin/main` is fine and expected; if
   `main` has moved far enough to matter, `git rebase origin/main` in the worktree
   before the run.

1. **Plan first, always.** Phase B often runs days after Phase A, so re-check the mode
   first: `<loop>/setup-loop.sh --show`. `LOOP_SANDBOX` EMPTY or absent means the choice
   in Phase A step 0 was never recorded; ask it now, the same way. `LOOP_SANDBOX=1` with a
   token EMPTY means the user has to run `<loop>/setup-loop.sh` before anything can start.
   Then:
   ```sh
   <loop>/delivery-loop.sh .ai/specs/{file}.md --dry-run
   ```
   Show the user the plan: the unit, its branch, its phases with their ticks and
   skills, the gates and where they came from, the models, the bounds, and the
   `sandbox:` line, which confirms the mode they chose. It creates nothing and
   finishes in seconds, so it runs in the foreground.
2. **Build, detached.** The run lasts longer than any tool call may, and it must
   outlive this chat session: a foreground command times out, and a plain
   background job is killed when the session ends or the machine is short of
   memory. So the loop is started as its own process group, with its output in a
   log outside the repository, and the session only watches. One plain command does
   it — a worktree-isolated session's guard refuses a compound `nohup bash -c` line,
   so do not write one of your own:
   ```sh
   <loop>/launch.sh .ai/specs/{file}.md
   ```
   It prints the log path (`~/.local/state/engineering-loop/runs/<repo>-<branch>.log`)
   and the pid beside it. Tell the user the log path and that the run survives closing
   this chat.

   Tell the user how to see for themselves, once, at launch:
   ```sh
   tail -1 <log>          # the last line names the run's state; 'delivery-loop: exit N' ends it
   ```

   **Watch with a timer that exits, not with a process that waits.** A monitor on the
   file and a `tail -F | grep` pipeline are both long-lived processes: the machine kills
   them under memory pressure — two Opus sessions and two test stacks are enough — and
   the run carries on with nobody watching. A session that waits on them alone waits
   forever, and the user reads that as a hung feature. The primary signal is therefore
   one background command that sleeps and then prints the last loop line:
   ```sh
   sleep 600; grep '^delivery-loop: ' <log> | tail -1
   ```
   run in the background so that its exit — after its sleep, or when something kills
   it — wakes you. On every wake, read the line it printed, act on it as below, and
   arm the same command again while the run is in flight. A monitor on the file may
   run beside it; it is a bonus, never the thing you rely on. Ten minutes is the
   cadence while building: a phase lasts twenty to forty, and a shorter sleep burns
   turns narrating nothing.

   **Match `^delivery-loop: ` and nothing else.** The log also carries the sessions'
   and the gates' output, and a bare `error` or `fail` matches a passing test's name.
   Relay **only** these events, one sentence each, and only when the line has changed
   since you last spoke: a phase `ticked and pushed`; `paused:`; `ESCALATE`; the PR
   `open and waiting for review`; `delivery-loop: exit N`. Not the sessions starting,
   not the gates running, not the closing steps, not your own watching: the user asked
   for a feature, not a narration. A line that has not changed is not an event — re-arm
   the timer and say nothing. A `delivery-loop: exit N` line, however it is noticed,
   always produces the report in step 3, within one turn of noticing it.

   A log that has not changed for longer than `UNIT_TIMEOUT` (two hours by default)
   is a dead run, not a slow one: check the pid in `<log>.pid` with `ps` before
   saying anything else.

   What the loop does meanwhile: one fresh `claude -p` per unticked phase in this
   worktree, on `LOOP_MODEL` (default `opus`). Each session implements its phase
   directly, runs the spec's gates, commits, ticks the phase under `## Progress`,
   rewrites the notes beneath the checklist, pushes and writes `CONTINUE`. The
   loop reads the tick from origin — a `CONTINUE` whose phase is not ticked is an
   escalation, not progress. When no phase is left, three closing sessions run in
   turn, each fresh: `/sync-context-docs`, then `/code-review` with its fix wave,
   then `/archive-spec`, which writes `OK`. The loop then runs the gates
   **itself** rather than trusting the session's report, opens one PR on
   `sonnet`, attests it on origin, and records the tick with the measurements and
   the PR number.
3. **Report and stop** when the exit line arrives. `exit 0`: the PR, what the
   loop verified, and — from `<state>/telemetry/<spec>/<unit>.md`, the same table the
   PR body carries under `## Sessions` — one row per session: turns, context against
   the alarm, wall clock, model. There is no cost figure, and none is estimated:
   context is what says whether the phasing held. Then wait;
   merging is the user's gate. `exit 5` and `exit 4` are the two sections below.

   **If the log says the PR conflicts with main**, main moved under the build, which
   is ordinary for a run of hours. Resolve it yourself, in the worktree, and say what
   you resolved: `git merge origin/main` — a merge, not a rebase, because it needs no
   force-push and so no permission — then each conflicted file by judgement, never
   `--ours` or `--theirs`: a rule or a paragraph that main moved to another file goes
   where that file now is. Then the spec's gates, then a plain push. Name every file
   that conflicted, and if any of them is code rather than docs, say that the review
   did not see the result and offer `/code-review` on the merge before the user merges.

**The gates are the spec's, and the spec's are the host's.** The `## Gates` section
`/spec-writing` derived from the host's docs is what every session runs and what the
loop re-runs on the host; there is no default, and pre-flight refuses a spec without
one. `--dry-run` prints them with their source.

**If the loop pauses (exit 5), the account's usage limit is reached.** Nothing is
wrong with the unit, and nothing at all happens until the limit resets — which is
hours, and is the one wait the user must not mistake for a hang. So say two things,
once: that the run is paused on the usage limit, and **when it resumes**. The reset
time is in the refused session's own result: `jq -r .result <state>/<branch>.json`
prints the CLI's message, `You've hit your … limit · resets 3:20am (UTC)`. Then keep
the ten-minute timer running silently, and when the reset time has passed, re-run the
launch yourself:
```sh
<loop>/launch.sh .ai/specs/{file}.md
```
The user's OK at gate 1 covers the whole build; a pause changes nothing about the
unit, and asking for a second OK at four in the morning is what leaves a run idle
until breakfast. Relaunching **continues the refused session** — `claude --resume`
on the id in `<state>/units/<branch>/session`, in the worktree that session left —
rather than rebuilding its phase. A session commits once, at the end of its phase, so
the refused one's work is uncommitted in that worktree and nowhere else. Built in
place, that worktree is the user's own and is never reclaimed by anything; deleting
`units/<branch>/session` is what refuses the resume, and that is the user's call,
not yours. `--dry-run` prints the decision as a `resume:` line and changes nothing,
so run it first and relay only a `resume:` line that is not the expected one.

**Read the telemetry, every time.** A session's context — the window it held at its
last call — is the only evidence that its phase was cut to a size one session can
hold. The alarm is half the model's window unless `SESSION_CONTEXT_ALARM` names a
token count. A row over it means the phase was too large; the fix is in the spec's
phasing, not in the session. Much of every row is what a session carries before it
does anything — the host's docs and the prompt — so read rows against each other, not
against zero.
`SESSION_CONTEXT_ALARM` is a reading on the telemetry, never something a session
is told — a session cannot observe its own context.

## When the loop escalates (exit 4)

It stopped because the unit is **finished and wrong**, which is not the same as
unfinished. Never retry it blindly. Read `<state>/<branch>.json` — the last
session's whole result is there, and it is the only thing that can explain a
failure the one-line sentinel cannot. Every session's result is beside it as
`<branch>.s<run>-<pid>-<n>.json`.

The worktree is still there. If the session wrote **no** sentinel — it stopped to
ask, timed out, or was killed — so is `<state>/units/<branch>/session`, naming
the phase that was in flight, and a re-run resumes that session rather than
rebuilding its phase: answering the question and re-running is the ordinary path. A
session that wrote `ESCALATE:` reported on itself and had its say, so its record is
dropped; the worktree stays, and a re-run builds that phase fresh in it. Either way,
read the worktree before deciding anything — an escalation leaves work on disk that
no commit mentions. Built in place, the worktree is the user's own — do not offer to
reclaim it at all. A worktree the loop created (a run driven from `main`) goes with
`<loop>/reclaim-worktree.sh <path>`, and only once the user has decided what happens
to that work.

| Sentinel / signal | What actually happened |
|---|---|
| no sentinel written, twice | the session ended its turn early — asked something, or backgrounded its gates and waited for a next turn it never gets. The loop resumed that conversation once; it ended the same way |
| `ESCALATE:<reason>` | the session knew it was blocked and said so |
| `permission_denials` non-empty | a tool was denied; it reports as success everywhere else |
| `is_error: true` | a hard API error, reported alongside `subtype: "success"` |
| "handed over without ticking Phase N" | the session pushed but did not finish its phase |
| "a phase session wrote OK" | the session skipped to the closing sentinel; nothing was reviewed |
| "the closing step … ran with N phase(s) still unticked" | a closing session ran with work still owed |
| "the archive step wrote OK but … is not ticked" | `/archive-spec` did not tick the ledger line |
| "the ## Progress checklist no longer parses" | a session broke the checklist it was told to tick |
| still not finished after `MAX_SESSIONS` | it is not converging — the spec is probably contradictory |
| a closed, unmerged PR | a human rejected the unit |
| a `LOOP_GATES` command red | the loop's own gate, on the host, not the session's claim |

## Never

- **Never** run Phase B before the user has said OK to the spec. Gate 1 is theirs,
  and an unread spec built overnight is the one failure this whole flow exists to
  prevent.
- **Never** open a PR for the spec, and never put it on a branch of its own. It is
  the unit's first commit and ships in the unit's one PR.
- **Never** skip the `--dry-run`.
- **Never** wait on a monitor or a `tail -F` alone. The sleeping timer that exits is
  what wakes you; a run reported late is a run the user believes is hung.
- **Never** resolve a conflict with `--ours`/`--theirs`, and never rebase and force-push
  a unit's branch: merge `origin/main` into it, so the history the review saw stands.
- **Never** merge anything on the user's behalf. Both gates are theirs.
- **Never** open a PR per phase. The phases are commits on one branch behind one PR.
- **Never** retry an escalated unit without reading the persisted JSON first.
- **Never** report a run as verified without saying whether the gates actually
  ran. Under `LOOP_SANDBOX=1` pre-flight refuses when the container cannot reach
  the Docker daemon; on the host the gates run as you. Either way the loop's own
  host-side `LOOP_GATES` run is the check that counts, never the session's claim.
