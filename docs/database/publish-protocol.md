# Publish Protocol — updating the agent handbook

This runbook is for the FB-Manager repo only. It is how we publish a
new version of the agent handbook so that other agents in other repos
pick up the change automatically.

## The model in one paragraph

`docs/database/agent-handbook.md` (this repo) is the **source** —
that is where humans edit. `public.agent_handbook` (Supabase) is the
**published channel** — that is where other agents read from. The two
are kept in sync by a migration that inserts a new row whenever we
publish. The DB table is append-only: every version is preserved.

## When to publish a new version

Publish when the handbook's *content* meaningfully changes for an
external agent. Examples:

- A new pattern they need to know about (new table, new pipeline,
  new MCP tool).
- A correction to an existing instruction.
- A new decision checkpoint.

Do **not** publish for typos that change no behavior. Just edit the
.md and commit.

## Step-by-step

1. **Edit the source.** Open `docs/database/agent-handbook.md`. Update
   the body. Leave the YAML frontmatter for the next step.

2. **Update the frontmatter.** In the YAML at the top:
   - Bump `version` by 1 (integers only — no semver).
   - Write a one-sentence `changelog` describing the change. Write it
     for an agent who has never read the previous version.
   - Set `is_breaking: true` **only if** an agent following the
     previous handbook would now do something wrong. Otherwise leave
     it `false`.

3. **Pause for the operator.** Per the project's decision-checkpoint
   rules, the operator gets to see what is about to be published
   before the migration runs. Show them:
   - the new version number
   - the changelog
   - the `is_breaking` setting and why
   - a diff of the body (or the full new body if short)

4. **Apply the migration.** Once approved, run a migration named
   `publish_handbook_v<N>` (where `<N>` is the new version). The
   migration is a single `INSERT`:

   ```sql
   INSERT INTO public.agent_handbook
     (name, version, content, changelog, is_breaking)
   VALUES (
     'supabase-usage',
     <N>,
     $HB$<full new content here, exactly as in the .md body>$HB$,
     '<changelog>',
     <is_breaking>
   );
   ```

   Use `apply_migration`, not `execute_sql`. The migration is the
   audit trail.

5. **Verify.** Run:

   ```sql
   SELECT version, is_breaking, changelog, published_at
   FROM public.agent_handbook
   WHERE name = 'supabase-usage'
   ORDER BY version DESC LIMIT 3;
   ```

   Confirm the new version is on top.

6. **Commit.** One commit, two changes: the updated
   `agent-handbook.md` and the new migration. Commit message:
   `Publish agent handbook v<N>: <changelog>`.

## Rolling back

The table is append-only, so "rolling back" is just publishing again
with the previous content under a higher version number. Set
`is_breaking: true` and changelog `Revert v<N> — see v<N-1>.`

Do **not** `DELETE` rows from `agent_handbook`. The history is the
audit trail.

## What can go wrong, and what to do

- **Other agent is on an old version.** Expected for any agent whose
  session started before the publish. They will catch up on their
  next session.
- **Other agent has no Supabase access.** They cannot read the
  handbook at all. The bootstrap snippet should explicitly require a
  Supabase MCP server or anon key.
- **A breaking change goes out without `is_breaking = true`.** Agents
  silently start using the new instructions, possibly contradicting
  what they already did this session. Recovery: publish a follow-up
  version with `is_breaking: true` and a corrective changelog.
- **Frontmatter drifts from DB.** Symptom: `agent-handbook.md` claims
  v5 but the DB latest is v4 (or vice versa). Diagnose by comparing
  `length(content)` between file and DB row. Fix by publishing a new
  version that re-syncs.

## Current handbooks and their source files

| `name`              | Source of truth (markdown body matches DB row)   |
|---------------------|--------------------------------------------------|
| `supabase-usage`    | `docs/database/agent-handbook.md`                |
| `bootstrap-snippet` | `docs/database/agent-handbook-bootstrap.md`      |

When you publish a new version of either, edit the file and the DB row
together in the same commit, named to match: migrations
`publish_handbook_v<N>` for `supabase-usage`, and
`publish_bootstrap_snippet_v<N>` for `bootstrap-snippet`.

## Adding a new handbook (different `name`)

If you eventually need another handbook for a different topic
(e.g. `name = 'apify-pipeline'`), no schema change is needed. Create a
new source file (`docs/database/handbook-<topic>.md`, or whatever
naming scheme you prefer), add a frontmatter block, write a migration
that inserts the first row with that `name`, and update the table
above so the source-of-truth mapping stays accurate.
