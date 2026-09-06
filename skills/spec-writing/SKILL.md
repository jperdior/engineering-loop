---
name: spec-writing
description: "Draft or review architectural specs under .ai/specs/. Use when starting a new feature or any change touching multiple files. Adopts a \"staff engineer\" reviewer lens and holds the spec to the host repository's own conventions."
---

# Spec Writing & Review

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.

Design and review specifications against **the host repository's own conventions**, as written in its
root `AGENTS.md` / `CLAUDE.md` and in the nearest such file to the code the spec touches. Adopt the
**staff engineer** persona — flexible about innovation, uncompromising about the boundaries the host
declares.

The engine has no opinion about architecture. It has an opinion about *shape*: one ledger line, one
phase checklist, each phase buildable by one fresh session.

## Superpowers Integration

Invoke before starting this workflow:
- `superpowers:brainstorming` — design first, code never until approved; collaborative dialogue to validate the approach and produce a design doc before writing the spec.
- `superpowers:writing-plans` — after the spec is finalised, structure it into a concrete implementation plan with bite-sized tasks.

For research-heavy specs (a new module, a cross-cutting concern), spawn an Explore agent before
step 5 to benchmark the design against the patterns the host repository already uses — return a gap
analysis and 2-3 alternative designs with trade-offs.

## Workflow

0. **Worktree gate** — run `git branch --show-current` before doing anything else. If the result is `main` (or any protected branch), **stop immediately** and tell the user:
   > "You're on `main`. Run `/new-feature feat-<slug>` first to create the feature worktree, then re-run `/spec-writing` from inside it."
   Do not create any file, do not read context, do not proceed until the branch is a `feat-*` branch.
1. **Load context**: read the task description, then the host's root `AGENTS.md` / `CLAUDE.md` and the nearest one to each area the change touches. Identify which modules, packages and apps are affected, and follow every pointer those files give. A spec that silently contradicts a rule the host has written down is a **Critical** finding.

   Then read **the host's skill index** — the skills this repository has written for building in it, which the phases will name (step 7). It is, in order of preference:
   - the router or index table in the root `AGENTS.md` / `CLAUDE.md` that maps kinds of task to `SKILL.md` files, when the host keeps one;
   - otherwise the `description:` line of every `.claude/skills/*/SKILL.md`.

   The engine's own skills — `ship`, `spec-writing`, `pre-implement-spec`, `implement-spec`, `run-gates`, `code-review`, `sync-context-docs`, `archive-spec`, `new-feature`, `open-pr` — are the process and are never part of the index. What the index holds is the host's: how it scaffolds a module, adds an endpoint, writes a migration, runs its linters, creates a page, translates a string.
