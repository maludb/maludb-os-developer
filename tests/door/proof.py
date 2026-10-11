"""The door proof — every bullet of design §6.12, on scratch roles `dx_proof_*` and scratch databases `dx_door_*` only.

    tests/door/run.sh          (KEEP=1 keeps the scratch roles and databases for a look afterwards)

Fixtures (made as postgres with `sudo -n -u postgres psql`, SQL on stdin — the owner's leave covers dx_* roles and databases only):
  dx_door_app       a fake application: members (email, full_name personal; password_hash secret by pattern), orders (ON DELETE CASCADE
                    from members; an AFTER UPDATE trigger writing audit_trail), a postgres-owned SECURITY DEFINER function, a hostile-named
                    table, 50,000 orders for the timings
  dx_door_kernel    a stand-in for the kernel's database (structure only; no grants to the tool's tiers)
  dx_door_hr        HR's real db/*.sql (from /srv/apps/hr, read at dev time) with its three roles renamed dx_proof_hr_* — the clone source
  dx_door_colo      a co-located-memory application: maludb_core (+ vector) and a `memory` schema beside its own tables
  dx_door_template  a template carrying `vector` (the owner's dx_template in production)
  dx_door_own       a stand-in for the tool's own database: the target list and dx_signal()
Workbenches and rehearsal clones are made by the rolemaker under the prefixes dx_door_wb_ / dx_door_rh_ (production: dxw_ / dxr_).
"""
from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "services"))

import psycopg  # noqa: E402
from psycopg import sql  # noqa: E402

from door import apply as apply_mod  # noqa: E402
from door import classify, clone, connections, decide, execute, functions, memory_queries, named, pgquery, rehearse, run, server  # noqa: E402
from door import workbench  # noqa: E402
from door.policy import DEFAULT_LIMITS, FakePolicies  # noqa: E402
from grants import grants as grants_mod  # noqa: E402
from grants.patterns import is_secret_name  # noqa: E402

KEEP = os.environ.get("KEEP") == "1"
N_OK = 0
N_FAIL = 0
FINDINGS: list[str] = []
TIMINGS: dict[str, float] = {}


def check(name: str, cond, detail: str = "") -> bool:
    global N_OK, N_FAIL
    if cond:
        N_OK += 1
        print(f"ok {N_OK + N_FAIL} - {name}")
    else:
        N_FAIL += 1
        print(f"not ok {N_OK + N_FAIL} - {name}" + (f"  # {detail}" if detail else ""))
    return bool(cond)


def pg_admin(script: str, db: str = "postgres", *, check_rc: bool = True, at: bool = False) -> str:
    args = ["sudo", "-n", "-u", "postgres", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", db]
    if at:
        args += ["-At"]
    p = subprocess.run(args, input=script, capture_output=True, text=True, timeout=600)
    if check_rc and p.returncode != 0:
        raise RuntimeError(f"psql on {db} failed: {p.stderr[-2000:]}")
    return p.stdout


# ── scratch credentials ─────────────────────────────────────────────────────────────────────────────────────────────────────────
TIERS = ["meta", "read", "read_masked", "write", "ops", "memory", "rolemaker", "grantor", "victim"]
ROLE = {t: f"dx_proof_{t}" for t in TIERS}
WB_PREFIX, RH_PREFIX = "dx_door_wb_", "dx_door_rh_"
DBS = ["dx_door_app", "dx_door_kernel", "dx_door_hr", "dx_door_colo", "dx_door_template", "dx_door_own"]
TMP = tempfile.mkdtemp(prefix="dx-door-proof-")
os.chmod(TMP, 0o700)
PASSFILE = os.path.join(TMP, "passfile")
PASSWORDS = {t: secrets.token_urlsafe(24) for t in TIERS}
with open(os.open(PASSFILE, os.O_WRONLY | os.O_CREAT, 0o600), "w") as f:
    for t, pw in PASSWORDS.items():
        f.write(f"*:*:*:{ROLE[t]}:{pw}\n")
CFG = connections.Config(passfile=PASSFILE, workbench_store=os.path.join(TMP, "workbenches.json"),
                         roles={t: ROLE[t] for t in TIERS if t != "victim"}, workbench_prefix=WB_PREFIX, rehearsal_prefix=RH_PREFIX,
                         template="dx_door_template", rolemaker_db="dx_door_own", own_db="dx_door_own",
                         memory_auditor="dx_proof_mem_auditor", sslmode="disable")


def scram(role: str, pw: str) -> str:
    """A SCRAM-SHA-256 verifier computed here (RFC 7677, as libpq's PQencryptPasswordConn does) — the scratch roles are created before
    any login exists, and no plain password ever reaches the server or its log."""
    import base64
    import hashlib
    import hmac as _h
    salt = os.urandom(16)
    it = 4096
    salted = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, it)
    ck = _h.new(salted, b"Client Key", hashlib.sha256).digest()
    sk = _h.new(salted, b"Server Key", hashlib.sha256).digest()
    stored = hashlib.sha256(ck).digest()
    b = base64.b64encode
    return f"SCRAM-SHA-256${it}:{b(salt).decode()}${b(stored).decode()}:{b(sk).decode()}"


# ── cleanup and setup ──────────────────────────────────────────────────────────────────────────────────────────────────────────
def cleanup():
    dbs = pg_admin("SELECT datname FROM pg_database WHERE datname LIKE 'dx\\_door\\_%' ESCAPE '\\'", at=True, check_rc=False).split()
    for d in dbs:
        if d == "dx_door_template":
            pg_admin("ALTER DATABASE dx_door_template IS_TEMPLATE false", check_rc=False)
        pg_admin(f"DROP DATABASE IF EXISTS {d} WITH (FORCE)", check_rc=False)
    roles = pg_admin("SELECT rolname FROM pg_roles WHERE rolname LIKE 'dx\\_proof\\_%' ESCAPE '\\'"
                     " OR rolname LIKE 'dx\\_door\\_%' ESCAPE '\\'", at=True, check_rc=False).split()
    # roles made by the rolemaker first (they may be members of nothing but were granted to it)
    for r in sorted(roles, key=lambda x: (not x.startswith("dx_door_"), x)):
        pg_admin(f"DROP ROLE IF EXISTS {r}", check_rc=False)


