#!/bin/bash
# hg-stack installer.
# Symlinks skills, hooks, rules, and statuslines from this repo into ~/.claude/.
# Conflict-aware: never overwrites a real file that differs from ours without
# your explicit confirmation. Safe to re-run.
#
# Modes:
#   ./install.sh                     # additive install (skip conflicts, log them)
#   ./install.sh --dry-run           # show classifications, change nothing
#   ./install.sh --reconcile         # diagnostic only: scan ~/.claude/ + report
#   ./install.sh --interactive       # prompt per conflict (keep / replace / diff)
#   ./install.sh --force             # override conflicts (CI / scripted use)
#   ./install.sh --update            # git pull --rebase, then install
#   ./install.sh --rollback          # restore from most recent backup directory
#   ./install.sh skills              # only install named categories
#   ./install.sh skills rules        # multiple categories
#
# After install, restart Claude Code to pick up new skills.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BACKUP_ROOT="$CLAUDE_DIR/backups"
BACKUP_DIR=""

DRY_RUN=false
RECONCILE=false
INTERACTIVE=false
FORCE=false
UPDATE=false
ROLLBACK=false
SKIP_ALL_CONFLICTS=false
CATEGORIES=()

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --reconcile)   RECONCILE=true ;;
    --interactive) INTERACTIVE=true ;;
    --force)       FORCE=true ;;
    --update)      UPDATE=true ;;
    --rollback)    ROLLBACK=true ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) CATEGORIES+=("$arg") ;;
  esac
done

if [ ${#CATEGORIES[@]} -eq 0 ]; then
  CATEGORIES=(skills hooks rules statuslines)
fi

red()    { printf '\033[31m%s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
blue()   { printf '\033[34m%s\033[0m\n' "$1"; }
dim()    { printf '\033[90m%s\033[0m\n' "$1"; }
bold()   { printf '\033[1m%s\033[0m\n' "$1"; }

COUNT_NEW=0
COUNT_CURRENT=0
COUNT_UPDATE=0
COUNT_CONFLICT=0
COUNT_SKIPPED=0
CONFLICT_LOG=()

# Classify a (source, target) pair.
# States:
#   new      - target doesn't exist; safe to symlink
#   current  - target already symlinks to our source; no-op
#   update   - target is a stale symlink OR a real file byte-identical to ours; safe to replace
#   conflict - target is a real file with different content; LEAVE ALONE by default
classify() {
  local src="$1"
  local tgt="$2"
  if [ ! -e "$tgt" ] && [ ! -L "$tgt" ]; then
    echo "new"
    return
  fi
  if [ -L "$tgt" ]; then
    local link_target
    link_target="$(readlink "$tgt")"
    if [ "$link_target" = "$src" ]; then
      echo "current"
    else
      echo "update"
    fi
    return
  fi
  if diff -q "$src" "$tgt" >/dev/null 2>&1; then
    echo "update"
    return
  fi
  echo "conflict"
}

ensure_backup_dir() {
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$BACKUP_ROOT/hg-stack-$(date +%Y%m%d-%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
      mkdir -p "$BACKUP_DIR"
    fi
  fi
}

backup_target() {
  local tgt="$1"
  ensure_backup_dir
  local rel_path="${tgt#$CLAUDE_DIR/}"
  local backup_path="$BACKUP_DIR/$rel_path"
  if [ "$DRY_RUN" = true ]; then
    dim "    would back up $tgt -> $backup_path"
    return
  fi
  mkdir -p "$(dirname "$backup_path")"
  if [ -L "$tgt" ]; then
    printf 'symlink -> %s\n' "$(readlink "$tgt")" > "$backup_path.info"
  elif [ -f "$tgt" ]; then
    cp "$tgt" "$backup_path"
  elif [ -d "$tgt" ]; then
    cp -R "$tgt" "$backup_path"
  fi
}

prompt_conflict() {
  local rel="$1"
  local src="$2"
  local tgt="$3"
  if [ "$SKIP_ALL_CONFLICTS" = true ]; then
    echo "skip"
    return
  fi
  while true; do
    yellow "    conflict: $rel already exists with different content"
    echo "      [k]eep yours (skip)   [r]eplace (back up + symlink ours)   [d]iff   [s]kip all remaining   [q]uit"
    local choice
    read -rp "    choice: " choice
    case "$choice" in
      k|K|"") echo "skip"; return ;;
      r|R)    echo "replace"; return ;;
      d|D)    diff -u "$tgt" "$src" || true ;;
      s|S)    SKIP_ALL_CONFLICTS=true; echo "skip"; return ;;
      q|Q)    red "Aborted by user."; exit 1 ;;
      *)      echo "      (unrecognised)" ;;
    esac
  done
}

