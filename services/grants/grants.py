"""The grants service's pass (design §6.1, §6.9): keep the COLUMN privileges of the read, masked and write tiers in step with the
classifications — masks as privileges, never a display filter.

    report = run_pass(conn_as_grantor, plan, tiers)

`conn_as_grantor`: a connection to ONE target as the grantor (table-level SELECT, INSERT, UPDATE, DELETE WITH GRANT OPTION on the target's
tables and views, USAGE WITH GRANT OPTION on its sequences — given by the owner's grant-target.sh, and for future objects `postgres`
creates, by its default privileges). `plan`: the tool's classifications for this target, [{"schema", "table", "column", "class":
"secret"|"personal"|"none", "cleared_secret": bool}] (from the view `mcp_grant_plan`). `tiers`: {"read": role, "read_masked": role,
"write": role}.

Per column: `secret` (by the plan, OR by the built-in patterns unless a super-admin cleared it) → no tier; `personal` → read and write
only; else all three. Write additionally gets INSERT and UPDATE on every non-secret column, table-level DELETE, and USAGE on the schema's
sequences. A table the grantor holds no grant option on is reported `not_granted` (the owner re-runs grant-target.sh). Every change is
returned so the tool records it (drift marks it explained).
"""
from __future__ import annotations

from psycopg import sql

from grants.patterns import is_secret_name

_RELS = """
SELECT c.oid, n.nspname, c.relname, c.relkind,
       has_table_privilege(current_user, c.oid, 'SELECT WITH GRANT OPTION') AS can_grant
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'memory', 'maludb_core', 'mc2db') AND n.nspname NOT LIKE 'pg_%%'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
 ORDER BY 2, 3
"""
_COLS = """
SELECT a.attnum, a.attname, a.attgenerated <> '' AS generated,
       has_column_privilege(%(read)s, a.attrelid, a.attnum, 'SELECT') AS r_sel,
       has_column_privilege(%(masked)s, a.attrelid, a.attnum, 'SELECT') AS m_sel,
       has_column_privilege(%(write)s, a.attrelid, a.attnum, 'SELECT') AS w_sel,
       has_column_privilege(%(write)s, a.attrelid, a.attnum, 'INSERT') AS w_ins,
       has_column_privilege(%(write)s, a.attrelid, a.attnum, 'UPDATE') AS w_upd
  FROM pg_attribute a WHERE a.attrelid = %(oid)s AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
"""


def run_pass(conn, plan: list[dict], tiers: dict) -> dict:
    classes = {(p["schema"], p["table"], p["column"]): p for p in plan}
    changes: list[str] = []
    not_granted: list[str] = []
    conn.autocommit = False
    try:
        for oid, nsp, rel, kind, can_grant in conn.execute(_RELS).fetchall():
            if not can_grant:
                not_granted.append(f"{nsp}.{rel}")
                continue
            t = sql.Identifier(nsp, rel)
            want = {"r_sel": [], "m_sel": [], "w_sel": [], "w_ins": [], "w_upd": []}
            have = {k: [] for k in want}
            cols = conn.execute(_COLS, {"oid": oid, "read": tiers["read"], "masked": tiers["read_masked"], "write": tiers["write"]}).fetchall()
            for _num, col, generated, r_sel, m_sel, w_sel, w_ins, w_upd in cols:
                p = classes.get((nsp, rel, col)) or {}
                cls = p.get("class") or "none"
                secret = cls == "secret" or (is_secret_name(col) and not p.get("cleared_secret"))
                personal = cls == "personal"
                for k, flag in (("r_sel", r_sel), ("m_sel", m_sel), ("w_sel", w_sel), ("w_ins", w_ins), ("w_upd", w_upd)):
                    if flag:
                        have[k].append(col)
                if not secret:
                    want["r_sel"].append(col)
                    want["w_sel"].append(col)
                    if kind in ("r", "p") and not generated:
                        want["w_ins"].append(col)
                        want["w_upd"].append(col)
                    if not personal:
                        want["m_sel"].append(col)
            for key, role, priv in (("r_sel", tiers["read"], "SELECT"), ("m_sel", tiers["read_masked"], "SELECT"),
                                    ("w_sel", tiers["write"], "SELECT"), ("w_ins", tiers["write"], "INSERT"),
                                    ("w_upd", tiers["write"], "UPDATE")):
                if key.startswith("w_") and kind not in ("r", "p") and key != "w_sel":
                    continue
                add = [c for c in want[key] if c not in have[key]]
                rem = [c for c in have[key] if c not in want[key]]
                if add:
                    conn.execute(sql.SQL("GRANT {} ({}) ON {} TO {}").format(
                        sql.SQL(priv), sql.SQL(", ").join(map(sql.Identifier, add)), t, sql.Identifier(role)))
                    changes.append(f"grant {priv}({', '.join(add)}) on {nsp}.{rel} to {role}")
                if rem:
                    conn.execute(sql.SQL("REVOKE {} ({}) ON {} FROM {}").format(
                        sql.SQL(priv), sql.SQL(", ").join(map(sql.Identifier, rem)), t, sql.Identifier(role)))
                    changes.append(f"revoke {priv}({', '.join(rem)}) on {nsp}.{rel} from {role}")
            if kind in ("r", "p"):
                # the SYSTEM column xmin needs its own column grant (attnum < 0 is not in the column list): the grid's optimistic
                # concurrency reads it — a table-level SELECT would open every column, secrets included
                for role in (tiers["read"], tiers["read_masked"], tiers["write"]):
                    if not conn.execute("SELECT has_column_privilege(%s, %s, 'xmin', 'SELECT')", (role, oid)).fetchone()[0]:
                        conn.execute(sql.SQL("GRANT SELECT (xmin) ON {} TO {}").format(t, sql.Identifier(role)))
                        changes.append(f"grant SELECT(xmin) on {nsp}.{rel} to {role}")
                has_del = conn.execute("SELECT has_table_privilege(%s, %s, 'DELETE')", (tiers["write"], oid)).fetchone()[0]
                if not has_del:
                    conn.execute(sql.SQL("GRANT DELETE ON {} TO {}").format(t, sql.Identifier(tiers["write"])))
                    changes.append(f"grant DELETE on {nsp}.{rel} to {tiers['write']}")
        for (seq,) in conn.execute(
                "SELECT c.oid::regclass::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
                " WHERE c.relkind = 'S' AND n.nspname NOT IN ('pg_catalog','information_schema','memory','maludb_core')"
                # CASE fixes the evaluation order: the planner may test the privilege before relkind otherwise
                " AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege(current_user, c.oid, 'USAGE WITH GRANT OPTION')"
                "          AND NOT has_sequence_privilege(%s, c.oid, 'USAGE') ELSE false END", (tiers["write"],)).fetchall():
            conn.execute(sql.SQL("GRANT USAGE ON SEQUENCE {} TO {}").format(sql.SQL(seq), sql.Identifier(tiers["write"])))
            changes.append(f"grant USAGE on {seq} to {tiers['write']}")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.autocommit = True
    return {"changes": changes, "not_granted": not_granted}