def setup():
    cleanup()
    roles_sql = []
    for t in TIERS:
        extra = {"rolemaker": " CREATEROLE CREATEDB"}.get(t, "")
        roles_sql.append(f"CREATE ROLE {ROLE[t]} LOGIN NOINHERIT{extra} PASSWORD '{scram(ROLE[t], PASSWORDS[t])}';")
    for t in ("meta", "read", "read_masked", "memory"):
        roles_sql.append(f"ALTER ROLE {ROLE[t]} SET default_transaction_read_only = on;")
    for t in ("read", "read_masked"):
        roles_sql.append(f"ALTER ROLE {ROLE[t]} SET statement_timeout = '60s'; ALTER ROLE {ROLE[t]} SET lock_timeout = '5s';"
                         f" ALTER ROLE {ROLE[t]} SET idle_in_transaction_session_timeout = '60s';"
                         f" ALTER ROLE {ROLE[t]} SET transaction_timeout = '120s';")
    roles_sql.append("CREATE ROLE dx_proof_signaller NOLOGIN; GRANT pg_signal_backend TO dx_proof_signaller;")
    roles_sql.append("CREATE ROLE dx_proof_mem_auditor NOLOGIN BYPASSRLS;")
    roles_sql.append(f"GRANT dx_proof_mem_auditor TO {ROLE['memory']} WITH INHERIT FALSE, SET TRUE;")
    pg_admin("\n".join(roles_sql))
    for d in DBS:
        pg_admin(f"CREATE DATABASE {d}")

    grant_target = """
GRANT CONNECT ON DATABASE {db} TO dx_proof_meta, dx_proof_read, dx_proof_read_masked, dx_proof_write, dx_proof_ops, dx_proof_grantor;
GRANT USAGE ON SCHEMA public TO dx_proof_meta, dx_proof_read, dx_proof_read_masked, dx_proof_write, dx_proof_ops, dx_proof_grantor;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dx_proof_grantor WITH GRANT OPTION;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dx_proof_grantor WITH GRANT OPTION;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO dx_proof_meta;
GRANT MAINTAIN ON ALL TABLES IN SCHEMA public TO dx_proof_ops;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dx_proof_grantor WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO dx_proof_grantor WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT MAINTAIN ON TABLES TO dx_proof_ops;
"""
    pg_admin(r"""
CREATE TABLE members (id bigint PRIMARY KEY, email text, full_name text, password_hash text, active boolean DEFAULT true);
CREATE TABLE orders (id bigint PRIMARY KEY, member_id bigint REFERENCES members ON DELETE CASCADE, qty int, total numeric(12,2),
                     note text);
CREATE TABLE audit_trail (id bigserial PRIMARY KEY, what text, at timestamptz DEFAULT now());
CREATE FUNCTION orders_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO audit_trail(what) VALUES ('order ' || NEW.id);
  RETURN NEW; END $$;
CREATE TRIGGER orders_audit AFTER UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION orders_audit();
CREATE FUNCTION app_secret_count() RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
  AS 'SELECT count(*) FROM members WHERE password_hash IS NOT NULL';
CREATE VIEW v_members AS SELECT id, email FROM members;
INSERT INTO members SELECT g, 'person' || g || '@example.org', 'Person ' || g, 'scram$fake$' || g, true FROM generate_series(1, 200) g;
INSERT INTO orders SELECT g, 1 + (g % 200), g % 7, (g % 1000) / 10.0, 'note ' || g FROM generate_series(1, 50000) g;
CREATE TABLE "we'ird;ta""ble" (id int PRIMARY KEY, "co'l;umn" text, "back\slash" text);
INSERT INTO "we'ird;ta""ble" VALUES (1, 'a', 'b');
ANALYZE;
""" + grant_target.format(db="dx_door_app"), "dx_door_app")

    pg_admin("CREATE TABLE members (id bigint PRIMARY KEY, token_hash text, business_role text);"
             " INSERT INTO members VALUES (1, 'h', 'super_admin');", "dx_door_kernel")
    pg_admin("GRANT CONNECT ON DATABASE dx_door_kernel TO dx_proof_meta;", "dx_door_kernel")

    hr = []
    for fn in sorted(os.listdir("/srv/apps/hr/db")):
        if re.match(r"^\d{3}_.*\.sql$", fn):
            with open(os.path.join("/srv/apps/hr/db", fn)) as f:
                txt = f.read()
            txt = re.sub(r"\bhr_(rw|records_ro|activity_ro)\b", r"dx_proof_hr_\1", txt)
            hr.append(txt)
    pg_admin("\n".join(hr), "dx_door_hr")
    pg_admin(grant_target.format(db="dx_door_hr"), "dx_door_hr")

    pg_admin("CREATE EXTENSION vector; ALTER DATABASE dx_door_template IS_TEMPLATE true;", "dx_door_template")
    t0 = time.monotonic()
    pg_admin("CREATE EXTENSION maludb_core CASCADE; CREATE SCHEMA memory; CREATE TABLE memory.notes (id int PRIMARY KEY, body text);"
             " CREATE TABLE public.batches (id int PRIMARY KEY, product text, litres numeric);"
             " INSERT INTO public.batches VALUES (1, 'cider', 100);", "dx_door_colo")
    TIMINGS["maludb_core install (s)"] = round(time.monotonic() - t0, 1)
    pg_admin(grant_target.format(db="dx_door_colo") + """
GRANT CONNECT ON DATABASE dx_door_colo TO dx_proof_memory;
GRANT USAGE ON SCHEMA maludb_core TO dx_proof_mem_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA maludb_core TO dx_proof_mem_auditor;
""", "dx_door_colo")

    pg_admin(r"""
CREATE TABLE dx_targets (datname text PRIMARY KEY, class text NOT NULL);
INSERT INTO dx_targets VALUES ('dx_door_app', 'application'), ('dx_door_hr', 'application'), ('dx_door_kernel', 'kernel'),
                              ('dx_door_colo', 'application');
GRANT SELECT ON dx_targets TO dx_proof_signaller;
CREATE FUNCTION public.dx_signal(p_pid int, p_kind text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, pg_temp AS $$
DECLARE a record;
BEGIN
  SELECT s.datname, r.rolsuper INTO a FROM pg_stat_activity s JOIN pg_roles r ON r.oid = s.usesysid WHERE s.pid = p_pid;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such session' USING ERRCODE = '22023'; END IF;
  IF a.rolsuper THEN RAISE EXCEPTION 'a superuser''s session is cancelled from psql as postgres' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.dx_targets t WHERE t.datname = a.datname AND t.class IN ('application', 'development', 'workbench'))
  THEN RAISE EXCEPTION 'sessions on this database are shown, never signalled' USING ERRCODE = '42501'; END IF;
  IF p_kind = 'cancel' THEN RETURN pg_cancel_backend(p_pid); END IF;
  IF p_kind = 'terminate' THEN RETURN pg_terminate_backend(p_pid); END IF;
  RAISE EXCEPTION 'unknown kind' USING ERRCODE = '22023';
END $$;
ALTER FUNCTION public.dx_signal(int, text) OWNER TO dx_proof_signaller;
REVOKE EXECUTE ON FUNCTION public.dx_signal(int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dx_signal(int, text) TO dx_proof_ops;
GRANT CONNECT ON DATABASE dx_door_own TO dx_proof_ops, dx_proof_rolemaker;
""", "dx_door_own")
    for d in ("dx_door_app", "dx_door_kernel"):
        pg_admin(f"GRANT CONNECT ON DATABASE {d} TO dx_proof_victim;", d)


# ── policies ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
VIEWER = {"catalog.read", "plans.explain", "activity.read", "health.read", "memory.read"}
ENGINEER = VIEWER | {"data.read", "queries.save", "workbench.use", "workbench.apply", "changes.prepare", "migrations.draft", "exports.make"}
DBA = ENGINEER | {"data.unmask", "window.request", "data.write", "sessions.cancel", "sessions.terminate", "maintenance.run",
                  "classifications.confirm", "memory.content"}
AGENT = VIEWER | {"queries.save", "changes.prepare", "migrations.draft"}
APP = {"datname": "dx_door_app", "class": "application", "application_key": "app", "private_by_design": False, "grants_state": "in_place"}


def entry(caller, rights, level="structure", target=None, is_agent=False, window=None, workbench_=None, limits=None, **kw):
    d = {"ok": True, "caller": {"member_id": caller, "is_agent": is_agent, "active": True, "is_super_admin": False},
         "target": target or APP, "rights": sorted(rights), "level": level, "window": window or {"read": None, "write": None},
         "workbench": workbench_, "limits": {**DEFAULT_LIMITS, **(limits or {})}}
    d.update(kw)
    return d


TABLE: dict = {}
POL = FakePolicies(TABLE)
REG = run.Registry()


def req(caller, datname, text, **kw):
    r = {"request_id": str(uuid.uuid4()), "caller": caller, "datname": datname, "sql": text, "source": "editor"}
    r.update(kw)
    return run.run_request(CFG, POL, REG, r)


def conn_as(tier, db, role=None):
    if role:
        return connections.connect(CFG, "workbench", db, workbench_role=role)
    return connections.connect(CFG, tier, db)


