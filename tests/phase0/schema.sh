#!/usr/bin/env bash
# The schema proof (docs/developer-design.md §10, Phase 0; the Phase 1 reads proof, db/012, after it): a fresh scratch database `dx_proof`, every db/[0-9]*.sql applied in order as
# postgres, then db/proof/phase0_proof.sql (one transaction, rolled back). Re-runnable from nothing; never touches an installed database.
# The three installer roles are made here when missing (cluster-wide, NOLOGIN — the installer gives them passwords).
# `sudo -n -u postgres` is used for scratch dx_* databases and these roles only.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=${DX_PROOF_DB:-dx_proof}
case "$DB" in dx_*) ;; *) echo "refused: the proof database must be named dx_*"; exit 2 ;; esac
PSQL="sudo -n -u postgres psql -v ON_ERROR_STOP=1 -q -X"
sudo -n -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1
sudo -n -u postgres createdb "$DB"
$PSQL -d postgres >/dev/null <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'developer_rw') THEN CREATE ROLE developer_rw NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'developer_records_ro') THEN CREATE ROLE developer_records_ro NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'developer_activity_ro') THEN CREATE ROLE developer_activity_ro NOLOGIN; END IF;
END $$;
SQL
n=0
for f in db/[0-9]*.sql; do
  $PSQL -d "$DB" -f "$f" >/dev/null || { echo "MIGRATION FAILED: $f"; exit 1; }
  n=$((n + 1))
done
echo " $n migrations applied to $DB"
$PSQL -d "$DB" -f db/proof/phase0_proof.sql
$PSQL -d "$DB" -f db/proof/phase1_proof.sql