2. **Initialize**: create `.ai/specs/{YYYY-MM-DD}-{kebab-case-title}.md`.
3. **Start minimal — skeleton + open-questions gate**: write a skeleton (TLDR + 2-3 key sections only). Before writing it, scan the brief for **critical unknowns** — decisions where the wrong assumption forces a rewrite. List them as an **Open Questions** block (`Q1`, `Q2`, …) immediately after the TLDR. **STOP after presenting the skeleton.** Do not proceed past this gate until the user has answered every question.
4. **Apply answers**: remove the Open Questions block and fill the skeleton.
5. **Research**: when relevant, compare against open-source leaders, RFCs, or the framework's own recipes. Quote evidence.
6. **Design**: write the Architecture, Data Models and API Contracts sections. Name, for every unit of state the spec introduces, where it lives and which module owns it; for every endpoint, its route, its auth requirement and the exact JSON shape of its request and response; for every interaction across a boundary the host declares, the mechanism the host permits — never an import the host forbids.
7. **Phasing and the Delivery ledger**: break delivery into testable phases. Each phase ends with the host's gates green and a working app. Define phases at a granularity that is independently reviewable and leaves the app in a valid state at each checkpoint.

    Write each phase as its own `### Phase N — title` section under `## Phasing`, and in it **name the
    host's skills the phase must use**, resolved against the skill index read in step 1:

    ```markdown
    ### Phase 2 — the endpoint and its client

    - **Build:** …
    - **Skills:** `add-route`, `integration-tests`, `regenerate-api-client`
    - **Done when:** …
    ```

    Match the phase's deliverables against the index: a new module takes the host's scaffold, an
    endpoint its route skill and its test skill, a UI change its page skill and its translation
    skill, and so on. Each name is a backticked skill name that exists in the host. A phase to
    which nothing in the index applies has no `Skills:` line — never an empty one.
    `<loop>/parse-ledger.sh <spec> --skills "Phase N"` reads the line; the delivery loop puts the
    names in the session's prompt, and `/implement-spec` invokes them before writing. This is the
    only place the host's skills are resolved, and the human who approves the spec reads the
    resolution: a phase that names the wrong skill, or none where one applies, is caught here.

    Then declare a `## Delivery` section — **one unit, for the whole feature**:

    ```markdown
    ## Delivery

    - [ ] **PR 1** — `feat-<slug>` — the whole feature — est ~600
    ```

    The unit's **branch is its backticked name**, directly after the `**PR N**` label, and it is
    the branch the delivery loop builds on. `<loop>/parse-ledger.sh` reads this grammar, and a spec
    without this section cannot be implemented — the harness stops and asks. `est ~N` is a
    reviewable-line estimate kept when the line is ticked so estimate-versus-realised stays
    comparable; **it bounds nothing**. `<loop>/unit-size.sh` reports and always exits 0.

    **Never ask the user how to cut the units.** It is not a product decision and
    they should not spend attention on it: one unit unless a deployment seam forces
    otherwise, and if one does, say so in the ledger line rather than opening a menu. The seams are
    in `references/delivery-units.md`; a second unit with no seam named is a High finding in
    `/pre-implement-spec`.

    Then declare a `## Progress` section that opens with the phase checklist — one line per phase,
    in the order of `## Phasing`, the same titles — followed by the notes sessions leave for each
    other:

    ```markdown
    ## Progress

    - [ ] **Phase 1** — the port and its value objects
    - [ ] **Phase 2** — the persistence adapter and the migration
    - [ ] **Phase 3** — the retriever and its wiring

    _Notes:_ not started.
    ```

    **The phases are the sessions.** The delivery loop hands each fresh session the first unticked
    phase and checks the tick when it exits, and `/implement-spec` dispatches one fresh implementer
    per phase. A phase is therefore cut to what a single session can read and build: one seam, one
    module, the files it must open named in its section. A phase that needs half the tree read
    first is two phases. `<loop>/parse-ledger.sh --phases` reads this checklist, and the loop refuses
    a spec without it.

    Keep the checklist parseable. Every unindented checkbox under `## Progress` must be a
    `- [ ] **Phase N** — title` line; a free-form `- [ ] remember to …` note among them breaks the
    parse and escalates the run. Notes go under `_Notes:_` as prose.

    **The notes are how sessions hand work to each other.** A session rewrites them when it hands
    over — what it learned that the spec does not say, what the next phase must know — and the next
    session reads them before the phases. They are the ONLY thing that survives between sessions;
    anything left in a session's head is lost.

    `/implement-spec` ticks each phase as it lands; `/archive-spec` ticks the ledger and moves the
    spec to `.ai/specs/implemented/` once no unit is left unticked.

    Then declare a `## Gates` section — **the host contract, derived from the host's own docs, every
    time**. Read the root `AGENTS.md` / `CLAUDE.md`: the commands its validation section names as
    what must be green before a PR are the gates, in that order, one backticked command per line.
    Three optional italic-labelled lines carry the rest, each from something the docs say:

    ```markdown
    ## Gates

    - `make lint`
    - `make test`

    _Cleanup:_ `make clean-worktree`
    _Excludes:_ `apps/api/openapi.json`, `packages/api-client-ts/src/types.gen.ts`
    _Denials:_ `Bash(make migrate)`, `Bash(* doctrine:migrations:migrate*)`
    ```

    `_Cleanup:_` is the per-worktree teardown the docs name (a stack to drop, a cache keyed by
    directory); `_Excludes:_` the generated paths the docs say nobody reviews; `_Denials:_` the
    commands the docs mark as never run by an agent, as Claude Code permission patterns. Omit a line
    the docs give no basis for. Only commands the docs name — never a guess and never a default.
    `<loop>/parse-ledger.sh <spec> --gates` reads the list; the loop runs it in every session and once
    more on the host, and refuses a spec that declares none. This is why nothing about the host is
    configured in a file for the loop's sake: the contract is re-derived with each spec and approved
    with it, so a change to the host's docs reaches the next feature without anyone editing config.