# ── the checks ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def proof_classification():
    corpus = [
        ("select 1", "read"), ("values (1),(2)", "read"), ("table orders", "read"), ("show work_mem", "read"),
        ("with x as (delete from orders returning *) select count(*) from x", "dml"),
        ("select * into t2 from orders", "ddl"), ("explain analyze create table z as select 1", "explain:ddl"),
        ("explain select * from orders", "explain:read"), ("explain analyze delete from orders", "explain:dml"),
        ("prepare p as select 1", "refused"), ("execute p", "refused"), ("declare c cursor for select 1", "refused"),
        ("fetch 10 from c", "refused"), ("merge into orders o using members m on o.member_id = m.id when matched then delete", "dml"),
        ("select * from orders for update", "dml"), ("create database x", "refused"), ("alter database x connection limit 0", "refused"),
        ("drop database x", "refused"), ("create role x", "refused"), ("alter role current_role password 'x'", "refused"),
        ("grant pg_read_server_files to x", "refused"), ("alter system set work_mem = '1GB'", "refused"), ("load 'x'", "refused"),
        ("copy orders to stdout", "refused"), ("listen x", "refused"), ("notify x", "refused"), ("checkpoint", "refused"),
        ("discard all", "refused"), ("set role postgres", "refused"), ("set session authorization postgres", "refused"),
        ("reset all", "refused"), ("prepare transaction 'x'", "refused"), ("alter table orders owner to postgres", "refused"),
        ("create table t (a int)", "ddl"), ("create index concurrently i on orders(note)", "ddl"), ("begin", "tx"),
        ("commit", "tx"), ("set work_mem = '64MB'", "utility"), ("do $$ begin end $$", "utility"),
        ("create subscription s connection 'x' publication p", "refused"), ("security label on table t is 'x'", "refused"),
    ]
    for text, want in corpus:
        c = classify.classify(text)
        got = f"explain:{c.wraps}" if c.cls == "explain" else c.cls
        check(f"classify {text[:50]!r} → {want}", got == want, f"got {got}")
    t0 = time.monotonic()
    parts = pgquery.split("select 1; select $$a;b$$; /* c; */ select E'x\\';y'; create function f() returns int begin atomic select 1; end")
    check("split by the parser: dollar quotes, E'' strings, comments, BEGIN ATOMIC", len(parts) == 4, str([p.text for p in parts]))
    check("an unknown node is refused", classify.classify_node({"FutureStmt": {}}).cls == "refused")
    check("several statements in one text are refused by classify", classify.classify("select 1; select 2").cls == "refused")
    TIMINGS["split + classify 45 statements (ms)"] = round((time.monotonic() - t0) * 1000, 1)
    check("libpg_query grammar is PostgreSQL 17", 170000 <= pgquery.server_version_num() < 180000, str(pgquery.server_version_num()))


def proof_bypass():
    TABLE[(11, "dx_door_app")] = entry(11, ENGINEER, "masked")
    TABLE[(12, "dx_door_app")] = entry(12, DBA, "rows", window={"read": None, "write": {"id": 5, "expires_at": "x"}})
    a = req(12, "dx_door_app", "COMMIT; DROP TABLE members")
    check("COMMIT; DROP … refused before anything ran", a["status"] == "refused" and a["statements"] == [], json.dumps(a)[:200])
    a = req(12, "dx_door_app", "END; delete from members")
    check("END; DELETE … refused before anything ran", a["status"] == "refused", json.dumps(a)[:200])
    n = pg_admin("SELECT count(*) FROM members", "dx_door_app", at=True).strip()
    check("members untouched after the bypass attempts", n == "200", n)

    with conn_as("read", "dx_door_app") as c:                                          # privileges, not the parser
        r = execute.Runner(c, {"statement_timeout_ms": 5000, "lock_timeout_ms": 1000, "idle_in_tx_ms": 5000,
                                "transaction_timeout_ms": 10000}, DEFAULT_LIMITS)
        x = r.run(0, "SELECT * FROM pg_read_file('/etc/hostname')", "read", wrap="read_only", cursorable=False)
        check("a function in FROM refused by privileges (42501)", x.sqlstate == "42501", f"{x.sqlstate} {x.message}")
        x = r.run(1, "DELETE FROM members", "dml", wrap="read_only", cursorable=False)
        check("the read tier cannot write even when told nothing", x.status == "error" and x.sqlstate in ("25006", "42501"),
              f"{x.sqlstate}")
        x = r.run(2, "SELECT app_secret_count()", "read", wrap="read_only", cursorable=False)
        FINDINGS.append(f"Without the function screen, the read tier ran a postgres-owned SECURITY DEFINER function from a plain SELECT "
                        f"(status {x.status}, returned {x.rows[:1]}) — PUBLIC EXECUTE is the default; the screen is the wall until K53.")
        check("SECURITY DEFINER code is reachable by privileges alone (why the screen exists)", x.status == "ok", x.message or "")
    a = req(12, "dx_door_app", "SELECT * FROM pg_read_file('/etc/hostname')")
    check("the function screen refuses pg_read_file", a["status"] == "refused" and a["refusal_rule"] == "function", a.get("message", ""))
    a = req(12, "dx_door_app", "SELECT app_secret_count()")
    check("the function screen refuses a postgres-owned SECURITY DEFINER function", a["status"] == "refused"
          and "SECURITY DEFINER" in a.get("message", ""), a.get("message", ""))
    a = req(12, "dx_door_app", "SELECT set_config('statement_timeout', '0', false)")
    check("set_config refused by the function screen", a["status"] == "refused", a.get("message", ""))
    a = req(12, "dx_door_app", "SELECT query_to_xml('select 1', true, true, '')")
    check("query_to_xml (SQL in a string) refused", a["status"] == "refused", a.get("message", ""))
    refs = functions.called_functions(pgquery.parse("CALL app_proc(1)"))
    check("CALL's function is screened too (a typed, unwrapped FuncCall in the tree)", [r.name for r in refs] == ["app_proc"], str(refs))
    refs = functions.called_functions(pgquery.parse("SELECT * FROM generate_series(1, 2) g, lateral pg_read_file('x') f"))
    check("functions in FROM and LATERAL are found", {r.name for r in refs} == {"generate_series", "pg_read_file"}, str(refs))

    wb = workbench.create(CFG, template=None)                                          # READ ONLY as a wall where privileges would allow
    with conn_as("workbench", wb["name"], wb["role"]) as c:
        c.execute("CREATE TABLE t (a int)")
        r = execute.Runner(c, CFG.workbench_settings, DEFAULT_LIMITS)
        x = r.run(0, "INSERT INTO t VALUES (1)", "dml", wrap="read_only", cursorable=False)
        check("the READ ONLY backstop refuses a write its role may do (25006)", x.sqlstate == "25006", f"{x.sqlstate}")
        r.run(1, "SELECT set_config('statement_timeout', '0', false)", "read", wrap=None, cursorable=False)
        x = r.run(2, "SELECT current_setting('statement_timeout')", "read", wrap="read_only", cursorable=True)
        check("the tier's settings re-asserted before the next statement", x.rows and x.rows[0][0] == "5min", str(x.rows))
    workbench.drop(CFG, wb["name"])


