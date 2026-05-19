-- Publishes handbook v4 of name='supabase-usage' to public.agent_handbook.
--
-- Already applied to the live DB on 2026-05-19. This file is the repo-side
-- record. The canonical source for the full content body is
-- docs/database/agent-handbook.md (kept in sync at v4).
--
-- is_breaking = true because v4 deprecates an actor an older agent might
-- still pick (scraper_one/facebook-reactions-scraper). Older agents that
-- ran that actor would waste money on a known-broken pipeline.
--
-- Changes vs v3:
--   - Added "Deprecated actors — DO NOT USE" section, with
--     scraper_one/facebook-reactions-scraper listed and the two quirks
--     (postUrl-only matching, paginated duplicates) documented.
--   - Generalised pattern #4 from a comments-specific note to a broader
--     "always DISTINCT before INSERT...ON CONFLICT" rule that covers
--     paginated-duplicate cases including the reactions scraper.
--   - Added rule in pattern #2: on UPSERT, also update source_run_id —
--     the legacy pipeline didn't, leaving stale audit trail on re-scraped
--     rows (~38 runs in the apify_runs table had this symptom).
--
-- See docs/database/publish-protocol.md for the publish runbook.

-- This INSERT is intentionally a no-op against a DB that already has v4.
-- For fresh-environment apply: replace this whole file with an INSERT that
-- uses the literal content from docs/database/agent-handbook.md.

INSERT INTO public.agent_handbook (name, version, content, changelog, is_breaking)
SELECT
  'supabase-usage',
  4,
  content,
  'Deprecated scraper_one/facebook-reactions-scraper (fragile postUrl-only matching + ~26% paginated duplicates). Generalized pattern #4 to "always DISTINCT before INSERT...ON CONFLICT". Added rule -- on UPSERT update source_run_id to keep the audit trail honest (legacy bug).',
  true
FROM (
  SELECT content
  FROM public.agent_handbook
  WHERE name = 'supabase-usage' AND version = 4
) src
WHERE NOT EXISTS (
  SELECT 1 FROM public.agent_handbook
  WHERE name = 'supabase-usage' AND version = 4
);
