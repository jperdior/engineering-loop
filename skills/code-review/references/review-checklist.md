# Review Checklist (Full)

Every item is judged against the rules the host repository documents for itself — the root
`AGENTS.md` / `CLAUDE.md` and the nearest one to each changed directory — plus the spec, when
there is one. An item the host says nothing about is judged against the surrounding code, and
the finding says the rule was inferred.

## Conventions

- [ ] Naming follows the documented convention for this kind of file
- [ ] Files are placed where the host's docs say this kind of file lives
- [ ] Language-level conventions the host mandates are honoured (strictness flags, immutability,
      error types, formatting)
- [ ] Public contracts (routes, messages, exported types, config keys) are shaped as the host
      documents
- [ ] No new dependency added without the host's stated approval path

## Boundaries

- [ ] Every dependency direction the host declares forbidden is respected
- [ ] Modules communicate through the interfaces the host names, not through each other's
      internals
- [ ] Interfaces live where the host says, implementations where the host says
- [ ] No new coupling between components the host documents as independent

## Security

- [ ] Every new or changed endpoint declares its authorisation
- [ ] Input is validated at the boundary before it reaches domain logic
- [ ] No injection surface introduced (SQL, command, template, path traversal)
- [ ] No credentials, tokens or keys hard-coded, logged or committed
- [ ] No PII in logs or error messages
- [ ] Error responses disclose no more than they must

## Data Integrity

- [ ] Schema migrations match the change's intent, with no unrelated churn
- [ ] Every migration has a working rollback, or documents why it cannot
- [ ] Retried and asynchronous work is idempotent
- [ ] Concurrent access to shared state is accounted for

## Code Quality

- [ ] No dead code, unreachable branches or commented-out blocks
- [ ] No logic duplicated from a place that already has it
- [ ] Error paths handled, not swallowed
- [ ] No debug output, temporary logging or scratch files left behind

## Tests

- [ ] Every case in the spec's Integration Coverage has a test
- [ ] New behaviour and every risk path are covered
- [ ] Tests assert behaviour, not implementation detail
- [ ] Tests are independent of each other and of ordering, and clean up after themselves
- [ ] No `.only`, skipped tests or disabled assertions left behind
- [ ] Tests use the framework, location and level the host's conventions name

## Backward Compatibility

- [ ] No public API route, message or event name renamed or removed
- [ ] No response field removed (additive only)
- [ ] No database column or table renamed or removed (additive only)
- [ ] No exported type or function signature broken
- [ ] No configuration key renamed without a fallback
- [ ] Deprecation path documented where a break was unavoidable

## Documentation

- [ ] The `AGENTS.md` / `CLAUDE.md` nearest to each changed directory describes the code as it
      now is
- [ ] The spec's Changelog records what this change delivered
