---
name: run-gates
description: "Run the host repository's verification gate — read the gate commands from the spec's ## Gates section (or derive them from the host's AGENTS.md when no spec is in play), dispatch each as a parallel subagent, and report PASS/FAIL per gate with evidence. Triggers on \"run the gate\", \"run gates\", \"verify the branch\", \"ci gate\"."
---

# Run the Verification Gate

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.
> **Names.** The engine's skills are invoked as `/engineering-loop:<name>`; a bare `/<name>` in this
> text means that one, never a host skill sharing the name.

The single source of truth for running the host repository's gate. Other skills
(`implement-spec`, `code-review`, `open-pr`) invoke this rather than naming commands
themselves.

**Two principles:** the gate commands come from the **host**, never from this skill; and the
gates are independent, so they run in **parallel** and each is read to completion before it is
called green.

## Method

- **One message, one subagent per gate.** Dispatch every gate in a single response so they run in
  parallel; one per response runs them in sequence and multiplies the wall clock.
- **Evidence before the verdict.** Read each subagent's complete output. PASS means exit 0 **and**
  zero errors read in the output; a summary line, a green-looking tail or the subagent's own word is
  not evidence. A gate you did not read is a gate that did not pass.

## Where the gates come from

**The spec, when there is one.** Every spec carries a `## Gates` section that `/spec-writing`
derived from the host's docs, and the loop runs exactly those. Under the loop the prompt names the
spec; interactively, the spec on this branch is the one whose `## Delivery` ledger names the
current branch. Read the list with the parser, one command per line, each run **from the
repository root**, in order:

```sh
<loop>/parse-ledger.sh <spec-file> --gates
```

Nothing here rewrites, narrows or re-orders a command: a gate is run exactly as the spec wrote it.

**The host's docs, when there is no spec.** A branch with no spec — a hotfix, a review of someone
else's work — still has gates: read the root `AGENTS.md` / `CLAUDE.md`, and the commands its
validation section names as what must be green before a PR (`make lint`, `make test`,
`pnpm check`, `cargo test` …) are the gates, in the order it lists them. Say in the report that
they came from the docs. Never invent a gate the docs do not name, and never fall back to a
default the host did not write; a host whose docs name no gate is a finding, not a pass.

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
Verification gate ({N} gates from the spec's ## Gates)
  diff: {M} files changed vs {base}
  make lint                     PASS
  make test                     PASS ({K} tests)
  teardown                      none required
```
