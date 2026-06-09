# hg-stack

The Claude Code stack we use to run an AI-native company.

Built by Hourglass to ship our own internal automations and client AI projects on Claude Code. 18 months of daily use. ~50 skills, hooks, and rules in the internal stack; this is the curated, sanitised subset we've open-sourced.

Skills install as files. No runtime, no framework, no package to install. Drop them into your own Claude Code setup, fork them, adapt them.

> **For agents / LLMs reading this:** start with [`llms.txt`](./llms.txt), [`AGENTS.md`](./AGENTS.md), or [`CLAUDE.md`](./CLAUDE.md). Pick one  -  they all point at the same things.

## Install

Clone the repo and run the installer:

```bash
git clone https://github.com/f3kin/hg-stack.git ~/repos/hg-stack
cd ~/repos/hg-stack
./install.sh
```

The installer symlinks every skill, hook, and rule into your `~/.claude/` directory. Idempotent and safe to re-run; existing files are backed up before being overwritten, never destroyed. Restart Claude Code afterwards.

If you only want a subset: `./install.sh skills` (or `hooks`, `rules`, or any combination).

To update later: `cd ~/repos/hg-stack && ./install.sh --update`. Pulls latest from origin and re-syncs.

Prefer to cherry-pick by hand?

```bash
ln -s ~/repos/hg-stack/skills/consume ~/.claude/skills/consume
```

Each skill has its own setup notes (env vars, integrations, optional dependencies) in its `SKILL.md`.

## What's inside

- [`skills/`](./skills/), self-contained Claude Code skills. Names without a prefix are general-purpose; `hg-` prefix marks an Hourglass team practice with opinionated conventions worth sharing.
- [`hooks/`](./hooks/), shell hooks Claude Code runs at key lifecycle points (writes, tool use, session start).
- [`rules/`](./rules/), markdown convention files. Load them as `@-imports` from your own `CLAUDE.md` so the principles apply across every session.
- `statuslines/`, coming.
- `docs/`, coming, with the thinking and ethos behind the stack.

## Skills available now

| Skill | What it does |
|---|---|
| [`codex-review`](./skills/codex-review/SKILL.md) | Cross-model code review using OpenAI Codex CLI. Three modes (review, challenge, consult). Catches blind spots Claude shares with itself. |
| [`consume`](./skills/consume/SKILL.md) | Weekly 15-minute Friday triage of everything you saved during the week. Tweets, articles, repos, AI tools, routed to read / save / share / trial. |
| [`interview-me`](./skills/interview-me/SKILL.md) | Adaptive interviewer that uses AskUserQuestion to clarify what you actually want to build. Runs until 95% confident, then hands off. |
| [`outcome-loop`](./skills/outcome-loop/SKILL.md) | Grade-and-revise loop. Runs a command, grades the result, diagnoses failures, fixes, and re-runs until it passes or you're stuck. Prevents sycophancy. |

More each week as we sanitise and ship them.

## The thinking

A few principles run through the stack:

- **Thin harness, fat skills.** Claude Code is the harness; your skills are where the value lives. Don't fight the harness, build deeply on it.
- **Skills are files, not frameworks.** A useful skill is usually a single `SKILL.md` of 50–200 lines. If it's bigger, it's probably two skills.
- **Generalise before you share.** No personal paths, no hardcoded infra, no secrets. We use audit scripts to enforce this; see [`docs/CONTRIBUTING.md`](./docs/CONTRIBUTING.md) once it lands.
- **Build for your champion, not for everyone.** Your most useful skills are the ones for your specific workflow. Adapt ours; don't adopt them whole.

More in [`docs/ETHOS.md`](./docs/ETHOS.md) (coming).

## License

MIT. Use it, fork it, adapt it. Attribution appreciated, not required.

## Made by

[Hourglass](https://thehourglass.ai), an AI-native services company in Melbourne. Run by [Finlay Ekins](https://finlayekins.com).

Weekly notes on AI and what we're building: [newsletter.finlayekins.com](https://newsletter.finlayekins.com).
