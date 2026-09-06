---
name: open-pr
description: "Open a GitHub PR for the current branch with a templated body, labels, and a link to the spec. Triggers on \"open a PR\", \"create the PR\", \"submit PR\"."
---

# Open PR

> **Paths.** `<loop>` is the plugin's `loop/` directory, two levels above this skill's own directory
> (`<this skill's base dir>/../../loop`); Claude Code prints the base directory when the skill loads.

Open a PR for the work already on the current branch (the branch must have commits ahead of the
base).

## Superpowers Integration

Invoke before starting this workflow:
- `superpowers:finishing-a-development-branch` — structured branch-completion flow: verify tests
  → detect environment → present 4 options (merge locally, push+PR, keep, discard). Can replace
  steps 1-3 of this skill.

## Workflow

0. **The base is `main`.**
   ```sh
   BASE="${BASE:-main}"
   ```
   Everything below uses it.
1. **Check branch state**:
   ```sh
   git status
   git log --oneline "origin/$BASE"..HEAD
   git diff "origin/$BASE"...HEAD --stat
   ```
   If the branch has no commits ahead, stop and ask the user. Uncommitted changes mean the PR
   would be incomplete — commit or stash them first.
2. **Push** if not already pushed:
   ```sh
   git push -u origin $(git rev-parse --abbrev-ref HEAD)
   ```
3. **Read the gate commands**, so the test plan lists the real ones: from the spec this branch
   carries when there is one, else from the host's `AGENTS.md` validation section.
   ```sh
   <loop>/parse-ledger.sh .ai/specs/{file}.md --gates
   ```
   When the prompt names a telemetry file, put its markdown table in the body under a
   `## Sessions` heading, as it is: the repository carries no telemetry, so the PR is its record.
4. **Open the PR** with the body template, one test-plan checkbox per gate command:
   ```sh
   gh pr create --base "$BASE" --title "<type>(<scope>): <summary>" --body "$(cat <<'EOF'
   ## What
   <!-- One sentence: what does this PR do? -->

   ## Why
   Implements spec: <!-- .ai/specs/{file}.md — or "N/A" if no spec -->
   Delivery: <!-- the unit from the spec's ## Delivery ledger. Say whether this PR archives the
                  spec, and if not, what is still owed. Omit if no spec. -->

   ## How
   <!-- Key implementation decisions. Skip the obvious. -->

   ## Test plan
   - [ ] `<gate command>` exits 0
   - [ ] Manually tested: <!-- describe the happy path you exercised -->

   ## Checklist
   - [ ] Follows the conventions in the root AGENTS.md and the one nearest the changed code
   - [ ] No credentials, tokens or secrets committed
   - [ ] Docs updated for every directory this branch touched (`/sync-context-docs`)
   EOF
   )"
   ```
5. **Apply labels — only ones the repository already has**:
   ```sh
   gh label list --limit 200 --json name --jq '.[].name'
   ```
   Add the labels from that list that fit (a review label, a category such as
   `feature` / `bug` / `refactor` / `security` / `documentation`). A label the repository does
   not define is skipped silently — **never** create one, and never let a missing label fail the
   PR. If the PR is already open, say which labels were applied and which were skipped.
6. **Report** the PR URL.

## PR Title Convention

`<type>(<scope>): <summary>` — Conventional Commits.

| Type | When |
|------|------|
| `feat` | new behaviour |
| `fix` | bug fix |
| `refactor` | code change with no behavioural change |
| `chore` | maintenance, deps, CI |
| `docs` | documentation only |
| `test` | tests only |
| `perf` | perf improvement |
| `security` | security fix |

`<scope>` is the component or app the change belongs to, in the host's own vocabulary.

## Output

```
✅ PR opened: {URL}
   Title: {…}
   Labels: {applied} (skipped, not defined in this repo: {…})
   Base: {$BASE}
   Head: {branch}
```

## Rules

- NEVER force-push a shared branch.
- Always use a HEREDOC for the body to preserve formatting.
- Always include the spec link in the body if one exists.
- If the branch carries a spec, read its `## Delivery` ledger and state the unit in the body. A
  spec still sitting in `.ai/specs/` with every unit ticked means `/archive-spec` has not run —
  run it before opening the PR, since archival belongs in the last delivery PR and nothing
  archives on merge.
- Always check `git status` first.
