#!/usr/bin/env bash
# The door's own code against the REAL schema (Phase 0): services/door/policy.py's SqlPolicies and decide() over dx_door_policy() and the
# four audit functions of db/006–011 — the JSON contract proven end to end, not by a table-driven stand-in. Builds dx_policy (a scratch
# database with every migration and committed fixtures) and a scratch login dx_proof_policy_meta standing in for developer_meta (EXECUTE
# on the dx_door_* functions only, as deploy/own-database.sql grants); drops both unless KEEP=1. `sudo -n -u postgres` for dx_* names only.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DB=dx_policy; ROLE=dx_proof_policy_meta; PW=$(openssl rand -hex 16)
PSQL="sudo -n -u postgres psql -v ON_ERROR_STOP=1 -q -X"
cleanup() { [ "${KEEP:-}" = 1 ] && return; sudo -n -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1 || true; $PSQL -d postgres -c "DROP ROLE IF EXISTS $ROLE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
sudo -n -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1; sudo -n -u postgres createdb "$DB"
for f in "$ROOT"/db/[0-9]*.sql; do $PSQL -d "$DB" -f "$f" >/dev/null; done
$PSQL -d postgres -c "DROP ROLE IF EXISTS $ROLE" -c "CREATE ROLE $ROLE LOGIN PASSWORD '$PW'" >/dev/null
$PSQL -d "$DB" >/dev/null <<SQL
GRANT CONNECT ON DATABASE $DB TO $ROLE; GRANT USAGE ON SCHEMA public TO $ROLE;
GRANT EXECUTE ON FUNCTION dx_door_policy(bigint, bigint, text), dx_door_member_active(bigint), dx_door_run_open(jsonb),
    dx_door_run_close(bigint, jsonb), dx_door_statement_log(jsonb), dx_door_usage_bump(bigint, text) TO $ROLE;
INSERT INTO members (id, member_kind, display_name, email, business_role, is_external, status, capability, roles) VALUES
 (1, 'human', 'SMOKE Owner', 'owner@example.invalid', 'super_admin', false, 'active', 'admin', '{admin}'),
 (26, 'human', 'SMOKE Priya', 'priya@example.invalid', 'user', false, 'active', 'write', '{engineer}'),
 (30, 'human', 'SMOKE Dana', 'dana@example.invalid', 'user', false, 'active', 'write', '{dba}'),
 (40, 'agent', 'SMOKE Expert', NULL, 'user', false, 'active', 'write', '{engineer}');
INSERT INTO target_databases (datname, class, application_key, grants_state) VALUES ('subello_gl', 'application', 'gl', 'in_place'),
 ('certstudy', 'kernel', NULL, 'not_needed'), ('dxw_1', 'workbench', NULL, 'not_needed');
INSERT INTO workbenches (target_database_id, datname, role_name, owner_member_id, title, kind, quota_bytes, expires_at, status)
SELECT id, 'dxw_1', 'dxw_1', 26, 'w', 'empty', 1073741824, now() + interval '1 day', 'ready' FROM target_databases WHERE datname = 'dxw_1';
INSERT INTO target_access (target_database_id, principal_kind, member_id, level) SELECT id, 'member', 26, 'masked' FROM target_databases WHERE datname = 'subello_gl';
INSERT INTO target_access (target_database_id, principal_kind, role_key, level) SELECT id, 'role', 'dba', 'rows' FROM target_databases WHERE datname = 'subello_gl';
SQL
"$ROOT/services/.venv/bin/python" -I - "$ROOT" "$DB" "$ROLE" "$PW" <<'PY'
import sys
root, db, role, pw = sys.argv[1:5]
sys.path.insert(0, root + "/services")
import psycopg
from door.policy import SqlPolicies
from door.classify import classify
from door.decide import decide
P = SqlPolicies(lambda: psycopg.connect(host="127.0.0.1", dbname=db, user=role, password=pw, sslmode="disable"))
n = bad = 0
def check(ok, label):
    global n, bad
    n += 1; bad += 0 if ok else 1
    print(("ok " if ok else "not ok ") + f"{n} - {label}")
pr = P.get(26, None, "subello_gl")
check(pr.ok and pr.level == "masked" and pr.target["class"] == "application" and "migrations.draft" in pr.rights and not pr.is_agent,
      "SqlPolicies reads dx_door_policy(): Priya on the GL, masked, her rights")
d = decide(classify("SELECT id FROM invoices"), pr)
check(d.tier == "read_masked" and d.wrap == "read_only", f"decide(): her SELECT runs on the masked tier inside READ ONLY ({d})")
d = decide(classify("ALTER TABLE invoices ADD COLUMN memo text"), pr)
check(d.tier is None and "migration draft" in (d.refusal or ""), "decide(): her DDL on the GL is refused with the draft offered")
d = decide(classify("UPDATE invoices SET memo = 'x' WHERE id = 1"), pr)
check(d.tier is None and "grid" in (d.refusal or ""), "decide(): typed DML on the GL is refused with the grid offered (R86)")
pd = P.get(30, None, "subello_gl")
d = decide(classify("SELECT id FROM invoices"), pd)
check(pd.level == "rows" and d.tier == "read", "Dana (DBA, rows through her role): the read tier")
pk = P.get(30, None, "certstudy")
d = decide(classify("SELECT 1"), pk)
check(pk.ok and pk.level == "structure" and d.tier is None and d.rule == "kernel", "the kernel's database: structure only, a SELECT refused (rule kernel)")
pw_ = P.get(26, None, "dxw_1")
d = decide(classify("CREATE TABLE t (id bigint)"), pw_)
check(pw_.workbench and pw_.workbench.get("role") == "dxw_1" and d.tier == "workbench", f"Priya's workbench: DDL on the workbench tier ({d})")
pa = P.get(40, 26, "subello_gl")
d = decide(classify("SELECT id FROM invoices"), pa)
check(pa.ok and pa.is_agent and pa.level == "structure" and d.tier is None, f"the Expert in Priya's chat turn reads no rows ({d.rule})")
d = decide(classify("EXPLAIN SELECT id FROM invoices"), pa)
check(d.tier == "read_masked", f"…but explains without running, on the masked tier ({d})")
check(P.member_active(26) and not P.member_active(999), "dx_door_member_active() through the door's login")
rid = P.run_open({"request_id": "i1", "caller": 26, "source": "editor", "datname": "subello_gl", "kind": "run", "sql": "SELECT 1"})
sid = P.statement_log({"run_id": rid, "statement_index": 0, "class": "read", "tier": "read_masked", "fingerprint": "f", "status": "running"})
P.statement_log({"id": sid, "status": "ok", "rows_affected": 1, "ms": 2})
P.run_close(rid, {"status": "ok", "tier": "read_masked", "level": "masked", "rows_returned": 1, "ms": 3})
P.usage_bump(26, "named:table_describe")
check(rid > 0 and sid > 0, "the audit round trip through the door's login: run_open, statement_log ×2, run_close, usage_bump")
print(f"# {n - bad} ok, {bad} not ok")
sys.exit(1 if bad else 0)
PY
