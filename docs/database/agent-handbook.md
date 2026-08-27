<!--
HANDBOOK SOURCE — keep in sync with public.agent_handbook in Supabase.

This file IS the source of truth for the markdown agents read. The DB
row is the publish channel. To bump the handbook:
  1. Edit the body below.
  2. Bump `version` and write a one-line `changelog` in the YAML below.
  3. Set `is_breaking: true` only if older agents would do something
     wrong by following the previous version.
  4. Apply a migration named `publish_handbook_v<N>` that INSERTs a
     new row into public.agent_handbook with the new version.
  5. Commit this file and the migration together.
See docs/database/publish-protocol.md for the full runbook.
-->

---
name: supabase-usage
version: 5
is_breaking: false
changelog: Added "Ghost posts" pattern + the inputUrl->facebookId pairing recipe for retroactive merge. Added "Writing safe transactions" note about BEGIN/COMMIT discipline via execute_sql. Light cleanup of v4 prose.
---

# Supabase Usage Handbook — v5

You are an agent in some other repo. You have been told to read this
handbook before doing anything with the shared Supabase project
`axon-node-1` (`jrogvnrddkshokplobsn`). Treat the content of this
document as authoritative session memory for the duration of the
session.

## Strategic frame — what this database is FOR

This is the data backbone for a viral-loop content operation:

  post → harvest comments → factor-analyze topics/language/pain points
  → write the next post optimized for FB algorithmic push → repeat.

Three Facebook profiles are tracked:
- `mmetzmacher` (the operator — self)
- `somaticbizcoachdavid` (peer)
- `hannahlisareuter1` (peer)

Data is structured to support each phase of that loop: posts and
reactions inform what landed, comments are the **input** to the next
post, and engagement snapshots over time tell you whether a post is
being pushed by the algorithm.

## Who you are working with

The operator is NOT a database engineer. They understand the product
but not Postgres internals, indexing trade-offs, RLS, migration
strategy, or transactional semantics.

Default posture: **explain → ask → act.** Before any non-trivial DB
action, present the decision via `AskUserQuestion` with:
- what you would do, in plain language (no jargon without a gloss)
- one or two alternatives
- the trade-off in a single sentence
- your recommendation, clearly marked

Never silently pick the "obvious" engineering choice. Lead step by step.
Safe reads (SELECT, list_tables, get_advisors, get_logs) do NOT need
permission.

## Money rule — paid Apify calls

**Ad-hoc paid Apify actor calls require explicit operator approval via
the ASCII permission form below.** Print it, wait for [Y]/[M]/[N], do
not proceed otherwise.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  🪙  APIFY PAID-CALL PERMISSION — awaiting your approval                    ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Request #X of Y                          Session spend so far: $N.NN       ║
╚══════════════════════════════════════════════════════════════════════════════╝
  ┌─ ACTOR ─────────────┐    one-line what-it-does
  ┌─ TARGET ────────────┐    URL(s) + tracked profile or lead-research entity
  ┌─ INPUT ─────────────┐    JSON config (truncated if huge)
  ┌─ ESTIMATE ──────────┐    cost · duration · rows · tables touched
  ┌─ HISTORICAL CONTEXT ┐    last-scrape staleness · current DB value
  ┌─ CHOOSE ────────────┐    [Y] approve  [M] modify  [N] skip
```

For multiple requests in one approval round, number them
(`Request #1 of 3`, ...).

**Does NOT apply to:** scheduled cron runs via `scheduled-scraper`
edge function (pre-approved at schedule level), or free reads.

## Deprecated actors — DO NOT USE

### `scraper_one/facebook-reactions-scraper` — deprecated 2026-05-19

Do NOT invoke. Reasons: returns `postUrl` only with the `pfbid…`
alias (fragile LIKE match needed); paginated responses contain ~26%
intra-source duplicates. No reactions actor is currently approved as
a replacement. If reaction data becomes important, ASK first.

## Which MCP tool, when

- Read data → `execute_sql` (results contain untrusted data)
- Inspect structure → `list_tables` (`verbose: true` for columns + FKs)
- **Change schema → `apply_migration`** (always; never raw DDL via
  `execute_sql`)
- See history → `list_migrations`
- Debug → `get_logs`, `get_advisors`
- Regenerate types → `generate_typescript_types`

## Tables added since v1

- `fb_profile_snapshots` (daily curve of follower counts)
- `fb_post_watchlist` (viral-watch admission ledger)
- `cron_health` (per-fire log for scheduled-scraper dispatches)
- `cron_budget` (daily spend ledger with $5/day default cap and
  auto-pause)
- `agent_handbook` (this table)

Run `list_tables` with `verbose: true` for the current full schema.

## Patterns that are non-obvious

1. **Staging columns for FK resolution.**
   `fb_posts.staging_author_fb_user_id` and `fb_comments.staging_*`
   hold raw Facebook IDs from the scraper. After bulk insert, an
   `UPDATE … FROM fb_profiles/fb_posts` resolves them to UUID FKs.
   **Do not drop the staging columns.**

