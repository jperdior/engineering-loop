---
name: run-gates
description: Run the host repository's verification gate — read the gate commands the host declares in .loop/loop.env, dispatch each as a parallel subagent, and report PASS/FAIL per gate with evidence. Triggers on "run the gate", "run gates", "verify the branch", "ci gate".
---

# Run the Verification Gate

The single source of truth for running the host repository's gate. Other skills
(`implement-spec`, `code-review`, `open-pr`) invoke this rather than naming commands
themselves.

**Two principles:** the gate commands come from the **host**, never from this skill; and the
gates are independent, so they run in **parallel** and each is read to completion before it is
called green.

## Superpowers Integration

- `superpowers:dispatching-parallel-agents` — dispatch every gate as its own subagent in a
  single message.
- `superpowers:verification-before-completion` — read each subagent's COMPLETE output and
  confirm 0 errors before reporting PASS. Evidence before assertions.

## Where the gates come from

The host declares them in `.loop/loop.env`:

```sh
LOOP_GATES="make lint;make test"
```

A semicolon-separated list of shell commands, each run **from the repository root**. That
default is the fallback when `.loop/loop.env` is absent or sets no `LOOP_GATES`.

Read the value, split it on `;`, trim each entry. Empty entries are dropped. Nothing here
rewrites, narrows or re-orders a command: a gate is run exactly as the host wrote it.

```sh
# shellcheck disable=SC1091
[ -f .loop/loop.env ] && . .loop/loop.env
printf '%s\n' "${LOOP_GATES:-make lint;make test}" | tr ';' '\n'
```

## The base

```
/run-gates [base]
```

`base` defaults to `origin/main`; a delivery-loop session passes the `Base:` its prompt names.
It is used **only to describe the diff in the report** — `git diff --name-only "$BASE"...HEAD`.
It never selects which gates run: every declared gate runs, every time.

## Workflow

### 1. Read the gate list

Resolve `LOOP_GATES` as above and print the list you are about to run. If the host declares
none and no default applies, say so and stop — an empty gate list is a finding, not a pass.

### 2. Describe the diff

`git diff --name-only "$BASE"...HEAD` — carried into the report so a reader knows what was
gated. Do not use it to skip a gate.

### 3. Dispatch one subagent per gate, all in a single message

Each subagent runs with `model: "haiku"` and is told: run **exactly one** command, from the
repository root, read its COMPLETE output, and return `PASS` or `FAIL` with the command name
and, on failure, the failing lines. Nothing in that needs a larger model, and the gate runs on
every phase.

Never merge two commands into one subagent, and never run a gate yourself in the controller
session — one command, one agent, one verdict.

### 4. Collect results

**Every gate MUST report PASS.** Any `FAIL` is blocking — a finding to fix or flag, even when
it also fails on the base. If it fails on the branch, CI fails.

### 5. Tear down what this run started

If the host's `AGENTS.md` / `CLAUDE.md` documents a teardown for a gate (a stack to stop, a
container to drop, a fixture to remove), run it as soon as the results are collected — pass or
fail, before you report or fix anything. A gate run that leaves the host's stack up is an
incomplete gate run. Hosts whose gates need no teardown skip this step.

### 6. Report

A compact table of gate → PASS/FAIL with evidence, plus the diff scope line.

## Never

- **Never** claim PASS without fresh output from the current run.
- **Never** substitute your own command for one the host declared, or skip a declared gate
  because the diff "cannot" affect it.
- **Never** finish while a stack this run started is still up.

## Output

```text
Verification gate ({N} gates from .loop/loop.env)
  diff: {M} files changed vs {base}
  make lint                     PASS
  make test                     PASS ({K} tests)
  teardown                      none required
```
