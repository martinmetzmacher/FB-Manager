#!/usr/bin/env bash
# Install the FB-Manager automation scaffolding into this repo.
#
# Run this from the ROOT of the target repo (e.g. martinmetzmacher/Supabase).
# It clones FB-Manager, copies the scaffold/ contents into the current dir,
# stages them for commit, and tells you what's next.

set -euo pipefail

[ -d .git ] || { echo "ERROR: not in a git repository"; exit 1; }

if [ -d supabase/functions/ingest-fb-posts ] \
   || [ -e supabase/migrations/20260519_create_ingest_helpers.sql ] \
   || [ -e claude-triggers/daily-smart-comments-refresh.md ] \
   || [ -e docs/automation/SETUP.md ]; then
  echo "ERROR: some scaffold paths already exist. Aborting to avoid overwriting your edits."
  echo "Inspect and remove these before re-running:"
  ls -la supabase/functions/ingest-fb-posts 2>/dev/null || true
  ls -la supabase/migrations/20260519_create_ingest_helpers.sql 2>/dev/null || true
  ls -la claude-triggers/daily-smart-comments-refresh.md 2>/dev/null || true
  ls -la docs/automation/SETUP.md 2>/dev/null || true
  exit 1
fi

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

echo "Cloning FB-Manager (depth 1) into $TMP/src ..."
git clone --depth 1 https://github.com/martinmetzmacher/FB-Manager.git "$TMP/src"

echo "Copying scaffold into $(pwd) ..."
mkdir -p supabase/functions/ingest-fb-posts \
         supabase/migrations \
         docs/automation \
         claude-triggers

cp "$TMP/src/scaffold/supabase/functions/ingest-fb-posts/index.ts" \
   supabase/functions/ingest-fb-posts/index.ts
cp "$TMP/src/scaffold/supabase/migrations/20260519_create_ingest_helpers.sql" \
   supabase/migrations/20260519_create_ingest_helpers.sql
cp "$TMP/src/scaffold/docs/automation/SETUP.md" \
   docs/automation/SETUP.md
cp "$TMP/src/scaffold/claude-triggers/daily-smart-comments-refresh.md" \
   claude-triggers/daily-smart-comments-refresh.md

git add supabase/functions/ingest-fb-posts/index.ts \
        supabase/migrations/20260519_create_ingest_helpers.sql \
        docs/automation/SETUP.md \
        claude-triggers/daily-smart-comments-refresh.md

cat <<'EOF'

Scaffold copied and staged. Files added:
  supabase/functions/ingest-fb-posts/index.ts
  supabase/migrations/20260519_create_ingest_helpers.sql
  docs/automation/SETUP.md
  claude-triggers/daily-smart-comments-refresh.md

Next steps (operator):
  1. Review the staged files.
  2. Commit and push:
       git commit -m "Add automation scaffolding: Apify -> Edge Function ingest"
       git push
  3. Follow docs/automation/SETUP.md to:
       - apply the migration (creates the resolve_fb_posts_staging RPC)
       - deploy the edge function
       - configure the Apify schedule + webhook
       - (optional) wire the Claude scheduled trigger for path B

The scaffold is the starting point, not the finished product.
Read it before deploying anything.
EOF
