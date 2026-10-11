"""The workbench lifecycle, composed by the door as the rolemaker (design §6.1, §6.5): a login role and a database of one name, each
workbench isolated from every other.

    wb = create(cfg, owner_note="member 12", template=cfg.template)      # {"name": "dxw_7", "role": "dxw_7"}
    drop(cfg, "dxw_7")
    reset_credential(cfg, "dxw_7")

- The role is created LOGIN with a generated password kept in the door's 0600 store; PostgreSQL receives a SCRAM verifier computed on
  the client (libpq's PQencryptPasswordConn), so no server log ever holds the password.
- PostgreSQL 16 gives the creating CREATEROLE role ADMIN on the new role but not SET; to create a database OWNED by it, the rolemaker
  grants itself SET (INHERIT FALSE) on that one role, and acts as it only inside these composed statements (SET ROLE … RESET ROLE).
- The database is created owned by the workbench role (from the template when given — the owner's `dx_template`, which carries the
  untrusted extensions a clone needs), CONNECT and TEMPORARY revoked from PUBLIC: another workbench's role cannot even connect.
- The workbench role's settings carry the door's ceilings; the door re-asserts them before each statement anyway (a role may change its
  own defaults).
- Only names with the configured prefixes are ever created or dropped.
"""
from __future__ import annotations

import psycopg
from psycopg import sql

from door import connections


def _rm(cfg) -> psycopg.Connection:
    return connections.connect(cfg, "rolemaker", cfg.rolemaker_db, app="developer:rolemaker")


def _next_name(conn, prefix: str) -> str:
    rows = conn.execute("SELECT datname FROM pg_database WHERE starts_with(datname, %s)"
                        " UNION SELECT rolname FROM pg_roles WHERE starts_with(rolname, %s)", (prefix, prefix)).fetchall()
    n = 0
    for (name,) in rows:
        tail = name[len(prefix):]
        if tail.isdigit():
            n = max(n, int(tail))
    return f"{prefix}{n + 1}"


def _verifier(conn, role: str, password: str) -> str:
    return conn.pgconn.encrypt_password(password.encode(), role.encode(), b"scram-sha-256").decode()


def create(cfg, *, prefix: str | None = None, template: str | None = None) -> dict:
    prefix = prefix or cfg.workbench_prefix
    store = connections.WorkbenchStore(cfg.workbench_store)
    with _rm(cfg) as conn:
        name = _next_name(conn, prefix)
        connections.check_name(name)
        role = sql.Identifier(name)
        pw = store.new(name)
        conn.execute(sql.SQL("CREATE ROLE {} LOGIN NOINHERIT PASSWORD {}").format(role, sql.Literal(_verifier(conn, name, pw))))
        me = conn.execute("SELECT current_user").fetchone()[0]
        conn.execute(sql.SQL("GRANT {} TO {} WITH INHERIT FALSE, SET TRUE").format(role, sql.Identifier(me)))
        s = cfg.workbench_settings
        for guc, val in (("statement_timeout", f"{s['statement_timeout_ms']}ms"), ("lock_timeout", f"{s['lock_timeout_ms']}ms"),
                         ("idle_in_transaction_session_timeout", f"{s['idle_in_tx_ms']}ms"),
                         ("transaction_timeout", f"{s['transaction_timeout_ms']}ms")):
            conn.execute(sql.SQL("ALTER ROLE {} SET {} = {}").format(role, sql.Identifier(guc), sql.Literal(val)))
        # CREATE DATABASE needs CREATEDB on the CURRENT role (the rolemaker), and OWNER needs SET on the new owner (granted above).
        if template:
            conn.execute(sql.SQL("CREATE DATABASE {} OWNER {} TEMPLATE {}").format(role, role,
                                                                                  sql.Identifier(connections.check_name(template))))
        else:
            conn.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(role, role))
        conn.execute(sql.SQL("SET ROLE {}").format(role))              # the owner revokes PUBLIC's CONNECT and TEMPORARY
        try:
            conn.execute(sql.SQL("REVOKE CONNECT, TEMPORARY ON DATABASE {} FROM PUBLIC").format(role))
        finally:
            conn.execute("RESET ROLE")
    return {"name": name, "role": name}


def drop(cfg, name: str) -> None:
    connections.check_name(name)
    if not connections.is_tool_database(cfg, name):
        raise connections.DoorRefusal("name", "The door drops only the databases it created.")
    with _rm(cfg) as conn:
        exists = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (name,)).fetchone()
        if exists:
            conn.execute(sql.SQL("SET ROLE {}").format(sql.Identifier(name)))
            try:
                conn.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(name)))
            finally:
                conn.execute("RESET ROLE")
            conn.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(name)))
    connections.WorkbenchStore(cfg.workbench_store).forget(name)


def reset_credential(cfg, name: str) -> None:
    connections.check_name(name)
    if not connections.is_tool_database(cfg, name):
        raise connections.DoorRefusal("name", "The door resets only the roles it created.")
    store = connections.WorkbenchStore(cfg.workbench_store)
    with _rm(cfg) as conn:
        pw = store.new(name)
        conn.execute(sql.SQL("ALTER ROLE {} PASSWORD {}").format(sql.Identifier(name), sql.Literal(_verifier(conn, name, pw))))
