// Scheduled scraper dispatcher.
//
// Invoked by pg_cron via pg_net.http_post with body { tier, job }.
// One Edge Function handles all jobs (A..E) — see JOB_CATALOG below.
//
// Pipeline per invocation:
//   1. Verify x-dispatch-secret header.
//   2. Budget gate: skip with status='skipped_budget' if today is paused
//      or spent_usd >= cap_usd.
//   3. Select targets (URLs, post IDs, watchlist entries) for the job.
//   4. Invoke the Apify actor; poll until terminal; fetch dataset.
//   5. Ingest into Supabase using the staging-FK pattern.
//   6. Log to cron_health, bump cron_budget.
//   7. Post-process: admit new posts to watchlist (B/C) or graduate
//      cold posts (E).
//   8. On any error: log status='error' and write a triage_inbox row.
//
// Required env (set via `supabase secrets set`):
//   APIFY_TOKEN
//   DISPATCH_SECRET                — shared secret in x-dispatch-secret header
//   SUPABASE_URL                   — auto-injected
//   SUPABASE_SERVICE_ROLE_KEY      — auto-injected

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.45.0";

// ─── Config ────────────────────────────────────────────────────────────────

const APIFY_TOKEN = Deno.env.get("APIFY_TOKEN");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DISPATCH_SECRET = Deno.env.get("DISPATCH_SECRET");

type Job = "A" | "B" | "C" | "D" | "E";

const JOB_CATALOG: Record<Job, { tier: 1 | 2 | 3; actor: string; description: string }> = {
  A: { tier: 1, actor: "premiumscraper/facebook-pages-profile-scraper",
       description: "Daily profile snapshot for all tracked profiles" },
  B: { tier: 2, actor: "apify/facebook-posts-scraper",
       description: "Self feed (mmetzmacher), 4×/day" },
  C: { tier: 2, actor: "apify/facebook-posts-scraper",
       description: "Peer feeds (somaticbizcoachdavid, hannahlisareuter1), 2×/day" },
  D: { tier: 2, actor: "apify/facebook-comments-scraper",
       description: "Comments harvest on posts <7d old, 1×/day" },
  E: { tier: 3, actor: "apify/facebook-posts-scraper",
       description: "Viral watchlist polling, every 15 min" },
};

const TRACKED = {
  self: "mmetzmacher",
  peers: ["somaticbizcoachdavid", "hannahlisareuter1"],
};

// ─── Helpers ───────────────────────────────────────────────────────────────

function todayUTC(): string {
  return new Date().toISOString().slice(0, 10);
}

function classifyError(e: unknown): string {
  const msg = String(e).toLowerCase();
  if (msg.includes("timeout") || msg.includes("timed out")) return "apify_timeout";
  if (msg.includes("402") || msg.includes("insufficient")) return "http_402";
  if (msg.includes("404")) return "http_404";
  if (/\b5\d\d\b/.test(msg)) return "http_5xx";
  if (msg.includes("parse") || msg.includes("json")) return "parse_fail";
  return "unknown";
}

async function getCronBudget(sb: SupabaseClient, day: string) {
  const { data } = await sb.from("cron_budget").select("*").eq("day", day).maybeSingle();
  if (data) return data;
  const { data: inserted } = await sb
    .from("cron_budget")
    .upsert({ day }, { onConflict: "day" })
    .select()
    .single();
  return inserted!;
}

async function bumpBudget(sb: SupabaseClient, day: string, costUsd: number) {
  // Read-modify-write. For higher contention, replace with a Postgres
  // function that does UPDATE cron_budget SET spent_usd = spent_usd + $1.
  const { data } = await sb.from("cron_budget").select("spent_usd").eq("day", day).single();
  await sb
    .from("cron_budget")
    .update({ spent_usd: (data?.spent_usd ?? 0) + (costUsd ?? 0) })
    .eq("day", day);
}

type HealthRow = {
  job: string;
  status: "queued" | "running" | "success" | "error" | "skipped_budget";
  finished_at?: string;
  apify_run_id?: string | null;
  dataset_id?: string | null;
  cost_usd?: number | null;
  items_in?: number | null;
  rows_written?: Record<string, number> | null;
  error_kind?: string | null;
  error_detail?: string | null;
  notes?: string | null;
};

async function logHealth(sb: SupabaseClient, row: HealthRow) {
  await sb.from("cron_health").insert({
    ...row,
    finished_at: row.finished_at ?? new Date().toISOString(),
  });
}

async function insertTriage(sb: SupabaseClient, args: { job: string; error: unknown }) {
  await sb.from("triage_inbox").insert({
    kind: "cron_error",
    data: { job: args.job, error: String(args.error) },
    reason: `Cron job ${args.job} failed: ${classifyError(args.error)}`,
    status: "pending",
  });
}

