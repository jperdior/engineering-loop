# engineering-loop

A set of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills and a small bash
engine that turn a feature request into a reviewed pull request, unattended, in any repository
Claude Code can build.

You describe the feature. You approve two things: the spec, and the PR. Everything in between is
automated, and nothing merges itself.

```
/ship <what you want>
        │
        ▼
  worktree ─▶ interview ─▶ spec ─▶ audit        ▣  you read the spec, you say OK
        │
        ▼
  one fresh session per spec phase ─▶ closing review ─▶ one PR
                                                  ▣  you read it, you merge it
```

## What it does

- **Interviews you and writes a spec.** `/ship` creates the feature's worktree, uses a structured
  interview to pin down scope and the decisions with more than one defensible answer, writes the
  spec under `.ai/specs/` as the branch's first commit, audits it with four parallel agents, and
  stops for your OK. You review the plan before any code exists.
- **Builds the spec one phase at a time.** Once you say go, the delivery loop runs in that same
  worktree and starts a fresh `claude -p` session for the first unticked phase. The session writes
  the failing test first, then the code, runs your repository's gates, commits, ticks the phase in
  the spec, and pushes. The loop reads the tick back from origin and starts the next session.
- **Reviews the whole branch, then opens one PR.** When every phase is ticked, three closing
  sessions run in turn: one syncs the context docs, one runs a three-reviewer code review over the
  full diff and fixes what it finds, one archives the spec. The loop then runs your gates itself on
  the host and opens the PR.
- **Stops when something is wrong.** A session that exits without proof of progress is never
  retried. The loop stops, says why, and leaves the last session's full result on disk.

## Why

- **Small contexts, by construction.** A session cannot see how many tokens it holds, so asking it
  to stay small does nothing. The loop bounds context by scope instead: each session gets exactly
  one phase and a fresh process. An eleven-phase feature is eleven short sessions, not one long
  conversation that degrades as it grows.
- **The handover is on the branch.** What one phase learns that the next must know is written into
  the spec's notes and committed with the tick. Nothing lives in anyone's memory, and a run
  interrupted by a usage limit resumes the interrupted session in the worktree it left.
- **Proof, not claims.** The loop never takes a session's word for anything: the tick is read from
  origin, the pushed sha is checked against the sentinel, the gates are re-run on the host, and
  the PR is confirmed to exist before it is recorded.
- **Your rules, not the engine's.** The skills build to whatever your `AGENTS.md` or `CLAUDE.md`
  declares, and run whatever gates you name. The engine carries no architecture opinions of its
  own.
- **Two human gates, clearly placed.** You spend attention on the spec, where it matters most, and
  on the final PR. The loop never merges.

## How it works

**The spec is the plan.** `/spec-writing` produces a spec whose `## Delivery` section names one
branch and whose `## Progress` section is a checklist of phases, each small enough for one session
to read and build. `.loop/parse-ledger.sh` reads both sections with a strict grammar; a spec that
does not parse is refused before any session is paid for.

**One session per phase.** `delivery-loop.sh` hands the first unticked phase to a fresh session
with a prompt that names the spec, the unit, the phase, and the base commit. The session follows
`/implement-spec` in its loop-driven mode: it is the implementer, it uses test-driven development
(via `superpowers:test-driven-development`), it runs `/sync-context-docs` and `/run-gates`, and
it ends by writing a one-line sentinel. The loop verifies the sentinel against origin and against
the phase checklist, then starts the next session.

**Three closing sessions finish the branch.** With every phase ticked, the loop runs one fresh
session per closing step: `/sync-context-docs`, then `/code-review` over the whole diff with its
fix wave, then `/archive-spec`. Each is verified like a phase: the pushed sha must match the
sentinel, and the archive step's `OK` is believed only when the ledger line is ticked on origin.
The loop then runs `LOOP_GATES` itself, opens the PR through a short `/open-pr` session, and
records the unit's measured size and per-session telemetry on the branch.

**Everything is resumable.** Phase ticks and the ledger tick are commits on the unit's branch, so
phases already ticked are never rebuilt. The phase that was in flight is not rebuilt either: a stop
keeps the worktree, and the loop records which session it launched before launching it. A re-run
finds that record, checks that the branch is still where the session left it and that nothing else
is writing the worktree, and continues the session with `claude --resume`. A transcript that is
gone falls back to a fresh session told the work in the tree is its predecessor's. Only the done
path reclaims a worktree the loop created.

**It builds where it is driven from.** Run from a linked worktree already on the unit's branch,
which is what `/ship` leaves behind, the loop builds in that tree: no second worktree, no checkout,
no reclaim. Run from a `main` checkout, it creates `.claude/worktrees/<branch>`. The loop's own
state, in `.loop/state/` under the main checkout, is keyed by branch, and so is its lock: two specs
build side by side from two shells.

## Requirements

