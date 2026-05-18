# Database — Quick Start for Future Sessions

This is the entry point for any Claude session that needs to read or write
the FB-Manager Supabase database. Read this first; it tells you what the
database is, how to connect to it, and where the detailed schema lives.

## What this database is

A Postgres 17 database hosted on Supabase. It stores Facebook intelligence
data (profiles, posts, comments, reactions, photos), the Apify scraping
pipeline that ingests it, a manual triage/review workflow, lead-enrichment
data (places, web contacts, email verifications), and a scaffolded
NLP layer (embeddings, sentiment, topic clusters).

Most rows arrive via Apify actor runs. Each ingested row carries a
`source_run_id` pointing back to `public.apify_runs`.

## Project coordinates

| Field             | Value                                          |
|-------------------|------------------------------------------------|
| Project name      | `axon-node-1`                                  |
| Project ref / ID  | `jrogvnrddkshokplobsn`                         |
| Region            | `eu-central-1`                                 |
| Postgres version  | `17.6.1.121`                                   |
| API URL           | `https://jrogvnrddkshokplobsn.supabase.co`     |
| DB host           | `db.jrogvnrddkshokplobsn.supabase.co`          |

API keys are **not** committed. Fetch them at session start with
`mcp__supabase__get_publishable_keys` (publishable / anon) or from the
Supabase dashboard (service role).

## How to query the database

In an MCP-enabled session you have a Supabase server attached (tool prefix
`mcp__887846af-6712-4a01-93a9-fb38519888be__` — search for it with
`ToolSearch` if the schemas are not loaded). The tools you will use most:

| Tool                         | Use it for                                            |
|------------------------------|-------------------------------------------------------|
| `list_projects`              | Confirm the project ID if it ever changes             |
| `list_tables`                | Re-derive the schema (set `verbose: true` for columns)|
| `execute_sql`                | Reads + ad-hoc analytics (returns untrusted data)     |
| `apply_migration`            | DDL changes — versioned and tracked by Supabase       |
| `list_migrations`            | See what migrations have been applied                 |
| `get_logs`                   | Debug API / Postgres / auth issues                    |
| `get_advisors`               | Surface security + performance warnings               |
| `generate_typescript_types`  | Re-generate `Database` types for the TS client        |

Rule of thumb: prefer `list_tables` before guessing column names, and
`apply_migration` (not raw `execute_sql`) for any schema change so the
migration history stays clean.

## Standard session-start checklist

When a session begins and the task touches the database:

1. **Confirm the project is reachable** — call `list_projects` and verify
   `jrogvnrddkshokplobsn` is in `ACTIVE_HEALTHY` state.
2. **Refresh your mental model** — skim `docs/database/schema.md`. If the
   task is non-trivial, run `list_tables` with `verbose: true` to make
   sure the local docs are not stale (the schema can drift).
3. **Check advisories** — call `get_advisors` for `security` and
   `performance`. RLS is currently disabled on every public table; see the
   warning in `schema.md`.
4. **Look at recent runs** — `SELECT … FROM public.apify_runs ORDER BY
   started_at DESC LIMIT 10;` tells you what data was most recently
   ingested.
5. **Use the staging columns** when ingesting — `fb_posts.staging_*` and
   `fb_comments.staging_*` hold raw FB IDs that need a follow-up
   `UPDATE … FROM fb_profiles` to resolve to UUID foreign keys.

## Files in this folder

- `README.md` (this file) — orientation + quick start.
- `schema.md` — full table-by-table reference with columns, FKs,
  indexes, enums, extensions, and the lone view.
- `erd.md` — Mermaid entity-relationship diagram.

## Keeping these docs honest

If you change the schema (via `apply_migration`), update `schema.md`
and `erd.md` in the same commit. A quick way to regenerate the raw
material is:

```sql
-- enums
SELECT t.typname, string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'public'
GROUP BY t.typname;

-- indexes
SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes WHERE schemaname = 'public'
ORDER BY tablename, indexname;
```

Or call `list_tables` with `verbose: true` and copy the structure.
