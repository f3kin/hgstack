#!/usr/bin/env bash
# PostToolUse hook: auto-replace em dashes (U+2014) with a regular hyphen-dash
# Reads tool input JSON from stdin, replaces in-place if found.

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty')

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

EM_DASH=$(printf '\xe2\x80\x94')

if grep -q "$EM_DASH" "$FILE_PATH" 2>/dev/null; then
  python3 -c "
import sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
content = content.replace('\u2014', ' - ')
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$FILE_PATH"
fi

exit 0
