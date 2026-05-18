# Database Schema Reference

Project `axon-node-1` (`jrogvnrddkshokplobsn`), Postgres 17, schema
`public`. Last verified 2026-05-18 against the live database.

> **⚠ Security: RLS is disabled on every public table.** Anyone with the
> Supabase anon key can read or modify every row. Do not paste the anon
> key into client-facing code without first enabling RLS and writing
> policies. Remediation SQL lives at the bottom of this file.

## Installed extensions (public-relevant)

| Extension          | Schema       | Why it's here                              |
|--------------------|--------------|--------------------------------------------|
| `vector` 0.8.0     | `public`     | pgvector embeddings (1536 + 3072 dim)      |
| `pgcrypto` 1.3     | `extensions` | `gen_random_uuid()` defaults               |
| `uuid-ossp` 1.1    | `extensions` | UUID helpers                               |
| `pg_stat_statements` 1.11 | `extensions` | Query statistics                      |
| `supabase_vault` 0.3.1    | `vault`      | Supabase secret storage              |
| `plpgsql` 1.0      | `pg_catalog` | (default)                                  |

All other extensions are **available** but not installed.

## Enums

| Enum                   | Values                                              |
|------------------------|-----------------------------------------------------|
| `profile_role`         | `self`, `tracked`, `audience`                       |
| `reaction_kind`        | `like`, `love`, `care`, `haha`, `wow`, `sad`, `angry`, `support` |
| `comment_queue_status` | `draft`, `approved`, `posted`, `skipped`, `failed`  |
| `triage_status`        | `pending`, `reviewed`, `resolved`, `discarded`      |

## Functional groups

The 22 tables fall into six clusters:

1. **Facebook intelligence core** — what the product is about.
2. **Ingestion & staging pipeline** — how data arrives and gets cleaned.
3. **Lead enrichment** — places, contacts, emails, screenshots.
4. **NLP / ML layer** — embeddings, sentiment, topic clusters
   (scaffolded, 0 rows today).
5. **Operational / workflow** — comment queue, triage inbox, briefings,
   experiments, engagement snapshots.
6. **Agent coordination** — `agent_handbook`, the versioned
   propagation channel for telling agents in other repos how to use
   this database (see `docs/database/publish-protocol.md`).

---

## 1. Facebook intelligence core

### `fb_profiles` — 9,099 rows

People and pages observed on Facebook.

| Column                    | Type           | Notes                                    |
|---------------------------|----------------|------------------------------------------|
| `profile_id` PK           | uuid           | `gen_random_uuid()` default              |
| `fb_user_id` UNIQUE       | text           | FB-native ID (numeric or `pfbid…`)       |
| `username`                | text           | indexed                                  |
| `display_name`            | text           |                                          |
| `profile_url`             | text           |                                          |
| `role`                    | `profile_role` | default `audience`; indexed              |
| `is_verified`             | bool           |                                          |
| `category`                | text           |                                          |
| `bio`, `description`      | text           |                                          |
| `followers_count`         | int4           |                                          |
| `following_count`         | int4           |                                          |
| `page_likes`              | int4           |                                          |
| `profile_picture_url`     | text           |                                          |
| `cover_photo_url`         | text           |                                          |
| `gender`                  | text           |                                          |
| `creation_date_text`      | text           |                                          |
| `last_profile_scrape_at`  | timestamptz    |                                          |
| `first_seen_at`           | timestamptz    | default `now()`                          |
| `raw_metadata`            | jsonb          |                                          |
| `notes`                   | text           |                                          |
| `last_posts_pull_at`      | timestamptz    | last posts-scraper run for this timeline |

Referenced by: `fb_posts.author_profile_id`,
`fb_comments.commenter_profile_id`, `fb_reactions.reactor_profile_id`,
`fb_photos.owner_profile_id`, `fb_content_experiments.author_profile_id`,
`creator_briefings.profile_id`.

### `fb_posts` — 1,374 rows

Posts authored by, or shared by, a tracked profile.

Key columns: `post_id` PK, `fb_post_id` UNIQUE, `author_profile_id` FK →
`fb_profiles`, `posted_at`, `text`, `url`, `top_level_url`, `language`,
`language_detected_by`, engagement counts (`likes_count`,
`comments_count`, `shares_count`, `top_reactions_count`, plus per-reaction
columns: `reaction_like`/`love`/`care`/`wow`/`haha`/`sad`/`angry`),
`has_media` (bool, default false), `media` jsonb, `feedback_id`,
`raw_data` jsonb, `source_run_id` text, `first_seen_at` (default
`now()`), `is_shared_post` (bool, default false),
`staging_author_fb_user_id` (text, resolved to `author_profile_id` via
`UPDATE … FROM fb_profiles`).

