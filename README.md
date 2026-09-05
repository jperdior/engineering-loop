# engineering-loop

Turns a feature request into a reviewed pull request, unattended, in any repository that Claude Code
can build. You describe the feature and merge two things: the spec, and the PR.

```
/ship <what you want>
        ↓
  interview → spec → audit → the spec's own PR      ▣ you merge it
        ↓
  the loop: one fresh session per spec phase → a closing review session → one PR
                                                    ▣ you merge it
```

Nothing merges itself.

## How it works

**The spec is the plan.** `/ship` interviews you about the feature, writes a spec under `.ai/specs/`,
audits it with four parallel agents, and opens a PR for the spec alone. You review the plan before
any code exists. Once it is merged, the spec's `## Progress` section is a checklist of phases, each
small enough to build in one sitting.

**The loop builds the plan, one phase at a time.** `delivery-loop.sh` creates a worktree on the
spec's branch and starts a fresh `claude -p` session for the first unticked phase. The session builds
that phase, runs the host's gates, commits, ticks the phase in the spec and pushes. The loop reads the
tick back from origin and starts the next session for the next phase. A phase whose session exits
without a tick is not retried: the loop stops and tells you why.

**Every phase starts with an empty context.** A session reads only the spec, the phase it was given
and the code that phase touches. A feature of eleven phases is eleven short sessions, not one long
conversation that degrades as it grows. What one phase needs the next to know is written into the
spec's notes and committed with the tick, so the handover is on the branch, not in anyone's memory.

**A closing session reviews the whole branch.** When every phase is ticked, one more session runs
`/sync-context-docs`, `/code-review` over the full diff and `/archive-spec`. The loop then runs the
gates itself on the host, opens one PR, and stops.

## What the host provides

The engine is vendored into the host at `.loop/`. The host's side of the contract is small:

