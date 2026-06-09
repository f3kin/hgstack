---
name: hg-ship
description: >
  Ship your current work. Handles commits, PRs, CI, merges, deploys,
  and PROJECT.md updates. Use when done with a feature and ready to ship.
  Trigger phrases include "ship it", "deploy", "push this",
  "merge it", "done", "I'm done", "finished", "ready to merge",
  "looks good let's push", "open a PR", "send the PR", "good to go",
  "PR time", "ready for review". For parking or saving progress without
  shipping, use a park skill if you have one.
argument-hint: "(no args)"
triggers:
  - ship it
  - deploy
  - merge it
  - ready to merge
  - open a PR
  - PR time
---

# Ship

Get your code from "done coding" to "live in production". Updates PROJECT.md in the repo so every session starts with current context.

## Prerequisites

- `git` and a remote configured (`origin`).
- `gh` (GitHub CLI) authenticated. If not available, the skill falls back to manual instructions.
- Optional: `vercel` CLI for production deploy verification on Vercel projects.
- Optional companion skills (each used only if installed): a park skill, a code review skill, a docs sync skill, a cross-model review skill, a verification skill. If any of these are not present, skip that step.

## Config

| Var | Purpose | Required |
|---|---|---|
| `HG_SHIP_STACK_DIR` | Path to a shared stack repo that provides helper scripts (`setup-repo-ci.sh`, `diff-scope.sh`, `slop-diff.sh`). | No (helpers are skipped if unset or missing) |

If `HG_SHIP_STACK_DIR` is set, the skill uses its scripts to enforce CI baseline and scope analysis. If not, those steps are skipped with a one-line note.

## Mode selection

If the user's intent is clearly to park or save progress (not ship), redirect to a park skill if available, otherwise tell the user there's nothing to ship and stop.

---

## Ship mode

Feature is complete. Goal: committed, pushed, PR'd, reviewed, CI green, merged, deployed.

### Step -1: Detect worktree

Standard git worktrees share one `.git` directory across multiple checkouts. `.git` in a worktree is a *file* (a gitlink), and `main` is usually checked out in a sibling worktree, so `.git/hooks/*` lookups and `git checkout main` both fail in ways that look like missing hooks or a broken repo.

Probe once at the top of the workflow:

```bash
IS_WORKTREE=false
if [ -f .git ] && head -1 .git 2>/dev/null | grep -q "^gitdir:"; then
  IS_WORKTREE=true
fi
GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")
```

Use `GIT_COMMON_DIR` whenever checking shared git state (hooks, packed refs, etc.) so the same checks work in both worktrees and standard checkouts. Skip any step that requires `checkout main` when `IS_WORKTREE=true`. Use `git fetch origin main` instead.

### Step 0: Verify dev pipeline is wired up

Before doing any of the rest, confirm this repo has a baseline dev pipeline installed. If it doesn't, the rest of the workflow has weaker guardrails.

```bash
NEEDS_SETUP=false
[ -f ".github/workflows/ci.yml" ] || NEEDS_SETUP=true
[ -f "$GIT_COMMON_DIR/hooks/pre-commit" ] || NEEDS_SETUP=true
[ -f "$GIT_COMMON_DIR/hooks/pre-push" ] || NEEDS_SETUP=true
```

If `NEEDS_SETUP=true`, stop and report:
> "This repo is missing parts of the baseline dev pipeline (CI, pre-commit, or pre-push). Want me to wire them up before continuing?"
> Options: "Yes, set up first" / "Skip, ship anyway"

For "Yes, set up first", if `HG_SHIP_STACK_DIR` is set and `setup-repo-ci.sh` exists there, run it. Otherwise, tell the user no setup helper is configured and continue with "Skip, ship anyway".

### Step 1: Check git state

```bash
git status --porcelain
git branch --show-current
git log --oneline @{u}..HEAD 2>/dev/null  # unpushed commits
```

Report: uncommitted changes, current branch, unpushed commits.

If there are no changes and no unpushed commits, there's nothing to ship. Redirect to a park skill if available, otherwise stop.

### Step 1.5: Diff scope (optional)

If `HG_SHIP_STACK_DIR/scripts/diff-scope.sh` exists, source it and categorise what changed to focus reviews and catch scope creep. Use scope to focus reviews, flag auth/migration changes as higher risk in the PR description, and warn if the diff touches many unrelated scopes.

### Step 2: Branch check

If on `main` or `master`:
1. Infer a branch name from the session context using `feat/<short-description>` format.
2. Create and switch to the branch without asking.
3. Tell the user which branch you created.

If already on a feature branch, continue.

### Step 3: Run local checks

