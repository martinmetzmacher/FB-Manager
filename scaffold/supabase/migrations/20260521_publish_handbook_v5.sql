-- Publishes handbook v5 of name='supabase-usage' to public.agent_handbook.
--
-- Already applied to the live DB on 2026-05-21. Repo-side record only.
-- Canonical source for the full content body is docs/database/agent-handbook.md.
--
-- Changes vs v4:
--   - New pattern #5: "Ghost posts" — fb_posts rows where fb_post_id is a
--     `pfbid…` alias instead of a numeric FB post ID. Creates double-counting
--     on fill metrics. Distinguishes inert (safe bulk delete) from active
--     (need pairing) ghosts.
--   - New section "How to pair an active ghost with its canonical numeric
--     post" — documents the inputUrl→facebookId recipe used in this session
--     to merge 38 ghosts (2 mmetzmacher + 36 somaticbizcoachdavid) without
--     re-ingesting any comments.
--   - New section "Writing safe transactions via execute_sql" — the BEGIN
--     without COMMIT pitfall (silent rollback at connection close). Verify
--     writes by re-querying afterward.
--   - Light cleanup of v4 prose. No removed semantics.
--
-- is_breaking = false. v5 is additive — older agents that didn't know about
-- ghosts wouldn't have done anything WRONG; they just wouldn't have detected
-- or cleaned the duplication.

INSERT INTO public.agent_handbook (name, version, content, changelog, is_breaking)
SELECT
  'supabase-usage',
  5,
  content,
  'Added "Ghost posts" pattern + the inputUrl->facebookId pairing recipe for retroactive merge. Added "Writing safe transactions" note about BEGIN/COMMIT discipline via execute_sql. Light cleanup of v4 prose.',
  false
FROM (
  SELECT content
  FROM public.agent_handbook
  WHERE name = 'supabase-usage' AND version = 5
) src
WHERE NOT EXISTS (
  SELECT 1 FROM public.agent_handbook
  WHERE name = 'supabase-usage' AND version = 5
);
