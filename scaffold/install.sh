#!/usr/bin/env bash
# Install the FB-Manager automation scaffolding into this repo.
#
# Run this from the ROOT of the target repo (e.g. martinmetzmacher/Supabase).
# It clones FB-Manager, copies the scaffold/ contents into the current dir,
# stages them for commit, and tells you what's next.

set -euo pipefail

[ -d .git ] || { echo "ERROR: not in a git repository"; exit 1; }

if [ -d supabase/functions/scheduled-scraper ] \
   || [ -e supabase/migrations/20260519_create_cron_health_and_budget.sql ] \
   || [ -e supabase/pg_cron_schedules.sql ] \
   || [ -e docs/automation/SETUP.md ]; then
  echo "ERROR: some scaffold paths already exist. Aborting to avoid overwriting your edits."
  exit 1
fi

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

echo "Cloning FB-Manager (depth 1) into $TMP/src ..."
git clone --depth 1 https://github.com/martinmetzmacher/FB-Manager.git "$TMP/src"

echo "Copying scaffold into $(pwd) ..."
mkdir -p supabase/functions/scheduled-scraper \
         supabase/migrations \
         docs/automation

# Edge function
cp "$TMP/src/scaffold/supabase/functions/scheduled-scraper/index.ts" \
   supabase/functions/scheduled-scraper/index.ts

# Migrations (record of what's already live in the DB)
cp "$TMP/src/scaffold/supabase/migrations/20260519_create_ingest_helpers.sql" \
   supabase/migrations/20260519_create_ingest_helpers.sql
cp "$TMP/src/scaffold/supabase/migrations/20260519_create_cron_health_and_budget.sql" \
   supabase/migrations/20260519_create_cron_health_and_budget.sql
cp "$TMP/src/scaffold/supabase/migrations/20260519_publish_handbook_v3.sql" \
   supabase/migrations/20260519_publish_handbook_v3.sql

# pg_cron schedule definitions
cp "$TMP/src/scaffold/supabase/pg_cron_schedules.sql" \
   supabase/pg_cron_schedules.sql

# Setup runbook
cp "$TMP/src/scaffold/docs/automation/SETUP.md" \
   docs/automation/SETUP.md

git add supabase/ docs/automation/

cat <<'EOF'

Scaffold copied and staged. Files added:
  supabase/functions/scheduled-scraper/index.ts
  supabase/migrations/20260519_create_ingest_helpers.sql
  supabase/migrations/20260519_create_cron_health_and_budget.sql
  supabase/migrations/20260519_publish_handbook_v3.sql
  supabase/pg_cron_schedules.sql
  docs/automation/SETUP.md

The two cron tables + handbook v3 are ALREADY APPLIED to the live DB.
The migration files in supabase/migrations/ are kept as a fresh-env
reproducibility record, not as something to re-apply against the live
project (running them is safe — they're idempotent).

Next steps (operator):
  1. Review the staged files (git diff --cached).
  2. Commit and push:
       git commit -m "Add scheduled-scraper dispatcher + cron tables migration"
       git push
  3. Follow docs/automation/SETUP.md:
       - set APIFY_TOKEN + DISPATCH_SECRET secrets
       - deploy the edge function: supabase functions deploy scheduled-scraper
       - test each job manually with curl (see SETUP.md step 3)
       - activate Tier 1 only, watch cron_health for 3 days
       - progressively enable Tier 2 then Tier 3

The dispatcher's per-job ingest functions are STUBBED (throw "TODO:
implement"). Implementing them is the next chunk of work — one job at
a time, testing with curl before activating cron.
EOF
