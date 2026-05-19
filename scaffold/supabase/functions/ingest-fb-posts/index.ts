// Ingest Facebook posts from an Apify run into Supabase.
//
// Trigger: Apify webhook on "Run succeeded" for an apify/facebook-posts-scraper
// run. Configure the webhook URL in your Apify Schedule:
//   https://<project-ref>.functions.supabase.co/ingest-fb-posts?secret=<INGEST_WEBHOOK_SECRET>
//
// Required env vars (set via `supabase secrets set`):
//   APIFY_TOKEN              — to fetch the dataset items
//   INGEST_WEBHOOK_SECRET    — shared secret, checked against ?secret=...
//   SUPABASE_URL             — auto-set by Supabase
//   SUPABASE_SERVICE_ROLE_KEY — auto-set by Supabase
//
// What it does:
//   1. Verifies the webhook secret.
//   2. Fetches the dataset items from Apify.
//   3. Logs the run into public.apify_runs.
//   4. Upserts posts into public.fb_posts (matched on fb_post_id; engagement
//      counts get refreshed via ON CONFLICT).
//   5. Calls public.resolve_fb_posts_staging(run_id) which resolves the
//      staging_author_fb_user_id → author_profile_id FK, bumps
//      fb_profiles.last_posts_pull_at, and captures an engagement snapshot.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const APIFY_TOKEN = Deno.env.get("APIFY_TOKEN");
const WEBHOOK_SECRET = Deno.env.get("INGEST_WEBHOOK_SECRET");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type ApifyWebhookPayload = {
  eventType?: string;
  eventData?: { actorRunId?: string; actorId?: string };
  resource?: {
    id?: string;
    actId?: string;
    userId?: string;
    startedAt?: string;
    finishedAt?: string;
    status?: string;
    defaultDatasetId?: string;
    options?: { input?: unknown };
  };
};

type PostItem = {
  postId: string;
  url?: string;
  topLevelUrl?: string;
  time?: string;
  text?: string;
  likes?: number;
  comments?: number;
  shares?: number;
  topReactionsCount?: number;
  reactionLikeCount?: number;
  reactionLoveCount?: number;
  reactionCareCount?: number;
  reactionWowCount?: number;
  reactionHahaCount?: number;
  reactionSadCount?: number;
  reactionAngryCount?: number;
  media?: unknown[];
  feedbackId?: string;
  user?: { id?: string };
};

serve(async (req: Request) => {
  // 1. Secret check
  const url = new URL(req.url);
  if (!WEBHOOK_SECRET || url.searchParams.get("secret") !== WEBHOOK_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }

  let payload: ApifyWebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response("invalid json body", { status: 400 });
  }

  const runId = payload.resource?.id ?? payload.eventData?.actorRunId;
  const datasetId = payload.resource?.defaultDatasetId;
  if (!runId || !datasetId) {
    return new Response("missing runId or datasetId", { status: 400 });
  }
  if (!APIFY_TOKEN) {
    return new Response("APIFY_TOKEN not configured", { status: 500 });
  }

  // 2. Fetch dataset items
  const resp = await fetch(
    `https://api.apify.com/v2/datasets/${datasetId}/items?token=${APIFY_TOKEN}&format=json&clean=true`,
  );
  if (!resp.ok) {
    return new Response(`apify dataset fetch failed: ${resp.status}`, { status: 502 });
  }
  const items: PostItem[] = await resp.json();

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  // 3. Log the run
  await sb.from("apify_runs").upsert(
    {
      run_id: runId,
      actor_name: "apify/facebook-posts-scraper",
      actor_id: payload.resource?.actId ?? null,
      dataset_id: datasetId,
      status: payload.resource?.status ?? "SUCCEEDED",
      started_at: payload.resource?.startedAt ?? null,
      finished_at: payload.resource?.finishedAt ?? null,
      item_count: items.length,
      input: payload.resource?.options?.input ?? null,
      ingest_summary: { posts: items.length, source: "edge-function" },
      notes: "Auto-ingested via ingest-fb-posts edge function",
    },
    { onConflict: "run_id" },
  );

  if (items.length === 0) {
    return new Response(JSON.stringify({ runId, posts: 0, note: "empty dataset" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  // 4. Upsert posts
  const postRows = items.map((it) => ({
    fb_post_id: it.postId,
    posted_at: it.time ?? null,
    text: it.text ?? null,
    url: it.url ?? null,
    top_level_url: it.topLevelUrl ?? null,
    likes_count: it.likes ?? null,
    comments_count: it.comments ?? null,
    shares_count: it.shares ?? null,
    top_reactions_count: it.topReactionsCount ?? null,
    reaction_like: it.reactionLikeCount ?? 0,
    reaction_love: it.reactionLoveCount ?? 0,
    reaction_care: it.reactionCareCount ?? 0,
    reaction_wow: it.reactionWowCount ?? 0,
    reaction_haha: it.reactionHahaCount ?? 0,
    reaction_sad: it.reactionSadCount ?? 0,
    reaction_angry: it.reactionAngryCount ?? 0,
    has_media: (it.media?.length ?? 0) > 0,
    feedback_id: it.feedbackId ?? null,
    source_run_id: runId,
    staging_author_fb_user_id: it.user?.id ?? null,
  }));

  const { error: upsertErr } = await sb
    .from("fb_posts")
    .upsert(postRows, { onConflict: "fb_post_id" });
  if (upsertErr) {
    return new Response(`fb_posts upsert failed: ${upsertErr.message}`, { status: 500 });
  }

  // 5. Resolve staging FKs + bump last_posts_pull_at + capture snapshots
  const { data: resolved, error: rpcErr } = await sb.rpc("resolve_fb_posts_staging", {
    run_id_param: runId,
  });
  if (rpcErr) {
    return new Response(`resolve_fb_posts_staging failed: ${rpcErr.message}`, { status: 500 });
  }

  return new Response(
    JSON.stringify({
      runId,
      posts_ingested: items.length,
      fks_resolved: resolved,
    }),
    { headers: { "Content-Type": "application/json" } },
  );
});
