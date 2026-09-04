# Final Compliance Gate

Run before declaring a spec ready for implementation. Every row MUST pass.

The gate has two halves: **the host's rules**, which are whatever its own docs declare, and **the
engine's**, which are about the spec's shape and are the same in every repository.

## The host's rules

Read the host's root `AGENTS.md` / `CLAUDE.md` and the nearest one to each area the spec touches.
**Every item those files mark MUST or Never is a row of this gate.** Enumerate them explicitly in
the Final Compliance Report — the rule, quoted, and how the spec satisfies it. A rule the spec
breaks is a **Critical** finding; a rule you cannot tell either way about is an Open Question, not
a pass.

## The engine's rules

| Gate | Question | Pass criteria |
|------|----------|---------------|
| Delivery | Is there a `## Delivery` ledger with **one** unit, on one line, naming its branch first in backticks? | Yes. One unit is the default and needs no justification; more than one must name a real deployment seam per unit and leave `main` deployable when merged in ledger order. See `delivery-units.md`. |
| Progress | Is there a `## Progress` section opening with one `- [ ] **Phase N** — title` line per phase, in the order and with the titles of `## Phasing`? | Yes. Every unindented checkbox in the section is a phase line; notes are prose under `_Notes:_`. |
| Phase size | Can each phase be built by **one fresh session** — one seam, one module, the files it must open named in its own section? | Yes. A phase that needs half the tree read first is two phases. |
| Tests | Does each phase name the tests that prove it, in the frameworks and at the paths the host uses? | Yes. A phase whose tests live in another phase is not independently verifiable. |
| Gates | Does each phase end with the host's `LOOP_GATES` green and the app in a working state? | Yes. |
| Contracts | Does every endpoint with a body carry an explicit JSON example with exact field names? | Yes. |
| BC | Is any contract surface removed or renamed without a deprecation bridge? | No. |
| Open questions | Is the Open Questions block empty or removed? | Yes. A spec with an unanswered question is not ready. |
