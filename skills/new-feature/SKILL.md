---
name: new-feature
description: "Create an isolated git worktree on a new branch from main and enter it, ready for feature work. Triggers on \"new feature\", \"let's do a new feature\", \"start a feature\", \"let's plan a feature\", \"new branch for\", \"open a worktree\"."
---

# New Feature

> **Names.** The engine's skills are invoked as `/engineering-loop:<name>`; a bare `/<name>` in this
> text means that one, never a host skill sharing the name.

Spin up an isolated worktree from `main` so the feature has its own branch and working tree without touching the main checkout.

> **A feature is one worktree, one branch, one PR.** Driven by hand, that worktree carries the spec and its implementation together.
>
> **`/ship` and the delivery loop are the exception, and it is not cosmetic.** There the spec ships as its own PR on `feat-<slug>-spec` and is merged before anything is built, because the loop creates the build worktree from `main` itself and copies in nothing but `settings.local.json` — a spec that is not on `main` is not in the worktree, and the session is told to implement a file that does not exist. The loop does not call this skill.
>
> Building a later unit of a spec whose ledger declares a deployment seam? Name this branch exactly as its `## Delivery` line does; the ledger binds units to branch names. Re-verify the spec's **Current State** section before implementing — `main` has moved since the previous unit merged.

## Method

- **Check before creating.** `git worktree list` first: a worktree already on this branch is entered,
  not duplicated. Prefer the `EnterWorktree` tool over a raw `git worktree add`; it creates, enters
  and registers the tree in one step.
- **Design before branching when the scope is unclear.** Have the design conversation `/ship` step 1
  describes — or the skill the host's `AGENTS.md` routes design to — before naming a branch after
  a feature nobody has agreed on.

## Workflow

1. **Get the feature name** from the user's message or ask if not clear enough to derive a branch name.
2. **Derive the branch name**: `feat-<kebab-case-description>` — max ~40 chars, lowercase, hyphens only, no slashes. **Do not ask for confirmation** — just pick the name and go.
3. **Refresh `main` before branching**: run `git fetch origin` so the worktree's base ref is current. `EnterWorktree`'s default `fresh` base ref branches from `origin/<default-branch>` **as of the last fetch** — without this step the new branch can silently start from a stale `main`. The worktree branches from the freshly-fetched `origin/main` regardless of your local `main`'s position, so the fetch is what matters. (To confirm local `main` is itself level with the remote, `git rev-list --left-right --count main...origin/main` prints `0	0` — any nonzero side means it has diverged.)
4. **Create the worktree** at `.claude/worktrees/<branch>` on the new branch, and enter it. Use `EnterWorktree` with the derived name where the tool is available, otherwise:
   ```sh
   git worktree add -b feat-<slug> .claude/worktrees/feat-<slug> origin/main
   ```

   **Keep the checkout clean without committing anything**: the worktree directory would otherwise
   show as untracked in the main checkout. Add it to the repository's *local* exclude file, never to
   `.gitignore`:
   ```sh
   grep -qxF '.claude/worktrees/' "$(git rev-parse --git-common-dir)/info/exclude" 2>/dev/null \
     || printf '.claude/worktrees/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
   ```

   **Then check the branch name** — `EnterWorktree` may name it `worktree-<name>`, which is not the convention. If it did, rename it from inside the worktree: `git branch -m feat-<slug>`. The branch name is load-bearing: a spec's `## Delivery` ledger binds the delivery unit to a branch name in backticks, the delivery loop builds the branch that line names, and `/archive-spec` stops and asks when the current branch matches no unit.
5. **Report** the branch name, worktree path, and the correct next steps.

## Branch naming

`feat-<kebab-case>` — max 40 chars, lowercase, hyphens only, no slashes. Strip articles. Derive and go; never ask for confirmation.

## Output

```
Worktree ready on branch `feat-<name>`.
Path: .claude/worktrees/feat-<name>

Next steps:
1. /spec-writing                              ← draft spec locally on this branch
2. /pre-implement-spec .ai/specs/{file}.md    ← audit the spec for gaps
3. /implement-spec .ai/specs/{file}.md        ← implement phase by phase
4. /open-pr                                   ← this unit's PR to main (first unit: spec + code)
```
