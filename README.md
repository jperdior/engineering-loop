# engineering-loop

Claude Code skills and a small bash loop that take a feature from a sentence to a reviewed pull
request, unattended, in any repository Claude Code can build. You approve two things: the spec, and
the PR. Nothing merges itself.

```
/ship <what you want>
        │
        ▼
  worktree ─▶ interview ─▶ spec ─▶ audit        ▣  you read the spec, you say OK
        │
        ▼
  one fresh session per spec phase ─▶ docs, review, archive ─▶ one PR
                                                  ▣  you read the PR, you merge it
```

## Install

In Claude Code:

```
/plugin marketplace add jperdior/engineering-loop
/plugin install engineering-loop@engineering-loop
```

That is the whole install. **Nothing is written into your repository**: the skills and the loop
live in the plugin, your settings in `~/.config/engineering-loop/loop.env`, the loop's state in
`~/.local/state/engineering-loop/`. The only files the engine ever adds to a repository are the specs
you approve, which ship in the PR they describe.

The plugin depends on no other. Where a skill needs a way of working — a design conversation, test
first, verifying before claiming done — it uses the skill your repository's `AGENTS.md` routes that
job to, else one you have installed, else the steps it carries itself. You also need `git`, `jq`,
GNU `timeout` (`brew install coreutils` on macOS), and an authenticated `gh`.

## Use

In Claude Code, inside your repository:

```
/ship I want <the feature>
```

It creates a worktree, interviews you, writes the spec on the feature's branch, audits it, and
stops. **Read the spec and say OK.** It then starts the loop in the background and reports as each
phase lands. When the PR is open, **read it and merge it.**

The loop runs until the feature is built and survives closing the chat. It stops on its own for a
usage limit, which it resumes from when you run it again, and for an escalation, which it explains.

Prefer a terminal for an overnight run over SSH? The loop is a script inside the plugin; from the
feature's worktree:

```sh
LOOP=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/engineering-loop/engineering-loop/*/loop
$LOOP/delivery-loop.sh .ai/specs/<file>.md --dry-run   # the plan; creates nothing
$LOOP/delivery-loop.sh .ai/specs/<file>.md             # build it
$LOOP/launch.sh .ai/specs/<file>.md                    # the same, detached: what /ship runs
```

A detached run logs to `~/.local/state/engineering-loop/runs/<repo>-<branch>.log`; its last line
is `delivery-loop: exit N` once it has finished.

## What your repository needs

An `AGENTS.md` (or `CLAUDE.md`) that says three things. The loop reads it; you configure nothing.

- **Your gates.** The commands that must be green before a PR, for example `make lint` and
  `make test`. Every spec copies them into its `## Gates` section; every session runs them, and the
  loop runs them once more on the host before opening the PR.
- **Your conventions.** Layout, naming, the rules you mark MUST and Never. A spec that breaks one is
  refused at audit.
- **Your skills.** A table that maps kinds of task to the skills your repository has written for
  itself. Each spec phase names the ones it needs, and the session invokes them before writing.

```markdown
## Validation Commands
    make lint
    make test

## Task Router
| Task                | Guide                                    |
|---------------------|------------------------------------------|
| Adding an endpoint  | `.claude/skills/add-route/SKILL.md`      |
```

## When the loop stops

| Exit | Meaning | What to do |
|---|---|---|
| 0 | done; the PR is open | review the PR |
| 3 | pre-flight refused: a dirty tree, a tree behind its upstream, a spec without gates, a missing tool | fix it, re-run |
| 4 | escalation: something is wrong and the loop will not guess | read the last session's result under `~/.local/state/engineering-loop/`, and the worktree |
| 5 | paused: the account's usage limit | re-run once it resets; the interrupted session continues |

A stop keeps the worktree and the half-built phase in it. Only a finished unit reclaims a worktree
the loop created; a worktree you were already in is never touched. The last session's full result
is in `~/.local/state/engineering-loop/<repo>/<branch>.json`.

## Settings

Personal settings live in `~/.config/engineering-loop/loop.env`, one file for every repository;
`setup-loop.sh` in the plugin writes the two sandbox tokens into it. A value exported in the shell
wins.

| Setting | Default | Meaning |
|---|---|---|
| `LOOP_MODEL` | `opus` | the model of every build session; the PR session runs on `sonnet` |
| `LOOP_SANDBOX` | none, required | `1` runs each session in a container with no host credentials; needs `setup-loop.sh` for the two tokens and `sandbox/build.sh` for the image, both in the plugin's `loop/`. `0` runs on this host as you; `setup-loop.sh --host` records it. The loop refuses to run until one is chosen, and `/ship` asks on first use |
| `MAX_SESSIONS` | phases + 4 | sessions per run before the unit is declared non-converging |
| `UNIT_TIMEOUT` | `7200` | seconds per session |
| `SESSION_CONTEXT_ALARM` | half the model window | context, in tokens, above which a phase is reported as cut too large; unset, half of the session model's context window |
| `DELIVERY_LOOP_NOTIFY` | unset | a command that receives the headline when the loop needs you |

The gates, the worktree cleanup and the extra denials are not settings: they come from each spec's
`## Gates` section, which `/spec-writing` derives from your `AGENTS.md` every time.

## Skills

| Skill | What it does |
|---|---|
| `/ship` | the front door: worktree, interview, spec, audit, your OK, the loop, one PR |
| `/new-feature` | a worktree on a new branch from `main` |
| `/spec-writing` | drafts the spec: ledger, phase checklist, per-phase skills, gates |
| `/pre-implement-spec` | audits the spec with four parallel agents |
| `/implement-spec` | builds one phase per fresh implementer, gates after each |
| `/run-gates` | runs the spec's gates, one subagent per gate |
| `/code-review` | reviews the whole branch against the host's conventions |
| `/sync-context-docs` | updates the `AGENTS.md` nearest to what changed |
| `/archive-spec` | ticks the ledger and archives the spec |
| `/open-pr` | opens the one PR |

## Contributing

`bash tests/test-delivery-loop.sh` builds whole units against stubbed `claude`, `gh`, `make` and
`docker`; the other suites under `tests/` cover the parser, the size report, the reclaim and the
setup wizard. Run `tests/test-reclaim-worktree.sh` from a main checkout, not a linked worktree.
Every script is shellchecked in CI.
