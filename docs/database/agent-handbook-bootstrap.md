# Bootstrap snippet for OTHER agents' CLAUDE.md

If you have **another** repo with its own Claude Code agent, and that
agent needs to interact with the shared Supabase project
`axon-node-1` (`jrogvnrddkshokplobsn`), paste the section below into
that repo's `CLAUDE.md`. After this one-time paste, the other agent
will pull the latest handbook from the database on every new session —
no further sync work needed when we publish updates from this repo.

---

**Copy from here into the other repo's `CLAUDE.md`:**

```markdown
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
  telling you that something an older agent would do is now wrong.
- Re-check the handbook at the start of every new session. The
  version may have changed.

The handbook covers: project coordinates, which MCP tool to use for
what, the three non-obvious data patterns (staging columns,
`source_run_id`, polymorphic content refs), the standing RLS-disabled
issue, and the decision checkpoints that require pausing to ask the
operator before acting.
```

**Stop copying.**

---

## Why this works

- The handbook lives in `public.agent_handbook` in the shared database.
- New versions are inserted (append-only) when we publish from
  FB-Manager. See [`publish-protocol.md`](publish-protocol.md).
- Any agent with a Supabase MCP connection (or anon key) to the project
  can read the latest version — no extra credentials, no extra
  endpoints.
- Once the snippet above is in their `CLAUDE.md`, the other agent
  follows it on every session automatically.

## What you (the operator) need to do, once per repo

1. Open the other repo's `CLAUDE.md` (create if missing).
2. Paste the snippet above.
3. Commit. Done.

## What to do when something doesn't propagate

- Confirm the other agent's session has the Supabase MCP server
  attached (or anon-key access) for project `jrogvnrddkshokplobsn`.
- Ask the agent: "What handbook version are you on?" It should be able
  to tell you. If it answers an old version, ask it to re-run the query.
- If the agent reports a permission error: anon role currently has
  read access (RLS disabled). If RLS gets enabled later, the read
  policy for `agent_handbook` needs to be permissive for `anon` and
  `authenticated`.
