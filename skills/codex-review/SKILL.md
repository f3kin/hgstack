---
name: codex-review
description: >
  Cross-model code review using OpenAI Codex CLI or direct API fallback.
  Three modes (review for diff review, challenge for adversarial
  break-the-code, consult for ask-anything with session continuity).
  Catches blind spots that Claude shares with itself. Use before merging
  risky PRs, after large refactors, or whenever a second opinion from a
  different model family helps. Trigger phrases include "codex review",
  "second opinion", "cross-model review", "hostile review",
  "challenge this code", "have codex look at this".
argument-hint: "[--review | --challenge | --consult] [diff-spec]"
triggers:
  - codex review
  - second opinion
  - cross-model review
  - hostile review
  - challenge this code
---

# Cross-Model Review

Runs a cross-model code review using OpenAI's Codex CLI or the OpenAI API directly. Cross-family review surfaces issues that same-family review (Claude reviewing Claude's code) misses.

## Prerequisites

You need at least one of the following:

- **Codex CLI** installed and authenticated (`codex auth`). Install via `npm i -g @openai/codex` or the official installer.
- **OpenAI API key** available as `OPENAI_API_KEY` env var, or stored at `$HOME/.config/openai/api_key`.
- Optionally a **1Password CLI** (`op`) with a secret reference you configure via the env vars below.

## Config

| Env var | Purpose | Default |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI API key for the fallback path | unset |
| `CODEX_REVIEW_MODEL` | Override the model used by the API fallback | `gpt-5.5` (set in `codex-review.sh`) |
| `CODEX_REVIEW_OP_REF` | 1Password secret reference for the API key (e.g. `op://<vault>/<item>/<field>`) | unset |
| `CODEX_REVIEW_SCRIPT` | Absolute path to a `codex-review.sh` helper script if you keep one in your stack | unset |

## Modes

- `/codex-review` or `/codex-review --review` : standard diff review (default)
- `/codex-review --challenge` : adversarial mode, actively tries to break the code
- `/codex-review --consult <question>` : ask Codex anything with session continuity

## When to use

- Before merging a PR that touches >100 lines or >5 files.
- After any refactor of security-sensitive or public API modules.
- When debugging code Claude wrote that "should work" but doesn't.
- When the user asks for a "second opinion", "hostile review", or "cross-model review".

Do NOT use for:
- Trivial changes (typos, lint fixes, one-liners) where adversarial review is overkill.
- Changes already reviewed by an automated workflow on the PR (avoid duplicate cost).

## Pre-flight: Auth Resolution

Try multiple auth methods in order. The first one that works is used:

```bash
# 1. Codex CLI (preferred if installed and authenticated)
if command -v codex &>/dev/null; then
  codex exec --sandbox read-only --skip-git-repo-check "echo hello" < /dev/null > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    AUTH_METHOD="codex-cli"
  fi
fi

# 2. OpenAI API key (env var)
if [ -z "$AUTH_METHOD" ] && [ -n "$OPENAI_API_KEY" ]; then
  AUTH_METHOD="openai-api"
fi

# 3. OpenAI API key (file)
if [ -z "$AUTH_METHOD" ] && [ -f "$HOME/.config/openai/api_key" ]; then
  export OPENAI_API_KEY=$(cat "$HOME/.config/openai/api_key")
  AUTH_METHOD="openai-api"
fi

# 4. 1Password CLI fallback (pulls from a user-configured secret reference)
if [ -z "$AUTH_METHOD" ] && command -v op &>/dev/null && [ -n "${CODEX_REVIEW_OP_REF:-}" ]; then
  export OP_BIOMETRIC_UNLOCK_ENABLED=true
  OPENAI_API_KEY=$(op read "$CODEX_REVIEW_OP_REF" 2>/dev/null)
  if [ -n "$OPENAI_API_KEY" ]; then
    export OPENAI_API_KEY
    AUTH_METHOD="openai-api"
  fi
fi
```

