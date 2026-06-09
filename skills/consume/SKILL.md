---
name: consume
description: Review the week's captured links (articles, tweets, AI tools, GitHub repos) one at a time. Pulls everything saved via the Consume capture path (e.g. an iOS Shortcut posting to a Supabase Edge Function) from a `consume_items` table, summarises each, and routes it to one of these actions (read, save to brain, share to Slack, or repo/tool review). Use when the user says "consume", "review my consume list", "go through my saved links", "what did I save this week", "triage my reading", or invokes /consume.
argument-hint: "[optional: filter e.g. 'repos only' or a count]"
---

# Consume

One pipe for everything you save during the week. Capture happens via your own
"Consume" capture path (e.g. an iOS / Apple Shortcut that posts URL → secret-
protected Edge Function → `consume_items` table in Supabase). This skill is the
**review** half: walk the list together, decide what each item deserves.

This is the shareable / generic version of the skill. Wire it up to your own
Supabase project, brain destination, and Slack channel via env vars and config.

## Prerequisites

To run this skill end-to-end you need:

1. **A Supabase project** with a `consume_items` table. Recommended schema:
   - `id` (uuid, pk), `url` (text, not null), `title` (text, nullable),
     `created_at` (timestamptz, default now), `status` (text, default `pending`),
     `action_taken` (text, nullable), `triaged_at` (timestamptz, nullable),
     `notes` (text, nullable).
2. **A capture path that inserts rows**  -  an iOS / Apple Shortcut, browser
   bookmarklet, or any small webhook is fine. Insert a row with at least `url`
   and the row defaults to `status='pending'`.
3. **A service-role key** for the Supabase project (RLS denies the anon key for
   updates).
4. **Optional integrations**  -  wire any of these in via your own skills:
   - A brain / notes skill that can save a topic + body (mapped to the
     "save to brain" action below).
   - A Slack share channel (mapped to the "share to Slack" action below).
   - A target stack repo where useful patterns from reviewed repos / tools get
     pulled in.

## Config

Read these from env (set them in your shell config or a sourced file). The
skill stops early with a clear message if a required one is missing  -  don't
guess defaults.

| Var | Purpose | Required |
|---|---|---|
| `CONSUME_SUPABASE_URL` | e.g. `https://<project-ref>.supabase.co` | yes |
| `CONSUME_SUPABASE_KEY` | service-role key for the project | yes |
| `CONSUME_ENV_FILE` | optional path to a file with the above (sourced if set) | no |
| `CONSUME_SLACK_CHANNEL` | channel ID for the "share to Slack" action | no, but required to use that action |
| `CONSUME_STACK_DIR` | absolute path to the stack repo where reviewed-and-kept tooling lands | no, but required for repo `add` verdicts |

If `CONSUME_ENV_FILE` is set, source it first:

```bash
[ -n "${CONSUME_ENV_FILE:-}" ] && [ -f "$CONSUME_ENV_FILE" ] && { set -a; . "$CONSUME_ENV_FILE"; set +a; }
```

If `CONSUME_SUPABASE_URL` or `CONSUME_SUPABASE_KEY` is missing or empty after
that, tell the user how to set them and stop.

## Step 1  -  Fetch pending items

```bash
curl -sS "${CONSUME_SUPABASE_URL}/rest/v1/consume_items?status=eq.pending&order=created_at.asc" \
  -H "apikey: ${CONSUME_SUPABASE_KEY}" \
  -H "Authorization: Bearer ${CONSUME_SUPABASE_KEY}"
```

If the argument narrows scope (e.g. "repos only", "just 5"), apply it after
fetching. If nothing is pending, say so and stop  -  don't invent items.

Tell the user how many are pending before starting, e.g. "You've got 12 saved.
Let's go through them."

## Step 2  -  Label each item

The table stores only the raw URL. Resolve what each one actually is:

- **X / Twitter** (`x.com/*/status/*` or `twitter.com/*/status/*`): use your
  preferred X-reading tool (e.g. a `/read-x` skill if you have one, or
  `WebFetch` on the URL  -  note the public Twitter page often blocks fetches,
  so a dedicated reader is more reliable).
- **GitHub repo** (`github.com/owner/repo`): note it's a repo; the README is
  the WebFetch target.
