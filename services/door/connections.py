"""The door's configuration and its connections to targets (design §6.1). Only the door reads the credentials: the fixed roles' passwords
in a libpq passfile (0600, owned by the door's system user), each workbench role's generated password in a JSON store (0600).

A connection is always fresh: one per request and per tier — never carried from one person or agent run to another (S7). The target's
name is checked against `^[a-z0-9_]+$` before anything else (design §3 wall 1), and the conninfo is built by psycopg's own quoting, so no
name can become a connection option (the pg_dump `-d` conninfo trap — 05-safety §3).
"""
from __future__ import annotations

import json
import os
import re
import secrets
from dataclasses import dataclass, field

import psycopg
from psycopg.conninfo import make_conninfo

NAME_RE = re.compile(r"^[a-z0-9_]{1,63}$")
FIXED_TIERS = ("meta", "read", "read_masked", "write", "ops", "memory", "rolemaker")


class DoorRefusal(Exception):
    def __init__(self, rule: str, message: str):
        super().__init__(message)
        self.rule = rule
        self.message = message


@dataclass
class Config:
    passfile: str
    workbench_store: str
    roles: dict = field(default_factory=lambda: {
        "meta": "developer_meta", "read": "developer_read", "read_masked": "developer_read_masked", "write": "developer_write",
        "ops": "developer_ops", "memory": "developer_memory", "rolemaker": "developer_rolemaker", "grantor": "developer_grantor"})
    host: str = "127.0.0.1"
    port: int = 5432
    sslmode: str = "prefer"
    workbench_prefix: str = "dxw_"
    rehearsal_prefix: str = "dxr_"
    template: str | None = "dx_template"
    rolemaker_db: str = "postgres"            # where the rolemaker connects to run CREATE/DROP ROLE and DATABASE
    own_db: str = "subello_developer"         # the tool's own database (policies and the audit, as developer_meta)
    memory_auditor: str = "maludb_memory_auditor"
    pg_dump: str = "/usr/lib/postgresql/17/bin/pg_dump"
    pg_restore: str = "/usr/lib/postgresql/17/bin/pg_restore"
    workbench_settings: dict = field(default_factory=lambda: {"statement_timeout_ms": 300000, "lock_timeout_ms": 10000,
                                                               "idle_in_tx_ms": 120000, "transaction_timeout_ms": 600000})

    @classmethod
    def from_env(cls) -> "Config":
        c = cls(passfile=os.environ["DX_DOOR_PASSFILE"], workbench_store=os.environ["DX_DOOR_WORKBENCH_STORE"])
        for t in FIXED_TIERS + ("grantor",):
            v = os.environ.get(f"DX_ROLE_{t.upper()}")
            if v:
                c.roles[t] = v
        c.host = os.environ.get("DX_PGHOST", c.host)
        c.port = int(os.environ.get("DX_PGPORT", c.port))
        c.sslmode = os.environ.get("DX_PGSSLMODE", c.sslmode)
        c.workbench_prefix = os.environ.get("DX_WORKBENCH_PREFIX", c.workbench_prefix)
        c.rehearsal_prefix = os.environ.get("DX_REHEARSAL_PREFIX", c.rehearsal_prefix)
        c.template = os.environ.get("DX_TEMPLATE", c.template) or None
        c.rolemaker_db = os.environ.get("DX_ROLEMAKER_DB", c.own_db if "DX_OWN_DB" not in os.environ else os.environ["DX_OWN_DB"])
        c.own_db = os.environ.get("DX_OWN_DB", c.own_db)
        c.memory_auditor = os.environ.get("DX_MEMORY_AUDITOR", c.memory_auditor)
        return c


def check_name(name: str) -> str:
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise DoorRefusal("name", "That is not a database the tool may reach.")
    return name


def is_tool_database(cfg: Config, name: str) -> bool:
    return name.startswith(cfg.workbench_prefix) or name.startswith(cfg.rehearsal_prefix)


class WorkbenchStore:
    """{role: password} in a 0600 JSON file the door alone reads and writes."""

    def __init__(self, path: str):
        self.path = path

    def _read(self) -> dict:
        try:
            with open(self.path) as f:
                return json.load(f)
        except FileNotFoundError:
            return {}

    def _write(self, d: dict) -> None:
        tmp = self.path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(d, f)
        os.replace(tmp, self.path)

    def get(self, role: str) -> str | None:
        return self._read().get(role)

    def new(self, role: str) -> str:
        pw = secrets.token_urlsafe(32)
        d = self._read()
        d[role] = pw
        self._write(d)
        return pw

    def forget(self, role: str) -> None:
        d = self._read()
        if d.pop(role, None) is not None:
            self._write(d)


def conninfo(cfg: Config, role: str, dbname: str, *, password: str | None = None, app: str = "developer") -> str:
    check_name(dbname)
    kw = dict(host=cfg.host, port=cfg.port, dbname=dbname, user=role, sslmode=cfg.sslmode, connect_timeout=5,
              application_name=app[:63])
    if password is not None:
        kw["password"] = password
    else:
        kw["passfile"] = cfg.passfile
    return make_conninfo(**kw)


def connect(cfg: Config, tier: str, dbname: str, *, workbench_role: str | None = None, app: str = "developer") -> psycopg.Connection:
    if tier == "workbench":
        if not workbench_role:
            raise DoorRefusal("workbench", "No workbench role.")
        pw = WorkbenchStore(cfg.workbench_store).get(workbench_role)
        if pw is None:
            raise DoorRefusal("credential", "This workbench's credential is lost — a super-admin can reset it.")
        ci = conninfo(cfg, workbench_role, dbname, password=pw, app=app)
    else:
        role = cfg.roles.get(tier)
        if not role:
            raise DoorRefusal("tier", "No such tier.")
        ci = conninfo(cfg, role, dbname, app=app)
    conn = psycopg.connect(ci, autocommit=True)
    return conn