Indexes: `fb_posts_pkey`, `fb_posts_fb_post_id_key` (unique),
`ix_fb_posts_author`, `ix_fb_posts_posted_at DESC`, `ix_fb_posts_url`.

### `fb_comments` — 13,370 rows

Comments and replies. `parent_comment_id` is self-referential for
threading.

Key columns: `comment_id` PK, `fb_comment_id` UNIQUE,
`post_id` FK → `fb_posts`, `parent_comment_id` FK → `fb_comments`,
`commenter_profile_id` FK → `fb_profiles`, `text`, `posted_at`,
`likes_count`, `threading_depth` (default 0), `language`,
`language_detected_by`, `comment_url`, `raw_data`, `source_run_id`,
`first_seen_at` (default `now()`),
plus three staging columns for FK resolution:
`staging_parent_fb_comment_id`, `staging_commenter_fb_user_id`,
`staging_post_fb_id`.

Indexes: pkey, `fb_comments_fb_comment_id_key` (unique),
`ix_fb_comments_post`, `ix_fb_comments_commenter`,
`ix_fb_comments_parent`.

### `fb_reactions` — 2,847 rows

One row per (post, reactor) — `(post_id, reactor_profile_id)` is unique.

Key columns: `reaction_id` PK, `post_id` FK → `fb_posts`,
`reactor_profile_id` FK → `fb_profiles`, `reaction_type` (`reaction_kind`
enum), `reaction_icon_url`, `raw_data`, `source_run_id`, `first_seen_at`,
`staging_reactor_fb_user_id`.

Indexes: pkey, `fb_reactions_post_reactor_unique`, `ix_fb_reactions_post`,
`ix_fb_reactions_reactor`, `ix_fb_reactions_type`.

### `fb_photos` — 300 rows

Photo metadata.

Columns: `photo_id` PK, `fb_photo_id` UNIQUE, `owner_profile_id` FK →
`fb_profiles`, `photo_type`, `image_url`, `thumbnail_url`, `image_width`,
`image_height`, `caption`, `post_url`, `raw_data`, `source_run_id`,
`first_seen_at`. Indexed on `owner_profile_id`.

---

## 2. Operational / workflow (FB-related)

### `fb_post_engagement_snapshots` — 15 rows

Time-series snapshots of post engagement; insert one row per scraper run.
Deltas are derived at query time via `LAG()` (see the view below).

Columns: `snapshot_id` PK, `post_id` FK → `fb_posts`, `captured_at`
(default `now()`), all per-reaction and aggregate counts mirrored from
`fb_posts`, `source_run_id`, `notes`.

Indexes: pkey, `idx_engagement_post_time (post_id, captured_at DESC)`,
`idx_engagement_captured_at (captured_at DESC)`.

### `fb_content_experiments` — 1 row

Long-running ledger of content experiments. Each post is a hypothesis
test against a baseline post; positive/negative modifiers accumulate as
patterns across many experiments.

Columns: `experiment_id` PK, `created_at`, `published_at`, `status` (CHECK
in `{draft, scheduled, published, measuring, concluded, abandoned}`,
default `draft`), `post_id` FK → `fb_posts`, `author_profile_id` FK →
`fb_profiles`, `baseline_post_id` FK → `fb_posts`, `hypothesis`,
`prediction`, `primary_modifier`, `secondary_modifiers` jsonb,
`measurement_hours` (default 24), `outcomes` jsonb, `conclusion`,
`positive_modifiers` jsonb, `negative_modifiers` jsonb, `notes`.

### `creator_briefings` — 1 row

Markdown briefings generated by the `fb-creator-briefing` skill. Unique
on `(profile_id, briefing_date)`.

Columns: `briefing_id` PK, `profile_id` FK → `fb_profiles`,
`briefing_date` (date, default `CURRENT_DATE`), `title`, `markdown`,
`summary` jsonb (dominant_mode, top_post_ids, mode_distribution),
`data_window` jsonb, `created_at`.

### `comment_queue` — 16 rows

AI-drafted replies awaiting approval and posting.

Columns: `queue_id` PK, `post_id` FK → `fb_posts`, `draft_text`,
`draft_model`, `draft_rationale`, `final_text`, `status`
(`comment_queue_status` enum, default `draft`), `priority` (default 0),
`drafted_at`, `reviewed_at`, `posted_at`, `notes`, `parent_comment_id` FK
→ `fb_comments`.

Notable: partial unique index
`comment_queue_one_active_per_target` on `(post_id,
COALESCE(parent_comment_id, '0000…'))` `WHERE status IN ('draft',
'approved')` — prevents two open drafts targeting the same post/thread.