// ─── Apify ─────────────────────────────────────────────────────────────────

async function invokeActor(actor: string, input: unknown) {
  const url = `https://api.apify.com/v2/acts/${actor.replace("/", "~")}/runs?token=${APIFY_TOKEN}`;
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!r.ok) throw new Error(`apify invoke ${r.status}: ${await r.text()}`);
  const { data } = await r.json();
  return data as { id: string; defaultDatasetId: string; status: string };
}

async function pollUntilTerminal(runId: string, maxWaitMs = 240_000) {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    const r = await fetch(`https://api.apify.com/v2/actor-runs/${runId}?token=${APIFY_TOKEN}`);
    const { data: run } = await r.json();
    if (run.status === "SUCCEEDED") return run;
    if (["FAILED", "ABORTED", "TIMED-OUT"].includes(run.status)) {
      throw new Error(`apify run ${runId} terminated: ${run.status}`);
    }
    await new Promise((res) => setTimeout(res, 5_000));
  }
  throw new Error(`apify run ${runId} client-side polling timeout`);
}

async function fetchDataset(datasetId: string): Promise<unknown[]> {
  const url =
    `https://api.apify.com/v2/datasets/${datasetId}/items?token=${APIFY_TOKEN}` +
    `&format=json&clean=true`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`apify dataset ${datasetId}: ${r.status}`);
  return await r.json();
}

// ─── Target selection ──────────────────────────────────────────────────────

async function selectTargets(sb: SupabaseClient, job: Job): Promise<string[]> {
  switch (job) {
    case "A":
      return [TRACKED.self, ...TRACKED.peers].map((u) => `https://www.facebook.com/${u}`);
    case "B":
      return [`https://www.facebook.com/${TRACKED.self}`];
    case "C":
      return TRACKED.peers.map((u) => `https://www.facebook.com/${u}`);
    case "D": {
      const sevenDaysAgo = new Date(Date.now() - 7 * 86_400_000).toISOString();
      const { data } = await sb
        .from("fb_posts")
        .select("url, fb_profiles!inner(username)")
        .gt("posted_at", sevenDaysAgo)
        // deno-lint-ignore no-explicit-any
        .in("fb_profiles.username" as any, [TRACKED.self, ...TRACKED.peers])
        .limit(50);
      return (data ?? []).map((r: { url: string | null }) => r.url).filter(Boolean) as string[];
    }
    case "E": {
      const { data } = await sb
        .from("fb_post_watchlist")
        .select("post_id, fb_posts!inner(url)")
        .is("graduated_at", null)
        .limit(5);
      // deno-lint-ignore no-explicit-any
      return (data ?? []).map((r: any) => r.fb_posts?.url).filter(Boolean) as string[];
    }
  }
}

// ─── Actor input shape ────────────────────────────────────────────────────

function buildInput(job: Job, urls: string[]): unknown {
  switch (job) {
    case "A":
      // premiumscraper/facebook-pages-profile-scraper:
      // accepts `facebook_urls: [{url}]` or `username: [...]`
      return { facebook_urls: urls.map((url) => ({ url })) };
    case "B":
    case "C":
      return {
        startUrls: urls.map((url) => ({ url })),
        captionText: false,
        resultsLimit: 10,
      };
    case "D":
      return {
        startUrls: urls.map((url) => ({ url })),
        viewOption: "RANKED_THREADED",
        resultsLimit: 200,
        includeNestedComments: true,
      };
    case "E":
      return {
        startUrls: urls.map((url) => ({ url })),
        captionText: false,
        resultsLimit: 1,
      };
  }
}

// ─── Ingest dispatch ──────────────────────────────────────────────────────

async function ingest(
  sb: SupabaseClient,
  job: Job,
  items: unknown[],
  runId: string,
): Promise<Record<string, number>> {
  switch (job) {
    case "A":
      return await ingestProfileSnapshots(sb, items, runId);
    case "B":
    case "C":
    case "E":
      return await ingestPosts(sb, items, runId);
    case "D":
      return await ingestComments(sb, items, runId);
  }
}

// TODO — implement per the staging-FK pattern documented in
// docs/database/schema.md and the handbook v3 quirks. Each function
// returns a {table_name: rows_written} map for cron_health.rows_written.