8. **Risks & Impact**: document concrete failure scenarios (severity, affected area, mitigation, residual risk).
9. **Integration Coverage**: list the tests that must exist for the new behaviour, in the frameworks and at the paths the host repository already uses.
10. **Compliance gate**: apply [references/compliance-gate.md](references/compliance-gate.md).
11. **Output**: finalise the spec. If the host keeps a catalogue of domain rules or lessons, add any new rule the spec introduces to it.
12. **Commit the spec locally** on the current `feat-<slug>` branch:
    - `git add .ai/specs/{file} && git commit -m "spec: {title}"`
    - No spec-only PR is opened, in any flow: the spec is the unit's first commit and travels with the implementation in the same PR, staying in `.ai/specs/` until that PR archives it. Under `/ship` the user reads it here and says OK; that spoken OK is gate 1, and the loop then builds in this same worktree.
    - **Auto-proceed** to `/pre-implement-spec .ai/specs/{file}.md` — the audit runs next. If gaps are found, update the spec and re-audit before coding starts.
    - After the audit passes, run `/implement-spec .ai/specs/{file}.md`.

## Output Formats

### New spec — use the template

See [references/spec-template.md](references/spec-template.md) for the full skeleton.

### Reviewing an existing spec

```markdown
# Architectural Review: {Spec Title}

## Summary
{1-3 sentences: what the spec proposes and overall architectural health}

## Findings

### Critical
{A rule the host's AGENTS.md marks MUST or Never, broken; a missing deprecation bridge; a rule enforced only in the UI}

### High
{Missing phasing, unclear undo semantics, missing API contract, no integration coverage}

### Medium
{Inconsistent terminology, missing failure scenarios, a badly placed seam}

### Low
{Nits, diagram improvements}

## Checklist
See [references/spec-checklist.md](references/spec-checklist.md).
```

## Review Heuristics (The Staff-Engineer Lens)

1. **Host rules first.** Read the host's root `AGENTS.md` / `CLAUDE.md` and the nearest one to each
   area touched. Anything they mark **MUST** or **Never** that the spec proposes to break is a
   **Critical** finding, quoted with the rule it breaks. The engine adds no architecture of its own.
2. **Boundary integrity**: does the spec reach across a module boundary by a route the host forbids
   (a direct import where the host mandates an event, a message, or a published contract)? Critical
   — propose the mechanism the host does permit.
3. **State ownership**: is there exactly one owner per unit of state, and one owner per write
   transaction? Splitting one logical transaction across two owners is a smell; merging two distinct
   lifecycles into one is also a smell.
4. **Validation at the edge**: are user-supplied values validated where they enter the system, at
   construction, rather than deep inside a handler?
5. **Undoability**: for state-changing operations, is the inverse documented? Even if not implemented
   yet, the spec should describe how the change can be reverted.
6. **Idempotency**: are subscribers, workers and retried jobs idempotent?
7. **Auth**: does every protected endpoint declare the permission or role it requires?
8. **Frontend boundary**: for UI work, is the server/client boundary explicit and each client
   component justified? Does the spec describe loading, error and empty states?
9. **Rules belong in the core, not the UI**: any constraint derived from the domain (approval gates,
   ownership checks, status transitions, eligibility) MUST be enforced server-side and surfaced as a
   typed error. Filtering in the frontend is an optional nicety, never a substitute. A rule enforced
   only in the UI is a **Critical** finding.
10. **API contract field alignment**: every endpoint with a request or response body must include an
    explicit JSON example — not just a DTO or type name. The server-side field name is the exact key
    the client must send, and a spec that names only the type guarantees a field-name mismatch
    between the two sides. **High**.
11. **Testability by phase**: can each phase be built and proved by one fresh session, with the tests
    it needs named in its own section? A phase whose tests live in another phase is not
    independently verifiable.
12. **Skills by phase**: does each phase's `- **Skills:**` line name the host skills its deliverables
    call for, each resolving to a skill the host has? A deliverable the index has a skill for, with
    no skill named, is **High**; a name that resolves to nothing is **High**.

## Reference Materials

- [references/spec-template.md](references/spec-template.md) — the canonical skeleton
- [references/delivery-units.md](references/delivery-units.md) — why one unit is the default, and the deployment seams that justify more
- [references/spec-checklist.md](references/spec-checklist.md) — the review checklist
- [references/compliance-gate.md](references/compliance-gate.md) — final compliance gate
- The host's root `AGENTS.md` / `CLAUDE.md`, and the nearest one to each area the spec touches — the conventions this spec is held to
