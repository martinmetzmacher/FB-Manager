# Automation Setup

There are two automation paths. They can run independently or together.

## Path A — Posts refresh: Apify schedule → Supabase Edge Function

What it does: every day at 06:00 UTC, Apify scrapes the last N posts from a
target Facebook profile, then POSTs a webhook to the Supabase Edge Function,
which ingests the data and captures an engagement snapshot. No Claude
involvement.

```
Apify Schedule  --cron-->  apify/facebook-posts-scraper run
                                       |
                          run finishes, webhook fires
                                       v
        https://<ref>.functions.supabase.co/ingest-fb-posts?secret=<...>
                                       |
                                       v
        Supabase Edge Function fetches the dataset, upserts into
        fb_posts, calls resolve_fb_posts_staging() RPC, returns 200.
```

### One-time setup

1. **Apply the migration** that creates the helper RPC:

   ```bash
   supabase db push   # if running migrations via CLI
   # OR: apply via the MCP apply_migration tool
   ```

   File: `supabase/migrations/20260519_create_ingest_helpers.sql`.

2. **Set Edge Function secrets** (Supabase CLI, or dashboard → Project Settings → Edge Functions):

   ```bash
   supabase secrets set \
     APIFY_TOKEN=<your apify api token> \
     INGEST_WEBHOOK_SECRET=<a long random string you generate>
   ```

   `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by
   Supabase — do not set them yourself.

3. **Deploy the Edge Function:**

   ```bash
   supabase functions deploy ingest-fb-posts --project-ref jrogvnrddkshokplobsn
   ```

4. **Create the Apify Schedule** in the Apify Console (Schedules → Create):
   - Cron: `0 6 * * *` (every day at 06:00 UTC)
   - Actor: `apify/facebook-posts-scraper` (id `KoJrdxJCTtpon81KY`)
   - Input:
     ```json
     {
       "startUrls": [{ "url": "https://www.facebook.com/mmetzmacher" }],
       "captionText": false,
       "resultsLimit": 20
     }
     ```
   - Save.

5. **Add the webhook** to that schedule (Schedule → Settings → Integrations):
   - Event: "Run succeeded"
   - URL: `https://jrogvnrddkshokplobsn.functions.supabase.co/ingest-fb-posts?secret=<INGEST_WEBHOOK_SECRET>`
   - Payload template: leave default (Apify ships the standard run payload).

6. **Smoke test** by clicking "Run now" on the schedule. Then check:
   ```sql
   SELECT run_id, item_count, ingest_summary, ingested_at
   FROM public.apify_runs
   ORDER BY ingested_at DESC LIMIT 1;
   ```
   You should see the new run with `ingest_summary->>'source' = 'edge-function'`.

### Cost estimate
- Apify: ~$0.004 per post × 20 posts = ~$0.08/day = ~$2.40/month
- Supabase Edge Function: free tier covers thousands of invocations/month

---

## Path B — Smart comments refresh: Claude scheduled trigger

What it does: every day at 07:00 UTC (after Path A has refreshed posts),
a Claude Code session wakes up, queries engagement snapshots to find posts
where comment counts jumped meaningfully since the previous snapshot, and
runs a targeted Apify comments-scrape against those posts. Logs into
apify_runs as usual.

Why this needs Claude rather than another Edge Function: the decision
"which posts deserve a comments scrape?" depends on velocity, total
volume, and recency in ways that change over time. A prompt is easier to
tune than a fixed SQL heuristic.

### One-time setup

1. Open the `Supabase` repo in Claude Code on web: https://claude.ai/code
2. Navigate to **Settings → Triggers** for this repo.
3. Create a new **Scheduled trigger** with:
   - Schedule: `0 7 * * *` (daily 07:00 UTC)
   - Prompt: paste the contents of
     [`claude-triggers/daily-smart-comments-refresh.md`](../../claude-triggers/daily-smart-comments-refresh.md)
4. Save.

### Cost estimate
- Claude tokens per run: ~$0.50–$1.00 (one short Claude session)
- Apify costs depend on how many posts the prompt decides to scrape
  comments for; typical day: ~$0.50–$2.00

### Where the run output goes
The session ends naturally after it finishes. It can also commit a
summary file to the Supabase repo if you ask it to in the prompt, but the
canonical record is in `public.apify_runs`.

---

## Verifying it works

After both are running for a day:

```sql
-- Yesterday's automated runs
SELECT actor_name, status, item_count, cost_usd, started_at,
       ingest_summary
FROM public.apify_runs
WHERE started_at > now() - interval '36 hours'
  AND ingest_summary->>'source' = 'edge-function'
ORDER BY started_at DESC;

-- Engagement deltas captured by the snapshots
SELECT post_id, captured_at,
       likes_count - lag(likes_count) OVER w  AS d_likes,
       comments_count - lag(comments_count) OVER w AS d_comments
FROM public.fb_post_engagement_snapshots
WINDOW w AS (PARTITION BY post_id ORDER BY captured_at)
ORDER BY captured_at DESC LIMIT 20;
```

## What to do when it breaks

- **Edge Function 500s** → `supabase functions logs ingest-fb-posts`.
- **Apify run failed** → Apify Console → Runs → click the failed run.
- **Schedule didn't fire** → Apify Console → Schedules → check "Last run".
- **Webhook returned 401** → secret mismatch. Re-check
  `INGEST_WEBHOOK_SECRET` and the `?secret=` query param on the
  webhook URL.
- **Posts not appearing in DB** → run the verification query above. If
  `apify_runs` has the run but `fb_posts` is empty, the upsert returned
  no rows — check the function logs for an error.