| Requirement | Why |
|---|---|
| Claude Code with the [superpowers](https://github.com/obra/superpowers) plugin | the skills invoke `brainstorming`, `test-driven-development`, `subagent-driven-development` and `dispatching-parallel-agents` from it; `install.sh` installs it when it can |
| a GitHub remote and an authenticated `gh` | the loop pushes the branch and opens the PR |
| `git`, `jq`, and GNU `timeout` (`brew install coreutils` on macOS) | pre-flight refuses without them |
| gate commands that exit non-zero on failure | e.g. `make lint;make test`; every session runs them, and so does the loop |
| Docker, only for `LOOP_SANDBOX=1` | runs each session in a container with no host credentials |

Conventions live in your repository's `AGENTS.md` or `CLAUDE.md`. The skills read the nearest
one to every file they touch.

## Install

From the root of the repository you want to build in:

```sh
curl -fsSL https://raw.githubusercontent.com/jperdior/engineering-loop/main/install.sh | bash
```

This writes the engine to `.loop/`, symlinks every skill into `.claude/skills/`, creates
`.ai/specs/`, appends the loop's runtime paths to `.gitignore`, and installs the superpowers
plugin at user scope if the `claude` CLI is on PATH and the plugin is missing. Re-run it to
update; `.loop/loop.env` and `.loop/state/` are left alone.

Then set the gates:

```sh
cp .loop/loop.env.dist .loop/loop.env && chmod 600 .loop/loop.env
# edit LOOP_GATES, e.g.  LOOP_GATES=make lint;make test
```

Commit `.loop/`, `.claude/skills/`, and `.gitignore`.

**As a plugin.** The skills can also come from Claude Code's plugin system, which keeps them out
of the host's `.claude/skills/`:

```
/plugin marketplace add jperdior/engineering-loop
/plugin install engineering-loop@engineering-loop
```

The engine still has to be vendored, because the skills call `.loop/parse-ledger.sh` and the loop
reads `.loop/loop.env`. Run install.sh as above; it skips the skill symlinks when it finds the
plugin installed.

## Use

In Claude Code, inside your repository:

```
/ship I want <the feature>
```

Phase A creates the worktree, interviews you, writes `.ai/specs/<date>-<slug>.md` on the feature's
branch, audits it, and stops. Read the spec and say OK.

Then run `/ship` again, or drive the loop directly from that worktree:

```sh
.loop/delivery-loop.sh .ai/specs/<file>.md --dry-run   # the plan: unit, branch, phases, gates
.loop/delivery-loop.sh .ai/specs/<file>.md             # build it
```

Always run the dry run first. It performs the whole pre-flight and prints what the run would do
without creating anything.

The loop runs until the feature is built. There is no budget and no cap on the number of phases.
It rings the terminal bell when it needs you, and `DELIVERY_LOOP_NOTIFY` can run anything richer.

The skills also work by hand, without the loop: `/new-feature`, `/spec-writing`,
`/pre-implement-spec`, `/implement-spec`, `/open-pr`. Driven interactively, `/implement-spec`
dispatches one fresh implementer subagent per phase and pauses between phases for you.

## The spec contract

The loop reads two sections, both written by `/spec-writing`:

```markdown
## Delivery

- [ ] **PR 1** — `feat-<slug>` — the whole feature — est ~600

## Progress

- [ ] **Phase 1** — the port and its value objects
- [ ] **Phase 2** — the adapter and the migration
- [ ] **Phase 3** — the retriever

_Notes:_ what the last session learned that the spec does not say.
```

- The backticked name in `## Delivery` is the branch. Most features are one unit. A second unit
  exists only for a deployment seam, such as a migration that must settle before its reader.
- Each line in `## Progress` is one session. Every unindented checkbox there must be a phase line;
  anything else goes under `_Notes:_` as prose.
- The notes are the handover between sessions. A session rewrites them when it ticks its phase.

`.loop/parse-ledger.sh <spec>` prints the ledger; `--phases` prints the checklist.

## Configuration

All settings live in `.loop/loop.env`. A value exported in the shell overrides the file.

| Setting | Default | Meaning |
|---|---|---|
| `LOOP_GATES` | `make lint;make test` | your gates, run from the repo root in this order |
| `LOOP_MODEL` | `opus` | the model of every build session; the PR session runs on `sonnet` |
| `LOOP_SANDBOX` | `0` | `1` runs each session in a container with no host credentials |
| `LOOP_CLEAN_WORKTREE` | unset | a command run inside a worktree before it is removed |
| `LOOP_SIZE_EXCLUDES` | unset | generated paths excluded from the size the ledger records |
| `LOOP_DENIALS_EXTRA` | unset | extra tools a session must never run, e.g. `Bash(make migrate)` |
| `MAX_SESSIONS` | phases + 4 | sessions per invocation before the unit is declared non-converging |
| `UNIT_TIMEOUT` | `7200` | seconds per session |
| `SESSION_CONTEXT_ALARM` | `150000` | peak context above which a phase is flagged as cut too large |
| `DELIVERY_LOOP_NOTIFY` | unset | a command that receives the headline when the loop needs you |
| `DELIVERY_LOOP_BELL` | `1` | `0` silences the terminal bell |

## When the loop stops

| Exit | Meaning | What to do |
|---|---|---|
| 0 | the unit is done and its PR is open, or nothing was owed; a worktree the loop created is reclaimed | review the PR |
| 2 | wrong usage | read the usage line |
| 3 | pre-flight refused, or another loop holds this unit's lock | fix the tree or the tools, re-run |
| 4 | an escalation: the unit is stopped and something is wrong; the worktree is kept | read `.loop/state/<branch>.json` and the worktree |
| 5 | paused: the account's usage limit is reached; the worktree is kept | re-run once it resets |

**Pre-flight refuses** a dirty driver tree (unless the dirt is a paused in-place session's own, which
its record proves), a tree behind its upstream (`origin/main` from a main checkout, the branch's
own from its worktree), a branch name with a `/`, a ledger with two unticked units, a spec with no
phase checklist, a missing tool, and under the sandbox an unreachable Docker daemon. It refuses
rather than guessing, because a run driven from a wrong tree builds the wrong thing for hours.

**An escalation** is a finished session whose result the loop cannot trust: no sentinel, an
`ESCALATE:<reason>` from the session, a permission denial, an API error, a `CONTINUE` whose phase
is not ticked on origin, an `OK` with a phase still unticked, a checklist that stops parsing,
`MAX_SESSIONS` reached, or a red gate on the host. The loop never retries an escalation. The last
session's whole result is in `.loop/state/<branch>.json`.

**A pause** is not a failure. Re-running the same command continues the session the limit
refused, in the worktree it left, with its uncommitted work intact. `--dry-run` prints what a
re-run would resume as a `resume:` line and changes nothing. The re-run stops instead, with an
escalation, when the branch moved on origin under the interrupted session, when the branch is gone,
or when an earlier loop or its container is still running: those are a human's call.

**A stop keeps the worktree.** Exit 4 and exit 5 both leave the unit's worktree and, when the
session wrote no sentinel, the record naming its phase. Drop a worktree the loop created with
`.loop/reclaim-worktree.sh <path>`; the run names the path on its way out. A worktree the loop was
driven from is yours and is never offered for reclaim.

## What a run records

- **The ledger tick.** When a unit is done, its line in `## Delivery` gains the measured size of
  the branch: lines added, split into implementation and test, files touched, comment ratio,
  lines of context-bearing prose, and the PR number. It sits beside the estimate so the next
  spec's estimate can be better. Nothing gates on it.
- **The telemetry.** `.ai/telemetry/<spec>/<unit>.md` holds one row per session: the phase it
  built, turns, cost, peak context, wall clock, and model. A session whose peak exceeds
  `SESSION_CONTEXT_ALARM` is flagged as a phase cut too large. That is a reading to act on in the
  next spec, not a limit the loop enforces.

## Safety and the sandbox

The loop runs `claude -p` with permission prompts bypassed, because an unattended session has
nobody to answer them. A deny list blocks merging, force pushes, `ssh`, `scp`, volume removal,
`kubectl`, and `helm` by every route to them, and `LOOP_DENIALS_EXTRA` adds your own. A deny list
cannot enumerate everything, and on the host the session holds your ssh keys and your `gh` login.

`LOOP_SANDBOX=1` runs each session inside a container built from `.loop/sandbox/Dockerfile`, with
the worktree and the main `.git` mounted, the host Docker socket for gates that need it, and two
credentials from `.loop/loop.env`: `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) and a
`GH_TOKEN` that should be a fine-grained PAT scoped to the repository with `contents:write` and
`pull_requests:write`. `.loop/setup-loop.sh` asks for both without echoing them, and
`.loop/sandbox/build.sh` builds the image.

The sandbox bounds lateral reach: no `~/.ssh`, no other repositories, no `gh` login, and a token
that cannot merge. It does not bound the Docker socket, which a determined session could escape
through. It stops accidents, which is the threat an unattended loop actually presents. Use it for
any run nobody is watching.

## Skills

| Skill | Role |
|---|---|
| `/ship` | the front door: interview, spec, audit, spec PR, then the loop |
| `/spec-writing` | the spec, with the one-line ledger and the phase checklist |
| `/pre-implement-spec` | four parallel audits: gaps, backward compatibility, risk, self-consistency |
| `/implement-spec` | phase by phase, test-first; the implementer under the loop, the controller interactively |
| `/run-gates` | `LOOP_GATES`, one subagent per command |
| `/sync-context-docs` | the nearest `AGENTS.md` / `CLAUDE.md` of every touched directory |
| `/code-review` | one review over the whole branch, three parallel reviewers |
| `/archive-spec` | tick the ledger, move the spec to `.ai/specs/implemented/` |
| `/open-pr` | the PR, with a templated body and the gates as its test plan |
| `/new-feature` | a worktree on a new branch from `main` |

## Development

```sh
bash tests/test-delivery-loop.sh      # the loop, against stubbed claude, gh, make and docker
bash tests/test-parse-ledger.sh
bash tests/test-unit-size.sh
bash tests/test-reclaim-worktree.sh   # from a main checkout, not a linked worktree
bash tests/test-setup-wizard.sh
```

`test-delivery-loop.sh` asserts that no loop snapshot is left in `$TMPDIR`, so it cannot run on a
host where a real loop is in flight. CI runs shellcheck and every suite.

## License

[MIT](LICENSE)
