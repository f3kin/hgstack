#!/bin/bash
# check-shareable.sh - scan a file or directory for anything unsafe to share publicly.
#
# Run this before open-sourcing a skill, posting a gist, or publishing any config.
# It is the "is this safe to make public?" gate.
#
# Severity:
#   HIGH   - secrets / keys / tokens. NEVER share. Exit 1 if any found.
#   MEDIUM - private infra + PII (IPs, internal URLs, personal paths, emails,
#            1Password refs). Sanitise before sharing. Exit 1 only with --strict.
#
# Usage:
#   check-shareable.sh [--strict] [path]      (path defaults to current dir)
#
# Complements check-generalisable.sh (which audits for hardcoded *personal*
# references). This one is specifically about secrets and dangerous-to-publish data.

set -uo pipefail   # intentionally NOT -e: grep exits 1 on no-match, which is normal here

# --- args ---
STRICT=0
TARGET="."
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) TARGET="$arg" ;;
  esac
done

red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }
dim()    { printf '\033[90m%s\033[0m\n' "$1"; }

HIGH=0
MED=0

# pattern|description  (extended regex)
HIGH_PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}|Anthropic API key'
  'sk-[A-Za-z0-9]{20,}|OpenAI API key'
  'gh[pousr]_[A-Za-z0-9]{30,}|GitHub token'
  'AKIA[0-9A-Z]{16}|AWS access key id'
  'xox[baprs]-[A-Za-z0-9-]{10,}|Slack token'
  'AIza[0-9A-Za-z_-]{35}|Google API key'
  'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|JWT / signed token'
  'BEGIN [A-Z ]*PRIVATE KEY|Private key block'
  '(password|passwd|secret|api[_-]?key|access[_-]?token|client[_-]?secret)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9/+._-]{12,}|Hardcoded secret assignment'
)

MED_PATTERNS=(
  '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|IP address (check it is not private infra)'
  '[a-z0-9.-]+\.supabase\.co|Supabase project URL'
  'admin\.thehourglass\.ai|Internal admin URL'
  '\b[a-z0-9.-]+\.internal\b|Internal hostname'
  '/Users/[a-z][a-z0-9_-]*|Personal macOS path'
  '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|Email address'
  'op://[A-Za-z0-9 _./-]+|1Password secret reference'
)

# Obvious placeholders / examples that should NOT trip the scanner.
BENIGN='(xxx|example|placeholder|your[_-]|<[^>]+>|\bredacted\b|\bdummy\b|FAKE|sample)'

scan_target() {
  if [[ -f "$TARGET" ]]; then
    printf '%s\n' "$TARGET"
  else
    find "$TARGET" -type f \
      -not -path '*/.git/*' \
      -not -path '*/node_modules/*' \
      -not -path '*/__pycache__/*' \
      -not -path '*/.venv/*' \
      -not -name '*.pyc' \
      -not -name '*.png' -not -name '*.jpg' -not -name '*.jpeg' \
      -not -name '*.gif' -not -name '*.pdf' -not -name '*.lock' \
      -not -name '.DS_Store' \
      | sort
  fi
}

mask() {
  # show first 6 chars of a matched secret, redact the rest
  local s="$1"
  if [[ ${#s} -gt 10 ]]; then
    printf '%s…[redacted]' "${s:0:6}"
  else
    printf '[redacted]'
  fi
}

echo ""
echo "Shareability scan: $TARGET"
echo ""

run_patterns() {
  local level="$1"; shift
  local spec pattern desc file lineno match hit
  for spec in "$@"; do
    IFS='|' read -r pattern desc <<< "$spec"
    while IFS= read -r file; do
      # grep -I skips binary; -n line numbers; -E extended regex
      while IFS=: read -r lineno match; do
        [[ -z "$lineno" ]] && continue
        # skip obvious placeholders
        if printf '%s' "$match" | grep -qiE "$BENIGN"; then
          continue
        fi
        local hit
        hit=$(printf '%s' "$match" | grep -oE "$pattern" | head -1)
        if [[ "$level" == "HIGH" ]]; then
          red   "  HIGH  [$desc] ${file}:${lineno}"
          dim   "        $(mask "$hit")"
          HIGH=$((HIGH+1))
        else
          yellow "  MED   [$desc] ${file}:${lineno}"
          dim    "        ${hit}"
          MED=$((MED+1))
        fi
      done < <(grep -InE "$pattern" "$file" 2>/dev/null)
    done < <(scan_target)
  done
}

run_patterns HIGH "${HIGH_PATTERNS[@]}"
run_patterns MED  "${MED_PATTERNS[@]}"

echo ""
echo "----------------------------------------"
if [[ $HIGH -gt 0 ]]; then
  red "FAIL: $HIGH high-severity finding(s) (secrets/keys). Do NOT share until resolved."
fi
if [[ $MED -gt 0 ]]; then
  yellow "$MED medium-severity finding(s) (private infra / PII). Sanitise before sharing."
fi
if [[ $HIGH -eq 0 && $MED -eq 0 ]]; then
  green "Clean: nothing obviously unsafe to share. (Still eyeball it: no scanner is perfect.)"
fi
echo ""

if [[ $HIGH -gt 0 ]]; then exit 1; fi
if [[ $STRICT -eq 1 && $MED -gt 0 ]]; then exit 1; fi
exit 0
