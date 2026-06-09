#!/bin/bash
# check-generalisable.sh - audit repo for hardcoded personal references
# Run before every merge. Exit 1 if issues found.
#
# Checks for:
#   - Hardcoded usernames in paths (e.g. /Users/USERNAME, -Users-USERNAME-style project paths)
#   - Personal email addresses
#   - User-specific path assumptions
#
# Acceptable (not flagged):
#   - Generic ~ or $HOME references
#   - Documentation mentioning placeholder names in templates

set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ISSUES=0

red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }
dim()    { printf '\033[90m%s\033[0m\n' "$1"; }

echo ""
echo "Generalisation audit: $REPO_DIR"
echo ""

# Pattern definitions
# Each pattern: regex|description|exclude_glob (optional)
PATTERNS=(
  '/Users/[a-z][a-z0-9_-]*|Hardcoded macOS user path|'
  '-Users-[a-z][a-z0-9_]*-[^-]|Hardcoded Claude project path (username-specific)|check-generalisable'
  '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|Email address|'
)

# Scan all tracked/staged files (skip .git, binary files, this script's own patterns doc)
FILES=$(find "$REPO_DIR" -type f \
  -not -path '*/.git/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/__pycache__/*' \
  -not -name '*.pyc' \
  -not -name '.DS_Store' \
  | sort)

for pattern_spec in "${PATTERNS[@]}"; do
  IFS='|' read -r pattern desc exclude <<< "$pattern_spec"

  while IFS= read -r file; do
    rel="${file#$REPO_DIR/}"

    # Skip excluded files
    if [[ -n "$exclude" && "$rel" == *"$exclude"* ]]; then
      continue
    fi

    # Allow: team profiles are intentionally per-person (emails, names, paths)
    if [[ "$rel" == team/profiles/* || "$rel" == team/reconciliation/* ]]; then
      continue
    fi

    # Search for matches
    matches=$(grep -n -E "$pattern" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      # Filter out acceptable patterns
      filtered=""
      while IFS= read -r match; do
        line="$match"

        # Allow: regex patterns that match usernames generically (e.g. [a-z], [^-]+)
        if echo "$line" | grep -qE '\[a-z\]|\[\^-\]|\[a-z0-9\]'; then
          continue
        fi

        # Allow: this script's own pattern definitions
        if echo "$line" | grep -qE "^[0-9]+:.*PATTERNS|^[0-9]+:.*pattern_spec|^[0-9]+:.*# "; then
          continue
        fi

        # Allow: comments explaining what the check does
        if echo "$line" | grep -qE "^[0-9]+:\s*#"; then
          continue
        fi

        # Allow: git SSH URLs (git@<host> is not a personal email)
        if echo "$line" | grep -qE 'git@(github|gitlab|bitbucket)\.com'; then
          continue
        fi

        # Allow: placeholder/example emails (you@, billing@client, noreply@)
        if echo "$line" | grep -qE 'you@|billing@client|noreply@'; then
          continue
        fi

        # Allow: emails in .example config files (they're templates, not real addresses)
        if [[ "$rel" == *.example ]]; then
          continue
        fi

        # Allow: example/illustrative paths in documentation (e.g. "-Users-michaelbatko-batko-ai")
        if echo "$line" | grep -qE 'e\.g\.|for example|Example'; then
          continue
        fi

        filtered="$filtered$line"$'\n'
      done <<< "$matches"

      if [[ -n "${filtered%$'\n'}" ]]; then
        red "FAIL: $desc"
        echo "  File: $rel"
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          echo "    $line"
        done <<< "$filtered"
        echo ""
        ISSUES=$((ISSUES + 1))
      fi
    fi
  done <<< "$FILES"
done

# Summary
echo "---"
if [[ $ISSUES -eq 0 ]]; then
  green "PASS: No hardcoded personal references found."
else
  red "FAIL: $ISSUES issue(s) found. Fix before merging."
fi
echo ""

exit $ISSUES
