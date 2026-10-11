"""The door's NAMED queries (design §6.1): a fixed library of catalog, statistics and activity reads, run as the meta tier with bound
parameters — never a person's SQL. A caller names a query and passes its parameters; the door alone holds the text. Counted, not rowed,
in the audit (door_usage, design §6.10). Phase 1's slices add their queries here; the proof uses these.
"""
from __future__ import annotations

from door import pgquery

QUERIES: dict[str, dict] = {
    "databases": {"sql": "SELECT datname, pg_database_size(oid) AS bytes, datallowconn FROM pg_database WHERE NOT datistemplate"
                          " ORDER BY datname", "params": []},
    "tables": {"sql": "SELECT c.oid::bigint, n.nspname, c.relname, c.relkind, c.reltuples::bigint,"
                      " pg_total_relation_size(c.oid) AS bytes FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
                      " WHERE c.relkind IN ('r','p','v','m','f') AND n.nspname = %(schema)s ORDER BY c.relname LIMIT %(limit)s"
                      " OFFSET %(offset)s", "params": ["schema", "limit", "offset"]},
    "columns_map": {"sql": "SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod) FROM pg_attribute a"
                           " JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace"
                           " WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m','f')"
                           " AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%%'"
                           " ORDER BY 1, 2, a.attnum", "params": []},
    "activity": {"sql": "SELECT pid, usename, datname, state, wait_event_type, wait_event, backend_xmin::text,"
                        " now() - xact_start AS in_xact, pg_blocking_pids(pid) AS blocked_by, query FROM pg_stat_activity"
                        " WHERE backend_type = 'client backend' ORDER BY xact_start NULLS LAST LIMIT 500", "params": [],
                 "normalize": "query"},
}


def run_named(conn, name: str, params: dict) -> dict:
    q = QUERIES.get(name)
    if q is None:
        return {"status": "refused", "refusal_rule": "named", "message": "Unknown named query."}
    args = {k: params.get(k) for k in q["params"]}
    cur = conn.execute(q["sql"], args)
    cols = [d.name for d in cur.description]
    rows = [list(r) for r in cur.fetchall()]
    norm = q.get("normalize")
    if norm:
        i = cols.index(norm)
        for r in rows:
            if r[i]:
                try:
                    r[i] = pgquery.normalize(r[i])
                except pgquery.ParseError:
                    r[i] = "<not normalisable>"
    return {"status": "ok", "columns": cols, "rows": rows}