---

## 3. Ingestion & staging pipeline

### `apify_runs` — 229 rows

Run ledger for every Apify actor invocation.

Columns: `run_id` PK (text), `actor_name`, `actor_id`, `dataset_id`,
`kv_store_id`, `status`, `started_at`, `finished_at`, `cost_usd`, `input`
jsonb, `item_count`, `ingested_at` (default `now()`), `ingest_summary`
jsonb, `notes`. Indexed on `actor_name` and `started_at DESC`.

Referenced by: `triage_inbox.source_run_id`.

### `triage_inbox` — 947 rows

Items pulled from a run that need human review (unresolved FKs,
duplicates, suspect records).

Columns: `item_id` PK, `source_run_id` FK → `apify_runs`, `kind`, `data`
jsonb, `reason`, `status` (`triage_status` enum, default `pending`),
`resolved_to`, `notes`, `created_at`, `reviewed_at`. Indexed on `kind`,
`status`, `created_at DESC`.

---

## 4. Lead enrichment

### `places` — 100 rows

Google Maps businesses.

Columns: `place_id` PK, `google_place_id` UNIQUE, `cid`, `name`,
`category_name`, `categories` text[], `address`, `street`, `city`,
`postal_code`, `country_code`, `latitude`, `longitude`, `phone`,
`phone_international`, `website`, `reviews_count`, `total_score`,
`claimed_business`, `permanently_closed`, `business_industry`,
`google_url`, `raw_data`, `source_run_id`, `first_seen_at`.

Indexes: pkey, `places_google_place_id_key`, `ix_places_city`,
`ix_places_category`, `ix_places_website`.

### `web_contacts` — 94 rows

Domain-keyed contact pulls.

Columns: `contact_id` PK, `domain` UNIQUE, `url`, `emails` text[],
`phones` text[], `social_links` jsonb, `business_industry`,
`business_keywords` text[], `tech_signals` jsonb, `tracking_tags` jsonb,
`email_pattern`, `email_pattern_confidence`, `score`, `grade`,
`place_id` FK → `places`, `raw_data`, `source_run_id`, `first_seen_at`.

### `email_verifications` — 81 rows

Per-address deliverability checks (PK = `email`).

Columns: `email` PK, `domain`, `status`, `technical_status`, `score`,
`reason`, `is_free`, `is_role`, `is_disposable`, `is_catch_all`,
`has_tag`, `verification_details` jsonb, `raw_data`, `source_run_id`,
`verified_at`. Indexed on `domain` and `status`.

### `web_pages` — 20 rows

Crawled page metadata + markdown.

Columns: `page_id` PK, `url` UNIQUE, `redirected_url`, `title`,
`language_code`, `markdown`, `http_status`, `source_query`,
`raw_metadata`, `raw_crawl`, `source_run_id`, `fetched_at`. Indexed on
`language_code`.

### `screenshots` — 1 row

Page screenshots captured during crawls.

Columns: `screenshot_id` PK, `source_url`, `screenshot_url`,
`screenshot_key`, `source_run_id`, `raw_data`, `taken_at`.

---

## 4a. Agent coordination

### `agent_handbook` — 3 rows

Append-only table that publishes instructions from this repo to Claude
agents in **other** repos. They query `MAX(version) WHERE name=…` at
session start and treat `content` as authoritative session memory.
Current names: `supabase-usage` (v2 latest) and `bootstrap-snippet`
(v1, the paste-in markdown for wiring up new repos — retrievable from
any Supabase session so the operator does not need to clone this
repo).

Columns: `id` PK (uuid, default `gen_random_uuid()`), `name` (text —
which handbook; first one is `supabase-usage`), `version` (int —
monotonically increasing per `name`), `content` (text — the markdown
agents read), `changelog` (text — one line per version),
`is_breaking` (bool, default false — when true, agents should stop and
ask the operator before adopting the new version), `published_at`
(timestamptz, default `now()`).

Unique on `(name, version)`; secondary index
`ix_agent_handbook_latest (name, version DESC)` for the
`ORDER BY version DESC LIMIT 1` lookup pattern.

The source-of-truth markdown for the current handbook lives at
`docs/database/agent-handbook.md`. The publish runbook is at
`docs/database/publish-protocol.md`.

---

## 5. NLP / ML layer (scaffolded, 0 rows)

The NLP tables use a **polymorphic content reference** —
`(content_type, content_id)` where `content_type ∈ {fb_comment, fb_post,
fb_profile_bio, messenger_msg, other}` — instead of typed foreign keys.

### `content_embeddings`

