# Debugging rule

## Core principle

**No fixes without root cause investigation first.**

Fixing symptoms creates whack-a-mole debugging. Every fix that doesn't address root cause makes the next bug harder to find. Find the root cause, then fix it.

## When debugging

1. **Gather evidence first.** Read error messages, stack traces, reproduction steps. Trace the code path from symptom to cause.
2. **Check recent changes.** Run `git log --oneline -20 -- <affected-files>`. If this was working before, the root cause is in the diff.
3. **Form a hypothesis.** State it explicitly: "Root cause hypothesis: X because Y."
4. **Verify before fixing.** Add a log, assertion, or debug output to confirm the hypothesis. Don't guess.
5. **Fix the root cause, not the symptom.** Smallest change that eliminates the actual problem.
6. **Verify the fix.** Reproduce the original scenario and confirm it's fixed. Run the test suite.

## Red flags: stop and reassess

- Proposing a fix before tracing data flow: you're guessing
- "Quick fix for now": there is no "for now." Fix it right or escalate.
- Each fix reveals a new problem elsewhere: wrong layer, not wrong code
- 3+ failed fix attempts: question the architecture, not the code

## After fixing

- If the project has a `debug.md`, check whether this investigation revealed a reusable pattern or anti-pattern worth recording
- For the full structured investigation workflow, use `/investigate`
