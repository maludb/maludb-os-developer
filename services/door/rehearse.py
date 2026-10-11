"""A rehearsal (design §6.5): a change set applied to a throwaway schema-only clone of the target and MEASURED — the honest dry run
(S14). Never BEGIN … ROLLBACK on a live database for DDL: there the lock is taken and the rewrite done before the rollback.

    report = rehearse(cfg, source_db="subello_gl", statements=["ALTER TABLE …", …])

For each statement that can run in a transaction: inside BEGIN … COMMIT, the relation locks this backend holds just before COMMIT
(`pg_locks` for its own pid, user relations only) and whether any relation the statement names got a new file
(`pg_relation_filenode()` before and after — a changed filenode proves a rewrite, even on an empty table). Statements that cannot run in a
transaction (CONCURRENTLY) are run on their own and checked for success; their lock comes from the rule table and is labelled so. The clone
and its role are dropped at the end whatever happens.
"""
from __future__ import annotations

import time

import psycopg

from door import classify as classify_mod
from door import clone as clone_mod
from door import connections, workbench


def _concurrent(c: classify_mod.Classification) -> bool:
    if not c.tree:
        return False
    st = (c.tree.get("stmts") or [{}])[0].get("stmt") or {}
    node = next(iter(st), "")
    v = st.get(node) or {}
    if node in ("IndexStmt", "RefreshMatViewStmt", "DropStmt") and v.get("concurrent"):
        return True
    if node == "ReindexStmt" and any(((p.get("DefElem") or {}).get("defname") == "concurrently") for p in (v.get("params") or [])):
        return True
    if node == "AlterTableStmt":
        for cmd in v.get("cmds") or []:
            pc = ((cmd.get("AlterTableCmd") or {}).get("def") or {}).get("PartitionCmd") or {}
            if pc.get("concurrent"):
                return True
    return False


def _relations(tree) -> list[str]:
    """Every relation the statement names. A RangeVar is wrapped ({"RangeVar": {…}}) only in generic Node fields; typed fields
    (AlterTableStmt.relation, IndexStmt.relation, …) hold the body unwrapped — recognised by `relname` + `relpersistence`."""
    out = []
    stack = [tree]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            if o.get("relname") and "relpersistence" in o:
                out.append(((o.get("schemaname") or "public"), o["relname"]))
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    return list(dict.fromkeys(out))


_FILENODES = """
SELECT c.oid, n.nspname || '.' || c.relname, pg_relation_filenode(c.oid)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE (n.nspname, c.relname) IN (SELECT * FROM unnest(%s::text[], %s::text[]))
"""
_LOCKS = """
SELECT n.nspname || '.' || c.relname AS rel, l.mode
  FROM pg_locks l JOIN pg_class c ON c.oid = l.relation JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation' AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
 ORDER BY 1, 2
"""


def rehearse(cfg, *, source_db: str, statements: list[str], template: str | None | bool = True) -> dict:
    """`template`: True → the configured template (cfg.template); None → none (the source uses only trusted extensions); a name."""
    t0 = time.monotonic()
    tpl = cfg.template if template is True else template
    wb = workbench.create(cfg, prefix=cfg.rehearsal_prefix, template=tpl)
    out = {"clone": wb["name"], "statements": []}
    try:
        cl = clone_mod.schema_clone(cfg, source_db=source_db, target_db=wb["name"], target_role=wb["role"])
        out["clone_report"] = cl
        if cl.get("status") == "error":
            out["status"] = "error"
            return out
        with connections.connect(cfg, "workbench", wb["name"], workbench_role=wb["role"], app="developer:rehearsal") as conn:
            for i, text in enumerate(statements):
                c = classify_mod.classify(text)
                item = {"index": i, "class": c.cls, "node": c.node, "lock_source": "measured", "locks": [], "rewrites": [], "ms": 0}
                s0 = time.monotonic()
                try:
                    if _concurrent(c):
                        item["lock_source"] = "rule table"
                        conn.execute(text)
                    else:
                        rels = _relations(c.tree)
                        schemas = [r[0] for r in rels]
                        names = [r[1] for r in rels]
                        conn.execute("BEGIN")
                        before = {oid: (name, fn) for oid, name, fn in conn.execute(_FILENODES, (schemas, names)).fetchall()}
                        conn.execute(text)
                        item["locks"] = [{"relation": r, "mode": m} for r, m in conn.execute(_LOCKS).fetchall()]
                        after = {oid: fn for oid, _name, fn in conn.execute(_FILENODES, (schemas, names)).fetchall()}
                        item["rewrites"] = [name for oid, (name, fn) in before.items() if oid in after and after[oid] != fn]
                        conn.execute("COMMIT")
                    item["status"] = "ok"
                except psycopg.Error as e:
                    try:
                        conn.execute("ROLLBACK")
                    except psycopg.Error:
                        pass
                    item["status"] = "error"
                    item["sqlstate"] = e.diag.sqlstate
                    item["message"] = (e.diag.message_primary or str(e))[:500]
                item["ms"] = int((time.monotonic() - s0) * 1000)
                out["statements"].append(item)
                if item["status"] != "ok":
                    break
        out["status"] = "ok" if all(s["status"] == "ok" for s in out["statements"]) else "error"
        return out
    finally:
        try:
            workbench.drop(cfg, wb["name"])
        except Exception as e:  # pragma: no cover - reported, the worker's hourly sweep drops leftovers
            out["drop_error"] = str(e)[:300]
        out["ms"] = int((time.monotonic() - t0) * 1000)
