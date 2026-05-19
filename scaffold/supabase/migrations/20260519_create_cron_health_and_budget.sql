-- Already applied to the live DB (project jrogvnrddkshokplobsn) on
-- 2026-05-19. This file is the repo-side record so anyone setting up a
-- fresh environment can recreate it.

CREATE TABLE IF NOT EXISTS public.cron_health (
  run_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job           text NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  status        text NOT NULL CHECK (status IN (
                  'queued','running','success','error','skipped_budget'
                )),
  apify_run_id  text,
  dataset_id    text,
  cost_usd      numeric,
  items_in      int,
  rows_written  jsonb,
  error_kind    text,
  error_detail  text,
  notes         text
);

CREATE INDEX IF NOT EXISTS ix_cron_health_job_time
  ON public.cron_health (job, fired_at DESC);

CREATE TABLE IF NOT EXISTS public.cron_budget (
  day          date PRIMARY KEY DEFAULT CURRENT_DATE,
  spent_usd    numeric NOT NULL DEFAULT 0,
  cap_usd      numeric NOT NULL DEFAULT 5.00,
  paused       boolean NOT NULL DEFAULT false,
  pause_reason text
);

COMMENT ON TABLE  public.cron_health  IS 'Per-fire log for pg_cron jobs invoking scheduled-scraper. One row per dispatch.';
COMMENT ON TABLE  public.cron_budget  IS 'Daily spend ledger + cap + auto-pause flag. Keyed by UTC day; new day = fresh budget.';
COMMENT ON COLUMN public.cron_health.dataset_id   IS 'Apify dataset ID — handy if a deploy bug eats the first ingest and we need to re-pull.';
COMMENT ON COLUMN public.cron_health.rows_written IS 'Breakdown like {fb_posts: 10, fb_comments: 142, fb_profiles: 3}.';
COMMENT ON COLUMN public.cron_health.status       IS 'queued / running / success / error / skipped_budget.';
COMMENT ON COLUMN public.cron_budget.pause_reason IS 'When paused=true: ''budget_cap'' or ''consecutive_failures'' or operator-set string.';
