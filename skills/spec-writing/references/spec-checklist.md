# Spec Review Checklist

## 1. Structure

- [ ] Filename matches `{YYYY-MM-DD}-{kebab-case-title}.md`
- [ ] TLDR present, 2-3 sentences
- [ ] Open Questions block cleared before the research phase
- [ ] Phases declared; each phase deliverable is testable and ends with the host's gates green
- [ ] `## Delivery` ledger present; **one** unit on one line, naming its branch first in backticks
- [ ] `## Progress` present, opening with one `- [ ] **Phase N** — title` line per phase, in the order and with the titles of `## Phasing`
- [ ] Every unindented checkbox under `## Progress` is a phase line; notes are prose under `_Notes:_`
- [ ] Every unit leaves `main` deployable **when merged in ledger order** — no half-wired feature, no reader without its migration
- [ ] A second unit names a real deployment seam and its required merge order
- [ ] Changelog section present

## 2. Architecture

- [ ] Every rule the host's `AGENTS.md` / `CLAUDE.md` marks MUST or Never is enumerated and satisfied
- [ ] Every unit of state is placed in a module that owns it
- [ ] No cross-boundary interaction by a route the host forbids
- [ ] The design follows the layout the host already uses for this kind of code

## 3. Data & Security

- [ ] All inputs validated where they enter the system
- [ ] Sensitive fields (passwords, tokens) handled with the host's standard helpers
- [ ] Auth requirement declared per endpoint
- [ ] Migration scope is bounded; no unrelated table churn

## 4. Behaviour

- [ ] Write operations name their inverse, or say why there is none
- [ ] Read paths return read models, not internal entities
- [ ] Anything retried is idempotent
- [ ] Errors are typed and surfaced deliberately, not swallowed

## 5. API & UI

- [ ] Every endpoint with a body carries an explicit JSON example with exact field names
- [ ] Whatever API documentation the host generates is declared for every new endpoint
- [ ] Server/client boundary explicit for every page; each client component justified
- [ ] The host's design-system rules respected

## 6. Tests

- [ ] Every phase names the tests that prove it, in the host's frameworks and at the host's paths
- [ ] At least one test per new endpoint or entry point
- [ ] At least one test for every non-trivial frontend component, hook, or pure module added
- [ ] Edge cases enumerated (auth required, ownership, validation errors)

## 7. Backward Compatibility

- [ ] If any contract surface (message or event identifiers, API routes, response fields, DB columns) is removed or renamed, the host's deprecation protocol is followed (bridge + deprecation marker + migration note)
