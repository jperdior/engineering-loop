---
name: archive-spec
description: "Tick the current branch's unit in a spec's Delivery ledger and move the spec to .ai/specs/implemented/. A spec is one unit, so the branch that ticks it is the one that archives it. Triggers on \"archive spec\", \"archive the spec\", \"is this the last PR of the spec\"."
---

# Archive Spec

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.
> **Names.** The engine's skills are invoked as `/engineering-loop:<name>`; a bare `/<name>` in this
> text means that one, never a host skill sharing the name.

Tick this branch's unit in the spec's ledger and archive the spec into `.ai/specs/implemented/`.

**A spec is exactly one delivery unit**, so the branch that ticks it is always the branch that
archives it — there is no "is this the last one?" to decide. The count in step 5 is a check that the
ledger is well formed, not a fork in the flow.

The spec file itself is the ledger that records that the unit is built, because it is the one artefact
that travels to `main` with the PR. No CI job archives specs; archival is a commit on the delivery PR,
reviewed like any other change.

## The Delivery ledger

Every spec carries a `## Delivery` section holding **exactly one** checklist line:

```markdown
## Delivery

- [ ] **PR 1** — `feat-project-knowledge-retrieval` — the whole feature — est ~600
```

- `- [x]` — the unit is built and its PR is open or merged, or lands with the PR being opened right now.
- `- [ ]` — the unit is still owed.

The unit's backticked name — the one directly after its `**PR 1**` label — is its branch, and that is
what binds the unit to a branch. Read it, never guess it. `<loop>/parse-ledger.sh` applies this rule,
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
   <loop>/parse-ledger.sh "$SPEC"        # done|unit|branch — one row, always
   ```
   **Exit 3** means the ledger is malformed or the spec has no `## Delivery` section. Do not write one
   from guesswork: stop, show the user what the section looks like, and ask them to fix it.

   **More than one row** is a malformed spec too, and the more damaging kind — nothing builds a
   two-unit ledger, `<loop>/delivery-loop.sh` refuses it before it starts. Stop and say so: the spec
   should have been cut to the unit that merges first, with the rest deferred to its own spec
   (`../spec-writing/references/delivery-units.md`). Do not tick a row and carry on as if the flow
   were normal.

4. **Tick this branch's unit.** The row's **`branch` field** must equal the current branch; rewrite
   that line's `- [ ]` to `- [x]`. Then:
   - Already ticked → the unit is already recorded; leave it and carry on to step 5.
   - The row names a **different** branch → stop and ask. Either the ledger is stale or this branch is
     not this spec's delivery unit. Never invent a unit and never tick one whose branch is not yours.

   Write the tick as `- [x] … — est ~N`, leaving the estimate in place. The delivery loop rewrites
   that same line afterwards with the realised measurements from `<loop>/unit-size.sh` and the PR
   number; it replaces everything after the ` → `, so do not add measurements by hand.

5. **Count what is left.**
   ```sh
   <loop>/parse-ledger.sh "$SPEC" | grep -c '^ |' || true
   ```
   - **Zero → archive.** This is the only outcome a well-formed spec reaches. Continue to step 6.
   - **Greater than zero → stop, do not archive and do not commit.** With one unit ticked in step 4
     this cannot happen, so it means the ledger holds a row step 4 did not see. Report it as the
     malformed ledger of step 3 and leave the spec where it is.

6. **Close the spec out** before moving it:
   - Append a `## Changelog` row: `| {YYYY-MM-DD} | Implemented — delivery unit built, spec archived. |`
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
   git commit -m "chore(specs): archive {slug} — delivery unit built"
   ```

## Output

Archived:

```
✅ Spec archived: .ai/specs/implemented/{file}.md
   Delivery: PR 1 ticked — `{branch}`.
   References repointed: {count} file(s)
   Committed: {sha7}
```

Not archived — the ledger is malformed, and nothing was committed:

```
⏸  Spec stays open: .ai/specs/{file}.md
   Delivery: the ledger holds {N} lines; a spec is one delivery unit.
   Cut it to the unit that merges first and defer the rest to its own spec.
```

## Rules

- **Never** archive a spec with an unticked unit. That is the whole point of the skill: archival driven
  by a merge event cannot see past the merging PR.
- **Never** tick a unit for work that is not on the branch. The ledger is a claim about `main`.
- **Never** repair a multi-line ledger by ticking your row and archiving anyway. A second line means
  the spec was written wrong; say so and stop.
- **Never** hand-move a spec with `mv` — `git mv` is what keeps the file's history.
- **Never** archive from `main`.
- **Never** touch the `## Progress` phase checklist here. Phases are ticked by the session that
  builds them; this skill ticks the ledger only.
- A spec that is abandoned rather than implemented is **not** archived by this skill — `implemented/`
  means implemented. Ask the user what to do with it.