# Act on one (src, tgt) according to its classification.
apply() {
  local src="$1"
  local tgt="$2"
  local rel="${tgt#$CLAUDE_DIR/}"
  local class
  class="$(classify "$src" "$tgt")"

  case "$class" in
    new)
      COUNT_NEW=$((COUNT_NEW + 1))
      if [ "$DRY_RUN" = true ]; then
        dim "  new      $rel"
        dim "    would: ln -s $src $tgt"
      else
        mkdir -p "$(dirname "$tgt")"
        ln -s "$src" "$tgt"
        green "  new      $rel"
      fi
      ;;
    current)
      COUNT_CURRENT=$((COUNT_CURRENT + 1))
      dim "  current  $rel"
      ;;
    update)
      COUNT_UPDATE=$((COUNT_UPDATE + 1))
      if [ "$DRY_RUN" = true ]; then
        dim "  update   $rel"
        dim "    would back up + symlink"
      else
        backup_target "$tgt"
        rm -rf "$tgt"
        ln -s "$src" "$tgt"
        blue "  update   $rel"
      fi
      ;;
    conflict)
      COUNT_CONFLICT=$((COUNT_CONFLICT + 1))
      CONFLICT_LOG+=("$rel")
      local action="skip"
      if [ "$FORCE" = true ]; then
        action="replace"
      elif [ "$INTERACTIVE" = true ]; then
        action="$(prompt_conflict "$rel" "$src" "$tgt")"
      fi
      if [ "$action" = "replace" ]; then
        if [ "$DRY_RUN" = true ]; then
          yellow "  conflict $rel (would replace)"
        else
          backup_target "$tgt"
          rm -rf "$tgt"
          ln -s "$src" "$tgt"
          blue "  replaced $rel"
        fi
      else
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        yellow "  conflict $rel (kept yours)"
      fi
      ;;
  esac
}

# --- Rollback mode (exits early) ---

if [ "$ROLLBACK" = true ]; then
  if [ ! -d "$BACKUP_ROOT" ]; then
    red "No backups found at $BACKUP_ROOT."
    exit 1
  fi
  LATEST_BACKUP="$(ls -1dt "$BACKUP_ROOT"/hg-stack-* 2>/dev/null | head -1 || true)"
  if [ -z "$LATEST_BACKUP" ]; then
    red "No hg-stack backups found in $BACKUP_ROOT."
    exit 1
  fi
  bold "Rolling back from: $LATEST_BACKUP"
  if [ "$DRY_RUN" = true ]; then
    find "$LATEST_BACKUP" \( -type f -o -type l \) | while read -r f; do
      rel="${f#$LATEST_BACKUP/}"
      dim "  would restore $rel"
    done
    exit 0
  fi
  yellow "This will remove our symlinks and restore the files/symlinks present before the most recent install."
  read -rp "Proceed? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    red "Aborted."
    exit 1
  fi
  find "$LATEST_BACKUP" \( -type f -o -type l \) | while read -r f; do
    rel="${f#$LATEST_BACKUP/}"
    tgt="$CLAUDE_DIR/${rel%.info}"
    if [[ "$rel" == *.info ]]; then
      orig="$(sed -n 's/^symlink -> //p' "$f")"
      rm -f "$tgt"
      ln -s "$orig" "$tgt"
      green "  restored symlink: $tgt -> $orig"
    else
      mkdir -p "$(dirname "$tgt")"
      rm -rf "$tgt"
      cp "$f" "$tgt"
      green "  restored file: $tgt"
    fi
  done
  green ""
  green "Rollback complete. Restart Claude Code."
  exit 0
