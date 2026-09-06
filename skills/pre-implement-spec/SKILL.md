---
name: pre-implement-spec
description: Audit a spec before implementation. Produce a readiness report — gap analysis, backward-compatibility impact, risk assessment, missing tests. Triggers on "pre-implement", "analyze spec", "spec readiness", "spec gap analysis".
---

# Pre-Implement Spec

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.

## Superpowers Integration

Invoke before starting this workflow:
- `superpowers:dispatching-parallel-agents` — the 4 audit agents MUST be dispatched in a **single response** for true parallel execution; dispatching one-per-response produces sequential execution and quadruples the time.

All four audit agents (step 3) run with `model: "opus"`. The main thread synthesises their reports in step 4.

Audit a spec under `.ai/specs/` before any code is written. Output a **Readiness Report** that surfaces gaps, BC risks, missing coverage, and hidden assumptions. Goal: catch issues that would otherwise force mid-implementation rework.

The spec is held to **the host repository's own conventions**, as written in its root `AGENTS.md` /
`CLAUDE.md` and in the nearest such file to each area the spec touches. Every agent reads those
before it reads the spec.

## Workflow

1. **Identify the spec.** Confirm the file path (e.g. `.ai/specs/2026-06-04-add-notes.md`). If unclear, ask.
2. **Read the spec end-to-end.** Note every entity, endpoint, migration and test it proposes.

    **Read the `## Delivery` ledger and the `## Progress` checklist** before spawning anything. The ledger says which unit this audit covers and which are already ticked; when a unit is ticked, the spec is describing a tree that has moved, so re-verify its **Current State** section and every `file:123` reference against `main` — a stale line number is what a fresh implementer will be briefed on. Check the ledger itself: one unit needs no justification, and a spec that declares **several** units without a deployment seam named behind each boundary is a **High** finding against `../spec-writing/references/delivery-units.md`, as is a missing merge order (mitigation before the feature it protects, migration together with its reader). Check the phase checklist: a `## Progress` with no `- [ ] **Phase N** — …` lines, or with an unindented checkbox that is not a phase line, is a **High** finding, because `<loop>/parse-ledger.sh --phases` refuses it and the delivery loop escalates. A phase that cannot be built by one fresh session — it needs half the tree read first, or spans two seams — is a **Medium** finding with the cut proposed. **Check the gates**: `<loop>/parse-ledger.sh <spec> --gates` must exit 0 — a missing or empty `## Gates` is a **High** finding, because the loop refuses the spec — and every command it prints must be one the host's root `AGENTS.md` / `CLAUDE.md` names as a validation command; a gate the docs do not name, or a documented gate the spec left out, is **High**. **Check each phase's skills**: run `<loop>/parse-ledger.sh <spec> --skills "Phase N"` for every phase; exit 3 is a **High** finding (a `Skills:` line naming nothing), and every name printed must resolve to a skill the host has — a `.claude/skills/<name>/SKILL.md`, or a skill the session's own skill list shows — else **High**. Read the host's skill index (the root `AGENTS.md` router table, else the `description:` of every `.claude/skills/*/SKILL.md`) and flag as **High** any phase whose deliverables the index has a skill for and whose section names none. **Never report a finding about a unit's size.** Nothing gates on lines: `<loop>/unit-size.sh` reports and always exits 0; what bounds a session is the phase it is given.

3. **Spawn four audit agents in parallel** — see **Parallel Audit Strategy** below. Each agent receives: the full spec text, the list of files and modules it references, and the host's root `AGENTS.md` / `CLAUDE.md` plus the nearest one to each area touched.
4. **Synthesise**: merge the four agents' outputs into the Readiness Report. Where agents contradict, trust the one with more specific `file:line` evidence.

## Parallel Audit Strategy

Launch these four subagents simultaneously after step 2. Do not wait for one before spawning the next.

### Agent 1 — Gap & Compliance `model: "opus"`
**Role**: You are an expert software architect reviewing a spec against the conventions its own repository declares. Your job is to find missing pieces and internal inconsistencies before a single line of code is written.
**Task**: Read the spec and every source file it references, then the host's root `AGENTS.md` / `CLAUDE.md` and the nearest one to each area touched. Work through `../spec-writing/references/compliance-gate.md` item by item — including its instruction to turn every host **MUST** and **Never** into a row. Enumerate every deliverable (entity, endpoint, migration, test) and verify it is clearly defined and internally consistent.
**Produces**: list of missing deliverables, compliance-gate failures, unresolved ambiguities.