Detect available checks from `package.json` scripts, `Makefile`, or project config and run in order (skip any that don't exist): `lint`, `typecheck`, `build`, `test`. If `HG_SHIP_STACK_DIR/scripts/slop-diff.sh` exists, run it as an advisory pass.

If lint or build fails, report the error and ask: "Want to fix it, skip, or abort?"

**Test failure triage**:
- Determine whether the failure is **in-branch** (caused by code on this branch) or **pre-existing** (fails on main too).
- **In-branch failure**: blocker. Stop and fix. Do not offer "skip".
- **Pre-existing failure**: report and continue shipping.

**Regression rule** (mandatory): when a test fails due to in-branch code and you fix it, write a regression test for the specific failure before continuing.

### Step 3.25: Verification (opt-in)

If you have a verification skill installed, offer to run it after local checks pass. Treat its verdict as:
- PASS: continue
- PARTIAL: surface findings, ask whether to continue
- FAIL: stop

### Step 3.5: Code review (opt-in)

If you have a code review skill installed, invoke it for a structured pre-merge review (scope drift, plan completion, security, code quality). Verdict handling: BLOCK stops, CONCERNS asks, CLEAN continues.

### Step 3.75: Sync documentation (opt-in)

If you have a docs sync skill installed, invoke it to cross-reference the diff against project docs (PROJECT.md, CLAUDE.md, README, debug.md, etc.) and update them. Running this before staging means doc updates are included in the same commit.

### Step 4: Stage and commit

1. Show the diff summary (`git diff --stat`, `git diff --cached --stat`).
2. Stage all changes (`git add -A`).
3. Draft a commit message from the session context. Follow conventional commits if the repo uses them.
4. Commit directly without asking for confirmation (never use `--no-verify`).
5. Tell the user the commit message you used.

### Step 5: Push

```bash
git push -u origin <branch-name>
```

If push fails, report the error and provide manual instructions.

### Step 6: Create PR

```bash
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<1-3 bullet points>

## Test plan
- [ ] Local checks pass
- [ ] CI green
EOF
)"
```

If `gh` is not available, provide the GitHub URL for manual PR creation and continue.

### Step 6.5: Cross-model review (opt-in)

If you have a cross-model review skill installed, offer to run it before merging. Same-family review (Claude reviewing Claude) shares blind spots; cross-family review catches things we miss.

Ask: "PR is pushed. Want a cross-model review before merging?"

If yes, invoke the cross-model review skill and act on the verdict:
1. CLEAN: continue to Step 7.
2. CONCERNS or BLOCK: fix all findings (BLOCKING, SIGNIFICANT, and MINOR), commit, push, then re-run.

**Fix everything, don't defer.** The only exceptions are genuine false positives (surface to user) and already-executed one-off operations.

### Step 7: Wait for CI

```bash
gh pr checks --watch
```

If CI fails, report which checks failed and ask: "Want to investigate, skip CI, or abort?"

### Step 8: Merge

Ask: "PR is ready. Merge now?" Options: "Merge it" / "I'll merge later".

If approved:
```bash
# No --delete-branch: rely on the repo's "automatically delete head branches"
# setting. --delete-branch makes gh try to switch to the base branch locally,
# which fails in a worktree where main is checked out elsewhere.
gh pr merge --squash

# Worktree-safe local sync: never `git checkout main`. Just fetch and prune.
git fetch origin main --quiet
git remote prune origin 2>/dev/null || true

# Delete the local feature branch without switching to it.
HEAD_BRANCH=$(git branch --show-current)
MERGED_BRANCH="<the branch we just merged>"
if [ "$IS_WORKTREE" = "false" ] && [ "$HEAD_BRANCH" = "$MERGED_BRANCH" ]; then
  git checkout main && git pull --ff-only
fi
git branch -D "$MERGED_BRANCH" 2>/dev/null || true
```

### Step 9: Verify deploy (if applicable)

Look for deploy indicators:
```bash
DEPLOYS_VERCEL=false
[ -f "vercel.json" ] || [ -d ".vercel" ] && DEPLOYS_VERCEL=true
```

If Vercel is detected, actively wait for and verify the production deploy. Vercel's git integration triggers a deploy on push to main, so the merge in Step 8 already started one. We're verifying it succeeded.

```bash
if [ "$DEPLOYS_VERCEL" = "true" ] && command -v vercel &>/dev/null; then
  echo "Waiting for Vercel deploy..."
  TIMEOUT=300
  ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    LATEST=$(vercel ls --limit 1 --json 2>/dev/null | jq -r '.[0]')
    STATE=$(echo "$LATEST" | jq -r '.state // .readyState // "unknown"')
    URL=$(echo "$LATEST" | jq -r '.url')
    case "$STATE" in
      READY|"ready") echo "Deploy ready: $URL"; break ;;
      ERROR|"error"|CANCELED|"canceled") echo "Deploy failed ($STATE): $URL"; break ;;
      *) echo "Deploy state: $STATE (waiting)..." ; sleep 15 ; ELAPSED=$((ELAPSED + 15)) ;;
    esac
  done
elif [ "$DEPLOYS_VERCEL" = "true" ]; then
  echo "Vercel deploy triggered by push, but vercel CLI not installed locally."
fi
```

If the deploy went `ERROR` or `CANCELED`, report which deployment URL failed and stop. Don't update PROJECT.md as "shipped". The work isn't actually live.

If no Vercel detected, note that and continue.

---

## Idempotency

Re-running the skill on the same branch runs the entire checklist again (lint, test, review, etc.) but skips actions that are already complete:
- Branch already exists: don't create it again
- Commit already made (no new changes): skip staging and committing
- PR already created: skip PR creation, show existing PR URL
- Branch already pushed: skip push (unless there are new commits)

Every verification step runs on every invocation. Only actions are idempotent.

## Never stop for

These things are auto-decided without interrupting the user:
- **Commit message content**: draft from session context, commit directly
- **Branch name**: infer from context, create without asking
- **Which files to stage**: always `git add -A`, don't cherry-pick files
- **Auto-fixable lint issues**: fix them silently, report what was fixed
- **PR description content**: draft from context, create without asking
- **Regression tests**: write them immediately when in-branch failures are fixed

Everything else that involves a choice or a risk should prompt the user.

## Safety rules

1. **Never force push.** No `--force`, no `--force-with-lease` unless the user explicitly requests it.
2. **Never push directly to main.** Always use a feature branch and PR.
3. **Never skip hooks silently.** No `--no-verify` unless the user explicitly asks.
4. **If `gh` is unavailable**, provide manual instructions instead of failing.
5. **Report errors clearly.** If something fails, say what failed, why, and offer to skip or retry.
6. **Pull everything from context.** Don't ask the user to fill in PROJECT.md details. Infer from the session.
7. **In-branch test failures are blockers.** Never offer to skip past a test failure that your code caused.
