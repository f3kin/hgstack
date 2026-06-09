---
paths:
  - "**"
---

# Testing rules

## When to write tests
- **Internal prototypes and tooling:** skip tests unless the project is heading to production
- **Client work and production code:** write tests, always

## What to test
Focus on "what would be catastrophic if it broke":
- Authentication and authorisation flows
- Payment processing and billing logic
- Security boundaries (input validation, access control, token handling)
- Data integrity (migrations, critical writes, state transitions)

Don't aim for full coverage. Cover critical paths, not every helper function.

## How to test
- Check for a testing instructions file in the repo (e.g. `TESTING.md`, `tests/README.md`, or a `testing` section in `CLAUDE.md`). If one exists, follow it.
- Match the existing test framework and patterns in the repo. Don't introduce a new test runner.
- One test file per feature or module under test, not one giant test file.
- Name tests descriptively: what the test proves, not what it calls.
