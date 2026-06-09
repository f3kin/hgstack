#!/usr/bin/env python3
"""Claude Code status line: shows Pro subscription usage alongside context window info.

Reads Claude Code session JSON from stdin, fetches usage data from claude.ai API
(with Chrome cookie auto-extraction on macOS), and outputs a colored status line.

Requirements:
  - macOS (for Chrome cookie extraction via Keychain)
  - Google Chrome with an active claude.ai session
  - Python 3.8+
  - openssl CLI (ships with macOS)

No pip dependencies required - uses only Python stdlib and macOS system tools.

Cache: ~/.cache/claude-usage/cache.json
"""

import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

# =============================================================================
# Constants
# =============================================================================

HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(HOME, ".cache", "claude-usage")
CACHE_FILE = os.path.join(CACHE_DIR, "cache.json")
LOCK_FILE = os.path.join(CACHE_DIR, "cache.lock")

COOKIE_TTL = 1800  # 30 minutes
USAGE_TTL = 60  # 60 seconds
LOCK_STALE_SECONDS = 30
SUBPROCESS_TIMEOUT = 5

BROWSERS = [
    {
        "name": "Arc",
        "base": os.path.join(HOME, "Library", "Application Support", "Arc", "User Data"),
        "keychain_service": "Arc Safe Storage",
        "keychain_account": "Arc",
        "profiles": ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4", "Profile 5"],
    },
    {
        "name": "Chrome",
        "base": os.path.join(HOME, "Library", "Application Support", "Google", "Chrome"),
        "keychain_service": "Chrome Safe Storage",
        "keychain_account": "Chrome",
        "profiles": ["Default", "Profile 1", "Profile 2", "Profile 3"],
    },
]

API_BASE_TEMPLATE = "https://{domain}/api/organizations"

# =============================================================================
# Color Themes
# =============================================================================

RESET = "\033[0m"

# Catppuccin Mocha (default)
THEMES = {
    "catppuccin-mocha": {
        "green": "\033[38;2;166;227;161m",   # #a6e3a1
        "yellow": "\033[38;2;249;226;175m",  # #f9e2af
        "peach": "\033[38;2;250;179;135m",   # #fab387
        "red": "\033[38;2;243;139;168m",     # #f38ba8
        "accent": "\033[38;2;180;190;254m",  # #b4befe (lavender)
        "label": "\033[38;2;166;173;200m",   # #a6adc8 (subtext0)
        "dim": "\033[38;2;127;132;156m",     # #7f849c (overlay1)
    },
    "catppuccin-latte": {
        "green": "\033[38;2;64;160;43m",     # #40a02b
        "yellow": "\033[38;2;223;142;29m",   # #df8e1d
        "peach": "\033[38;2;254;100;11m",    # #fe640b
        "red": "\033[38;2;210;15;57m",       # #d20f39
        "accent": "\033[38;2;114;135;253m",  # #7287fd (lavender)
        "label": "\033[38;2;108;111;133m",   # #6c6f85 (subtext0)
        "dim": "\033[38;2;140;143;161m",     # #8c8fa1 (overlay1)
    },
    "tokyo-night": {
        "green": "\033[38;2;158;206;106m",   # #9ece6a
        "yellow": "\033[38;2;224;175;104m",  # #e0af68
        "peach": "\033[38;2;255;158;100m",   # #ff9e64
        "red": "\033[38;2;247;118;142m",     # #f7768e
        "accent": "\033[38;2;122;162;247m",  # #7aa2f7 (blue)
        "label": "\033[38;2;86;95;137m",     # #565f89 (comment)
        "dim": "\033[38;2;68;75;106m",       # #444b6a
    },
    "gruvbox": {
        "green": "\033[38;2;184;187;38m",    # #b8bb26
        "yellow": "\033[38;2;250;189;47m",   # #fabd2f
        "peach": "\033[38;2;254;128;25m",    # #fe8019
        "red": "\033[38;2;251;73;52m",       # #fb4934
        "accent": "\033[38;2;131;165;152m",  # #83a598 (blue)
        "label": "\033[38;2;168;153;132m",   # #a89984 (fg4)
        "dim": "\033[38;2;124;111;100m",     # #7c6f64 (bg4)
    },
    "plain": {
        "green": "\033[32m",
        "yellow": "\033[33m",
        "peach": "\033[33m",
        "red": "\033[31m",
        "accent": "\033[34m",
        "label": "\033[37m",
        "dim": "\033[90m",
    },
}