- **Everything else:** `WebFetch` the URL for title + gist.

If a fetch fails (paywall, login wall, JS-only), say so plainly and offer to
open it directly or skip. Don't guess at content you couldn't read.

Cache the resolved title back on the row (cheap, makes history readable):

```bash
curl -sS -X PATCH "${CONSUME_SUPABASE_URL}/rest/v1/consume_items?id=eq.<ID>" \
  -H "apikey: ${CONSUME_SUPABASE_KEY}" -H "Authorization: Bearer ${CONSUME_SUPABASE_KEY}" \
  -H "Content-Type: application/json" -d '{"title":"<resolved title>"}'
```

## Step 3  -  Walk item by item

For each pending item, present:

- **What it is** (title + one-line type: article / tweet / AI tool / GitHub repo)
- A **2–3 line summary**
- A **suggested action** with brief reasoning

Then use `AskUserQuestion` so the user picks the action. The skill ships with
these actions; wire each to your own tooling:

- **Read**  -  give a fuller summary + an honest "worth your time?" verdict.
  `action_taken='read'`.
- **Save to brain**  -  invoke your brain / notes skill if you have one. Pass a
  clear topic + self-contained content summarising the item and why it
  matters. `action_taken='brain'`.
- **Share to Slack**  -  post to `$CONSUME_SLACK_CHANNEL` via your Slack MCP /
  skill of choice: the link + a 1–2 line why-it's-interesting.
  `action_taken='shared'`.
- **Open in browser**  -  `open <url>` (macOS) or your platform equivalent so
  the user can read/explore it themselves. Then ask what action to take
  after. `action_taken='read'` with a note that it was opened for manual
  review.
- **Repo / tool review**  -  do real research, not a shallow skim. The point is
  to answer "how does this work and how could we use it" well enough that the
  user can decide without opening the repo themselves. Structure:
  1. **How it works**  -  fetch README, QUICKSTART, architecture docs
     (`gh api repos/<owner>/<repo>/contents/<file>`). Extract the data model,
     the pipeline (input → processing → output), the storage layout, the
     runtime requirements (services, keys, infra).
  2. **How we could use it**  -  map it concretely to the user's stack. Name
     2–3 specific integration points, not vague "could be useful". Be honest
     about what it replaces or duplicates.
  3. **Cost to try**  -  install footprint, external deps, ongoing cost, time
     to a working demo. Whether it's reversible.
  4. **Verdict**  -  `add` (worth integrating now) / `experiment` (worth a few
     hours to test) / `skip` (don't bother, here's why).
  If the verdict is `add` or `experiment` and the user agrees, `git clone` to
  a scratch dir, and pull the useful concepts into `$CONSUME_STACK_DIR` if
  set. Never auto-commit there. `action_taken='reviewed'`.
- **Skip**  -  leave for later (stays `pending`). Don't mark it triaged.

Always offer "Skip" / "Other" so the user stays in control (`AskUserQuestion`
includes an Other option automatically).

## Step 4  -  Mark triaged

After an action completes (anything except Skip), flip the row:

```bash
curl -sS -X PATCH "${CONSUME_SUPABASE_URL}/rest/v1/consume_items?id=eq.<ID>" \
  -H "apikey: ${CONSUME_SUPABASE_KEY}" -H "Authorization: Bearer ${CONSUME_SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"status":"triaged","action_taken":"<action>","triaged_at":"now()","notes":"<short note/verdict>"}'
```

History is preserved (no deletes). Triaged items won't show up next run.

## Step 5  -  Wrap up

When the list is done (or the user stops), give a quick tally: how many read /
brained / shared / reviewed / skipped, and flag anything left pending.

## Notes

- One item at a time. Don't dump the whole list with summaries up front  -  the
  point is a calm, guided pass, not a wall of text.
- Reuse existing tooling where you have it (X reader, brain skill, Slack
  poster). Don't reimplement them.
- Never auto-commit changes made to `$CONSUME_STACK_DIR`; leave that to the user.
- A triage item can balloon into a real coding task (e.g. "pull useful bits
  from this tool into my setup"). That's fine and expected. When it happens:
  flag the scope shift, confirm with the user, then pause the triage queue
  and do the work. Resume the queue after. Don't try to multitask the
  deep-dive against the rest of the list.
