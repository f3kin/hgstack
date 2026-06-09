---
name: outcome-loop
description: >
  Run a command, grade the result, diagnose failures, fix, and re-run until it
  passes or you're stuck. General-purpose grade-and-revise loop with objective
  graders (exit code, codex review, or a custom check command) to prevent
  sycophancy. Use when you want to iterate on a failing build, test suite,
  linter, deploy, or any command that should eventually succeed.
  Trigger phrases include "outcome loop", "keep trying until it works",
  "fix and re-run", "iterate until green", "grade and revise".
argument-hint: '<command> [--grader exit_code|codex|command:<cmd>] [--rubric "text"]'
---

# Outcome Loop

Run a command, objectively grade the result, diagnose failures, fix the code, and re-run. Repeats until the command passes or you're stuck (same failure repeating). No max iteration cap: stuck detection replaces arbitrary limits.

## Arguments

```
/outcome-loop <command> [--grader exit_code|codex|command:<cmd>] [--rubric "text"]
```

| Argument | Default | Description |
|---|---|---|
| `<command>` | required | The command to run each iteration |
| `--grader` | `exit_code` | How to judge pass/fail (see Grader Modes) |
| `--rubric` | none | Extra context for the codex grader (ignored by other modes) |

## Grader modes

| Mode | Verification | Why it's objective |
|---|---|---|
| `exit_code` | Exit 0 = pass | Binary: the process either succeeded or didn't |
| `codex` | Run `/hg-codex-review`, CLEAN verdict = pass | Separate model with separate context |
| `command:<cmd>` | Run `<cmd>` after the main command, exit 0 = pass | Binary: the check command either passed or didn't |

## Stuck detection

Track failure fingerprints: hash the first 1000 characters of stderr/error output. Keep the last 3 fingerprints. If the current failure's fingerprint matches any of the last 3, declare **stuck** and stop. This prevents infinite loops without imposing an arbitrary iteration cap.

## Flow

### 1. Parse arguments

Extract the command, grader mode, and rubric from the invocation. Defaults: grader = `exit_code`, rubric = none.

### 2. Loop

Each iteration:

#### a. Run the command

Execute the command and capture stdout, stderr, and exit code.

**Remote workflow detection:** if the command starts with `gh workflow run`, use the remote workflow protocol instead of direct execution:

1. Run the trigger command
2. Wait 5 seconds, then find the new run:
   ```bash
   sleep 5
   WORKFLOW_FILE=$(echo "<command>" | grep -oP '(?<=gh workflow run )\S+')
   RUN_ID=$(gh run list --workflow "$WORKFLOW_FILE" --limit 1 --json databaseId --jq '.[0].databaseId')
   RUN_URL=$(gh run list --workflow "$WORKFLOW_FILE" --limit 1 --json url --jq '.[0].url')
   echo "Triggered run: $RUN_ID ($RUN_URL)"
   ```
3. Poll until complete (max 30 minutes):
   ```bash
   TIMEOUT=1800
   ELAPSED=0
   while [ $ELAPSED -lt $TIMEOUT ]; do
     STATUS=$(gh run view "$RUN_ID" --json status,conclusion --jq '.status + ":" + (.conclusion // "pending")')
     echo "[$ELAPSED s] $STATUS"
     case "$STATUS" in
       completed:success) echo "PASSED"; break ;;
       completed:*) echo "FAILED"; break ;;
     esac
     sleep 30
     ELAPSED=$((ELAPSED + 30))
   done
   ```
4. If failed, pull logs for diagnosis:
   ```bash
   gh run view "$RUN_ID" --log-failed 2>&1 | tail -200
   ```
5. Use the run conclusion as the exit code equivalent (success = pass, anything else = fail).

#### b. Grade

Based on the grader mode:

- **`exit_code`**: exit 0 = pass, anything else = fail.
- **`codex`**: invoke `/hg-codex-review`. If the rubric argument was provided, pass it as context. Verdict of CLEAN = pass, anything else = fail.
- **`command:<cmd>`**: run the check command. Exit 0 = pass, anything else = fail.

#### c. If pass: report success and stop

Output:
```
Outcome loop passed on iteration <N>.
Command: <command>
Grader: <mode>
```

For remote workflows, also include the run URL.

#### d. If fail: check for stuck, then diagnose and fix

1. **Fingerprint the failure.** Take the first 1000 characters of the error output (stderr for local commands, failed job logs for remote workflows). Hash it (simple string hash or comparison is fine; exact algorithm doesn't matter, just consistent deduplication).

2. **Check against the last 3 fingerprints.** If the current fingerprint matches any of them, declare stuck:
   ```
   Outcome loop stuck after <N> iterations. Same failure repeating.

   Last failure:
   <truncated error output>

   Failure history:
   - Iteration 1: <one-line summary>
   - Iteration 2: <one-line summary>
   ...

   Suggested next steps:
   - <actionable suggestions based on the failure pattern>
   ```

3. **If not stuck, diagnose.** Read the error output, understand the root cause, and fix the code, config, or environment. Use your normal code-editing capabilities. The full history of previous attempts is in your context, so don't repeat fixes that already failed.

4. **Continue the loop.** Go back to step (a).

### 3. On stuck

When stuck detection fires:

1. Summarise the full failure history (all iterations, one line each)
2. Identify the repeating failure pattern
3. Suggest concrete next steps the user can take
4. Stop the loop

## Key principles

- **Objective graders only.** The grader is never "does this look right to me?" It's always a binary external check. This prevents the agent from convincing itself a broken fix is fine.
- **Full history in context.** Every iteration's output stays in the conversation. This means diagnosis improves over time and you won't repeat the same failed fix.
- **No arbitrary limits.** Stuck detection is strictly better than max iterations: it stops when actually stuck, not when a counter expires. A fix that takes 7 iterations should keep going if each iteration makes progress.
- **General purpose.** Works for builds, tests, linters, deploys, CI pipelines, or any command with a binary pass/fail signal. No domain-specific logic in the core loop.

## Examples

```bash
# Build until it compiles
/outcome-loop "npm run build"

# Run tests, use a separate lint check as the grader
/outcome-loop "npm test" --grader command:"npm run lint"

# Fix a CI pipeline with codex review as the grader
/outcome-loop "gh workflow run deploy.yml" --grader codex --rubric "Check for deployment errors and rollback issues"

# Build with type checking as the grader
/outcome-loop "npm run build" --grader command:"npx tsc --noEmit"
```
