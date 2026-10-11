"""The grants service (design §6.1, §6.9) — the unit developer-grants.service, its own system user and passfile, never the door's.

    services/.venv/bin/python services/grants/service.py            (a pass a minute; --once for one pass)

Each pass: read the plan from the tool's own database as `developer_grantor` —

    mcp_grant_plan(datname text, schema_name text, table_name text, column_name text, class text, cleared_secret boolean)

one row per classified column of every registered target the owner granted (class `application` or `development`, grants_state in_place
or partial), plus ONE row with table_name NULL for each such target (so a target with no classification yet is still passed) — then, for
each target, connect to it as the grantor and run grants.run_pass(). The changes are recorded through

    dx_grants_pass_log(datname text, p jsonb)        -- {"changes": [...], "not_granted": [...], "ms": n}  (EXECUTE for the grantor)

so drift marks them explained; when that function does not exist yet, they are written to the journal instead.
"""
from __future__ import annotations

import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or ".") != _HERE]
sys.path.insert(0, os.path.dirname(_HERE))

import psycopg  # noqa: E402

from door import connections  # noqa: E402
from grants.grants import run_pass  # noqa: E402

PLAN_SQL = ("SELECT datname, schema_name, table_name, column_name, class, cleared_secret FROM mcp_grant_plan"
            " ORDER BY datname, schema_name, table_name, column_name")


def one_pass(cfg) -> dict:
    tiers = {"read": cfg.roles["read"], "read_masked": cfg.roles["read_masked"], "write": cfg.roles["write"]}
    by_db: dict[str, list[dict]] = {}
    with connections.connect(cfg, "grantor", cfg.own_db, app="developer:grants") as own:
        for datname, sch, tbl, col, cls, cleared in own.execute(PLAN_SQL).fetchall():
            rows = by_db.setdefault(datname, [])
            if tbl and col:
                rows.append({"schema": sch, "table": tbl, "column": col, "class": cls or "none", "cleared_secret": bool(cleared)})
    report = {}
    for datname, plan in by_db.items():
        t0 = time.monotonic()
        try:
            with connections.connect(cfg, "grantor", datname, app="developer:grants") as conn:
                rep = run_pass(conn, plan, tiers)
        except (psycopg.Error, connections.DoorRefusal) as e:
            rep = {"changes": [], "not_granted": [], "error": str(e)[:300]}
        rep["ms"] = int((time.monotonic() - t0) * 1000)
        report[datname] = rep
        if rep.get("changes") or rep.get("not_granted") or rep.get("error"):
            try:
                with connections.connect(cfg, "grantor", cfg.own_db, app="developer:grants") as own:
                    own.execute("SET default_transaction_read_only = off")
                    own.execute("SELECT dx_grants_pass_log(%s, %s::jsonb)::text", (datname, json.dumps(rep)))
            except psycopg.errors.UndefinedFunction:
                print(json.dumps({"grants_pass": datname, **rep}), flush=True)
    return report


def main() -> int:  # pragma: no cover - the unit's entry point
    cfg = connections.Config.from_env()
    if "--once" in sys.argv:
        print(json.dumps(one_pass(cfg)), flush=True)
        return 0
    interval = int(os.environ.get("DX_GRANTS_INTERVAL", "60"))
    while True:
        try:
            one_pass(cfg)
        except Exception as e:
            print(json.dumps({"grants_pass_error": type(e).__name__, "message": str(e)[:300]}), flush=True)
        time.sleep(interval)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
