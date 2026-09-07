---
name: code-review
description: "Review code changes (PR, diff, branch, commit) against the host repository's documented conventions, security, and test quality. Runs the verification gate as part of the review. Triggers on \"code review\", \"review this PR\", \"review the diff\", \"review my branch\"."
---

# Code Review

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.
> **Names.** The engine's skills are invoked as `/engineering-loop:<name>`; a bare `/<name>` in this
> text means that one, never a host skill sharing the name.

## Method

Where this skill needs a way of working, it takes, in order: the skill the host's root `AGENTS.md` /
`CLAUDE.md` routes that job to; else a skill in your own skill list that does it; else the steps here.

- **One response, three reviewers and the gate.** Dispatch the reviewer agents and start the gate
  in a single response, so they run in parallel.
- **Acting on a finding.** Verify it against the code before changing anything: open the file, read
  the line, confirm the claim. A finding that is wrong is answered with the technical reason, not
  applied to keep the peace. A suggestion nobody verified is never implemented.

All reviewer agents run with `model: "opus"`. The main thread (current session) synthesises
findings and runs the gate concurrently.

Review code changes against:
- The host's documented rules — the root `AGENTS.md` / `CLAUDE.md` and the nearest one to each
  changed directory
- The spec the change implements, when there is one
- Security and data integrity
- Test coverage and code quality

Produce categorised findings (Critical / High / Medium / Low) with `file:line`, and run the
**verification gate** as part of the review.

## Workflow

1. **Scope**: identify the changed files (`git diff --name-only "$BASE"...HEAD`) and group them
   by the directory that governs them.
2. **Context**: read the root `AGENTS.md` / `CLAUDE.md` and the nearest one to each changed
   directory. If the change references a spec under `.ai/specs/`, read it — including its
   Integration Coverage section.
3. **Parallel execution**: spawn the three reviewer agents (below) **and** start the
   verification gate **at the same time**. The agents analyse the diff statically while the
   gate runs real checks — no need to wait for the gate before reviewing.
4. **Backward-compatibility gate**: check every change for contract-surface impact. Flag a break
   as **Critical** unless a deprecation path is provided.
5. **Checklist**: apply [references/review-checklist.md](references/review-checklist.md). Flag
   with severity + file + line + fix.
6. **Merge findings**: combine the reviewers' findings + the BC gate + the checklist.
   Deduplicate — the same `file:line` reported by several agents keeps the highest severity.
7. **Output**: produce the review report in the format below.

## Parallel Reviewer Agents

After loading context (step 2), spawn all three simultaneously. Each receives: the diff, the
`AGENTS.md` / `CLAUDE.md` content that governs the changed directories, and the spec if there is
one.

### Reviewer 1 — Architecture & conventions `model: "opus"`
**Role**: You review structural correctness against the rules this repository documents for
itself. You do not review security or test coverage.
**Scope**: every rule the host's `AGENTS.md` / `CLAUDE.md` states — layering, module boundaries,
allowed and forbidden dependency directions, naming, file placement, public-contract discipline
— applied to the changed files. Where the host is silent, judge against the shape of the
surrounding code, and say explicitly that the rule is inferred rather than documented. Also
check the change against the spec: does it build what the spec describes, and nothing the spec
does not?
**Produces**: Architecture findings (Critical / High / Medium / Low).

### Reviewer 2 — Security & data integrity `model: "opus"`
**Role**: You are an application security engineer. Your sole focus is authorisation, input
validation, data integrity and safe credential handling. You do not review architecture or test
coverage.
**Scope**: OWASP-style review of the diff — authorisation declared on every new or changed
endpoint and every non-public entry point; input validated at the boundary; injection surfaces
(SQL, command, template, path); secrets, tokens and credentials never hard-coded, logged or
committed; PII kept out of logs; schema migrations reviewed for scope and for a working
rollback; retried or asynchronous work idempotent; error responses that do not disclose more
than they must.
**Produces**: Security findings (Critical / High / Medium / Low).

### Reviewer 3 — Tests & quality `model: "opus"`
**Role**: You review whether the change is tested and whether the code earns its place. You do
not review architecture or security.
**Scope**: every case in the spec's **Integration Coverage** has a test; new behaviour and every
risk path are covered; tests assert behaviour rather than implementation and are independent of
each other and of ordering; no `.only`, skipped tests, or debug output left behind; dead code,
unreachable branches and commented-out blocks; logic duplicated from somewhere that already has
it; error paths handled rather than swallowed.
**Produces**: Test and quality findings (Critical / High / Medium / Low).

## Verification Gate (MANDATORY)

**NEVER claim "ready to merge" without running the gate.**

Invoke `/run-gates`. It reads the gate commands from the spec this branch carries (`## Gates`),
else from the host's `AGENTS.md` validation section, and dispatches each as a parallel subagent.

Rules:
- Every failure is a finding, even when it also fails on the base. If it fails on the branch,
  CI fails. Fix it or flag it.
- The review output MUST include actual pass/fail evidence from `/run-gates`.

## Output Format

```markdown
# Code Review: {PR title or change description}

## Summary
{1-3 sentences: what the change does, overall assessment}

## Verification

| Gate | Status | Notes |
|------|--------|-------|
| `{gate command from the spec}` | PASS/FAIL | |

## Findings

### Critical
{Security hole, data loss, contract break without a deprecation path, a documented rule broken
in a way that cannot be merged.}

### High
{Convention violation with real consequences, missing test on a risk path, missing authorisation
declaration, a spec requirement not built.}

### Medium
{Convention violation, suboptimal pattern, duplicated logic, missing best practice.}

### Low
{Style suggestion, minor improvement, nit.}

## Backward Compatibility

- [ ] No public API route, message or event name renamed or removed
- [ ] No response field removed (additive only)
- [ ] No database column or table renamed or removed (additive only)
- [ ] No exported type or function signature broken
- [ ] No configuration key renamed without a fallback
- [ ] Deprecation path provided where a break was unavoidable

## Checklist

(See `references/review-checklist.md`; mark passing items `[x]`, failing `[ ]` with explanation.)
```

## Severity

| Severity | Criteria | Action |
|----------|----------|--------|
| Critical | Security, data integrity, contract break without a deprecation path, a documented boundary rule violated | MUST fix before merge |
| High | Convention violation with real consequences, missing test on a risk path, missing authorisation, spec requirement not built | MUST fix before merge |
| Medium | Convention, suboptimal pattern, duplication, missing best practice | Should fix |
| Low | Style, nit | Nice to have |

## Rules

The host's documented rules are the standard — the root `AGENTS.md` / `CLAUDE.md` and the
nearest one to each changed directory. A finding that cites no documented rule and no spec
requirement is at most **Low**, and says so.

**A fix wave stays inside the spec's scope.** When the review is followed by fixes, they touch the
unit's own code and tests. A finding against a host skill, an `AGENTS.md` or any other doc beyond
what the spec names — a template that teaches the wrong thing, a rule the change revealed as
incomplete — is written into the review as a **proposal**, with the exact edit, and not applied.
The user approved the spec's scope at gate 1; a doc change they did not see there is theirs to
approve on the PR, not the reviewer's to make.
