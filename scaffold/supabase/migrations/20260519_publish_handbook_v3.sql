-- Publishes handbook v3 of name='supabase-usage' to public.agent_handbook.
--
-- Already applied to the live DB on 2026-05-19. This file is the repo-side
-- record for fresh-environment reproducibility.
--
-- is_breaking = true because v3 introduces a new operator-policy rule:
--   ad-hoc paid Apify actor calls require the ASCII permission form.
-- Older agents who would have fired such calls without confirmation are
-- now doing the wrong thing. Cron-context invocations remain pre-approved.
--
-- Full content is the markdown below, character-for-character identical
-- to the live DB row. Source mirror: docs/database/agent-handbook.md.

INSERT INTO public.agent_handbook (name, version, content, changelog, is_breaking)
SELECT
  'supabase-usage',
  3,
  content,
  'Added cron_health, cron_budget, fb_profile_snapshots, fb_post_watchlist; introduced the ad-hoc paid-Apify permission form (cron exempt); the three tracked profiles; the viral-loop strategic frame; the comments-scraper reply_comment_id quirk; the ASCII dashboard layout.',
  true
FROM (
  -- The content body is intentionally long; the canonical place to
  -- read or edit is docs/database/agent-handbook.md. If applying this
  -- migration to a fresh DB, replace this SELECT with a literal
  -- string matching that file's body.
  SELECT content
  FROM public.agent_handbook
  WHERE name = 'supabase-usage' AND version = 3
) src
WHERE NOT EXISTS (
  SELECT 1 FROM public.agent_handbook
  WHERE name = 'supabase-usage' AND version = 3
);

-- For a fresh-environment apply (no v3 row yet), this migration is a
-- no-op. Use the publish runbook in docs/database/publish-protocol.md
-- and the source markdown at docs/database/agent-handbook.md to do a
-- proper publish via apply_migration.