# Theme selection: set CLAUDE_USAGE_THEME env var, or defaults to catppuccin-mocha
THEME_NAME = os.environ.get("CLAUDE_USAGE_THEME", "catppuccin-mocha")
THEME = THEMES.get(THEME_NAME, THEMES["catppuccin-mocha"])

BAR_WIDTH = 10
TRANSCRIPT_TAIL_BYTES = 256 * 1024
ACTIVITY_RECENCY_SECONDS = 60
BAR_FILLED = "\u2588"  # █
BAR_EMPTY = "\u2591"   # ░


# =============================================================================
# Stdin parsing
# =============================================================================

def parse_stdin():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return {}
    return data


# =============================================================================
# Cache
# =============================================================================

def load_cache():
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_cache(cache):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp_path = CACHE_FILE + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            json.dump(cache, f)
        os.rename(tmp_path, CACHE_FILE)
    except OSError:
        pass


def is_stale(entry, ttl_key="expires_at"):
    if not entry or ttl_key not in entry:
        return True
    return time.time() > entry[ttl_key]


def acquire_lock():
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if os.path.exists(LOCK_FILE):
            lock_age = time.time() - os.path.getmtime(LOCK_FILE)
            if lock_age < LOCK_STALE_SECONDS:
                return False
            os.unlink(LOCK_FILE)
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        return True
    except OSError:
        return False


def release_lock():
    try:
        os.unlink(LOCK_FILE)
    except OSError:
        pass


# =============================================================================
# Chrome cookie extraction (macOS)
# =============================================================================

def get_browser_encryption_key(service, account):
    result = subprocess.run(
        ["security", "find-generic-password", "-w", "-s", service, "-a", account],
        capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    password = result.stdout.strip()
    return hashlib.pbkdf2_hmac("sha1", password.encode("utf-8"), b"saltysalt", 1003, dklen=16)


def decrypt_cookie(encrypted_value, key, db_version):
    if not encrypted_value or len(encrypted_value) < 4:
        return ""
    prefix = encrypted_value[:3]
    if prefix not in (b"v10", b"v11"):
        return ""
    ciphertext = encrypted_value[3:]
    hex_key = key.hex()
    hex_iv = "20" * 16

    result = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc", "-K", hex_key, "-iv", hex_iv, "-nopad"],
        input=ciphertext, capture_output=True, timeout=SUBPROCESS_TIMEOUT,
    )
    if result.returncode != 0:
        return ""
    decrypted = result.stdout
    if not decrypted:
        return ""

    # Strip PKCS7 padding
    pad_len = decrypted[-1]
    if 1 <= pad_len <= 16 and all(b == pad_len for b in decrypted[-pad_len:]):
        decrypted = decrypted[:-pad_len]

    # Chrome 130+ (DB version >= 24): skip 32-byte SHA256 prefix
    if db_version >= 24 and len(decrypted) > 32:
        decrypted = decrypted[32:]

    try:
        return decrypted.decode("utf-8")
    except UnicodeDecodeError:
        return ""