If no auth method works, tell the user:
> "Cross-model review needs one of: `codex` CLI (authenticated), `OPENAI_API_KEY` env var, or `op` CLI with `CODEX_REVIEW_OP_REF` configured. Set one up and try again."
>
> Options: "Skip codex review" / "I'll set it up"

## Step 1: Capture the diff

Default scope is `HEAD vs origin/main`. Override if the user specifies.

```bash
mkdir -p .claude/reviews
DIFF_FILE=".claude/reviews/diff-$(date +%Y%m%d-%H%M%S).txt"

git fetch origin main --quiet 2>/dev/null || true
git diff origin/main...HEAD > "$DIFF_FILE" 2>/dev/null

# Fallback: staged changes
if [ ! -s "$DIFF_FILE" ]; then
  git diff --cached > "$DIFF_FILE"
fi

# Final fallback: working tree
if [ ! -s "$DIFF_FILE" ]; then
  git diff > "$DIFF_FILE"
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE")
echo "Diff: $DIFF_LINES lines -> $DIFF_FILE"
```

If the diff is empty, tell the user there's nothing to review and stop.

If the diff exceeds 100KB, warn the user and offer to scope down to specific files.

## Mode A: Review (default)

### Build prompt

Write the prompt to a temp file (never pass complex prompts as shell arguments):

```bash
PROMPT_FILE=$(mktemp /tmp/codex-review-XXXXXXXX.md)
cat > "$PROMPT_FILE" << 'PROMPT'
You are a hostile code reviewer. Your goal is to find every problem with this diff before it ships. Assume the author got things wrong, not right.

Check:
1. CORRECTNESS: Does the code do what it claims to?
2. EDGE CASES: What inputs, states, or conditions would break this?
3. ERROR HANDLING: Are failures caught at the right boundary, or swallowed?
4. SECURITY: Validation, injection, auth bypass, data exposure, secrets leakage
5. PERFORMANCE: Complexity, allocations, N+1 queries, large unbounded loops
6. TESTABILITY: Is the new code structured so it can be tested?
7. API DESIGN: Will consumers find this intuitive? Will it be awkward to extend?
8. NAMING & CLARITY: Will a reader understand this in 6 months?

For EACH finding output:
- SEVERITY: BLOCKING | SIGNIFICANT | MINOR
- FILE: path/to/file.ext
- LOCATION: function/class/line
- ISSUE: what's wrong (one sentence)
- FIX: concrete suggestion

If you find no issues at any level, say so explicitly. Do not invent issues to look thorough.

Output only the findings list, in markdown. No preamble.
PROMPT
```

### Execute

**Codex CLI path:**
```bash
REVIEW_FILE=".claude/reviews/codex-review-$(date +%Y%m%d-%H%M%S).md"
LOG_FILE=".claude/reviews/codex-$(date +%Y%m%d-%H%M%S).log"

FULL_PROMPT="$(cat "$PROMPT_FILE")

DIFF:
$(cat "$DIFF_FILE")"

# Launch codex. Notes (codex 0.130, macOS):
#  - NO `-a never`: removed in codex >=0.30. `codex exec` is non-interactive
#    and `--sandbox read-only` already prevents approval deadlocks.
#  - `< /dev/null`: codex 0.130 blocks "Reading additional input from stdin"
#    when stdin is not a TTY (it is not, under an agent/CI shell).
#  - NO `timeout` wrapper: not present on macOS by default. The watchdog
#    loop below enforces both the hard 10-min cap and 90s stall detection.
codex exec --sandbox read-only --skip-git-repo-check "$FULL_PROMPT" \
  > "$REVIEW_FILE" 2> "$LOG_FILE" < /dev/null &
CODEX_PID=$!

LAST_SIZE=0
STALL_COUNT=0
ELAPSED=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  sleep 15
  ELAPSED=$((ELAPSED + 15))
  CURRENT_SIZE=$(wc -c < "$REVIEW_FILE" 2>/dev/null || echo 0)
  if [ "$CURRENT_SIZE" -eq "$LAST_SIZE" ]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    if [ "$STALL_COUNT" -ge 6 ]; then
      echo "STALL DETECTED after 90s with no output. Killing codex." >&2
      kill "$CODEX_PID" 2>/dev/null
      echo "STALLED" >> "$LOG_FILE"
      break
    fi
  else
    STALL_COUNT=0
    LAST_SIZE=$CURRENT_SIZE
  fi
  if [ "$ELAPSED" -ge 600 ]; then
    echo "HARD TIMEOUT after 600s. Killing codex." >&2
    kill "$CODEX_PID" 2>/dev/null
    echo "TIMEOUT" >> "$LOG_FILE"
    break
  fi
done
wait "$CODEX_PID" 2>/dev/null
```