| The host has | Why |
|---|---|
| a GitHub remote and an authenticated `gh` | the loop pushes the branch and opens the PR |
| `LOOP_GATES` in `.loop/loop.env`, e.g. `make lint;make test` | the commands that must be green: every session runs them through `/run-gates`, and the loop runs them itself on the host before opening the PR |
| its conventions in `AGENTS.md` / `CLAUDE.md` | the skills build to the host's rules; the engine carries none of its own |
| the [superpowers](https://github.com/obra/superpowers) plugin installed in Claude Code | `/ship` interviews with `brainstorming`; `/implement-spec` builds with `test-driven-development` and, interactively, `subagent-driven-development` |
| GNU coreutils (`timeout`), `jq`, `git` | the loop's pre-flight refuses without them |

## Install

From the host repository's root:

```sh
curl -fsSL https://raw.githubusercontent.com/jperdior/engineering-loop/main/install.sh | bash
```

It writes `.loop/` (scripts, skills, sandbox Dockerfile, `loop.env.dist`), symlinks every skill into
`.claude/skills/`, creates `.ai/specs/`, and appends the ignored paths to `.gitignore`. Re-run it to
update; `.loop/loop.env` and `.loop/state/` are left alone. Commit `.loop/`, `.claude/skills/` and
`.gitignore`.

Then:

```sh
cp .loop/loop.env.dist .loop/loop.env && chmod 600 .loop/loop.env
# set LOOP_GATES; optionally LOOP_CLEAN_WORKTREE, LOOP_MODEL
```

## Use

In Claude Code, in the host repository:

```
/ship I want <the feature>
```

Phase A interviews you, writes `.ai/specs/<date>-<slug>.md`, audits it and opens the spec's PR.
Merge it. Run `/ship` again, or name the spec: Phase B runs the loop.

```sh
.loop/delivery-loop.sh .ai/specs/<file>.md --dry-run   # the plan: unit, branch, phases, models, gates
.loop/delivery-loop.sh .ai/specs/<file>.md             # build it
```

Always run the dry run first. It performs the whole pre-flight and prints what the run would do
without creating anything.

The loop creates `.claude/worktrees/<branch>` from `origin/main`, runs one session per unticked
phase on `LOOP_MODEL` (default `opus`), then the closing session, runs `LOOP_GATES` on the host,
opens one PR on `sonnet`, and stops. Merge it.

A run takes as long as the feature takes. There is no budget and no cap on the number of phases; a
unit is built until it is done. The loop rings the terminal when it ends, and `DELIVERY_LOOP_NOTIFY`
can run anything richer.

## The spec's two checklists

The loop reads two things from a spec, both written by `/spec-writing`:

```markdown
## Delivery

- [ ] **PR 1** — `feat-<slug>` — the whole feature — est ~600

## Progress

- [ ] **Phase 1** — the port and its value objects
- [ ] **Phase 2** — the adapter and the migration
- [ ] **Phase 3** — the retriever

_Notes:_ what the last session learned that the spec does not say.
```

The backticked name is the branch. Each phase is one session. The notes are how one session hands
over to the next: a session that discovers something the spec does not say writes it there and
commits it with the tick. `.loop/parse-ledger.sh <spec>` reads the ledger; `--phases` reads the
checklist.

Most features are one unit: one branch, one PR. A spec gets a second unit only for a deployment
seam, such as a migration that must land and settle before the code that reads it.

## When the loop stops

Every exit code means one thing, and the log's last lines say which applies.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | the unit is done and its PR is open, or nothing was owed | review the PR |
| 2 | wrong usage | read the usage line |
| 3 | pre-flight refused, or another loop holds the lock | fix the tree or the tools, re-run |
| 4 | an escalation: the unit is stopped and something is wrong | read `.loop/state/<branch>.json` |
| 5 | paused: the account's usage limit is reached | re-run the same command once it resets |

**Pre-flight refuses (3)** a dirty driver tree, a driver tree behind `origin/main`, a ledger with two
unticked units, a spec with no phase checklist, a missing tool, and under the sandbox an unreachable
Docker daemon. It refuses rather than guessing, because a run driven from a wrong tree builds the
wrong thing for hours.

**An escalation (4)** is a finished session whose result the loop cannot trust: no sentinel, an
`ESCALATE:<reason>` from the session, a permission denial, an API error, a `CONTINUE` whose phase is
not ticked on origin, an `OK` with a phase still unticked, a `## Progress` that stops parsing,
`MAX_SESSIONS` reached, or a red gate on the host. The loop never retries an escalation. The last
session's whole result is in `.loop/state/<branch>.json`.

**A pause (5)** is not a failure. Nothing is wrong with the unit; the account is out of quota until
it resets. Re-running the same command reads the ticks on the branch and continues from the first
unticked phase. Phases already ticked are never rebuilt. The phase that was running when the limit
hit is rebuilt from its start on resume, because the loop removes the worktree on every exit and only
committed work survives.

## What a run records

Two things, both on the branch.

The **ledger tick**: when a unit is done, `/archive-spec` ticks its line in `## Delivery` and the
loop appends the measurement `unit-size.sh` takes of the branch: lines added, split into
implementation and test, files touched, comment ratio, lines of prose that carry context for later
readers, and the PR number. It sits beside the spec's estimate so the next spec's estimate can be
better. Nothing gates on it.

The **telemetry**: `.ai/telemetry/<spec>/<unit>.md` holds one row per session: the phase it built,
turns, notional API cost, peak context, wall clock and model. Peak context is the size of the largest
request the session made. A phase whose session peaks above `SESSION_CONTEXT_ALARM` is flagged in the
log and the telemetry as cut too large; that is a reading to act on in the next spec's phasing, not
a limit the loop enforces.

## Settings

All in `.loop/loop.env`; the shell overrides the file.

| Setting | Default | |
|---|---|---|
| `LOOP_GATES` | `make lint;make test` | the host's gates, in order |
| `LOOP_CLEAN_WORKTREE` | unset | a command run inside a worktree before it is removed |
| `LOOP_SIZE_EXCLUDES` | unset | generated paths excluded from the size the ledger records |
| `LOOP_DENIALS_EXTRA` | unset | host-specific tools a session must never run, e.g. `Bash(make migrate)` |
| `LOOP_MODEL` | `opus` | the model of every build session; the PR session runs on `sonnet` |
| `MAX_SESSIONS` | phases + 2 | sessions per invocation before the unit is declared non-converging |
| `UNIT_TIMEOUT` | `7200` | seconds per session |
| `SESSION_CONTEXT_ALARM` | `150000` | peak context above which a phase is flagged as cut too large; reporting only |
| `LOOP_SANDBOX` | `0` | `1` runs each session in a container with no host credentials |
| `DELIVERY_LOOP_NOTIFY` | unset | a command that receives the headline when the loop needs you |
| `DELIVERY_LOOP_BELL` | `1` | `0` silences the terminal bell on completion and escalation |

## The sandbox

The loop runs `claude -p` with permission prompts bypassed, because an unattended session has nobody
to answer them. A deny list blocks the dangerous verbs by every route to them, but a deny list cannot
enumerate everything, and on the host the session holds your ssh keys and your `gh` login.

`LOOP_SANDBOX=1` runs each session inside `.loop/sandbox/Dockerfile` (`.loop/sandbox/build.sh`
builds it) with the worktree and the main `.git` mounted, the host Docker socket for the gates, and
two credentials from `.loop/loop.env`: `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) and a
`GH_TOKEN` that should be a fine-grained PAT scoped to the repository, with `contents:write` and
`pull_requests:write`. `.loop/setup-loop.sh` asks for both without echoing them.

What it bounds is lateral reach: no `~/.ssh`, no other repositories, no `gh` login, and a token that
cannot merge. What it does not bound is the Docker socket, which the gates need and which a
determined session could escape through. It stops accidents, which is the threat an unattended loop
actually presents. Use it for any run nobody is watching.

## Skills

| Skill | Role |
|---|---|
| `/ship` | the front door: interview → spec → audit → spec PR, then the loop |
| `/spec-writing` | the spec, with the one-line ledger and the phase checklist |
| `/pre-implement-spec` | four parallel audits: gaps, backward compatibility, risk, resolution & self-consistency |
| `/implement-spec` | phase by phase; the implementer of one phase under the loop, the controller interactively |
| `/run-gates` | `LOOP_GATES`, one subagent per command |
| `/sync-context-docs` | the nearest `AGENTS.md` / `CLAUDE.md` of every touched directory |
| `/code-review` | one review over the whole branch, three parallel reviewers |
| `/archive-spec` | tick the ledger, move the spec to `.ai/specs/implemented/` |
| `/open-pr`, `/new-feature` | the PR, the worktree |

## Developing the engine

```sh
bash tests/test-delivery-loop.sh      # the loop, against stubbed claude/gh/make/docker
bash tests/test-parse-ledger.sh
bash tests/test-unit-size.sh
bash tests/test-reclaim-worktree.sh   # from a main checkout, not a linked worktree
bash tests/test-setup-wizard.sh
```

`test-delivery-loop.sh` checks that no loop snapshot is left in `$TMPDIR`, so it cannot run on a
host where a real loop is in flight. CI runs shellcheck and the suites.
