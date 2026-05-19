-- Helper RPC for the ingest-fb-posts edge function.
--
-- After the edge function bulk-upserts rows into fb_posts (with the staging
-- columns populated), it calls this function to:
--   1. resolve staging_author_fb_user_id -> author_profile_id
--   2. bump last_posts_pull_at on the profiles whose posts were just refreshed
--   3. capture an engagement snapshot per refreshed post
--
-- Returns the number of FK rows that were resolved.

CREATE OR REPLACE FUNCTION public.resolve_fb_posts_staging(run_id_param text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  resolved_count int := 0;
BEGIN
  -- 1. Resolve staging FK
  WITH upd AS (
    UPDATE public.fb_posts
    SET author_profile_id = fp.profile_id
    FROM public.fb_profiles fp
    WHERE public.fb_posts.staging_author_fb_user_id = fp.fb_user_id
      AND public.fb_posts.author_profile_id IS NULL
      AND public.fb_posts.source_run_id = run_id_param
    RETURNING 1
  )
  SELECT count(*) INTO resolved_count FROM upd;

  -- 2. Bump last_posts_pull_at for any profile whose posts we touched
  UPDATE public.fb_profiles fp
  SET last_posts_pull_at = now()
  WHERE EXISTS (
    SELECT 1 FROM public.fb_posts p
    WHERE p.source_run_id = run_id_param
      AND p.author_profile_id = fp.profile_id
  );

  -- 3. Engagement snapshot per refreshed post
  INSERT INTO public.fb_post_engagement_snapshots (
    post_id, captured_at,
    likes_count, comments_count, shares_count, top_reactions_count,
    reaction_like, reaction_love, reaction_care, reaction_wow,
    reaction_haha, reaction_sad, reaction_angry,
    source_run_id
  )
  SELECT p.post_id, now(),
         p.likes_count, p.comments_count, p.shares_count, p.top_reactions_count,
         p.reaction_like, p.reaction_love, p.reaction_care, p.reaction_wow,
         p.reaction_haha, p.reaction_sad, p.reaction_angry,
         run_id_param
  FROM public.fb_posts p
  WHERE p.source_run_id = run_id_param;

  RETURN resolved_count;
END;
$$;

COMMENT ON FUNCTION public.resolve_fb_posts_staging(text) IS
'Called by the ingest-fb-posts edge function after bulk-upserting posts. '
'Resolves staging_author_fb_user_id -> author_profile_id, bumps '
'last_posts_pull_at, and captures an engagement snapshot per row. '
'Returns count of FK resolutions performed.';

-- Allow the anon and authenticated roles to call this. The function is
-- SECURITY DEFINER so it runs with the owner's permissions; the only entry
-- point is via supabase-js .rpc() with the service role key (the edge
-- function uses SERVICE_ROLE_KEY).
GRANT EXECUTE ON FUNCTION public.resolve_fb_posts_staging(text) TO service_role;