**OpenAI API fallback path:**

If using `openai-api` auth method, call a `codex-review.sh` helper script (if you maintain one in your stack):

```bash
REVIEW_FILE=".claude/reviews/codex-review-$(date +%Y%m%d-%H%M%S).md"

# Build combined prompt file
COMBINED_PROMPT=$(mktemp /tmp/codex-combined-XXXXXXXX.md)
cat "$PROMPT_FILE" > "$COMBINED_PROMPT"
printf '\n\nDIFF:\n' >> "$COMBINED_PROMPT"
cat "$DIFF_FILE" >> "$COMBINED_PROMPT"

# Locate the helper script (configurable via CODEX_REVIEW_SCRIPT env var)
SCRIPT_PATH="${CODEX_REVIEW_SCRIPT:-}"
if [ -z "$SCRIPT_PATH" ] || [ ! -x "$SCRIPT_PATH" ]; then
  SCRIPT_PATH="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]:-$0}")")")/scripts/codex-review.sh"
fi

if [ -x "$SCRIPT_PATH" ]; then
  "$SCRIPT_PATH" -f "$COMBINED_PROMPT" > "$REVIEW_FILE" 2>/dev/null
else
  # Inline minimal fallback: direct curl to OpenAI Chat Completions
  MODEL="${CODEX_REVIEW_MODEL:-gpt-4o}"
  PROMPT_CONTENT=$(cat "$COMBINED_PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  curl -sS https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":$PROMPT_CONTENT}]}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' \
    > "$REVIEW_FILE"
fi

rm -f "$COMBINED_PROMPT"
```

If the review file is empty after either path, report the failure with the log file contents.

## Mode B: Challenge

Same diff capture as Review, but with a different prompt focused on active exploitation:

```
You are a security researcher and adversarial tester. Your goal is to break this code.

For each potential vulnerability or exploit:
1. Describe the attack vector (how an attacker would exploit this)
2. Rate exploitability: TRIVIAL | MODERATE | DIFFICULT
3. Rate impact: CRITICAL | HIGH | MEDIUM | LOW
4. Provide a concrete proof-of-concept or attack scenario
5. Suggest a fix

Focus on:
- Input validation bypasses
- Authentication and authorisation flaws
- Race conditions and state corruption
- Data leakage paths
- Injection vectors (SQL, command, template, prompt)
- Business logic abuse

Do not list theoretical risks without concrete attack paths. If the code is solid, say so.
```

Challenge mode uses the same execution and stall detection logic as Review.

## Mode C: Consult

Ask Codex a specific question with optional session continuity.

```bash
SESSION_FILE=".claude/reviews/codex-session-id"
SESSION_FLAG=""
if [ -f "$SESSION_FILE" ]; then
  SESSION_FLAG="--session $(cat "$SESSION_FILE")"
fi
```

**Codex CLI path:**
```bash
codex exec --sandbox read-only --skip-git-repo-check $SESSION_FLAG "$QUESTION" \
  > "$REVIEW_FILE" 2> "$LOG_FILE" < /dev/null
```

