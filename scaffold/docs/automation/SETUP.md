# Automation Setup — pg_cron → scheduled-scraper

## Architecture

```
pg_cron (Supabase, free)
    └── POST /functions/v1/scheduled-scraper  { tier, job }
           ├── verify x-dispatch-secret
           ├── budget gate (cron_budget)
           ├── select targets (tracked profiles, posts, watchlist)
           ├── invoke Apify actor; poll until terminal
           ├── ingest dataset (staging-FK pattern)
           ├── log cron_health row
           ├── bump cron_budget
           ├── on error → triage_inbox row
           └── post-process: admit/graduate watchlist (B/C/E)
```

Three tiers, independently toggle-able. Build order: Tier 1 → wait 3
clean days → Tier 2 → wait 3 → Tier 3.

| Job | Tier | Cadence              | Actor                                        | Est. cost |
|-----|------|----------------------|----------------------------------------------|-----------|
| A   | 1    | daily 06:00 UTC      | premiumscraper/facebook-pages-profile-scraper| ~$0.03/day |
| B   | 2    | 4×/day               | apify/facebook-posts-scraper                 | ~$0.16/day |
| C   | 2    | 2×/day               | apify/facebook-posts-scraper                 | ~$0.16/day |
| D   | 2    | daily 23:00 UTC      | apify/facebook-comments-scraper              | ~$1-2/day |
| E   | 3    | every 15 min         | apify/facebook-posts-scraper                 | ~$1-2/day |

Hard cap: $5/day, auto-paused via `cron_budget.paused`.

## One-time setup

### 1. Apply the migrations

These have already been applied to the live DB on 2026-05-19 and are in
this repo as records for fresh-environment reproducibility:

- `supabase/migrations/20260519_create_ingest_helpers.sql` — RPC
  `resolve_fb_posts_staging(text)` used by the dispatcher's posts ingest.
- `supabase/migrations/20260519_create_cron_health_and_budget.sql` —
  `cron_health` + `cron_budget` tables.
- `supabase/migrations/20260519_publish_handbook_v3.sql` — handbook
  bumped to v3 with the new tables + permission policy documented.

If you ever need to recreate from scratch:

```bash
supabase db push   # applies any migrations in supabase/migrations/
```

### 2. Set Edge Function secrets

```bash
supabase secrets set \
  APIFY_TOKEN=<your apify api token> \
  DISPATCH_SECRET=<a long random string you generate>
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected — do
not set them manually.

### 3. Deploy the Edge Function

```bash
supabase functions deploy scheduled-scraper --project-ref jrogvnrddkshokplobsn
```

Each job is testable independently via curl before pg_cron drives it:

```bash
curl -X POST \
  -H 'Content-Type: application/json' \
  -H 'x-dispatch-secret: <DISPATCH_SECRET>' \
  -d '{"tier":1,"job":"A"}' \
  https://jrogvnrddkshokplobsn.supabase.co/functions/v1/scheduled-scraper
```

Verify by looking at `cron_health`:

```sql
SELECT job, status, cost_usd, items_in, rows_written, error_kind
FROM public.cron_health
ORDER BY fired_at DESC LIMIT 5;
```

### 4. Schedule the pg_cron jobs

Edit `supabase/pg_cron_schedules.sql` — replace the `\set
dispatch_secret '<paste...>'` placeholder with the same string you set
in step 2. Apply once (idempotent):

```bash
psql <YOUR_CONNECTION_STRING> -f supabase/pg_cron_schedules.sql
# or via Supabase SQL editor
```

Confirm:

```sql
SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;
```

You should see `tier1_A`, `tier2_B`, `tier2_C`, `tier2_D`, `tier3_E`.

### 5. Phased activation

The pg_cron schedule file enables ALL tiers at once. To do phased
activation, deactivate the higher tiers first and reactivate them as
each one proves stable:

```sql
-- Activate only Tier 1 for now
UPDATE cron.job SET active = false WHERE jobname IN ('tier2_B','tier2_C','tier2_D','tier3_E');
UPDATE cron.job SET active = true  WHERE jobname = 'tier1_A';
```

After 3 days of clean Tier 1 runs (check `cron_health`), enable Tier 2:

```sql
UPDATE cron.job SET active = true
WHERE jobname IN ('tier2_B','tier2_C','tier2_D');
```

Same pattern for Tier 3.

## Verifying health

```sql
-- Last 24h runs grouped by job + status
SELECT job, status, count(*),
       round(sum(cost_usd)::numeric, 4) AS spent
FROM public.cron_health
WHERE fired_at > now() - interval '24 hours'
GROUP BY job, status
ORDER BY job;

-- Today's spend vs cap
SELECT day, spent_usd, cap_usd, paused, pause_reason
FROM public.cron_budget
WHERE day = current_date;

-- Watchlist
SELECT post_id, admit_reason, admitted_at, poll_interval_sec
FROM public.fb_post_watchlist
WHERE graduated_at IS NULL
ORDER BY admitted_at DESC;
```

## Daily digest (TODO)

A 7th cron at 07:00 UTC should query the last 24h of `cron_health`,
summarise, and write a `triage_inbox` row with `kind='cron_daily_digest'`.
Not yet implemented — add as a v1 follow-up.

## Auto-pause behavior

| Trigger                                         | What happens                                      | Recovery |
|-------------------------------------------------|---------------------------------------------------|----------|
| `spent_usd >= cap_usd`                          | All jobs return `skipped_budget` until UTC midnight | Auto: new day = fresh row |
| ≥3 errors in 24h on the same job (TODO)         | Set `paused=true, pause_reason='consecutive_failures'` | Manual: `UPDATE cron_budget SET paused=false WHERE day=...` |
| Operator-set pause                              | Same as above with `pause_reason='operator'`      | Manual: same |

## What's NOT in this scaffold (yet)

- The per-job ingest implementations (`ingestProfileSnapshots`,
  `ingestPosts`, `ingestComments`). Currently throw `TODO: implement`
  with comments on the staging-FK pattern. Build these one job at a
  time, test by curling the endpoint, then activate the cron schedule.
- Watchlist admit/graduate logic (`admitNewPostsToWatchlist`,
  `graduateColdPosts`). Stubbed.
- Daily digest + drift detection + cost anomaly detection — design in
  the project status doc; implement once Tier 1 has 3 clean days.

## Reference

- Permission policy: see `public.agent_handbook` row where
  `name = 'supabase-usage' AND version = 3`. Ad-hoc paid Apify calls
  need the ASCII permission form; scheduled cron is exempt.
- Schema reference: run `list_tables` with `verbose: true`. There is
  no maintained .md schema doc.
