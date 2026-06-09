#!/bin/bash
# hg-stack installer.
# Symlinks skills, hooks, and rules from this repo into ~/.claude/.
# Idempotent and safe to re-run. Never destructive: existing files are backed up before overwriting.
#
# Usage:
#   ./install.sh                # symlink everything into ~/.claude/
#   ./install.sh --dry-run      # print what would happen, don't touch anything
#   ./install.sh --update       # same as default; just runs git pull first
#   ./install.sh skills         # only install skills (skip hooks, rules)
#   ./install.sh skills rules   # install named categories only
#
# After running, restart Claude Code to pick up the new skills.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
DRY_RUN=false
UPDATE=false
CATEGORIES=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --update)  UPDATE=true ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) CATEGORIES+=("$arg") ;;
  esac
done

if [ ${#CATEGORIES[@]} -eq 0 ]; then
  CATEGORIES=(skills hooks rules)
fi

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
dim() { printf '\033[90m%s\033[0m\n' "$1"; }

run() {
  if [ "$DRY_RUN" = true ]; then
    dim "would: $*"
  else
    "$@"
  fi
}

if [ "$UPDATE" = true ]; then
  green "Pulling latest from origin..."
  run git -C "$REPO_DIR" pull --rebase --autostash
fi

mkdir -p "$CLAUDE_DIR"

install_category() {
  local category="$1"
  local source_dir="$REPO_DIR/$category"
  local target_dir="$CLAUDE_DIR/$category"

  if [ ! -d "$source_dir" ]; then
    yellow "Skipping $category: no $source_dir in this repo."
    return
  fi

  mkdir -p "$target_dir"
  green ""
  green "Installing $category from $source_dir -> $target_dir"

  local count=0
  for item in "$source_dir"/*; do
    [ -e "$item" ] || continue
    local name
    name="$(basename "$item")"
    local link="$target_dir/$name"

    if [ -L "$link" ]; then
      local existing_target
      existing_target="$(readlink "$link")"
      if [ "$existing_target" = "$item" ]; then
        dim "  $name already linked"
        continue
      fi
      yellow "  $name: replacing existing symlink ($existing_target)"
      run rm "$link"
    elif [ -e "$link" ]; then
      local backup="$link.backup.$(date +%Y%m%d-%H%M%S)"
      yellow "  $name: existing file, backing up to $backup"
      run mv "$link" "$backup"
    fi

    run ln -s "$item" "$link"
    green "  + $name"
    count=$((count + 1))
  done

  green "  $count item(s) installed in $category."
}

for category in "${CATEGORIES[@]}"; do
  install_category "$category"
done

green ""
green "Done. Restart Claude Code to pick up new skills."
if [ "$DRY_RUN" = true ]; then
  yellow "(dry run: nothing was actually changed.)"
fi
