-- pg_cron schedule for the scheduled-scraper dispatcher.
--
-- Each row schedules a POST to /functions/v1/scheduled-scraper with
-- the matching { tier, job } payload. The function handles everything
-- else (target selection, Apify call, ingest, logging).
--
-- Prereqs:
--   - pg_cron + pg_net extensions enabled.
--   - DISPATCH_SECRET set as an edge function secret (matches header).
--   - cron_health + cron_budget tables exist.
--
-- To apply, set DISPATCH_SECRET below to the same value you used in
-- `supabase secrets set DISPATCH_SECRET=...`, then run this whole
-- file via psql or supabase db push. Re-running is safe: cron.unschedule
-- ignores missing job names.

-- Replace before running:
\set dispatch_secret '<paste your DISPATCH_SECRET here>'

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Helper: emit a SELECT net.http_post(...) string for a given job.
-- We just inline it in each schedule to keep this file self-contained.

-- Wipe prior versions (idempotent re-apply).
SELECT cron.unschedule(job_name)
FROM cron.job
WHERE job_name IN ('tier1_A','tier2_B','tier2_C','tier2_D','tier3_E');

-- Tier 1 — daily profile snapshot @ 06:00 UTC
SELECT cron.schedule('tier1_A', '0 6 * * *', $cmd$
  SELECT net.http_post(
    url := 'https://jrogvnrddkshokplobsn.supabase.co/functions/v1/scheduled-scraper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', :'dispatch_secret'
    ),
    body := jsonb_build_object('tier', 1, 'job', 'A')
  );
$cmd$);

-- Tier 2 — self feed (Martin) @ 02 / 08 / 14 / 20 UTC
SELECT cron.schedule('tier2_B', '0 2,8,14,20 * * *', $cmd$
  SELECT net.http_post(
    url := 'https://jrogvnrddkshokplobsn.supabase.co/functions/v1/scheduled-scraper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', :'dispatch_secret'
    ),
    body := jsonb_build_object('tier', 2, 'job', 'B')
  );
$cmd$);

-- Tier 2 — peer feeds @ 06 / 18 UTC
SELECT cron.schedule('tier2_C', '0 6,18 * * *', $cmd$
  SELECT net.http_post(
    url := 'https://jrogvnrddkshokplobsn.supabase.co/functions/v1/scheduled-scraper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', :'dispatch_secret'
    ),
    body := jsonb_build_object('tier', 2, 'job', 'C')
  );
$cmd$);

-- Tier 2 — comments harvest @ 23:00 UTC
SELECT cron.schedule('tier2_D', '0 23 * * *', $cmd$
  SELECT net.http_post(
    url := 'https://jrogvnrddkshokplobsn.supabase.co/functions/v1/scheduled-scraper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', :'dispatch_secret'
    ),
    body := jsonb_build_object('tier', 2, 'job', 'D')
  );
$cmd$);

-- Tier 3 — viral watchlist every 15 min
SELECT cron.schedule('tier3_E', '*/15 * * * *', $cmd$
  SELECT net.http_post(
    url := 'https://jrogvnrddkshokplobsn.supabase.co/functions/v1/scheduled-scraper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', :'dispatch_secret'
    ),
    body := jsonb_build_object('tier', 3, 'job', 'E')
  );
$cmd$);

-- After running this file, verify with:
--   SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;