def proof_masks():
    plan = [{"schema": "public", "table": "members", "column": "email", "class": "personal"},
            {"schema": "public", "table": "members", "column": "full_name", "class": "personal"}]
    tiers = {"read": ROLE["read"], "read_masked": ROLE["read_masked"], "write": ROLE["write"]}
    with conn_as("grantor", "dx_door_app") as c:
        rep = grants_mod.run_pass(c, plan, tiers)
    check("the grants pass granted columns", any("members" in ch for ch in rep["changes"]), str(rep)[:300])
    check("password_hash (pattern) granted to no tier", not any("password_hash" in ch for ch in rep["changes"]))
    TABLE[(11, "dx_door_app")] = entry(11, ENGINEER, "masked")
    for label, text in (("select list", "SELECT email FROM members LIMIT 1"), ("expression", "SELECT lower(email) FROM members LIMIT 1"),
                        ("WHERE", "SELECT id FROM members WHERE email LIKE 'a%'"), ("aggregate", "SELECT count(email) FROM members")):
        a = req(11, "dx_door_app", text)
        st = (a.get("statements") or [{}])[-1]
        check(f"masked tier: a personal column refused in the {label} (by PostgreSQL)", st.get("sqlstate") == "42501",
              f"{a.get('status')} {st.get('sqlstate')} {st.get('message')}")
    a = req(11, "dx_door_app", "SELECT count(*) FROM members")
    check("masked tier: count(*) names no column and passes", a["status"] == "ok" and a["statements"][0]["rows"][0][0] == "200",
          json.dumps(a)[:200])
    a = req(11, "dx_door_app", "SELECT id FROM members ORDER BY id LIMIT 2")
    check("masked tier reads the unclassified columns", a["status"] == "ok" and len(a["statements"][0]["rows"]) == 2)
    for label, text in (("select list", "SELECT password_hash FROM members LIMIT 1"),
                        ("expression", "SELECT md5(password_hash) FROM members LIMIT 1"),
                        ("WHERE", "SELECT id FROM members WHERE password_hash LIKE 's%'"),
                        ("aggregate", "SELECT count(password_hash) FROM members")):
        a = req(12, "dx_door_app", text)
        st = (a.get("statements") or [{}])[-1]
        check(f"rows tier: a secret column refused in the {label}", st.get("sqlstate") == "42501", f"{st.get('sqlstate')}")
    a = req(12, "dx_door_app", "SELECT email FROM members ORDER BY id LIMIT 1")
    check("rows tier (DBA) reads a personal column", a["status"] == "ok" and "@example.org" in a["statements"][0]["rows"][0][0])
    a = req(12, "dx_door_app", "SELECT email::int FROM members LIMIT 1")
    stored = POL.statements[-1].get("error_masked") or ""
    shown = a["statements"][-1].get("message") or ""
    check("an error carrying a value is shown whole to its runner", "@example.org" in shown, shown)
    check("… and stored with the value masked", "@example.org" not in stored and "•••" in stored, stored)
    q = POL.runs[-1].get("error") or ""
    check("… and the run's audit row holds no value", "@example.org" not in q, q)
    pg_admin("ALTER TABLE members ADD COLUMN nickname text; ALTER TABLE members ADD COLUMN api_key text;", "dx_door_app")
    t0 = time.monotonic()
    with conn_as("grantor", "dx_door_app") as c:
        rep = grants_mod.run_pass(c, plan, tiers)
    TIMINGS["grants pass, 5 tables (ms)"] = round((time.monotonic() - t0) * 1000, 1)
    check("a column a migration added is granted on the next pass", any("nickname" in ch and ROLE["read"] in ch for ch in rep["changes"]),
          str(rep["changes"]))
    check("a secret-pattern column a migration added is granted to no tier", not any("api_key" in ch for ch in rep["changes"]))
    check("the classifier's pattern list knows api_key", is_secret_name("api_key") and not is_secret_name("nickname"))
    with conn_as("grantor", "dx_door_app") as c:
        rep2 = grants_mod.run_pass(c, plan, tiers)
    check("the grants pass is idempotent", rep2["changes"] == [], str(rep2["changes"]))
    with conn_as("read_masked", "dx_door_app") as c:
        x = c.execute("SELECT xmin::text FROM members WHERE id = 1").fetchone()
    check("the system column xmin granted on its own (the grid's concurrency), no table-level SELECT", x is not None)
    with conn_as("meta", "dx_door_app") as c:
        tl = c.execute("SELECT has_table_privilege(%s, 'members', 'SELECT')", (ROLE["read"],)).fetchone()[0]
    check("… and no tier holds a table-level SELECT that would open the secrets", tl is False)


def proof_policy_decisions():
    TABLE[(20, "dx_door_app")] = entry(20, AGENT, "structure", is_agent=True)
    a = req(20, "dx_door_app", "SELECT id FROM orders LIMIT 1")
    check("an agent reads no rows", a["status"] == "refused" and a["refusal_rule"] == "agent", a.get("message", ""))
    a = req(20, "dx_door_app", "EXPLAIN SELECT * FROM orders WHERE id = 5")
    check("an agent may ask for a plan (masked tier, nothing executes)", a["status"] == "ok" and a["tier"] == "read_masked",
          json.dumps(a)[:200])
    a = req(20, "dx_door_app", "EXPLAIN SELECT email FROM members")
    check("… but not a plan naming a personal column", a["status"] != "ok", json.dumps(a)[:160])
    TABLE[(12, "dx_door_kernel")] = entry(12, DBA, "rows", target={"datname": "dx_door_kernel", "class": "kernel"})
    a = req(12, "dx_door_kernel", "SELECT * FROM members")
    check("the kernel's database: structure only", a["status"] == "refused" and a["refusal_rule"] == "kernel")
    with conn_as("read", "dx_door_kernel") as c:
        try:
            c.execute("SELECT * FROM members")
            ok = False
        except psycopg.errors.InsufficientPrivilege:
            ok = True
    check("… and the read tier holds no privilege there anyway", ok)
    TABLE[(12, "dx_door_hr")] = entry(12, DBA, "rows", target={"datname": "dx_door_hr", "class": "application", "private_by_design": True,
                                                               "grants_state": "in_place"})
    a = req(12, "dx_door_hr", "SELECT count(*) FROM members")
    check("a private-by-design database needs a read window", a["status"] == "refused" and a["refusal_rule"] == "window")
    TABLE[(12, "dx_door_hr")]["window"] = {"read": {"id": 1, "expires_at": "x"}, "write": None}
    a = req(12, "dx_door_hr", "SELECT count(*) FROM pg_class")
    check("… and reads inside one", a["status"] == "ok", json.dumps(a)[:200])
    TABLE[(11, "dx_door_devx")] = entry(11, ENGINEER, "masked", target={"datname": "dx_door_devx", "class": "development",
                                                                        "grants_state": "pending"})
    a = req(11, "dx_door_devx", "SELECT 1")
    check("a development database not granted by the owner is refused", a["status"] == "refused" and a["refusal_rule"] == "grants")
    TABLE[(10, "dx_door_app")] = entry(10, VIEWER, "structure")
    a = req(10, "dx_door_app", "SELECT 1 FROM orders LIMIT 1")
    check("a Viewer reads no rows", a["status"] == "refused" and a["refusal_rule"] == "right")
    a = req(12, "dx_door_app", "UPDATE orders SET note = 'x' WHERE id = 1")
    check("typed DML on an application offers the grid or a draft", a["status"] == "refused" and a["refusal_rule"] == "app_dml"
          and "migration draft" in a["message"])
    a = req(12, "dx_door_app", "ALTER TABLE orders ADD COLUMN z int")
    check("typed DDL on an application offers a draft", a["status"] == "refused" and a["refusal_rule"] == "app_ddl")
    a = req(12, "dx_door_app", "SELECT 1; UPDATE orders SET note = 'x' WHERE id = 1")
    check("a script with one refused statement runs nothing", a["status"] == "refused" and a.get("statement_index") == 1)
    TABLE[(99, "dx_door_app")] = {"ok": False, "refusal": {"rule": "inactive", "message": "This member is not active."}}
    a = req(99, "dx_door_app", "SELECT 1")
    check("an inactive member is refused", a["status"] == "refused" and a["refusal_rule"] == "inactive")
    TABLE[(12, "dx_door_app")]["frozen"] = True
    a = req(12, "dx_door_app", "SELECT 1")
    check("freeze refuses every run", a["status"] == "refused" and a["refusal_rule"] == "frozen")
    TABLE[(12, "dx_door_app")]["frozen"] = False
    a = req(12, "dx_door; drop", "SELECT 1")
    check("a database name outside [a-z0-9_] is refused before anything", a["status"] == "refused" and a["refusal_rule"] == "name")