def extract_chrome_cookies():
    for browser in BROWSERS:
        base = browser["base"]
        if not os.path.isdir(base):
            continue

        key = get_browser_encryption_key(browser["keychain_service"], browser["keychain_account"])
        if not key:
            continue

        for profile in browser["profiles"]:
            cookies_path = os.path.join(base, profile, "Cookies")
            if not os.path.exists(cookies_path):
                continue

            tmp_fd, tmp_path = tempfile.mkstemp(suffix=".db")
            os.close(tmp_fd)
            try:
                shutil.copy2(cookies_path, tmp_path)
                for ext in ("-wal", "-shm"):
                    src = cookies_path + ext
                    if os.path.exists(src):
                        shutil.copy2(src, tmp_path + ext)

                conn = sqlite3.connect(tmp_path)
                try:
                    db_version = 0
                    try:
                        row = conn.execute("SELECT value FROM meta WHERE key='version'").fetchone()
                        if row:
                            db_version = int(row[0])
                    except Exception:
                        pass

                    rows = conn.execute(
                        "SELECT name, encrypted_value, host_key FROM cookies "
                        "WHERE host_key IN ('.claude.ai', '.claude.com', 'claude.ai', 'claude.com', "
                        "'.platform.claude.com', 'platform.claude.com') "
                        "AND name IN ('sessionKey', 'lastActiveOrg')"
                    ).fetchall()
                finally:
                    conn.close()

                # Group cookies by domain family to avoid mixing sessions
                domain_cookies = {}  # domain_root -> {sessionKey, lastActiveOrg}
                for name, encrypted_value, host_key in rows:
                    # Normalise to root domain
                    if "claude.ai" in host_key:
                        root = "claude.ai"
                    elif "claude.com" in host_key:
                        root = "claude.com"
                    else:
                        continue
                    decrypted = decrypt_cookie(encrypted_value, key, db_version)
                    if not decrypted:
                        continue
                    domain_cookies.setdefault(root, {})[name] = decrypted

                # Prefer claude.ai (known working), fall back to claude.com
                for domain_root in ("claude.ai", "claude.com"):
                    pair = domain_cookies.get(domain_root, {})
                    sk = pair.get("sessionKey")
                    oid = pair.get("lastActiveOrg")
                    if sk and oid:
                        return {"session_key": sk, "org_id": oid, "api_domain": domain_root}
            except Exception:
                continue
            finally:
                for ext in ("", "-wal", "-shm"):
                    try:
                        os.unlink(tmp_path + ext)
                    except OSError:
                        pass

    return None


# =============================================================================
# API fetch
# =============================================================================

def fetch_usage(session_key, org_id, api_domain="claude.ai"):
    api_base = API_BASE_TEMPLATE.format(domain=api_domain)
    url = f"{api_base}/{org_id}/usage"
    req = urllib.request.Request(url, headers={
        "Cookie": f"sessionKey={session_key}",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/120 Safari/537.36",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": f"https://{api_domain}/",
        "Origin": f"https://{api_domain}",
    })
    try:
        with urllib.request.urlopen(req, timeout=SUBPROCESS_TIMEOUT) as resp:
            return json.loads(resp.read())
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return None


# =============================================================================
# Background refresh
# =============================================================================

def background_refresh(cache):
    if not acquire_lock():
        return

    pid = os.fork()
    if pid != 0:
        return

    # Child process
    try:
        os.setsid()
        now = time.time()

        cookies = cache.get("cookies")
        if is_stale(cookies):
            result = extract_chrome_cookies()
            if result:
                cache["cookies"] = {
                    **result,
                    "fetched_at": now,
                    "expires_at": now + COOKIE_TTL,
                }
                save_cache(cache)
            else:
                release_lock()
                os._exit(0)

        cookies = cache.get("cookies", {})
        sk = cookies.get("session_key")
        oid = cookies.get("org_id")
        if not sk or not oid:
            release_lock()
            os._exit(0)

        domain = cookies.get("api_domain", "claude.ai")
        usage = fetch_usage(sk, oid, domain)
        if usage:
            cache["usage"] = {
                **usage,
                "fetched_at": now,
                "expires_at": now + USAGE_TTL,
            }
            save_cache(cache)
    except Exception:
        pass
    finally:
        release_lock()
        os._exit(0)


# =============================================================================
# Formatting
# =============================================================================

def color_for_pct(pct):
    pct = int(pct)
    if pct >= 90:
        return THEME["red"]
    if pct >= 70:
        return THEME["peach"]
    if pct >= 50:
        return THEME["yellow"]
    return THEME["green"]