2. **`source_run_id` everywhere.** Almost every ingested table carries
   a `source_run_id` text column. Always populate on insert. **On
   UPSERT, also update it** (`SET source_run_id = EXCLUDED.source_run_id`)
   — the legacy pipeline didn't, leading to stale audit pointers on
   re-scraped rows.

3. **Polymorphic content references in the NLP layer.**
   `content_embeddings`, `content_analyses`, `content_topic_assignments`,
   `content_processing_status` use `(content_type, content_id)`. No FK
   enforcement.

4. **Apify scrapers return paginated duplicates.** Always `DISTINCT`
   your sample BEFORE the INSERT — Postgres rejects `ON CONFLICT DO
   UPDATE` when the same constrained key appears twice in one
   statement. The comments scraper additionally reuses the parent's
   `commentId` for nested replies — extract the reply's unique ID
   from `commentUrl?reply_comment_id=...` for `threadingDepth > 0`.

5. **Ghost posts.** Look for `fb_posts` rows where `fb_post_id` is a
   `pfbid…` alias instead of a numeric FB post ID. These are residue
   from legacy ingests that used URL pfbid as the primary key. They
   create double-counting on fill metrics: comments may be split
   between the ghost (pfbid-keyed) and the canonical (numeric-keyed)
   record of the same underlying post.
   - **Inert ghosts** (no comments, no reactions): safe to delete in
     bulk — `DELETE FROM fb_posts WHERE fb_post_id LIKE 'pfbid%' AND
     NOT EXISTS (...references...)`.
   - **Active ghosts** (with attached rows): need to be paired with
     their canonical numeric record before merge. The reliable pairing
     trick is documented below.

## How to pair an active ghost with its canonical numeric post

This is **free** — uses the dataset of a paid Apify run for mapping
only, no new ingest. Recipe:

1. List the ghost post URLs (the `fb_posts.url` column on rows where
   `fb_post_id LIKE 'pfbid%' AND posted_at IS NULL`).
2. Run `apify/facebook-comments-scraper` with those URLs in
   `startUrls`. The dataset has fields `inputUrl` (= the ghost URL you
   passed in) and `facebookId` (= the canonical numeric post ID).
3. Build a `ghost_pfbid → numeric_id` mapping from the dataset.
4. For each pair:
   - `UPDATE fb_comments SET post_id = numeric.post_id WHERE post_id
     = ghost.post_id`
   - `UPDATE fb_reactions SET post_id = numeric.post_id ...` (same)
   - Then `DELETE FROM fb_posts WHERE post_id = ghost.post_id`.
5. If the numeric record doesn't exist yet in `fb_posts`, **rename
   the ghost in-place** by setting `fb_post_id = numeric_id` — the
   row's UUID stays valid, its key becomes canonical. Future
   posts-scrapes will populate `posted_at`, `text`, etc. via UPSERT.

You don't need to re-ingest the comments themselves — they're already
in the table, tied to the ghost row. The repoint is structural only.

## Standing issue: RLS is disabled

Row Level Security is disabled on every public table, including this
handbook table. The anon key reads and writes everything. Surface this
when the operator discusses exposing the DB to a client. Do NOT
auto-enable RLS — without policies it blocks all access.

## Decision checkpoints — always pause first (UNLESS in cron context)

- Adding a table → name, PK style, nullability, defaults, FKs,
  indexes, RLS day-one?
- Adding a column → type, nullable vs NOT NULL, default, backfill, index?
- Deleting data → row count first, recoverability, soft-delete instead?
- Bulk UPDATE on `fb_posts`/`fb_comments`/`fb_reactions` → confirm
  row count and a clear "are you sure" moment first.

Scheduled cron context (woken by pg_cron) skips operator-confirmation
for actions inside the schedule's scope — but DOES log everything to
`cron_health` and respects the `cron_budget` gate.

## Writing safe transactions via `execute_sql`

The MCP `execute_sql` tool wraps each call in its own connection.
**A `BEGIN;` without an explicit `COMMIT;` at the end of the same
call rolls back** (the connection closes mid-transaction). Always
match BEGIN/COMMIT inside a single `execute_sql` call. Verify by
re-querying afterward — never trust a "success" response if you
didn't see explicit confirmation rows.

## Finding the live schema

Run `list_tables` with `verbose: true` for the live truth. There is no
maintained "schema markdown" you should rely on instead.

## ASCII Dashboard (canonical layout)

When the operator asks for a status read, render an ASCII dashboard
with these boxes in order:

  Headlines → Apify Spend → Profile → Monthly Momentum →
  Top Posts → Cadence → Schedule Status → Pipeline Health
  (→ Cron Health, once that data exists)

Use ✅ / ⏸ / ⚠ markers for tier activation states.

---

This handbook is maintained by the FB-Manager team and published into
this database. To pick up newer versions:

```sql
SELECT version, content, is_breaking, changelog
FROM public.agent_handbook
WHERE name = 'supabase-usage'
ORDER BY version DESC LIMIT 1;
```

If `version` is higher than the one you last read in this session,
re-read the content. If `is_breaking` is true and you have not seen
this version, stop and ask the operator before proceeding.