def proof_workbenches():
    a_wb = workbench.create(CFG, template=None)
    b_wb = workbench.create(CFG, template=None)
    for caller, wb in ((12, a_wb), (13, b_wb)):
        TABLE[(caller, wb["name"])] = entry(caller, DBA, "rows", target={"datname": wb["name"], "class": "workbench"},
                                            workbench_={"id": 1, "owner_member_id": caller, "role": wb["role"], "suspended": False})
    try:
        connections.connect(CFG, "workbench", b_wb["name"], workbench_role=a_wb["role"]).close()
        ok = False
    except psycopg.OperationalError:
        ok = True
    check("a workbench's role cannot even connect to another workbench", ok)
    a = req(12, a_wb["name"], f"DROP DATABASE {b_wb['name']}")
    check("DROP DATABASE refused on a workbench (the door's lifecycle only)", a["status"] == "refused")
    a = req(12, a_wb["name"], f"ALTER DATABASE {b_wb['name']} CONNECTION LIMIT 0")
    check("ALTER DATABASE refused everywhere", a["status"] == "refused")
    a = req(12, a_wb["name"], "CREATE ROLE dx_door_evil")
    check("a role statement refused everywhere", a["status"] == "refused")
    a = req(12, a_wb["name"], "CREATE TABLE t (id int PRIMARY KEY, name text); INSERT INTO t VALUES (1, 'x'); SELECT * FROM t")
    check("a workbench runs DDL, DML and reads live", a["status"] == "ok" and a["statements"][2]["rows"] == [["1", "x"]], json.dumps(a)[:300])
    a = req(12, a_wb["name"], "BEGIN; INSERT INTO t VALUES (2, 'y')")
    check("a transaction left open at the end of a run is rolled back and said", a["status"] == "ok" and a.get("note"))
    a = req(12, a_wb["name"], "SELECT count(*) FROM t")
    check("… so the open transaction's insert is gone", a["statements"][0]["rows"][0][0] == "1", json.dumps(a)[:200])
    a = req(13, a_wb["name"], "SELECT 1")
    check("another person cannot run on my workbench", a["status"] == "refused")
    with conn_as("workbench", a_wb["name"], a_wb["role"]) as c:
        try:
            c.execute(sql.SQL("DROP DATABASE {}").format(sql.Identifier(b_wb["name"])))
            ok = False
        except psycopg.Error:
            ok = True
    check("even raw, a workbench's role cannot drop another workbench", ok)
    a = req(12, a_wb["name"], "DO $$ BEGIN EXECUTE 'ALTER ROLE CURRENT_ROLE PASSWORD ''changed-by-the-user'''; END $$")
    check("a DO changing its own role's password runs (it is the workbench's own business)", a["status"] == "ok", json.dumps(a)[:200])
    a = req(12, a_wb["name"], "SELECT 1")
    check("… which loses only that workbench to the door", a["status"] != "ok")
    a = req(13, b_wb["name"], "SELECT 1")
    check("… the other workbench is untouched", a["status"] == "ok")
    workbench.reset_credential(CFG, a_wb["name"])
    a = req(12, a_wb["name"], "SELECT count(*) FROM t")
    check("Reset credential recovers it", a["status"] == "ok" and a["statements"][0]["rows"][0][0] == "1", json.dumps(a)[:200])

    c_wb = workbench.create(CFG, template=None)
    t0 = time.monotonic()
    rep = clone.schema_clone(CFG, source_db="dx_door_hr", target_db=c_wb["name"], target_role=c_wb["role"])
    TIMINGS["clone of HR's schema (ms)"] = round((time.monotonic() - t0) * 1000, 1)
    with conn_as("workbench", c_wb["name"], c_wb["role"]) as c:
        n = c.execute("SELECT count(*) FROM pg_tables WHERE schemaname = 'public'").fetchone()[0]
        rows = c.execute("SELECT count(*) FROM members").fetchone()[0]
    check("a schema clone of HR's real migrations restores its tables, no restore error", n >= 15 and rep["status"] == "ok", f"{n} {rep}")
    check("… with no rows", rows == 0)
    if rep.get("error_count"):
        FINDINGS.append(f"pg_restore of HR's schema as the workbench role reported {rep['error_count']} errors, e.g. "
                        f"{rep['restore_errors'][:2]}")
    d_wb = workbench.create(CFG, template="dx_door_template")
    t0 = time.monotonic()
    rep = clone.schema_clone(CFG, source_db="dx_door_colo", target_db=d_wb["name"], target_role=d_wb["role"])
    TIMINGS["clone of a co-located-memory application (ms)"] = round((time.monotonic() - t0) * 1000, 1)
    with conn_as("workbench", d_wb["name"], d_wb["role"]) as c:
        has_mem = c.execute("SELECT count(*) FROM pg_namespace WHERE nspname IN ('memory', 'maludb_core')").fetchone()[0]
        has_ext = c.execute("SELECT count(*) FROM pg_extension WHERE extname = 'maludb_core'").fetchone()[0]
        has_batches = c.execute("SELECT count(*) FROM pg_tables WHERE tablename = 'batches'").fetchone()[0]
    check("a co-located-memory clone leaves the memory schema and maludb_core out", has_mem == 0 and has_ext == 0
          and rep["status"] == "ok", f"{has_mem} {has_ext} {rep}")
    check("… and keeps the application's own tables", has_batches == 1)
    for w in (a_wb, b_wb, c_wb, d_wb):
        workbench.drop(CFG, w["name"])
    left = pg_admin(f"SELECT count(*) FROM pg_database WHERE datname LIKE '{WB_PREFIX}%'", at=True).strip()
    check("workbenches and their roles dropped", left == "0", left)

    t0 = time.monotonic()
    rep = rehearse.rehearse(CFG, source_db="dx_door_app", template=None,
                            statements=["ALTER TABLE orders ALTER COLUMN qty TYPE bigint", "ALTER TABLE orders ADD COLUMN flag boolean",
                                        "CREATE INDEX CONCURRENTLY orders_note_idx ON orders (note)"])
    TIMINGS["rehearsal of 3 statements on the app's schema (ms)"] = round((time.monotonic() - t0) * 1000, 1)
    st = rep.get("statements") or []
    check("the rehearsal ran", rep.get("status") == "ok" and len(st) == 3, json.dumps(rep)[:400])
    if len(st) == 3:
        check("ALTER COLUMN TYPE measured as a rewrite (filenode changed)", "public.orders" in st[0]["rewrites"], json.dumps(st[0]))
        check("… under ACCESS EXCLUSIVE", any(lk["relation"] == "public.orders" and lk["mode"] == "AccessExclusiveLock"
                                              for lk in st[0]["locks"]), json.dumps(st[0]["locks"]))
        check("ADD COLUMN without a default measured as no rewrite", st[1]["rewrites"] == [], json.dumps(st[1]))
        check("CREATE INDEX CONCURRENTLY reported from the rule table", st[2]["lock_source"] == "rule table" and st[2]["status"] == "ok")
    left = pg_admin(f"SELECT count(*) FROM pg_database WHERE datname LIKE '{RH_PREFIX}%'", at=True).strip()
    check("the rehearsal clone dropped", left == "0", left)