async function ingestProfileSnapshots(
  _sb: SupabaseClient,
  _items: unknown[],
  _runId: string,
): Promise<Record<string, number>> {
  // Map each item (one per profile) to:
  //   1. UPDATE fb_profiles SET followers_count, page_likes, bio, ...
  //      last_profile_scrape_at = now() WHERE username = item.username;
  //   2. INSERT INTO fb_profile_snapshots (profile_id, captured_at, ...);
  throw new Error("TODO: implement ingestProfileSnapshots");
}

async function ingestPosts(
  _sb: SupabaseClient,
  _items: unknown[],
  _runId: string,
): Promise<Record<string, number>> {
  // Same shape as the v1 ingest-fb-posts function: bulk UPSERT fb_posts
  // with staging_author_fb_user_id, then call rpc('resolve_fb_posts_staging',
  // { run_id_param }) — this resolves the FK, bumps last_posts_pull_at,
  // and writes the engagement snapshot in one call.
  throw new Error("TODO: implement ingestPosts");
}

async function ingestComments(
  _sb: SupabaseClient,
  _items: unknown[],
  _runId: string,
): Promise<Record<string, number>> {
  // 1. UPSERT unique commenters into fb_profiles (ON CONFLICT DO NOTHING).
  // 2. For each item: if threadingDepth > 0, extract reply_comment_id
  //    from commentUrl ?reply_comment_id=... as fb_comment_id.
  //    Otherwise use commentId. (See handbook v3 §"comments scraper reuses
  //    commentId for replies".)
  // 3. UPSERT fb_comments with staging columns; then UPDATE to resolve.
  throw new Error("TODO: implement ingestComments");
}

// ─── Watchlist post-processing ────────────────────────────────────────────

async function admitNewPostsToWatchlist(
  _sb: SupabaseClient,
  _items: unknown[],
): Promise<void> {
  // Admit when: post < 24h old AND from tracked profile, OR
  //   likes_per_min > 0.5 sustained ≥ 2 polls (needs engagement snapshots).
  // Cap at 5 active rows.
  // TODO: implement
}

async function graduateColdPosts(_sb: SupabaseClient): Promise<void> {
  // Graduate when: 48h since publish, OR likes_per_min < 0.1 for 2 polls.
  // UPDATE fb_post_watchlist SET graduated_at = now(), graduate_reason = ...
  //   WHERE graduated_at IS NULL AND (... criteria ...);
  // TODO: implement
}

// ─── Handler ──────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  if (!DISPATCH_SECRET || req.headers.get("x-dispatch-secret") !== DISPATCH_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }
  if (!APIFY_TOKEN) {
    return new Response("APIFY_TOKEN not configured", { status: 500 });
  }

  let body: { tier?: number; job?: Job };
  try {
    body = await req.json();
  } catch {
    return new Response("invalid json", { status: 400 });
  }

  const job = body.job;
  if (!job || !JOB_CATALOG[job]) {
    return new Response(`unknown job: ${job}`, { status: 400 });
  }

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  const today = todayUTC();

  // 1. Budget gate
  const budget = await getCronBudget(sb, today);
  if (budget.paused || budget.spent_usd >= budget.cap_usd) {
    await logHealth(sb, {
      job,
      status: "skipped_budget",
      notes:
        `gate: spent=${budget.spent_usd} cap=${budget.cap_usd} paused=${budget.paused}`,
    });
    return new Response(JSON.stringify({ skipped: "budget" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  // 2. Targets
  const targets = await selectTargets(sb, job);
  if (targets.length === 0) {
    await logHealth(sb, { job, status: "success", notes: "no targets to scrape" });
    return new Response(JSON.stringify({ noop: "no targets" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  // 3. Run + ingest
  try {
    const run = await invokeActor(JOB_CATALOG[job].actor, buildInput(job, targets));
    const terminal = await pollUntilTerminal(run.id);
    const items = await fetchDataset(terminal.defaultDatasetId);
    const rowsWritten = await ingest(sb, job, items, run.id);
    // deno-lint-ignore no-explicit-any
    const cost = (terminal as any).usageTotalUsd ?? 0;

    await bumpBudget(sb, today, cost);
    await logHealth(sb, {
      job,
      status: "success",
      apify_run_id: run.id,
      dataset_id: terminal.defaultDatasetId,
      cost_usd: cost,
      items_in: items.length,
      rows_written: rowsWritten,
    });

    // 4. Post-process
    if (job === "B" || job === "C") await admitNewPostsToWatchlist(sb, items);
    if (job === "E") await graduateColdPosts(sb);

    return new Response(
      JSON.stringify({ ok: true, job, items: items.length, cost }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (e) {
    await logHealth(sb, {
      job,
      status: "error",
      error_kind: classifyError(e),
      error_detail: String(e).slice(0, 500),
    });
    await insertTriage(sb, { job, error: e });
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
