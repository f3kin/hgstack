# debug.md convention

Each project can have a `debug.md` at its root (or in `docs/`) that captures accumulated debugging context and operational patterns. This file is read by both human developers and the autonomous bug fixer.

## When to read it

- At the start of any debugging or bug-fixing session
- Before the `/investigate` skill's Phase 1
- When the autonomous bug fixer runs on a project

## When to write to it

After fixing a bug or discovering a non-obvious pattern, offer to append an entry if:
- The root cause was surprising or non-obvious
- The same area has had bugs before (architectural smell)
- A framework/library quirk caused the issue
- A useful debugging technique was discovered

Don't log obvious things, one-time transient errors, or generic best practices.

## Format

```markdown
# Debug Context

Project-specific debugging patterns, anti-patterns, and operational knowledge.
Updated by both humans and Claude sessions.

## Patterns

### [Short description] ([YYYY-MM-DD])

**Symptom:** [what was observed]
**Root cause:** [what was actually wrong]
**Fix:** [what was changed]
**Lesson:** [reusable takeaway]

## Anti-patterns

- [thing to avoid] because [why]

## Environment notes

- [operational quirk, e.g. "dev server must run on port 3001 not 3000"]
```

## Relationship to other files

- `debug.md`: project-specific debugging context (this file)
- `CLAUDE.md`: project conventions, stack, structure
- `PROJECT.md`: project status, tasks, decisions
- Brain (`/brain-write`): cross-project learnings, company knowledge
