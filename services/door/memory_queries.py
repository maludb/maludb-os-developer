"""The memory section's NAMED queries (design §6.8), run as the memory login, which reaches `maludb_memory_auditor` only by SET ROLE inside
these statements. That role holds BYPASSRLS once set and can read ciphertext, so this library is fixed code with a STATIC TEST:
`forbidden_references()` parses every query with PostgreSQL's parser and names any reference to a secret table or column, or a call to a
claim function — the proof fails if the list is not empty. Each entry is ONE statement; the door wraps it as
SET ROLE <auditor>; <query>; RESET ROLE inside BEGIN READ ONLY … COMMIT.
"""
from __future__ import annotations

import re

from door import pgquery

QUERIES: dict[str, str] = {
    "tenant_counts": "SELECT (SELECT count(*) FROM maludb_core.\"malu$episode_object\") AS episodes,"
                     " (SELECT count(*) FROM maludb_core.\"malu$document\") AS documents,"
                     " (SELECT count(*) FROM maludb_core.\"malu$svpor_subject\") AS subjects",
    "embedding_backlog": "SELECT count(*) AS dirty, min(e.dirty_since) AS oldest FROM maludb_core.\"malu$embedding_dirty\" e",
    "extension_version": "SELECT extversion FROM pg_extension WHERE extname = 'maludb_core'",
}

FORBIDDEN_TABLE = re.compile(r"^malu\$(secret|secret_version|secret_use|secret_master_key|auth_token|auth_signing_key|pepper)", re.I)
FORBIDDEN_COLUMN = re.compile(r"^(value_encrypted|token_hash|secret_hash|password_hash|signing_key|pepper)$", re.I)
FORBIDDEN_FUNC = re.compile(r"_claim$", re.I)


def _walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from _walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from _walk(v)


def run_memory(conn, auditor_role: str, name: str) -> dict:
    """One named memory query on `conn` (the memory login, on a memory database): BEGIN READ ONLY; SET ROLE <auditor>; the query;
    RESET ROLE; COMMIT. Never a caller's text."""
    from psycopg import sql
    text = QUERIES.get(name)
    if text is None:
        return {"status": "refused", "refusal_rule": "named", "message": "Unknown memory query."}
    conn.execute("BEGIN READ ONLY")
    try:
        conn.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(auditor_role)))
        cur = conn.execute(text)
        cols = [d.name for d in cur.description]
        rows = [list(r) for r in cur.fetchall()]
        conn.execute("COMMIT")
        return {"status": "ok", "columns": cols, "rows": rows}
    except Exception:
        conn.execute("ROLLBACK")
        raise


def forbidden_references(queries: dict[str, str] | None = None) -> list[str]:
    bad = []
    for name, text in (queries or QUERIES).items():
        tree = pgquery.parse(text)
        if len(tree.get("stmts") or []) != 1:
            bad.append(f"{name}: not exactly one statement")
        for d in _walk(tree):
            if d.get("relname") and "relpersistence" in d and FORBIDDEN_TABLE.search(d.get("relname") or ""):   # a RangeVar body
                bad.append(f"{name}: table {d.get('relname')}")
            cr = d.get("ColumnRef")
            if isinstance(cr, dict):
                for f in cr.get("fields") or []:
                    s = (f.get("String") or {}).get("sval") or ""
                    if FORBIDDEN_COLUMN.search(s):
                        bad.append(f"{name}: column {s}")
                    if f.get("A_Star") is not None:
                        bad.append(f"{name}: SELECT * (name the columns)")
            if "funcname" in d and "funcformat" in d:                                                       # a FuncCall body
                fn = ((d.get("funcname") or [{}])[-1].get("String") or {}).get("sval") or ""
                if FORBIDDEN_FUNC.search(fn):
                    bad.append(f"{name}: calls {fn}()")
    return bad
