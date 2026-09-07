---
name: archive-spec
description: "Tick the current branch's unit in a spec's Delivery ledger and move the spec to .ai/specs/implemented/ only when no unit is left unticked. Triggers on \"archive spec\", \"archive the spec\", \"is this the last PR of the spec\"."
---

# Archive Spec

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.
> **Names.** The engine's skills are invoked as `/engineering-loop:<name>`; a bare `/<name>` in this
> text means that one, never a host skill sharing the name.

Decide whether the branch about to become a PR is the spec's **last** delivery unit, and archive the
spec into `.ai/specs/implemented/` when — and only when — it is.

The spec file itself is the ledger that records which units are built, because it is the one artefact
that travels to `main` with the PR. No CI job archives specs; archival is a commit on the delivery PR,
reviewed like any other change.

## The Delivery ledger

Every spec carries a `## Delivery` section whose units are checklist lines. A spec is one unit unless a
deployment seam forces a second:

```markdown
## Delivery

- [ ] **PR 1** — `feat-project-knowledge-retrieval` — the whole feature — est ~600
```

- `- [x]` — the unit is built and its PR is open or merged, or lands with the PR being opened right now.
- `- [ ]` — the unit is still owed.

A unit's backticked name — the one directly after its `**PR N**` label — is its branch, and that is
what binds a unit to a branch. Read it, never guess it. `<loop>/parse-ledger.sh` applies this rule,
which is why the steps below call it rather than matching backticks by hand.

## Workflow

1. **Branch gate** — `git branch --show-current`. If the result is `main`, stop: archival is a commit on
   a feature branch that lands through a PR, never a direct edit to `main`.

2. **Resolve the spec** — take it from the argument. With no argument, derive it from the branch:
   ```sh
   git diff --name-only --diff-filter=AM origin/main...HEAD -- '.ai/specs/*.md' \
     | grep -v '/implemented/' | grep -v '/AGENTS\.md$' | grep -v '/CLAUDE\.md$'
   ```
   Zero matches → report "no spec on this branch, nothing to archive" and stop (a hotfix or short-path
   branch legitimately has none). More than one → handle each in turn.

3. **Read the ledger.** Extract the units:
   ```sh
   <loop>/parse-ledger.sh "$SPEC"        # done|unit|branch, one row per unit
   ```
   **Exit 3** means the ledger is malformed or the spec has no `## Delivery` section. Do not assume it
   is single-unit. Stop and ask the user how many delivery units the spec has, add the ledger, and
   continue.

4. **Tick this branch's unit.** Find the unticked row whose **`branch` field** equals the current
   branch and rewrite that line's `- [ ]` to `- [x]`. Then:
   - Already ticked → the unit is already recorded; leave it and carry on to step 5.
   - The branch is named by **no** line → stop and ask. Either the ledger is stale or this branch is not a
     delivery unit of this spec. Never invent a unit and never tick an arbitrary one.

   Write the tick as `- [x] … — est ~N`, leaving the estimate in place. The delivery loop rewrites
   that same line afterwards with the realised measurements from `<loop>/unit-size.sh` and the PR
   number; it replaces everything after the ` → `, so do not add measurements by hand.

5. **Count what is left.**
   ```sh
   <loop>/parse-ledger.sh "$SPEC" | grep -c '^ |' || true
   ```
   - **Greater than zero → do not archive.** Commit the ticked ledger, report the units still owed, and
     stop. The spec stays in `.ai/specs/` where the next branch will find it.
   - **Zero → archive.** Continue to step 6.

6. **Close the spec out** before moving it:
   - Append a `## Changelog` row: `| {YYYY-MM-DD} | Implemented — PR N of N, spec archived. |`
   - Fill the **Final Compliance Report** if it is still a placeholder (see
     `../spec-writing/references/compliance-gate.md`).

7. **Move it, preserving history:**
   ```sh
   git mv ".ai/specs/$(basename "$SPEC")" ".ai/specs/implemented/$(basename "$SPEC")"
   ```

8. **Repoint every reference.** A moved spec breaks every in-repo link to its old path — other specs,
   `docs/**`, `AGENTS.md` files, anything the host keeps:
   ```sh
   BASE=$(basename "$SPEC")
   grep -rl "\.ai/specs/$BASE" --include='*.md' . | grep -v node_modules
   ```
   Rewrite each hit `.ai/specs/<BASE>` → `.ai/specs/implemented/<BASE>`. Skip anything already carrying
   `implemented/`, and leave `.ai/specs/implemented/*` files that quote a *different* spec's earlier
   path alone — an archived spec is a record and its own text is never repointed.

9. **Commit** on the current branch, staging the spec directory and every file step 8 rewrote:
   ```sh
   git add -A .ai/specs
   git add {the files repointed in step 8}
   git commit -m "chore(specs): archive {slug} — last delivery unit"
   ```
   When step 5 said "do not archive", the message is instead
   `chore(specs): tick delivery unit {N} for {slug}`.

## Output

Archived:

```
✅ Spec archived: .ai/specs/implemented/{file}.md
   Delivery: {N}/{N} units ticked — this branch was the last.
   References repointed: {count} file(s)
   Committed: {sha7}
```

Not archived:

```
⏸  Spec stays open: .ai/specs/{file}.md
   Delivery: {done}/{total} units ticked (this branch = PR {N}).
   Still owed:
     - PR {M} — `{branch}` — {scope}
   Committed: {sha7}  (ledger tick only)
```

## Rules

- **Never** archive a spec with an unticked unit. That is the whole point of the skill: archival driven
  by a merge event cannot see past the merging PR.
- **Never** tick a unit for work that is not on the branch. The ledger is a claim about `main`.
- **Never** hand-move a spec with `mv` — `git mv` is what keeps the file's history.
- **Never** archive from `main`.
- **Never** touch the `## Progress` phase checklist here. Phases are ticked by the session that
  builds them; this skill ticks the ledger only.
- A spec that is abandoned rather than implemented is **not** archived by this skill — `implemented/`
  means implemented. Ask the user what to do with it.
