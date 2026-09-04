# Delivery Units — when a spec needs more than one

A **delivery unit** is one branch, one PR, one full cycle: its own worktree, its own phases, its own
gates, its own `/code-review`. A spec declares its units as the checklist in its `## Delivery` section.

**A spec is one unit.** The whole feature is one branch and one PR, with the phases as its commits.
What keeps a session small is the phase it is given, not the size of the PR: the delivery loop runs
one fresh session per phase, and `/implement-spec` dispatches one fresh implementer per phase.

**Nothing gates on size.** `.loop/unit-size.sh` reports and always exits 0. `est ~N` in a ledger line
is kept beside the realised figure so estimates stay comparable; it bounds nothing.

## When a spec needs more than one unit

Only for a real **deployment seam** — an ordering constraint on `main`, not a size judgement. If the
whole feature can merge at once without breaking `main`, it is one unit.

| Seam | Rule |
|---|---|
| **Security mitigation → the feature it protects** | The mitigation is its own unit and merges **first**. Never ship the data path in the same PR as the fence that makes it safe; a partial merge leaves the hole open on `main`. |
| **Migration → its reader** | The migration, its persistence mapping, and the code reading or writing those columns go in **one** unit. A deployed schema nobody reads yet is harmless; a reader whose columns do not exist is a broken `main`. Never split these apart. |
| **Backend contract → frontend consumer** | Split only when another team is waiting on the contract. Otherwise ship them together: the endpoint, its types, any generated client, and the UI that calls them. |
| **Migration that must settle before its reader deploys** | When ops requires the schema change to land and drain ahead of the code, the migration is its own unit, and the host's own deployment procedure applies between the two merges. |

A unit boundary that is not one of these is not a seam. Do not manufacture units to hit a count.

## When a spec does declare several units

The units are built **by hand, one at a time, in ledger order**: `/new-feature` for the unit's
branch from an up-to-date `main`, `/implement-spec` for its phases, `/open-pr`, merge, then the next.
The delivery loop builds exactly one unticked unit and refuses a ledger with two, because a second
unit exists only for a seam that a human has to see land.

- **Releasable in order.** The host's `LOOP_GATES` green on the unit's own branch, and `main`
  deployable after it merges.
- No half-wired user-visible feature. A picker calling an endpoint that returns 404 is not a delivery
  unit, it is a broken deploy.
- No dangling contract. A unit adding a field nothing reads has to say in the ledger which later unit
  consumes it.
- Say why in the ledger line. A second unit with no seam named is a High finding in
  `/pre-implement-spec`.

## Later units start from a moved `main`

Unit 2 may begin days after unit 1 merged, on a `main` that has moved underneath the spec.

- Re-verify the spec's **Current State** section (and any `file:123` references) before implementing
  a later unit. Line numbers rot fastest.
- Re-run `/pre-implement-spec` for that unit when anything it assumed has changed on `main`.
- Update the spec in the unit's own PR when reality has moved. The spec is the live document every
  remaining unit reads.