### Agent 2 — Backward Compatibility `model: "opus"`
**Role**: You are an expert in API and contract stability. Your job is to catch breaking changes that would silently break existing consumers or require a deprecation bridge.
**Task**: For every contract surface named in the spec (message and event identifiers, API routes, response fields, DB columns, service names, exported types), find all current usages in the codebase. Flag any renamed or removed surface that lacks a documented deprecation bridge. Also list every existing module the spec touches by import, subscription, or shared package — flag any interaction the host's conventions forbid as Critical.
**Produces**: BC audit table; cross-module impact list.

### Agent 3 — Risk & Security `model: "opus"`
**Role**: You are an expert in application security and backend risk assessment. Your job is to surface auth gaps, migration hazards, and idempotency failures before they reach production.
**Task**: For each phase, audit: the permission or role declared on every new endpoint, migration scope (does it touch tables outside the feature?), idempotency of anything retried, session and token handling if auth is touched, boundary violations, and any irreversible operation without a documented rollback path.
**Produces**: risk hot-spots list with severity (Critical / High / Medium / Low).

### Agent 4 — Resolution & Self-consistency `model: "opus"`
**Role**: You are the implementer who will be handed this spec with no one to ask. Your job is to make every reference in it resolve before anyone writes code, and to find the places where the spec contradicts itself.
**Task**: Enumerate every type, method, constructor signature, enum case, interface method, migration column, service id, route, file and **skill** the spec names — a skill in a phase's `- **Skills:**` line resolves when `.claude/skills/<name>/SKILL.md` exists or the name is in your own skill list. For each, confirm it either exists in the tree at the path and shape the spec assumes, or is defined by the spec itself — and that the two do not disagree (a constructor the spec calls with five arguments that takes four; a column the spec writes through a path the same spec forbids). Then read every mandated test against the behaviour the same spec mandates: a test that asserts X where an edit elsewhere in the spec makes X false by construction is a **Critical** finding, because the implementer can satisfy only one of them and will pick silently. Quote both sides with `file:line` or spec line numbers.
**Produces**: resolution table (reference → resolves / missing / contradicts, with evidence); list of self-contradictions with the two readings each admits.

## Output Format

```markdown
# Readiness Report: {Spec Title}

**Spec**: `.ai/specs/{file}.md`
**Phases**: {N}
**Delivery**: unit `{branch}`; {ticked}/{N} units ticked
**Phase checklist**: {N} phases under `## Progress` {| MISSING | DOES NOT PARSE}
**Modules affected**: {list}

## Verdict

- [ ] Ready to implement
- [ ] Needs revisions (see Critical/High findings)

## Critical

{A host MUST/Never broken, a boundary violation, a missing deprecation bridge, missing auth, a spec that contradicts itself.}

## High

{Missing or unparseable phase checklist, missing test coverage, unclear undo semantics, vague API contract, missing idempotency guarantees.}

## Medium

{A phase too large for one session, inconsistent naming, unclear failure modes.}

## Low

{Nits, diagram fixes, copy.}

## Test Coverage Map

| Phase | Path / area | Test type | Spec'd? | Exists? |
|-------|-------------|-----------|---------|---------|
| 1     | …           | …         | yes     | no      |

## Backward Compatibility Audit

| Contract surface | Change | BC impact | Mitigation |
|------------------|--------|-----------|------------|

## Suggested Revisions

1. …
2. …

## Next step

If verdict = ready: run `/implement-spec {file}`.
If verdict = needs revisions: update the spec, then re-run `/pre-implement-spec`.
```

## Heuristics

- A spec that says "we'll handle errors later" is **not ready** — push back.
- A spec with no integration tests for a behaviour change is **not ready**.
- A spec that adds an endpoint without declaring the permission it requires is **not ready**.
- A spec touching auth without describing session and token lifetime is **not ready**.
- A spec adding a column without a migration is **not ready**.
- A spec with an unanswered Open Question is **not ready**.
