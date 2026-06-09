# CLAUDE.md  -  hgstack

Context for Claude Code (and other coding agents) working in this repository.

## What this repo is

A public, curated subset of the Claude Code stack used by [Hourglass](https://thehourglass.ai) to run internal automations and ship client AI projects. Plain markdown / shell files. No runtime, no framework, no package.

The internal stack lives in a private repo (`hourglass-claude-stack`) under the Hourglass GitHub org. This public version is curated, sanitised, and generalised for anyone to fork.

## Conventions

- **Skills** live in `skills/<name>/SKILL.md`. Each is self-contained.
- **Naming:** `hg-*` prefix = Hourglass team practice. Unprefixed = general-purpose.
- **Frontmatter:** every `SKILL.md` has YAML frontmatter with `name`, `description`, optional `argument-hint`. The `name` field must match the directory name.
- **No hardcoded paths, secrets, or personal references.** Use env vars (`$<SKILL>_<PURPOSE>`) for anything external. Two audit scripts in the private stack (`check-generalisable.sh`, `check-shareable.sh`) enforce this before anything ships here.
- **Australian English.** Never use em dashes  -  use colons, semicolons, commas, or rewrite.

## How skills get added

Skills are sanitised in the private `hourglass-claude-stack` repo using the `/generalise` skill, audited by `check-generalisable.sh` and `check-shareable.sh`, then copied here in batches. We don't accept skills directly into this repo unless they've been through that pipeline.

External contributions are welcome via PR  -  see `CONTRIBUTING.md` (coming) for the audit process.

## What this repo is NOT

- A framework. Don't add a `package.json`, a CLI, or a runtime. Skills are files.
- A kitchen-sink dump. Every skill here has earned its place by being useful enough that we run it daily.
- Hourglass-internal infrastructure. Anything wiring into our private brain, VPS, client deliverables, or internal Supabase stays in the private stack.
