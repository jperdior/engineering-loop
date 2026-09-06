# Spec Template

```markdown
# {Title}

## TLDR

{2-3 sentences. What is this? Why now? What changes?}

## Overview

{Context, motivation, business value. 1-2 paragraphs.}

## Problem Statement

{What are we solving? Quote concrete pain.}

## Proposed Solution

{High-level approach. Diagrams welcome. Keep ASCII; render at PR time.}

## Architecture

- **Modules / packages affected**: {list}
- **New types, entities or value objects**: {list, each with the module that owns it}
- **Cross-boundary interaction**: {the mechanism the host's AGENTS.md permits for each — never an
  import it forbids}
- **Host conventions this touches**: {quote the rules from the host's AGENTS.md / CLAUDE.md that
  govern this area, and how the design satisfies them}

## Data Models

For each unit of persisted state:
- Identifier and how it is generated
- Fields with types and invariants
- Where the persistence mapping lives, following the host's own layout
- Migrations needed

## API Contracts

| Method | Path | Auth | Request type | Response type | Notes |
|--------|------|------|--------------|---------------|-------|

For each endpoint, include:
- Validation rules, and where they are enforced
- Error responses (404, 422, 401, 403, 409)
- Whatever API documentation the host generates, and how this endpoint declares itself to it
- **Explicit JSON body example** — required for every endpoint with a request or response body.
  The server-side field name is the exact key the client must send. Do not leave field names
  implicit.

  ```jsonc
  // POST /example — request
  { "fieldName": "value" }   // must match the server-side field name exactly

  // POST /example — response (if non-empty)
  { "id": "..." }
  ```

## Frontend Plan (if applicable)

- Routes
- Server vs client components — justify each client component
- Forms and their validation schema
- Loading / error / empty states
- Mutation strategy

## Phasing

One phase is one session. Each phase has its own section, in the order and with the titles of the
`## Progress` checklist; `.loop/parse-ledger.sh --skills "Phase N"` reads its `Skills:` line.

### Phase 1 — {title}

- **Build:** {what this phase delivers; the files it opens, named}
- **Skills:** `{host-skill}`, `{host-skill}` — {the host's own skills this phase must use, resolved
  against the host's skill index (the root AGENTS.md router, else `.claude/skills/*/SKILL.md`).
  Omit the line when none applies; never leave it empty.}
- **Read first:** {the spec sections a fresh session reads before anything else}
- **Done when:** {the Integration Coverage rows that prove it, and the host's gates green}

### Phase 2 — {title}

- **Build:** …
- **Skills:** …
- **Read first:** …
- **Done when:** …

## Delivery

One checklist line: the feature is one delivery unit (= one branch, one PR). The unit's **branch is
its backticked name**, directly after the `**PR N**` label, and it is the branch the delivery loop
builds on. `.loop/parse-ledger.sh` reads this grammar. Required — the harness stops without it.

- [ ] **PR 1** — `feat-{slug}` — {the whole feature} — est ~{N}

A ticked line keeps its estimate and appends the realised measurements, so estimate-versus-realised
stays comparable — that comparison is the only reason to record anything:

```markdown
- [x] **PR 1** — `feat-x` — the whole feature — est ~300 → 412 lines (260 impl + 152 test), 9 files, 22% comments, 60 ctx (#142)
```

The tick is written in two passes: `/archive-spec` writes `- [x] … — est ~N` before the PR exists,
and the delivery loop appends the measurements and `(#PR)` once it does. The measurements are
**not** counted by hand — `.loop/unit-size.sh` prints them in exactly this order. It reports and
always exits 0; no size bounds anything.

A second unit exists only for a deployment seam (`references/delivery-units.md`); say why in its
line, and state the merge order inline: `(merge first — {why})`.

## Progress

The phase checklist — one line per phase, in the order of `## Phasing`, the same titles — followed by
the notes sessions leave for each other. `.loop/parse-ledger.sh --phases` reads the checklist; the
delivery loop hands each session the first unticked phase and checks its tick on exit. Every
unindented checkbox here must be a phase line; put anything else under `_Notes:_` as prose.

- [ ] **Phase 1** — {title}
- [ ] **Phase 2** — {title}

_Notes:_ not started.

## Gates

The host contract, derived from the host's `AGENTS.md` / `CLAUDE.md` when this spec is written and
read by the loop from the branch. One backticked command per line, in the order the host's validation
section names them; the three labelled lines are optional and each comes from something the docs say.
`.loop/parse-ledger.sh --gates` reads the list; the loop refuses a spec without one. Required.

- `{gate command}`
- `{gate command}`

_Cleanup:_ `{per-worktree teardown the docs name; omit the line when there is none}`
_Excludes:_ `{generated path}`, `{generated path}`
_Denials:_ `Bash({command the docs say an agent never runs})`

## Risks & Impact Review

| Risk | Severity | Affected area | Mitigation | Residual |
|------|----------|---------------|------------|----------|

## Integration Coverage

| Test ID | Type | Path | Asserts |
|---------|------|------|---------|
| TC-… | {the host's test framework for this layer} | {the path the host puts such tests at} | … |

## Backward Compatibility

- [ ] No removed/renamed public message, event or job identifiers
- [ ] No removed/renamed API routes
- [ ] No removed response fields
- [ ] No removed DB columns
- [ ] Deprecation bridge added if any contract surface changed

## Open Questions

(Remove once answered.)

- Q1. …
- Q2. …

## Final Compliance Report

(Filled in at the end. See `references/compliance-gate.md`.)

## Changelog

| Date | Change |
|------|--------|
| {YYYY-MM-DD} | Spec drafted. |
| {YYYY-MM-DD} | Phase 1 implemented. |
```
