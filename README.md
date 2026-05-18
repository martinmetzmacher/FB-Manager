# FB-Manager

Facebook intelligence + outreach pipeline. Ingests profiles, posts,
comments, reactions, and photos from Apify scrapers into Supabase
(Postgres 17 + pgvector), then runs review workflows (triage inbox,
comment queue), enrichment (places, web contacts, email verification),
and a scaffolded NLP layer (embeddings, sentiment, topics).

## For Claude (and humans browsing the repo)

[`CLAUDE.md`](CLAUDE.md) briefs every new Claude Code session on the
operator's skill level (not a database engineer) and the database
rules of engagement (explain → ask → act, use migrations not raw
DDL, RLS is disabled, decision checkpoints). Read it first if you're
about to do anything to the database.

## Database

The Supabase database is the source of truth. **Start here when working
with it:** [`docs/database/README.md`](docs/database/README.md).

- [`docs/database/README.md`](docs/database/README.md) — project
  coordinates, MCP tooling, session-start checklist.
- [`docs/database/schema.md`](docs/database/schema.md) — full table
  reference: columns, FKs, indexes, enums, extensions, RLS advisory.
- [`docs/database/erd.md`](docs/database/erd.md) — Mermaid ER diagram.
- [`docs/database/agent-handbook.md`](docs/database/agent-handbook.md) —
  source of truth for the handbook published from this repo to
  `public.agent_handbook` in Supabase. Other agents read it from there.
- [`docs/database/agent-handbook-bootstrap.md`](docs/database/agent-handbook-bootstrap.md) —
  one-time snippet to paste into other repos' `CLAUDE.md` so their
  agents start pulling the handbook on every session.
- [`docs/database/publish-protocol.md`](docs/database/publish-protocol.md) —
  runbook for publishing a new handbook version.