def mini_bar(pct):
    pct = int(pct)
    filled = max(0, min(BAR_WIDTH, pct * BAR_WIDTH // 100))
    color = color_for_pct(pct)
    return f"{color}{BAR_FILLED * filled}{THEME['dim']}{BAR_EMPTY * (BAR_WIDTH - filled)}{RESET}"


def format_reset_time(resets_at):
    if not resets_at:
        return ""
    try:
        ts = resets_at.replace("Z", "+00:00")
        from datetime import datetime, timezone
        reset_dt = datetime.fromisoformat(ts)
        now = datetime.now(timezone.utc)
        diff = (reset_dt - now).total_seconds()
        if diff < 0:
            return "resetting"
        hours = int(diff // 3600)
        minutes = int((diff % 3600) // 60)
        if hours >= 24:
            days = hours // 24
            rem_hours = hours % 24
            return f"~{days}d{rem_hours}h"
        return f"~{hours}h{minutes:02d}m"
    except Exception:
        return ""


def get_git_status(cwd):
    """Return (branch, dirty_bool) or (None, False) if not a git repo."""
    if not cwd or not os.path.isdir(cwd):
        return None, False
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "symbolic-ref", "--short", "HEAD"],
            capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT,
        )
        if r.returncode != 0:
            return None, False
        branch = r.stdout.strip()
        d = subprocess.run(
            ["git", "-C", cwd, "status", "--porcelain"],
            capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT,
        )
        dirty = bool(d.stdout.strip())
        return branch, dirty
    except (OSError, subprocess.SubprocessError):
        return None, False


def format_duration(seconds):
    if seconds is None or seconds < 0:
        return ""
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m"
    return f"{sec}s"


def read_transcript_tail(transcript_path):
    """Read last TRANSCRIPT_TAIL_BYTES of transcript and return parsed JSON lines."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return []
    try:
        size = os.path.getsize(transcript_path)
        with open(transcript_path, "rb") as f:
            if size > TRANSCRIPT_TAIL_BYTES:
                f.seek(size - TRANSCRIPT_TAIL_BYTES)
                f.readline()  # discard partial line
            data = f.read().decode("utf-8", errors="ignore")
    except OSError:
        return []
    out = []
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            continue
    return out


def parse_iso_ts(ts):
    if not ts:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def extract_activity(records):
    """Walk transcript records \u2192 (current_tool, current_agent, current_todos).

    current_tool: (name, target_str) of the most recent assistant tool_use whose
      tool_result has not yet arrived, or None.
    current_agent: (description, started_ts) of an Agent/Task tool_use without
      a matching result, or None.
    current_todos: latest TodoWrite input dict, or None.
    """
    # collect tool_uses with id \u2192 (name, input, ts), and tool_use_ids seen as results
    pending = {}  # tool_use_id \u2192 (name, input, ts)
    results_seen = set()
    todos = None
    # Task system state (TaskCreate/TaskUpdate). id \u2192 {subject, activeForm, status}
    task_state = {}
    # Map tool_use_id of a TaskCreate call \u2192 its input (so we can resolve the id from its result)
    pending_creates = {}

    for j in records:
        t = j.get("type")
        if t == "assistant":
            ts = j.get("timestamp")
            for c in j.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    name = c.get("name", "")
                    inp = c.get("input", {}) or {}
                    pending[c.get("id")] = (name, inp, ts)
                    if name == "TodoWrite":
                        todos = inp
                    elif name == "TaskCreate":
                        pending_creates[c.get("id")] = inp
                    elif name == "TaskUpdate":
                        tid = str(inp.get("taskId", ""))
                        if tid and tid in task_state:
                            status = inp.get("status")
                            if status == "deleted":
                                task_state.pop(tid, None)
                            elif status:
                                task_state[tid]["status"] = status
                            for fld in ("subject", "activeForm"):
                                if inp.get(fld):
                                    task_state[tid][fld] = inp[fld]
        elif t == "user":
            # tool_result blocks live in user messages
            content = j.get("message", {}).get("content", [])
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        tuid = c.get("tool_use_id")
                        results_seen.add(tuid)
                        # If this is a TaskCreate result, extract the assigned id
                        if tuid in pending_creates:
                            text = c.get("content", "")
                            if isinstance(text, list) and text and isinstance(text[0], dict):
                                text = text[0].get("text", "")
                            import re
                            m = re.search(r"Task\s*#(\d+)", str(text))
                            if m:
                                tid = m.group(1)
                                inp = pending_creates.pop(tuid)
                                task_state[tid] = {
                                    "subject": inp.get("subject", ""),
                                    "activeForm": inp.get("activeForm", ""),
                                    "status": "pending",
                                }

    # Active = most recent pending tool_use without a matching result
    active_tool = None
    active_agent = None
    for tid, (name, inp, ts) in reversed(list(pending.items())):
        if tid in results_seen:
            continue
        if name in ("Agent", "Task") and active_agent is None:
            desc = inp.get("description") or inp.get("subagent_type") or "agent"
            active_agent = (str(desc)[:40], ts)
        elif active_tool is None and name not in ("Agent", "Task"):
            # pick a short target string for context
            target = ""
            for key in ("file_path", "path", "command", "url", "pattern", "query"):
                if key in inp and inp[key]:
                    target = str(inp[key])
                    # basename for paths, first word for commands
                    if key in ("file_path", "path"):
                        target = os.path.basename(target)
                    elif key == "command":
                        target = target.split()[0] if target.split() else ""
                    target = target[:30]
                    break
            active_tool = (name, target, ts)
        if active_tool and active_agent:
            break

    # Merge Task system state into the todos return value if TodoWrite wasn't used
    if not todos and task_state:
        items = [
            {
                "content": v.get("activeForm") if v.get("status") == "in_progress" else v.get("subject"),
                "status": v.get("status", "pending"),
            }
            for v in task_state.values()
        ]
        todos = {"todos": items}

    return active_tool, active_agent, todos


def format_todos(todos_input):
    """TodoWrite input \u2192 'current task title (done/total)' or None."""
    if not todos_input:
        return None
    items = todos_input.get("todos") or todos_input.get("tasks") or []
    if not isinstance(items, list) or not items:
        return None
    total = len(items)
    done = sum(1 for t in items if isinstance(t, dict) and t.get("status") == "completed")
    # active = first in_progress, else first pending, else last
    current = None
    for t in items:
        if isinstance(t, dict) and t.get("status") == "in_progress":
            current = t; break
    if current is None:
        for t in items:
            if isinstance(t, dict) and t.get("status") == "pending":
                current = t; break
    if current is None:
        current = items[-1] if isinstance(items[-1], dict) else None
    title = ""
    if current:
        title = current.get("content") or current.get("activeForm") or current.get("subject") or ""
    title = str(title)[:50]
    return f"{title} ({done}/{total})" if title else f"({done}/{total})"


def format_output(session_data, usage):
    parts = []

    model = session_data.get("model", {}).get("display_name", "")
    if model:
        parts.append(f"{THEME['accent']}[{model}]{RESET}")

    # Line 1: core meters only (model + context + 5h + 7d) \u2014 keep narrow-friendly.
    ctx = session_data.get("context_window", {})
    ctx_pct = int(ctx.get("used_percentage") or 0)
    parts.append(f"{THEME['label']}Ctx{RESET} {mini_bar(ctx_pct)} {color_for_pct(ctx_pct)}{ctx_pct}%{RESET}")

    if usage:
        five_hour = usage.get("five_hour")
        if five_hour:
            pct = int(five_hour.get("utilization") or 0)
            reset = format_reset_time(five_hour.get("resets_at"))
            reset_str = f" {THEME['dim']}{reset}{RESET}" if reset else ""
            parts.append(f"{THEME['label']}5h{RESET} {mini_bar(pct)} {color_for_pct(pct)}{pct}%{RESET}{reset_str}")

        seven_day = usage.get("seven_day")
        if seven_day:
            pct = int(seven_day.get("utilization") or 0)
            reset = format_reset_time(seven_day.get("resets_at"))
            reset_str = f" {THEME['dim']}{reset}{RESET}" if reset else ""
            parts.append(f"{THEME['label']}7d{RESET} {mini_bar(pct)} {color_for_pct(pct)}{pct}%{RESET}{reset_str}")
    elif usage is None:
        pass
    else:
        parts.append(f"{THEME['dim']}Usage: ?{RESET}")

    sep = f" {THEME['dim']}\u2502{RESET} "
    line1 = sep.join(parts)

    # Line 2: project/git, duration, style, and live activity. Off-loads everything
    # non-meter so line 1 fits a narrow terminal.
    line2_parts = []

    cwd = session_data.get("cwd") or session_data.get("workspace", {}).get("current_dir")
    if cwd:
        project = os.path.basename(cwd.rstrip("/"))
        branch, dirty = get_git_status(cwd)
        if branch:
            dirty_marker = f"{THEME['red']}*{RESET}" if dirty else ""
            line2_parts.append(
                f"{THEME['yellow']}{project}{RESET}"
                f"{THEME['dim']} git:({RESET}"
                f"{THEME['accent']}{branch}{dirty_marker}{RESET}"
                f"{THEME['dim']}){RESET}"
            )
        else:
            line2_parts.append(f"{THEME['yellow']}{project}{RESET}")

    dur_ms = session_data.get("cost", {}).get("total_duration_ms")
    if dur_ms:
        d = format_duration(dur_ms / 1000.0)
        if d:
            line2_parts.append(f"{THEME['dim']}\u23f1 {d}{RESET}")

    style_field = session_data.get("output_style")
    style = style_field.get("name") if isinstance(style_field, dict) else style_field
    if style and style not in ("default", "Default"):
        line2_parts.append(f"{THEME['dim']}style: {style}{RESET}")

    transcript_path = session_data.get("transcript_path")
    if transcript_path:
        records = read_transcript_tail(transcript_path)
        active_tool, active_agent, _ = extract_activity(records)
        if active_agent:
            desc, _ts = active_agent
            line2_parts.append(f"{THEME['peach']}\u25d0 agent{RESET} {THEME['label']}{desc}{RESET}")
        if active_tool:
            name, target, _ts = active_tool
            tail = f" {THEME['label']}{target}{RESET}" if target else ""
            line2_parts.append(f"{THEME['accent']}\u25d0 {name}{RESET}{tail}")

    print(line1)
    if line2_parts:
        print(sep.join(line2_parts))


# =============================================================================
# Main
# =============================================================================

def main():
    session_data = parse_stdin()
    cache = load_cache()

    cookies = cache.get("cookies")
    usage_entry = cache.get("usage")

    STALE_SYNC_THRESHOLD = 900  # 15 minutes  -  force synchronous if background keeps failing

    needs_refresh = is_stale(cookies) or is_stale(usage_entry)
    very_stale = (
        usage_entry is not None
        and time.time() - usage_entry.get("fetched_at", 0) > STALE_SYNC_THRESHOLD
    )
    if needs_refresh:
        # On cold cache or very stale data (>15 min), do a synchronous fetch.
        # On warm cache (stale refresh), fork to background so output is instant.
        if usage_entry and "five_hour" in usage_entry and not very_stale:
            background_refresh(cache)
        else:
            # Synchronous prime  -  keychain access works reliably in the main process
            if acquire_lock():
                try:
                    now = time.time()
                    if is_stale(cookies):
                        result = extract_chrome_cookies()
                        if result:
                            cache["cookies"] = {**result, "fetched_at": now, "expires_at": now + COOKIE_TTL}
                            save_cache(cache)
                    cookies_data = cache.get("cookies", {})
                    sk = cookies_data.get("session_key")
                    oid = cookies_data.get("org_id")
                    if sk and oid:
                        domain = cookies_data.get("api_domain", "claude.ai")
                        usage_data = fetch_usage(sk, oid, domain)
                        if usage_data:
                            cache["usage"] = {**usage_data, "fetched_at": now, "expires_at": now + USAGE_TTL}
                            save_cache(cache)
                            usage_entry = cache["usage"]
                finally:
                    release_lock()

    usage = None
    if usage_entry and "five_hour" in usage_entry:
        usage = usage_entry

    format_output(session_data, usage)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        log_path = os.path.join(CACHE_DIR, "error.log")
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(log_path, "a") as f:
                f.write(f"\n[{time.strftime('%Y-%m-%d %H:%M:%S')}]\n")
                traceback.print_exc(file=f)
        except OSError:
            pass
