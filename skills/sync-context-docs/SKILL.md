---
name: sync-context-docs
description: Update or create the AGENTS.md nearest to every directory the branch touched, so the docs describe the code as it now is. Reads from code — never from memory. Run before opening a PR. Triggers on "sync docs", "update context docs", "sync context docs", "update agents".
---

# Sync Context Docs

After implementing a phase or a feature, update (or create) the documentation that governs every
directory the branch touched, so future agents do not have to re-read all the code to learn what
it does.

**Read from the filesystem, always.** Every claim you write must come from the code as it is on
this branch right now. A doc updated from recollection is worse than a stale one: it is
confidently wrong.

## The base

`$BASE` is the commit this work started from — `origin/main`, or the `Base:` a delivery-loop
session's prompt names:

```sh
BASE="${1:-origin/main}"
```

With a base that reaches back past this unit, the skill sees directories this unit never touched
and rewrites their docs on this branch. It runs once per phase, so the effect compounds.

## Superpowers Integration

Invoke before starting this workflow:
- `superpowers:verification-before-completion` — after updating each doc, re-read the changed
  sections against the code and confirm every statement is accurate before committing.

**Run this before `/open-pr` or `/check-and-commit`.** Every doc change on the branch must be
committed before the PR opens.

---

## Workflow

### Step 1 — Find every directory the branch touched

```bash
git diff "$BASE"...HEAD --name-only | xargs -n1 dirname | sort -u
```

### Step 2 — For each of them, find the doc that governs it

Walk up from the directory to the repository root and take the **first** `AGENTS.md` (or
`CLAUDE.md`, where the host uses that name) you find. That is the doc this change belongs in.
Several directories usually resolve to the same doc — group them and update it once.

A directory that resolves only to the root doc, and whose change is substantial enough to need
documenting locally, gets a new `AGENTS.md` of its own. Do not create one for a change that the
root doc already covers.

### Step 3 — Read the code, then update the doc

For each doc in the group:

1. Read the existing doc, if there is one, to see what is already claimed.
2. **Read the code it describes** — the public surface (entry points, exported functions and
   types, routes, commands, events), the rules the code enforces, the dependencies it has on
   other parts of the tree, and the file layout.
3. Rewrite only what changed. Leave accurate sections alone.

Write what the code **is**, in the present tense — not what changed, not what it replaced. The
history lives in `git log` and in the spec.

A good doc answers these without reading the code:

1. **What does this part of the system own?** — one paragraph, including what it does *not* own.
2. **What is its public surface?** — every entry point, with whatever the host records about it
   (auth level, parameters, return shape).
3. **What rules does it enforce?** — the invariants, and where each is enforced.
4. **What does it depend on, and how?** — direction and mechanism.
5. **What must never be done here?** — the anti-patterns specific to this code.
6. **Where are the files?** — an abbreviated structure tree.
7. **How is it validated?** — the commands that check it.

If any of those is missing or stale for the code the branch touched, fix it before committing.

### Step 4 — Sync the docs the root doc names

The root `AGENTS.md` / `CLAUDE.md` names the cross-cutting documents this repository keeps
(architecture, persistence, workflow, a status or roadmap file, a lessons file). Read that list
and update every entry the branch affected. If the root doc names none, there is nothing to do
in this step.

Two are worth naming as habits rather than as paths:

- **A status or roadmap doc is the row people forget.** It is the only source of truth for what
  exists. A stale ✅ sends the next person to build something twice; a stale ⬜ sends them to
  re-plan something already merged. When a status changes, update the row itself, **every other
  row that named it as a dependency**, and any open question the work resolved.
- **The spec** — record the phase's completion in its Changelog.

### Step 5 — Check the root doc's own index

If the branch introduces a new component, a new kind of task, or a new skill, add or update its
row in whatever index or router table the root `AGENTS.md` keeps.

### Step 6 — Commit

Stage and commit every doc change together:

```bash
git add $(git diff --name-only | grep -E '(AGENTS|CLAUDE)\.md$') .ai/specs/
git commit -m "docs: sync docs after <feature-name>"
```

Include whatever cross-cutting docs Step 4 changed.

---

## AGENTS.md Template

For a directory that needs its own doc and does not have one:

```markdown
# <Name>

<One paragraph: what this owns and what it does NOT own.>

---

## Public Surface

| Entry point | Kind | Notes |
|-------------|------|-------|
| `<name>` | <route / command / exported function / event> | ... |

---

## Rules & Invariants

- <Rule> (where it is enforced)
- <Dependency on another part of the tree: what, why, how>

---

## Always

- <Concrete rule agents must follow when editing this code>

## Never

- <Anti-pattern, with the reason>

---

## Structure

\`\`\`
<abbreviated tree, one line of purpose per entry>
\`\`\`

---

## Validation Commands

\`\`\`bash
<the commands from LOOP_GATES that cover this code>
\`\`\`
```

Then create a `CLAUDE.md` beside it containing `@AGENTS.md`, if that is the host's convention.

---

## When to Run

| Trigger | Action |
|---------|--------|
| After `/implement-spec` completes a phase | Run for the directories that phase touched |
| Before `/open-pr` | Always — enforced gate |
| After a hotfix touches non-trivial logic | Run for the affected directory |
| When a doc is visibly stale | Run on demand |
