# engineering-loop

Take a feature from a sentence to a pull request, unattended, in any repository that Claude Code
can build.

```
/ship <what you want>
        ↓
  interview → spec → audit → the spec's own PR      ▣ you merge it
        ↓
  the loop: one fresh session per spec phase → a closing review session → one PR
                                                    ▣ you merge it
```

Two human gates, the spec and the PR. Nothing merges itself.

## Why a phase per session

A Claude session cannot observe its own context, so telling it to stop at a token budget bounds
nothing. The loop bounds a session by scope instead: it hands each fresh `claude -p` exactly one
phase of the spec, reads the phase's tick back from the branch on origin when the session exits,
and refuses a handover that ticked nothing. A phase is observable; a token count is not. Context per
session stays at what one phase needs, and the telemetry records each session's peak so a phase cut
too large is visible.

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

Phase A interviews you about the product, writes `.ai/specs/<date>-<slug>.md`, audits it with four
parallel agents, and opens the spec's PR. Merge it. Run `/ship` again (or name the spec): Phase B
runs the loop.

```sh
.loop/delivery-loop.sh .ai/specs/<file>.md --dry-run   # the plan: unit, branch, phases, models, gates
.loop/delivery-loop.sh .ai/specs/<file>.md             # build it
```

The loop creates `.claude/worktrees/<branch>` from `origin/main`, runs one session per unticked
phase on `LOOP_MODEL` (default `opus`), then a closing session (`/sync-context-docs`, `/code-review`,
`/archive-spec`), runs `LOOP_GATES` on the host, opens one PR on `sonnet`, and stops. Merge it.

If the account's usage limit is reached mid-run the loop **pauses** (exit 5). Re-run the same command
once it resets; it continues from the first unticked phase. There is no budget.

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

The backticked name is the branch. Each phase is one session; the notes are the only thing that
survives between sessions. `.loop/parse-ledger.sh <spec>` and `--phases` are the readers.

## What the loop refuses, escalates and pauses

Pre-flight refuses (exit 3): a dirty or behind driver tree, a ledger with two unticked units, a spec
with no phase checklist, missing tools, an unreachable Docker daemon under the sandbox.

Escalates (exit 4): no sentinel, `ESCALATE:<reason>` from the session, a permission denial, an API
error, a `CONTINUE` whose phase is not ticked on origin, an `OK` with a phase still unticked, a
`## Progress` that stops parsing, `MAX_SESSIONS` reached, a red gate on the host. The last session's
whole result is in `.loop/state/<branch>.json`.

Pauses (exit 5): the account's usage limit.

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
| `SESSION_CONTEXT_ALARM` | `150000` | a session whose recorded peak context exceeds this is reported |
| `LOOP_SANDBOX` | `0` | `1` runs each session in a container with no host credentials |
| `DELIVERY_LOOP_NOTIFY` | unset | a command that receives the headline when the loop needs you |

## The sandbox

`LOOP_SANDBOX=1` runs each session inside `.loop/sandbox/Dockerfile` (`.loop/sandbox/build.sh` builds
it) with the worktree and the main `.git` mounted, the host Docker socket for the gates, and two
credentials from `.loop/loop.env`: `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) and a `GH_TOKEN`
that should be a fine-grained PAT scoped to the repository. `.loop/setup-loop.sh` asks for both. It
bounds lateral reach — no `~/.ssh`, no other repositories, no `gh` login — not a determined escape.

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

CI runs shellcheck and the suites.