def proof_operations():
    victims = {}

    def sleeper(db, key):
        with psycopg.connect(connections.conninfo(CFG, ROLE["victim"], db), autocommit=True) as c:
            victims[key] = c.info.backend_pid
            try:
                c.execute("SELECT pg_sleep(20)")
                victims[key + "_result"] = "finished"
            except psycopg.errors.QueryCanceled:
                victims[key + "_result"] = "cancelled"
            except psycopg.Error as e:
                victims[key + "_result"] = type(e).__name__
    th_app = threading.Thread(target=sleeper, args=("dx_door_app", "app"))
    th_k = threading.Thread(target=sleeper, args=("dx_door_kernel", "kernel"))
    th_app.start()
    th_k.start()
    for _ in range(100):
        if "app" in victims and "kernel" in victims:
            break
        time.sleep(0.05)
    time.sleep(0.3)
    with conn_as("ops", "dx_door_own") as c:
        r = c.execute("SELECT dx_signal(%s, 'cancel')", (victims["app"],)).fetchone()[0]
        check("dx_signal() cancels a session on an application database", r is True)
        try:
            c.execute("SELECT dx_signal(%s, 'cancel')", (victims["kernel"],))
            ok = False
        except psycopg.errors.InsufficientPrivilege as e:
            ok = "never signalled" in str(e)
        check("dx_signal() refuses a session on the kernel's database", ok)
        try:
            c.execute("SELECT pg_cancel_backend(%s)", (victims["kernel"],))
            direct = c.execute("SELECT 1").fetchone()
            ok = False
        except psycopg.Error:
            ok = True
        check("the ops role cannot signal directly (only through dx_signal)", ok)
    th_app.join(5)
    check("… and the cancelled session saw the cancel", victims.get("app_result") == "cancelled", str(victims))
    pg_admin(f"SELECT pg_cancel_backend({victims['kernel']})", "postgres", check_rc=False)
    th_k.join(25)
    with conn_as("ops", "dx_door_app") as c:
        notices = []
        c.add_notice_handler(lambda d: notices.append(d.message_primary))
        c.execute("VACUUM orders")
        check("MAINTAIN admits VACUUM on the application", not any("skipping" in (n or "") for n in notices), str(notices))
        with c.transaction():
            c.execute("LOCK TABLE orders IN ACCESS SHARE MODE")
        check("MAINTAIN admits the dump's ACCESS SHARE lock", True)
    with conn_as("meta", "dx_door_kernel") as c:
        notices = []
        c.add_notice_handler(lambda d: notices.append(d.message_primary))
    with psycopg.connect(connections.conninfo(CFG, ROLE["ops"], "dx_door_kernel"), autocommit=True) as c:
        notices = []
        c.add_notice_handler(lambda d: notices.append(d.message_primary))
        c.execute("VACUUM members")
        check("… and nothing on another database (VACUUM skipped there)", any("skipping" in (n or "") for n in notices), str(notices))
    with conn_as("meta", "dx_door_app") as c:
        t0 = time.monotonic()
        res = named.run_named(c, "activity", {})
        TIMINGS["named activity query (ms)"] = round((time.monotonic() - t0) * 1000, 1)
        qi = res["columns"].index("query")
        check("activity texts come back normalized", res["status"] == "ok" and all(("$" in (r[qi] or "$")) or not re.search(r"'\w", r[qi] or "")
                                                                                    for r in res["rows"]), str(res["rows"][:2])[:200])
        FINDINGS.append("The meta role in this proof holds no pg_monitor (granting it would expose live query texts of the real applications "
                        "to a scratch login); it saw only its own sessions' details — production's developer_meta holds pg_monitor.")


def proof_data():
    TABLE[(12, "dx_door_app")] = entry(12, DBA, "rows", window={"read": None, "write": {"id": 5, "expires_at": "x"}})
    p = POL.get(12, None, "dx_door_app")
    with conn_as("write", "dx_door_app") as c:
        xmin = c.execute("SELECT xmin::text FROM members WHERE id = 7").fetchone()[0]
        res = apply_mod.apply_change_set(c, [{"op": "delete", "table": "members", "key": {"id": "7"}, "xmin": xmin}], p.limits)
    check("a grid delete that cascades is rolled back, the cascaded table named", res["status"] == "refused"
          and "public.orders" in res.get("tables", []), json.dumps(res)[:300])
    n = pg_admin("SELECT count(*) FROM members WHERE id = 7", "dx_door_app", at=True).strip()
    check("… and nothing was applied", n == "1")
    with conn_as("write", "dx_door_app") as c:
        xmin = c.execute("SELECT xmin::text FROM orders WHERE id = 3").fetchone()[0]
        res = apply_mod.apply_change_set(c, [{"op": "update", "table": "orders", "key": {"id": "3"}, "xmin": xmin,
                                              "values": {"note": "changed"}}], p.limits)
    check("a grid update whose trigger writes elsewhere is rolled back, the table named", res["status"] == "refused"
          and "public.audit_trail" in res.get("tables", []), json.dumps(res)[:300])
    with conn_as("write", "dx_door_app") as c:
        res = apply_mod.apply_change_set(c, [{"op": "update", "table": "members", "key": {"id": "9"}, "xmin": "1",
                                              "values": {"full_name": "Changed"}}], p.limits)
    check("a stale xmin is a conflict", res["status"] == "conflict", json.dumps(res))
    with conn_as("write", "dx_door_app") as c:
        xmin = c.execute("SELECT xmin::text FROM members WHERE id = 9").fetchone()[0]
        res = apply_mod.apply_change_set(c, [{"op": "update", "table": "members", "key": {"id": "9"}, "xmin": xmin,
                                              "values": {"full_name": "Changed Once"}}], p.limits)
    check("a clean grid update applies, with its before-image", res["status"] == "ok" and res["images"][0]["before"]["full_name"] == "Person 9",
          json.dumps(res)[:300])
    images = res.get("images") or []
    check("the before-image holds no secret column", images and "password_hash" not in images[0]["before"], str(images)[:200])
    with conn_as("write", "dx_door_app") as c:
        u = apply_mod.undo_change_set(c, images)
    n = pg_admin("SELECT full_name FROM members WHERE id = 9", "dx_door_app", at=True).strip()
    check("undo restores the row", u["status"] == "ok" and n == "Person 9", f"{u} {n}")
    with conn_as("write", "dx_door_app") as c:
        xmin = c.execute("SELECT xmin::text FROM members WHERE id = 10").fetchone()[0]
        res = apply_mod.apply_change_set(c, [{"op": "update", "table": "members", "key": {"id": "10"}, "xmin": xmin,
                                              "values": {"full_name": "Changed"}}], p.limits)
    pg_admin("UPDATE members SET full_name = 'Someone else' WHERE id = 10", "dx_door_app")
    with conn_as("write", "dx_door_app") as c:
        u = apply_mod.undo_change_set(c, res["images"])
    check("undo refused after a later change", u["status"] == "refused" and u["refusal_rule"] == "changed_since", json.dumps(u))
    TABLE[(11, "dx_door_app")] = entry(11, ENGINEER, "masked")
    d = decide.decide_apply(POL.get(11, None, "dx_door_app"))
    check("an Engineer without a write window cannot apply", d.tier is None)
    TABLE[(20, "dx_door_app")] = entry(20, DBA, "rows", is_agent=True, window={"read": None, "write": {"id": 1}})
    d = decide.decide_apply(POL.get(20, None, "dx_door_app"))
    check("an agent never applies, whatever it holds", d.tier is None and d.rule == "agent")

    names = ["a'b", 'c"d', "e;f", "g\nh", "i\\j", "k" * 63]
    pg_admin("".join(sql_line for sql_line in [f"CREATE TABLE {quote(n)} (id int PRIMARY KEY, {quote(n)} text);"
                                               f" INSERT INTO {quote(n)} VALUES (1, 'v');" for n in names]), "dx_door_app")
    with conn_as("grantor", "dx_door_app") as c:
        grants_mod.run_pass(c, [], {"read": ROLE["read"], "read_masked": ROLE["read_masked"], "write": ROLE["write"]})
    allok = True
    with conn_as("write", "dx_door_app") as c:
        for n in names:
            xmin = c.execute(sql.SQL("SELECT xmin::text FROM {} WHERE id = 1").format(sql.Identifier("public", n))).fetchone()[0]
            res = apply_mod.apply_change_set(c, [{"op": "update", "table": n, "key": {"id": "1"}, "xmin": xmin, "values": {n: "w"}}],
                                             p.limits)
            composed = sql.SQL("UPDATE {t} SET {c} = $1 WHERE id = $2").format(t=sql.Identifier("public", n),
                                                                                 c=sql.Identifier(n)).as_string(c)
            one = len(pgquery.split(composed)) == 1
            tree = pgquery.parse(composed)
            rel = tree["stmts"][0]["stmt"]["UpdateStmt"]["relation"]["relname"]
            if not (res["status"] == "ok" and one and rel == n):
                allok = False
                FINDINGS.append(f"hostile name {n!r}: {res} one={one} rel={rel!r}")
    check("hostile names: one composed statement each, round-tripping, applied", allok)


def quote(n: str) -> str:
    return '"' + n.replace('"', '""') + '"'


