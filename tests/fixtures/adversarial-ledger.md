# Adversarial ledger fixture

Every shape `parse-ledger.sh` has to survive, in one file. The expected rows are in
`test-parse-ledger.sh`.

## Delivery — with a suffix on the heading

Prose before the units, mentioning a `feat-decoy-in-prose` branch in backticks.

- [x] **PR 1** — `feat-first` — the first thing — est ~100 → 96 lines, 4 files, 12% comments, 30 ctx (#101)
- [X] **PR 2a** — `feat-second-a` — a capital X and a letter suffix, and the word parent `feat-first` as plain text (#102)
- [ ]  **PR 2b**  — `feat-second-b`  — extra spaces everywhere
- [ ] **PR 3** — `feat-third` — an entry whose description mentions `main` in backticks
  > a blockquote under an entry is not a unit and must not be counted
  - [ ] a nested checkbox that is not a delivery unit

### PR 3 — a prose subsection whose heading looks like a unit

- [ ] a checkbox inside the subsection, with no PR label

The subsection heading above closed the section, so nothing from here on is parsed.

```markdown
- [ ] **PR 99** — `feat-fenced-example` — a documented example, not a real unit
```

 ## New business rules — a heading with a leading space

- [ ] **PR 98** — `feat-after-leading-space-heading` — must not be parsed

## Progress

- [x] **Phase 1** — the port, with `Inline` code
- [ ] **Phase 2** - the adapter - a plain dash and a nested note
  - [ ] a nested checkbox that is not a phase
- [ ]  **Phase 3**  —  the wiring

_Notes:_ a session rewrites this paragraph. It mentions **Phase 9** in bold and a `- [ ]` in code.

```markdown
- [ ] **Phase 99** — a documented example, not a real phase
```

## Risks

- [ ] a checkbox after the section closed
