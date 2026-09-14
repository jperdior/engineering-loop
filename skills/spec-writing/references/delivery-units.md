# Delivery Units — one spec is one unit

A **delivery unit** is one branch, one PR, one full cycle: its own worktree, its own phases, its own
gates, its own `/code-review`. A spec declares its unit as the single checklist line in its
`## Delivery` section.

**A spec is exactly one unit. Always.** The whole spec is one branch and one PR, with the phases as
its commits. What keeps a session small is the phase it is given, not the size of the PR: the
delivery loop runs one fresh session per phase, and `/implement-spec` dispatches one fresh
implementer per phase.

**Nothing gates on size.** `<loop>/unit-size.sh` reports and always exits 0. `est ~N` in a ledger line
is kept beside the realised figure so estimates stay comparable; it bounds nothing.

**A ledger with two lines is malformed, not ambitious.** `<loop>/delivery-loop.sh` refuses it before
it starts, and there is no flow anywhere that builds it — not the loop, not `/implement-spec`, not
`/ship`. Two units is two specs.

## When the work has a deployment seam

A **deployment seam** is an ordering constraint on `main` — not a size judgement. If the whole
change can merge at once without breaking `main`, there is no seam and there is nothing to decide.

| Seam | Rule |
|---|---|
| **Security mitigation → the feature it protects** | The mitigation is its own spec and merges **first**. Never ship the data path in the same PR as the fence that makes it safe; a partial merge leaves the hole open on `main`. |
| **Migration → its reader** | The migration, its persistence mapping, and the code reading or writing those columns go in **one** spec. A deployed schema nobody reads yet is harmless; a reader whose columns do not exist is a broken `main`. Never split these apart. |
| **Backend contract → frontend consumer** | Split only when another team is waiting on the contract. Otherwise ship them together: the endpoint, its types, any generated client, and the UI that calls them. |
| **Migration that must settle before its reader deploys** | When ops requires the schema change to land and drain ahead of the code, the migration is its own spec, and the host's own deployment procedure applies between the two merges. |

A boundary that is not one of these is not a seam. Do not manufacture one to split a spec.

## A seam makes two specs, built one after the other

Write **only the first** — the one that merges first. It is a whole spec: its own TLDR, its own
phases, its own `## Gates`, its own one-line ledger, its own branch and PR. It must stand on its own
against `main` with nothing after it assumed.

The remainder is **deferred, not specced**. Name it in the first spec's TLDR as a `**Deferred:**`
line — what is left, and which seam defers it — and stop there. Do not write phases for work whose
`main` has not happened yet.

```markdown
## TLDR

**Size:** bounded
**Deferred:** the reader for the `sent_at` column — a migration seam: the schema has to land and
drain on `main` before anything reads it. Its own spec, after this one merges.
```

Then, once the first has merged, the second is a fresh cycle from the top: a new `/ship` (or
`/new-feature` + `/spec-writing` + `/implement-spec` by hand), on a `main` that now contains the
first. That is the point of the deferral — the second spec is written against the tree it will
actually build on, not against a predicted one.

- **Releasable in order.** The host's `LOOP_GATES` green on each spec's own branch, and `main`
  deployable after each merges.
- No half-wired user-visible feature. A picker calling an endpoint that returns 404 is not a
  delivery unit, it is a broken deploy.
- No dangling contract. A spec adding a field nothing reads has to say in its `**Deferred:**` line
  what consumes it and when.
- Say the seam, in the deferral sentence. A split with no seam named is a **High** finding in
  `/pre-implement-spec`.

## The second spec starts from a moved `main`

It may begin days after the first merged, on a `main` that has moved underneath the assumptions.
That is why it is written then and not now:

- Write its **Current State** section against the tree as it is, after the first merge. Line
  numbers rot fastest; `file:123` references written before the first merge are already wrong.
- Re-read the first spec in `.ai/specs/implemented/` for what it actually built, which is not
  always what it planned.