**API fallback path:** same curl approach as Review but with the user's question as the prompt. No session continuity in API fallback mode.

Save session ID for continuity:
```bash
# If codex outputs a session ID, capture it
grep -oP 'session_id\K.*' "$LOG_FILE" > "$SESSION_FILE" 2>/dev/null || true
```

## Step 4: Triage and Present

Present Codex output verbatim in a bordered block. The value is Codex's actual reasoning, not a Claude paraphrase.

Count findings by severity and present a structured summary:

```
Codex review: <repo>@<branch>
Mode: <review | challenge | consult>

  BLOCKING:    <N>
  SIGNIFICANT: <N>
  MINOR:       <N>

[Show each BLOCKING and SIGNIFICANT finding with FILE:LOCATION + ISSUE + FIX.
Summarise MINOR findings (count + brief categorisation).]

Lead Judgment:
- Accept: <findings to act on, with rationale>
- Dismiss: <false positives, with rationale>
- Defer: <real but not for this PR>
```

## Step 5: Cross-Model Comparison

If your own code-review skill (if you have one) was run earlier in this session, produce a cross-model analysis:

```
CROSS-MODEL ANALYSIS
====================
Claude found exclusively:  <findings only Claude flagged>
Codex found exclusively:   <findings only Codex flagged>
Both agree on:             <shared findings>
Agreement rate:            <N>%

Recommendation: <action> because <specific finding with comparative reasoning>
```

The recommendation must be specific. "Because it's safer" is not a valid reason. Reference the specific finding and why the comparative view changes the assessment.

## Step 6: Offer Follow-up

| Verdict | Suggestion |
|---------|------------|
| BLOCK (any BLOCKING accepted) | "Want me to fix these before pushing?" |
| CONCERNS (no blocking, 2+ significant) | "Want me to address these, or push as-is?" |
| CLEAN | "Looks good. Ready to ship?" |

## Integration with a ship skill

If you have a `/ship` (or equivalent) skill, invoke this as an optional step for PRs above a size threshold (>100 lines or >5 files). The user is asked before it runs.

## Rules

1. **Cross-family only.** This skill exists because Claude can't reliably review Claude's code.
2. **Stall detection is mandatory.** Never run codex without polling for output.
3. **Read-only sandbox + no write directives.** The prompt must never instruct codex to write files.
4. **Present output verbatim.** Don't paraphrase Codex's findings. Show them as-is, then render your Lead Judgment.
5. **Saved reviews live in `.claude/reviews/`.** That directory should be gitignored.
6. **Don't run on trivial diffs.** Skip if diff is <50 lines unless user explicitly asked.
7. **API fallback is real.** If codex CLI isn't authenticated, fall back to the OpenAI API with `OPENAI_API_KEY`. The skill should work for anyone who has either.

## Gotchas

- **Codex 0.25+ uses `codex exec`**, not bare `codex`.
- **`--skip-git-repo-check`** prevents codex refusing in worktrees. Use it on the auth probe too, not just the real run.
- **No `-a never`**: removed in codex >=0.30 (0.130 errors on it). `codex exec` is non-interactive; `--sandbox read-only` alone prevents approval deadlocks.
- **Always `< /dev/null`**: codex 0.130 blocks on "Reading additional input from stdin" when stdin is not a TTY (agent/CI shells). Redirect stdin from /dev/null on every `codex exec`.
- **No `timeout` on macOS**: the GNU `timeout` binary is not installed by default. Don't wrap codex in `timeout`; rely on the watchdog loop's elapsed counter for the hard cap.
- **Prompt size**: codex handles ~100k tokens. Scope down large diffs.
- **API fallback model**: defaults to `gpt-4o` in the inline path, or whatever your `codex-review.sh` helper uses. Override with `CODEX_REVIEW_MODEL`.
- **First run** may require `codex auth` interactively. The API fallback avoids this entirely.