`id` PK, `(content_type, content_id, model_name)` UNIQUE, `model_name`,
`model_version`, `embedding_1536 vector(1536)`,
`embedding_3072 vector(3072)`, `embedded_text`, `embedded_text_hash`,
`created_at`, `source_run_id`.

Indexes: pkey, unique on `(content_type, content_id, model_name)`,
btree on `(content_type, content_id)`, btree on `model_name`, btree on
`embedded_text_hash`, **HNSW** on `embedding_1536` with
`vector_cosine_ops` (partial: `WHERE embedding_1536 IS NOT NULL`).

### `content_analyses`

`id` PK, polymorphic `(content_type, content_id)`, `analysis_type ∈
{sentiment, language, entities, topic, toxicity, intent, custom}`,
`model_name`, `model_version`, `result` jsonb, `confidence`,
`analyzed_text_hash`, `created_at`, `source_run_id`.
Unique on `(content_type, content_id, analysis_type, model_name)`.
GIN index on `result`.

### `topic_clusters`

`id` PK, `cluster_label`, `description`, `keywords` text[], `created_at`,
`model_run_id`, `metadata` jsonb.

### `content_topic_assignments`

`id` PK, polymorphic content reference, `cluster_id` FK →
`topic_clusters`, `similarity`, `is_primary` (default false),
`created_at`. Unique on `(content_type, content_id, cluster_id)`.

### `content_processing_status`

Per-(content, processor) job state.

`id` PK, polymorphic content reference, `processor ∈ {embedding,
sentiment, language, entities, topic, toxicity}`, `status ∈ {pending,
processing, done, error, stale}`, `processed_text_hash`,
`last_attempted_at`, `completed_at`, `error_message`, `attempts`
(default 0). Unique on `(content_type, content_id, processor)`. Partial
index on `(processor, status)` `WHERE status IN ('pending', 'error',
'stale')` for fast queue scans.

---

## Views

### `fb_post_engagement_velocity`

Derives per-snapshot deltas and per-minute rates from
`fb_post_engagement_snapshots` using `LAG()` over `(PARTITION BY post_id
ORDER BY captured_at)`.

Exposes: `snapshot_id, post_id, captured_at, likes_count,
comments_count, shares_count, reaction_{like,love,care,wow},
d_likes, d_comments, d_shares, minutes_since_prev, likes_per_min,
comments_per_min, source_run_id`.

---

## Functions

No project-specific functions today. The `public` schema contains a
trigger helper `set_updated_at()` and the full pgvector function set
(distance/normalize/cast operators for `vector`, `halfvec`, `sparsevec`).

---

## Foreign key map (round-up)

```
fb_profiles.profile_id  ←  fb_posts.author_profile_id
                        ←  fb_comments.commenter_profile_id
                        ←  fb_reactions.reactor_profile_id
                        ←  fb_photos.owner_profile_id
                        ←  fb_content_experiments.author_profile_id
                        ←  creator_briefings.profile_id

fb_posts.post_id        ←  fb_comments.post_id
                        ←  fb_reactions.post_id
                        ←  fb_post_engagement_snapshots.post_id
                        ←  fb_content_experiments.post_id
                        ←  fb_content_experiments.baseline_post_id
                        ←  comment_queue.post_id

fb_comments.comment_id  ←  fb_comments.parent_comment_id   (self)
                        ←  comment_queue.parent_comment_id

places.place_id         ←  web_contacts.place_id

apify_runs.run_id       ←  triage_inbox.source_run_id

topic_clusters.id       ←  content_topic_assignments.cluster_id
```

Note: `source_run_id` exists on many tables (`fb_posts`, `fb_comments`,
`fb_reactions`, `fb_photos`, `places`, `web_contacts`, `web_pages`,
`screenshots`, `email_verifications`, `content_embeddings`,
`content_analyses`, `fb_post_engagement_snapshots`, `topic_clusters`)
but is **not** a hard FK to `apify_runs` everywhere — types differ (text
vs uuid in the embeddings tables) and constraints are not enforced. Join
opportunistically.

---

## Security advisory (Supabase)

**RLS is disabled on all 22 public tables.** Remediation SQL (enabling
RLS without writing policies will block all anon/authenticated access —
add policies first):

```sql
ALTER TABLE public.content_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_analyses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.topic_clusters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_topic_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_processing_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.places ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_pages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.screenshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.apify_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.triage_inbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comment_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_post_engagement_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fb_content_experiments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_briefings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_handbook ENABLE ROW LEVEL SECURITY;
```

> Note for `agent_handbook`: when RLS is eventually designed, the
> `SELECT` policy must be permissive for `anon` and `authenticated`,
> otherwise external agents lose access to the handbook entirely.

Reference: https://supabase.com/docs/guides/database/postgres/row-level-security
