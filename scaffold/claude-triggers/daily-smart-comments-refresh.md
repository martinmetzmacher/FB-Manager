# Daily smart comments refresh — Claude scheduled trigger prompt

Paste the markdown below as the prompt for a daily scheduled trigger on
the `Supabase` repo (see `docs/automation/SETUP.md` Path B).

---

You are running as a daily scheduled job for the shared Supabase project
`jrogvnrddkshokplobsn`. The Apify posts scraper has already refreshed the
last 20 posts overnight (Path A). Your job is to decide which of those
posts warrant a *comments* refresh, run it, and ingest the results.

## Step 1 — Identify candidates

Run this query to find posts whose comment count grew meaningfully since
the previous snapshot:

```sql
WITH latest AS (
  SELECT DISTINCT ON (post_id)
         post_id, captured_at, comments_count, likes_count
  FROM public.fb_post_engagement_snapshots
  ORDER BY post_id, captured_at DESC
),
prev AS (
  SELECT post_id, captured_at, comments_count
  FROM public.fb_post_engagement_snapshots s
  WHERE captured_at < (SELECT captured_at FROM latest WHERE latest.post_id = s.post_id)
  ORDER BY post_id, captured_at DESC
),
deltas AS (
  SELECT l.post_id,
         l.comments_count AS now_comments,
         (SELECT comments_count FROM prev p
          WHERE p.post_id = l.post_id
          ORDER BY p.captured_at DESC LIMIT 1) AS prev_comments,
         l.likes_count,
         l.captured_at
  FROM latest l
)
SELECT p.fb_post_id, p.url, d.prev_comments, d.now_comments,
       d.now_comments - coalesce(d.prev_comments, 0) AS d_comments,
       d.likes_count, p.posted_at
FROM deltas d
JOIN public.fb_posts p ON p.post_id = d.post_id
WHERE d.now_comments - coalesce(d.prev_comments, 0) >= 20
   OR (d.prev_comments IS NULL AND d.now_comments >= 30)
ORDER BY d_comments DESC NULLS LAST
LIMIT 10;
```

Interpretation:
- `d_comments >= 20` → at least 20 new comments since last check; worth refreshing.
- `prev_comments IS NULL AND now_comments >= 30` → a new post we have not yet
  scraped comments for that has built meaningful engagement.

## Step 2 — Decide and report

If 0 posts qualify, exit with a one-line summary "No posts needed a
comments refresh today" and stop. Do not spend Apify credits unnecessarily.

If 1–10 posts qualify, prepare to run the comments scraper on those URLs.

If more than 10 posts qualify, take the top 10 by `d_comments` and note in
the summary that you capped.

## Step 3 — Run Apify

Call the `apify/facebook-comments-scraper` actor with `async: true`:

```json
{
  "startUrls": [{ "url": "<each URL from step 2>" }],
  "viewOption": "RANKED_THREADED",
  "resultsLimit": 50000,
  "includeNestedComments": true
}
```

Poll `get-actor-run` until status is `SUCCEEDED`. Then fetch the dataset
via `get-actor-output`.

## Step 4 — Ingest

The comments scraper returns:
- top-level comments (threadingDepth: 0)
- nested replies (threadingDepth: 1, 2, ...)

**Important data quirk:** Apify reuses the parent's `commentId` for nested
replies. The reply's unique ID is in the `commentUrl` query parameter
`reply_comment_id=...`. Extract that as the `fb_comment_id` for any row
where `threadingDepth > 0`. For top-level rows, the `commentId` field is
the unique ID.

Steps:
1. Upsert unique commenters into `public.fb_profiles` (matched on
   `fb_user_id`, `role = 'audience'`). Use `ON CONFLICT (fb_user_id) DO NOTHING`.
2. Upsert comments into `public.fb_comments` with the staging columns
   populated:
   - `staging_post_fb_id` = item.facebookId
   - `staging_commenter_fb_user_id` = item.profileId
   - `staging_parent_fb_comment_id` = (for replies, the parent's commentId; for top-level, NULL)
   - `fb_comment_id` = unique reply_comment_id if reply else commentId
3. UPDATE to resolve `post_id`, `commenter_profile_id`, and
   `parent_comment_id` via the staging columns.
4. Log the run into `public.apify_runs` with
   `ingest_summary->>'source' = 'claude-trigger'`.

## Step 5 — Summarise

Output a final summary (in your session response, NOT committed to the
repo) with:
- Number of posts checked
- Number of posts that triggered a comments scrape
- Number of comments ingested
- Total Apify cost
- Any posts that errored

Then end the session. Do NOT keep the session alive looping.

## Guardrails

- If the candidate query returns more than 30 results, something is wrong
  (e.g., the previous-snapshot logic regressed). Stop and report — do not
  spend money on a runaway scrape.
- If a single post has `d_comments > 500`, that is unusual. Scrape it, but
  flag it in the summary.
- If any Apify run fails with `RUN-TIMEOUT-EXCEEDED`, do NOT retry in
  this session — just log it and move on. The next day's run will pick
  it up.

## What you may NOT do without asking

- Add new tables, columns, or indexes.
- Change the engagement-snapshot logic.
- Modify any handbook in `public.agent_handbook`.
- Delete data from any table.

If any of those feels needed, end the session with a clearly-marked
request to the operator.
