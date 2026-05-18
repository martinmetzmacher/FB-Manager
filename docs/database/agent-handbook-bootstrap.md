<!--
HANDBOOK SOURCE — keep in sync with the public.agent_handbook row
where name = 'bootstrap-snippet'. The body below (frontmatter aside)
matches the published content character-for-character. To bump:
  1. Edit the body.
  2. Bump version in the frontmatter, write a one-line changelog.
  3. Apply a migration named publish_bootstrap_snippet_v<N> that
     inserts a new row.
  4. Commit this file and the migration together.
See docs/database/publish-protocol.md.
-->

---
name: bootstrap-snippet
version: 1
is_breaking: false
changelog: Initial publish of bootstrap snippet, retrievable from Supabase by any agent or operator.
---

# Bootstrap snippet — paste into a new repo's CLAUDE.md

If an operator wants to wire another repo into this shared Supabase
project, they paste the markdown block below into that repo's
`CLAUDE.md` (creating the file if it does not exist). After the paste,
no further sync work is needed in that repo — the agent there pulls
updates from this database on every new session.

You can retrieve this snippet at any time from any Supabase MCP
session by querying:

```sql
SELECT content FROM public.agent_handbook
WHERE name = 'bootstrap-snippet'
ORDER BY version DESC LIMIT 1;
```

---

**Copy the markdown between the markers into the other repo's `CLAUDE.md`.**

<!-- BEGIN PASTE -->

## Shared Supabase database — agent handbook

Some work in this repo touches the shared Supabase project
`axon-node-1` (ref `jrogvnrddkshokplobsn`, region `eu-central-1`).

Before doing **anything** with that database — including reads — run
this query first and treat the returned `content` as authoritative
session memory:

```sql
SELECT version, content, is_breaking, changelog
FROM public.agent_handbook
WHERE name = 'supabase-usage'
ORDER BY version DESC LIMIT 1;
```

Rules:
- If you have not seen this `version` in this session, read the full
  `content` before acting.
- If `is_breaking = true` and you have not seen this version,
  **stop and ask the operator** before proceeding — the handbook is
  telling you something an older agent would have done is now wrong.
- Re-check the handbook at the start of every new session. The
  version may have changed.

The handbook covers: project coordinates, which MCP tool to use for
what, the data patterns that are non-obvious if you have not seen this
project (staging columns, `source_run_id`, polymorphic content refs),
the standing RLS-disabled issue, and the decision checkpoints that
require pausing to ask the operator before acting.

<!-- END PASTE -->

---

## What the operator needs to confirm in the new repo

1. The session has a Supabase MCP server attached (or anon-key access)
   for project `jrogvnrddkshokplobsn`. Without it, the query above will
   fail and the agent has no handbook.
2. The `CLAUDE.md` in the new repo loads — open a fresh session and
   ask the agent "what should I know about the shared database?" — the
   agent should run the query and report the latest handbook version.

## Versioning

This bootstrap snippet itself is versioned in `public.agent_handbook`
under `name = 'bootstrap-snippet'`. If it ever changes (e.g. the SQL
needs adjustment), a new row is published. The previously-pasted
snippet keeps working unless the SQL itself becomes incompatible — in
which case a new bootstrap version with `is_breaking = true` will be
published, and the operator will need to re-paste in each downstream
repo.
