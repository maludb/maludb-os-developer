"""A grid change set's apply (design §6.6) — statements COMPOSED by the door with bound values, never typed SQL.

    answer = apply_change_set(conn, items, limits)        # conn: the write tier, on the target; autocommit off inside

`items`: [{"op": "update" | "delete" | "insert", "schema": "public", "table": "orders",
           "key": {"id": "17"}, "xmin": "1234", "values": {"note": "…"}}]

In ONE transaction: each update and delete is keyed by the row's identity AND its xmin (optimistic concurrency) and must touch exactly one
row; the before-image of every touched row is read first (`… FOR UPDATE`, only the columns the tier may read); after the last statement
and BEFORE COMMIT, pg_stat_xact_user_tables says which tables this transaction changed — if any table other than the change set's own
changed (a cascade, a trigger writing elsewhere), everything is rolled back and the tables are named (side effects are Extended). Identifiers
are composed with psycopg.sql.Identifier — never by string formatting.
"""
from __future__ import annotations

import psycopg
from psycopg import sql


def readable_columns(conn, schema: str, table: str, priv: str = "SELECT") -> list[str]:
    rows = conn.execute(
        "SELECT a.attname FROM pg_attribute a WHERE a.attrelid = format('%%I.%%I', %s::text, %s::text)::regclass"
        " AND a.attnum > 0 AND NOT a.attisdropped AND has_column_privilege(a.attrelid, a.attnum, %s) ORDER BY a.attnum",
        (schema, table, priv)).fetchall()
    return [r[0] for r in rows]


def _where(key: dict, with_xmin: bool):
    parts = [sql.SQL("{} = %s").format(sql.Identifier(k)) for k in key]
    if with_xmin:
        parts.append(sql.SQL("xmin = %s::xid"))
    return sql.SQL(" AND ").join(parts)


def apply_change_set(conn: psycopg.Connection, items: list[dict], limits: dict) -> dict:
    max_rows = int(limits.get("change_set_max_rows", 10000))
    if len(items) > max_rows:
        return {"status": "refused", "refusal_rule": "cap", "message": f"More than {max_rows} rows — that is a migration."}
    tables = {(it.get("schema") or "public", it["table"]) for it in items}
    images = []
    conn.autocommit = False
    try:
        # PostgreSQL 17's pg_stat_xact_* also holds a session's PENDING counts from earlier transactions not yet flushed (stats are
        # flushed at most once a second): take a baseline before the first write and judge by the deltas (door proof finding).
        baseline = {relid: (i, u, d) for relid, i, u, d in conn.execute(
            "SELECT relid, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_xact_user_tables").fetchall()}
        oids = {}
        for sch, tbl in tables:
            oids[(sch, tbl)] = conn.execute("SELECT format('%%I.%%I', %s::text, %s::text)::regclass::oid", (sch, tbl)).fetchone()[0]
        for n, it in enumerate(items):
            sch = it.get("schema") or "public"
            tbl = it["table"]
            ident = sql.Identifier(sch, tbl)
            op = it["op"]
            key = it.get("key") or {}
            if op in ("update", "delete"):
                if not key:
                    raise ValueError("a row without an identity is not editable")
                cols = readable_columns(conn, sch, tbl)
                sel = sql.SQL("SELECT {cols}, xmin::text FROM {t} WHERE {w} FOR UPDATE").format(
                    cols=sql.SQL(", ").join(sql.Identifier(c) for c in cols), t=ident, w=_where(key, True))
                before = conn.execute(sel, [*key.values(), it.get("xmin")]).fetchall()
                if len(before) != 1:
                    conn.rollback()
                    return {"status": "conflict", "item": n, "message": "This row changed or vanished since it was loaded — reload it."}
                images.append({"item": n, "table": f"{sch}.{tbl}", "key": key, "before": dict(zip(cols + ["xmin"], before[0]))})
                if op == "update":
                    vals = it.get("values") or {}
                    stmt = sql.SQL("UPDATE {t} SET {sets} WHERE {w} RETURNING xmin::text").format(
                        t=ident, sets=sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in vals),
                        w=_where(key, True))
                    cur = conn.execute(stmt, [*vals.values(), *key.values(), it.get("xmin")])
                    after = cur.fetchall()
                    if len(after) == 1:
                        images[-1]["after_xmin"] = after[0][0]
                        images[-1]["changed"] = list(vals)
                else:
                    stmt = sql.SQL("DELETE FROM {t} WHERE {w}").format(t=ident, w=_where(key, True))
                    cur = conn.execute(stmt, [*key.values(), it.get("xmin")])
                if cur.rowcount != 1:
                    conn.rollback()
                    return {"status": "conflict", "item": n, "message": "This row changed since it was loaded — reload it."}
            elif op == "insert":
                vals = it.get("values") or {}
                stmt = sql.SQL("INSERT INTO {t} ({cols}) VALUES ({ph})").format(
                    t=ident, cols=sql.SQL(", ").join(sql.Identifier(c) for c in vals),
                    ph=sql.SQL(", ").join(sql.Placeholder() for _ in vals))
                cur = conn.execute(stmt, list(vals.values()))
                if cur.rowcount != 1:
                    conn.rollback()
                    return {"status": "error", "item": n, "message": "The insert did not add one row."}
                images.append({"item": n, "table": f"{sch}.{tbl}", "key": None, "before": None})
            else:
                raise ValueError("unknown op")
        touched = []
        for relid, s, r, i, u, d in conn.execute(
                "SELECT relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_xact_user_tables").fetchall():
            if (i, u, d) != baseline.get(relid, (0, 0, 0)):
                touched.append((relid, s, r))
        others = [f"{s}.{r}" for relid, s, r in touched if relid not in set(oids.values())]
        if others:
            conn.rollback()
            return {"status": "refused", "refusal_rule": "side_effects",
                    "message": "This change would also change " + ", ".join(sorted(others))
                               + " (a cascade or a trigger) — nothing was applied.", "tables": sorted(others)}
        conn.commit()
        return {"status": "ok", "rows": len(items), "images": images}
    except psycopg.Error as e:
        conn.rollback()
        d = e.diag
        return {"status": "error", "sqlstate": d.sqlstate, "message": (d.message_primary or str(e))[:500]}
    finally:
        conn.autocommit = True


def undo_change_set(conn: psycopg.Connection, images: list[dict]) -> dict:
    """One-click undo of an applied change set's UPDATEs while no later change touched those rows (checked by the xmin the apply left).
    A row changed since → nothing is undone, and the table is named."""
    conn.autocommit = False
    try:
        for im in images:
            if im.get("after_xmin") is None or not im.get("changed"):
                continue
            sch, tbl = im["table"].split(".", 1)
            cols = im["changed"]
            stmt = sql.SQL("UPDATE {t} SET {sets} WHERE {w}").format(
                t=sql.Identifier(sch, tbl), sets=sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in cols),
                w=_where(im["key"], True))
            cur = conn.execute(stmt, [*(im["before"][c] for c in cols), *im["key"].values(), im["after_xmin"]])
            if cur.rowcount != 1:
                conn.rollback()
                return {"status": "refused", "refusal_rule": "changed_since",
                        "message": f"A row of {im['table']} changed after this change set — nothing was undone."}
        conn.commit()
        return {"status": "ok"}
    except psycopg.Error as e:
        conn.rollback()
        return {"status": "error", "sqlstate": e.diag.sqlstate, "message": (e.diag.message_primary or str(e))[:500]}
    finally:
        conn.autocommit = True