fi

# --- Update mode (pulls latest, then continues) ---

if [ "$UPDATE" = true ]; then
  green "Pulling latest from origin..."
  if [ "$DRY_RUN" = true ]; then
    dim "  would: git -C $REPO_DIR pull --rebase --autostash"
  else
    git -C "$REPO_DIR" pull --rebase --autostash
  fi
fi

# --- Install / reconcile ---

if [ "$RECONCILE" = true ]; then
  bold "Reconcile mode: scanning $CLAUDE_DIR/ against repo (no changes will be made)."
else
  bold "Installing $(IFS=','; echo "${CATEGORIES[*]}") from $REPO_DIR into $CLAUDE_DIR/"
  if [ "$DRY_RUN" = true ]; then
    yellow "(dry run: no files will change)"
  fi
fi

mkdir -p "$CLAUDE_DIR"

install_category() {
  local category="$1"
  local source_dir="$REPO_DIR/$category"
  local target_dir="$CLAUDE_DIR/$category"

  if [ ! -d "$source_dir" ]; then
    dim "  $category: no source directory in this repo, skipping"
    return
  fi

  green ""
  bold "$category"
  [ "$DRY_RUN" = false ] && mkdir -p "$target_dir"

  for item in "$source_dir"/*; do
    [ -e "$item" ] || continue
    local name
    name="$(basename "$item")"
    local link="$target_dir/$name"
    apply "$item" "$link"
  done

  if [ "$RECONCILE" = true ] && [ -d "$target_dir" ]; then
    local personal=()
    for item in "$target_dir"/*; do
      [ -e "$item" ] || continue
      local name
      name="$(basename "$item")"
      if [ ! -e "$source_dir/$name" ]; then
        personal+=("$name")
      fi
    done
    if [ ${#personal[@]} -gt 0 ]; then
      dim ""
      dim "  personal $category (not touched):"
      for p in "${personal[@]}"; do
        dim "    - $p"
      done
    fi
  fi
}

for category in "${CATEGORIES[@]}"; do
  install_category "$category"
done

# --- Summary ---

green ""
bold "Summary"
green "  new:      $COUNT_NEW"
dim   "  current:  $COUNT_CURRENT"
blue  "  update:   $COUNT_UPDATE"
if [ "$COUNT_CONFLICT" -gt 0 ]; then
  yellow "  conflict: $COUNT_CONFLICT ($COUNT_SKIPPED kept yours)"
fi

if [ -n "$BACKUP_DIR" ] && [ "$DRY_RUN" = false ]; then
  green ""
  green "Backups: $BACKUP_DIR"
  dim "  (run ./install.sh --rollback to revert this install)"
fi

if [ ${#CONFLICT_LOG[@]} -gt 0 ] && [ "$FORCE" = false ] && [ "$INTERACTIVE" = false ]; then
  yellow ""
  yellow "Conflicts left in place (your files weren't touched):"
  for c in "${CONFLICT_LOG[@]}"; do
    yellow "  - $c"
  done
  dim ""
  dim "  To resolve: re-run with --interactive to choose per-file, or"
  dim "  --force to back up yours and use ours."
fi

if [ "$DRY_RUN" = true ]; then
  yellow ""
  yellow "Dry run complete. Re-run without --dry-run to apply."
elif [ "$RECONCILE" = false ]; then
  green ""
  green "Done. Restart Claude Code to pick up new skills."
fi