def proof_memory():
    bad = memory_queries.forbidden_references()
    check("the memory query library names no secret table, column or claim function", bad == [], str(bad))
    bad2 = memory_queries.forbidden_references({"x": 'SELECT value_encrypted FROM maludb_core."malu$secret_version"',
                                                "y": "SELECT maludb_core.maludb_embedding_dirty_claim(10)"})
    check("… and the static test catches one that does", len(bad2) >= 3, str(bad2))
    with conn_as("memory", "dx_door_colo") as c:
        res = memory_queries.run_memory(c, "dx_proof_mem_auditor", "tenant_counts")
        check("SET ROLE to the auditor reads a tenant's counts", res["status"] == "ok" and len(res["rows"]) == 1, str(res))
        res = memory_queries.run_memory(c, "dx_proof_mem_auditor", "embedding_backlog")
        check("… and the embedding backlog", res["status"] == "ok", str(res))
        try:
            c.execute('SELECT count(*) FROM maludb_core."malu$episode_object"')
            ok = False
        except psycopg.errors.InsufficientPrivilege:
            ok = True
        check("without SET ROLE the memory login reads nothing (INHERIT FALSE)", ok)


def proof_plumbing():
    TABLE[(12, "dx_door_app")] = entry(12, DBA, "rows", window={"read": None, "write": {"id": 5}}, limits={"show_rows": 5})
    a = req(12, "dx_door_app", "SELECT id, note FROM orders ORDER BY id")
    check("rows capped (5 shown, truncated said)", a["status"] == "ok" and len(a["statements"][0]["rows"]) == 5
          and a["statements"][0]["truncated"], json.dumps(a)[:200])
    a = req(12, "dx_door_app", "SELECT repeat('x', 5000)")
    cellv = a["statements"][0]["rows"][0][0]
    check("a long cell cut with its full length", isinstance(cellv, dict) and cellv["full_length"] == 5000 and len(cellv["text"]) == 2000)
    TABLE[(12, "dx_door_app")]["limits"] = {**DEFAULT_LIMITS, "show_bytes": 2000}
    a = req(12, "dx_door_app", "SELECT note FROM orders")
    check("bytes capped", a["statements"][0]["truncated"] and len(a["statements"][0]["rows"]) < 1000)
    a = req(12, "dx_door_app", "SELECT '\\x00ff'::bytea, 12.30::numeric(10,2), '{\"a\": 1}'::jsonb, '2026-10-11 10:00+00'::timestamptz")
    row = a["statements"][0]["rows"][0]
    check("bytea as its size; numeric, jsonb, timestamptz as PostgreSQL's text", row[0] == {"binary_bytes": 2} and row[1] == "12.30"
          and row[2] == '{"a": 1}' and row[3].startswith("2026-10-11"), str(row))
    TABLE[(12, "dx_door_app")]["limits"] = {**DEFAULT_LIMITS, "statement_timeout_ms": 500}
    a = req(12, "dx_door_app", "SELECT count(*) FROM generate_series(1, 300000000)")
    check("the timeout stops a long statement", a["statements"][0]["status"] == "timeout", json.dumps(a)[:200])
    TABLE[(12, "dx_door_app")]["limits"] = dict(DEFAULT_LIMITS)
    p1 = req(12, "dx_door_app", "SELECT pg_backend_pid()::text")
    p2 = req(12, "dx_door_app", "SELECT pg_backend_pid()::text")
    check("a fresh connection per request (never reused across callers)", p1["statements"][0]["rows"] != p2["statements"][0]["rows"])
    a = req(12, "dx_door_app", "SELECT current_setting('application_name')", request_id="run-42")
    check("the session is named developer:<member>:<run> (what dx_signal() refuses)", a["statements"][0]["rows"][0][0] == "developer:12:run-42",
          str(a["statements"][0]["rows"]))
    a = req(12, "dx_door_app", "SELECT 1 FROM orders LIMIT 1; ALTER TABLE orders ADD COLUMN q int")
    r_ = POL.runs[a["run_id"] - 1]
    check("a refused run is audited too: opened, then closed with its rule", r_.get("status") == "refused"
          and r_.get("refusal_rule") == "app_ddl" and r_.get("sql_sha256"), str(r_)[:200])
    a = req(12, "dx_door_app", "SELECT id FROM orders WHERE id = 1; SELECT nosuchcol FROM orders")
    st = a["statements"][-1]
    check("an error's SQLSTATE and position (inside the script)", st["sqlstate"] == "42703" and st["position"] is not None
          and a["statements"][0]["status"] == "ok", json.dumps(st)[:200])
    TIMINGS["error position (char offset in the script)"] = st["position"]

    key = secrets.token_bytes(32)
    sock = os.path.join(TMP, "door.sock")
    srv = server.DoorServer(sock, CFG, POL, key, {os.getuid()})
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    base = {"caller": 12, "datname": "dx_door_app", "source": "editor"}
    r = server.ask(sock, key, {**base, "kind": "ping", "request_id": str(uuid.uuid4())})
    check("the socket answers ping", r.get("status") == "ok", str(r))
    r = server.ask(sock, b"wrong-key", {**base, "kind": "run", "request_id": str(uuid.uuid4()), "sql": "SELECT 1"})
    check("a request without a valid HMAC is refused", r.get("refusal_rule") == "mac", str(r))
    r = server.ask(sock, key, {**base, "kind": "run", "request_id": str(uuid.uuid4()), "sql": "SELECT 1", "ts": time.time() - 3600})
    check("a stale request is refused", r.get("refusal_rule") == "stale", str(r))
    rid = str(uuid.uuid4())
    server.ask(sock, key, {**base, "kind": "run", "request_id": rid, "sql": "SELECT 1"})
    r = server.ask(sock, key, {**base, "kind": "run", "request_id": rid, "sql": "SELECT 1"})
    check("a replayed request is refused", r.get("refusal_rule") == "replay", str(r))
    other = server.DoorServer(sock + "2", CFG, POL, key, {65534})
    th2 = threading.Thread(target=other.serve_forever, daemon=True)
    th2.start()
    r = server.ask(sock + "2", key, {**base, "kind": "ping", "request_id": str(uuid.uuid4())})
    check("a peer of another uid is refused at the socket", r.get("refusal_rule") == "peer", str(r))
    other.shutdown()
    long_rid = str(uuid.uuid4())
    out = {}

    def long_run():
        out["r"] = server.ask(sock, key, {**base, "kind": "run", "request_id": long_rid,
                                          "sql": "SELECT count(*) FROM generate_series(1, 2000000000)"})
    t = threading.Thread(target=long_run)
    t.start()
    time.sleep(0.8)
    c = server.ask(sock, key, {**base, "kind": "cancel", "request_id": str(uuid.uuid4()), "target_request_id": long_rid})
    t.join(30)
    check("cancel from a second request, answered beside the run", c.get("cancelled") is True
          and out.get("r", {}).get("statements", [{}])[0].get("status") == "cancelled", f"{c} {str(out)[:200]}")
    c = server.ask(sock, key, {**base, "caller": 13, "kind": "cancel", "request_id": str(uuid.uuid4()), "target_request_id": long_rid})
    check("nobody else may cancel my run", c.get("cancelled") is False)
    TABLE[(12, "dx_door_app")]["limits"] = {**DEFAULT_LIMITS, "concurrent_runs": 1}
    runs = {}

    def r1():
        runs["a"] = server.ask(sock, key, {**base, "kind": "run", "request_id": str(uuid.uuid4()),
                                           "sql": "SELECT count(*) FROM generate_series(1, 30000000)"})
    t = threading.Thread(target=r1)
    t.start()
    time.sleep(0.3)
    b = server.ask(sock, key, {**base, "kind": "run", "request_id": str(uuid.uuid4()), "sql": "SELECT 1"})
    t.join(60)
    check("the per-person concurrency cap", b.get("refusal_rule") == "busy", str(b))
    TABLE[(12, "dx_door_app")]["limits"] = dict(DEFAULT_LIMITS)
    POL.inactive.add(98)
    r = server.ask(sock, key, {**base, "caller": 98, "kind": "run", "request_id": str(uuid.uuid4()), "sql": "SELECT 1"})
    check("an inactive member refused at the door (dx_door_member_active)", r.get("refusal_rule") == "inactive", str(r))
    r = server.ask(sock, key, {**base, "kind": "named", "request_id": str(uuid.uuid4()), "name": "tables",
                               "params": {"schema": "public", "limit": 10, "offset": 0}})
    check("a named query through the socket, counted not rowed", r.get("status") == "ok" and POL.usage.get((12, "named:tables")) == 1,
          str(r)[:200])
    TABLE[(12, "dx_door_own")] = entry(12, DBA, "rows", target={"datname": "dx_door_own", "class": "own"})
    TABLE[(12, "dx_door_hr")] = entry(12, DBA, "rows", target={"datname": "dx_door_hr", "class": "application", "grants_state": "in_place"})
    r = server.ask(sock, key, {**base, "kind": "workbench_create", "request_id": str(uuid.uuid4()), "source": "dx_door_hr",
                               "template": False})
    check("workbench_create through the socket clones a schema", r.get("status") == "ok" and (r.get("clone") or {}).get("status") == "ok",
          str(r)[:300])
    if r.get("status") == "ok":
        TABLE[(12, r["name"])] = entry(12, DBA, "rows", target={"datname": r["name"], "class": "workbench"},
                                       workbench_={"id": 7, "owner_member_id": 12, "role": r["role"], "suspended": False})
        TABLE[(13, r["name"])] = entry(13, DBA, "rows", target={"datname": r["name"], "class": "workbench"},
                                       workbench_={"id": 7, "owner_member_id": 12, "role": r["role"], "suspended": False})
        x = server.ask(sock, key, {**base, "caller": 13, "kind": "workbench_drop", "request_id": str(uuid.uuid4()), "datname": r["name"]})
        check("… someone else may not drop it", x.get("refusal_rule") == "owner", str(x))
        x = server.ask(sock, key, {**base, "kind": "workbench_reset", "request_id": str(uuid.uuid4()), "datname": r["name"]})
        check("… resetting its credential is a super-admin's", x.get("refusal_rule") == "right", str(x))
        x = server.ask(sock, key, {**base, "kind": "workbench_drop", "request_id": str(uuid.uuid4()), "datname": r["name"]})
        check("… its owner drops it", x.get("status") == "ok", str(x))
    TABLE[(20, "dx_door_app")] = entry(20, AGENT, "structure", is_agent=True)
    r = server.ask(sock, key, {**base, "caller": 20, "kind": "rehearse", "request_id": str(uuid.uuid4()), "is_eval": True,
                               "statements": ["ALTER TABLE orders ADD COLUMN e int"]})
    check("an evaluation run may not rehearse", r.get("refusal_rule") == "eval", str(r))
    r = server.ask(sock, key, {**base, "caller": 20, "kind": "rehearse", "request_id": str(uuid.uuid4()), "template": None,
                               "statements": ["ALTER TABLE orders ADD COLUMN e int"]})
    check("an agent may rehearse a proposal on a throwaway copy", r.get("status") == "ok", str(r)[:300])
    TABLE[(12, "dx_door_colo")] = entry(12, DBA, "rows", target={"datname": "dx_door_colo", "class": "memory"})
    r = server.ask(sock, key, {**base, "kind": "memory", "request_id": str(uuid.uuid4()), "datname": "dx_door_colo",
                               "name": "tenant_counts"})
    check("a named memory query through the socket", r.get("status") == "ok", str(r)[:200])
    srv.shutdown()

    child = ("import os, socket, sys; sys.path.insert(0, %r);"
             "os.dup2(int(os.environ['DX_TEST_FD']), 3); os.environ['LISTEN_PID'] = str(os.getpid()); os.environ['LISTEN_FDS'] = '1';"
             "from door import server; s = server.systemd_socket(); assert s is not None and s.fileno() == 3;"
             "srv = server.DoorServer(None, None, None, bytes.fromhex(os.environ['DX_TEST_KEY']), {os.getuid()}, listening=s);"
             "srv.daemon_threads = False; srv.handle_request(); srv.server_close()") % os.path.join(ROOT, "services")
    lpath = os.path.join(TMP, "activated.sock")
    lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    lsock.bind(lpath)
    lsock.listen(8)
    proc = subprocess.Popen([sys.executable, "-I", "-c", child], pass_fds=(lsock.fileno(),), stderr=subprocess.PIPE, text=True,
                            env={"DX_TEST_FD": str(lsock.fileno()), "DX_TEST_KEY": key.hex(), "PATH": "/usr/bin:/bin"})
    try:
        r = server.ask(lpath, key, {**base, "kind": "ping", "request_id": str(uuid.uuid4())}, timeout=20)
    except OSError as e:
        r = {"error": str(e)}
    try:
        _out, err = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        err = "timeout"
    lsock.close()
    check("socket activation: the door serves the socket systemd passes as fd 3 (LISTEN_FDS / LISTEN_PID)", r.get("status") == "ok",
          f"{r} {err[-600:]}")

    f = os.path.join(TMP, "m.sql")
    with open(f, "w") as fh:
        fh.write("ALTER TABLE orders ADD COLUMN c int NOT NULL DEFAULT 1;\nCREATE INDEX i ON orders (note);\n")
    sq = subprocess.run([os.path.join(ROOT, "services", ".venv", "bin", "squawk"), "--reporter", "json", "--pg-version", "17", f],
                        capture_output=True, text=True, timeout=60)
    try:
        findings = json.loads(sq.stdout or "[]")
    except json.JSONDecodeError:
        findings = []
    rules = sorted({x.get("rule_name") or x.get("rule") or "" for x in findings}) if isinstance(findings, list) else []
    check("squawk runs on this CPU and flags the migration", sq.returncode != 0 and len(rules) >= 1, f"rc={sq.returncode} {rules} {sq.stderr[:200]}")
    FINDINGS.append(f"squawk 2.68.0 flagged: {rules}")

    TABLE[(12, "dx_door_app")] = entry(12, DBA, "rows")
    t0 = time.monotonic()
    a = req(12, "dx_door_app", "SELECT id, member_id, qty, total, note FROM orders ORDER BY id LIMIT 1000")
    TIMINGS["a 1,000-row page through the door (ms)"] = round((time.monotonic() - t0) * 1000, 1)
    check("a 1,000-row page", a["status"] == "ok" and len(a["statements"][0]["rows"]) == 1000)
    with conn_as("meta", "dx_door_hr") as c:
        t0 = time.monotonic()
        r = named.run_named(c, "tables", {"schema": "public", "limit": 200, "offset": 0})
        TIMINGS["catalog page: tables of HR's schema (ms)"] = round((time.monotonic() - t0) * 1000, 1)
        t0 = time.monotonic()
        m = named.run_named(c, "columns_map", {})
        TIMINGS["completion map: every column of HR (ms)"] = round((time.monotonic() - t0) * 1000, 1)
        TIMINGS["HR columns in the map"] = len(m["rows"])
    check("named catalog queries answer", r["status"] == "ok" and len(r["rows"]) >= 15 and m["status"] == "ok")
    t0 = time.monotonic()
    connections.connect(CFG, "read", "dx_door_app").close()
    TIMINGS["a fresh connection, loopback, sslmode=disable (ms)"] = round((time.monotonic() - t0) * 1000, 1)


def main() -> int:
    t0 = time.monotonic()
    try:
        setup()
        TIMINGS["setup (s)"] = round(time.monotonic() - t0, 1)
        proof_classification()
        proof_bypass()
        proof_masks()
        proof_policy_decisions()
        proof_workbenches()
        proof_operations()
        proof_data()
        proof_memory()
        proof_plumbing()
    except Exception as e:  # a crash is a failure, never a pass
        import traceback
        traceback.print_exc()
        check(f"the proof ran to the end ({type(e).__name__})", False, str(e)[:300])
    finally:
        if not KEEP:
            cleanup()
            shutil.rmtree(TMP, ignore_errors=True)
    print("# timings:", json.dumps(TIMINGS))
    for f_ in FINDINGS:
        print("# finding:", f_)
    print(f"# {N_OK} ok, {N_FAIL} not ok, {N_OK + N_FAIL} checks, {round(time.monotonic() - t0, 1)} s")
    return 0 if N_FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
