"""The caller's reach, computed by the tool's own database — never sent by a caller (design §6.1 step 1; §3).

    pol = policies.get(caller=12, on_behalf_of=None, datname="subello_gl")   # Policy

SqlPolicy asks the ONE enforcement function `dx_door_policy(caller bigint, on_behalf_of bigint, datname text) RETURNS jsonb` (the main
session's db/006+), as the door's own login to the tool's database. The JSON it must answer (every key present; nulls allowed where said):

    {
      "ok": true,                                   -- false → "refusal" says why (unknown member, inactive, unregistered target …)
      "refusal": null | {"rule": "…", "message": "a sentence for the person"},
      "frozen": false,                              -- the freeze switch (design §3 wall 8)
      "caller": {"member_id": 12, "is_agent": false, "active": true, "is_super_admin": false},
      "on_behalf_of": null | {"member_id": 7, "active": true},       -- K38's person, for an agent in a chat turn
      "target": {"datname": "subello_gl", "class": "application",   -- application|workbench|development|memory|kernel|own|system|unclassified
                 "application_key": "gl", "private_by_design": false,
                 "grants_state": "in_place"},                         -- pending|in_place|partial|revoked
      "rights": ["catalog.read", "data.read", …],   -- the rights the caller HOLDS (roles × held_by applied; an agent's people rights absent;
                                                    --   an agent in a chat turn: intersected with the person's)
      "level": "structure" | "masked" | "rows",     -- the caller's level on this target (for an agent: the person's, capped at structure in v1)
      "window": {"read": null | {"id": 4, "expires_at": "…"}, "write": null | {"id": 5, "expires_at": "…"}},
      "workbench": null | {"id": 9, "owner_member_id": 12, "role": "dxw_9", "suspended": false},   -- when class = workbench
      "limits": {"statement_timeout_ms": 30000, "lock_timeout_ms": 5000, "show_rows": 1000, "show_bytes": 8388608,
                 "cell_chars": 2000, "concurrent_runs": 2, "change_set_confirm_rows": 1000, "change_set_max_rows": 10000}
    }

The door signs in to the tool's own database as `developer_meta` (fork B's deploy) and calls six functions there (the main session's
db/006+; the JSON keys below are exactly what the door sends):

    dx_door_policy(caller bigint, on_behalf_of bigint, datname text) RETURNS jsonb      -- the shape above
    dx_door_member_active(member bigint) RETURNS boolean                                -- before anything else, every request
    dx_door_run_open(p jsonb) RETURNS bigint      -- the query_runs row, opened as the request starts (refusals included):
        {"request_id", "caller", "on_behalf_of", "agent_run_id", "source", "datname", "kind", "sql_sha256", "sql"}
    dx_door_statement_log(p jsonb) RETURNS bigint -- a door_statements row. INSERT (no "id"): the intent, before execution:
        {"run_id", "statement_index", "class", "tier", "fingerprint", "status": "running"}
                                                  -- UPDATE (with "id"), after execution — returns the same id:
        {"id", "status": ok|error|timeout|cancelled, "sqlstate", "rows_affected", "ms", "backend_pid", "error_masked"}
    dx_door_run_close(run_id bigint, p jsonb)     -- the request's end:
        {"status": ok|refused|error|timeout|cancelled, "refusal_rule", "tier", "level", "rows_returned", "truncated", "ms", "error"}
                                                  -- "error" is already masked (quoted fragments and key values → •••)
    dx_door_usage_bump(caller bigint, kind text)  -- a named catalog query counted, not rowed (kind 'named:<name>')
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field


@dataclass
class Policy:
    ok: bool
    refusal: dict | None = None
    frozen: bool = False
    caller: dict = field(default_factory=dict)
    on_behalf_of: dict | None = None
    target: dict = field(default_factory=dict)
    rights: set = field(default_factory=set)
    level: str = "structure"
    window: dict = field(default_factory=lambda: {"read": None, "write": None})
    workbench: dict | None = None
    limits: dict = field(default_factory=dict)

    @classmethod
    def from_json(cls, d: dict) -> "Policy":
        return cls(ok=bool(d.get("ok")), refusal=d.get("refusal"), frozen=bool(d.get("frozen")), caller=d.get("caller") or {},
                   on_behalf_of=d.get("on_behalf_of"), target=d.get("target") or {}, rights=set(d.get("rights") or []),
                   level=d.get("level") or "structure", window=d.get("window") or {"read": None, "write": None},
                   workbench=d.get("workbench"), limits=d.get("limits") or {})

    @property
    def is_agent(self) -> bool:
        return bool(self.caller.get("is_agent"))

    def has(self, right: str) -> bool:
        return right in self.rights


DEFAULT_LIMITS = {"statement_timeout_ms": 30000, "lock_timeout_ms": 5000, "idle_in_tx_ms": 60000, "transaction_timeout_ms": 120000,
                  "show_rows": 1000, "show_bytes": 8 * 1024 * 1024, "cell_chars": 2000, "concurrent_runs": 2,
                  "change_set_confirm_rows": 1000, "change_set_max_rows": 10000}


class Policies:  # pragma: no cover - interface
    def get(self, caller: int, on_behalf_of: int | None, datname: str) -> Policy:
        raise NotImplementedError

    def member_active(self, member: int) -> bool:
        raise NotImplementedError

    def run_open(self, p: dict) -> int:
        raise NotImplementedError

    def statement_log(self, p: dict) -> int:
        raise NotImplementedError

    def run_close(self, run_id: int, p: dict) -> None:
        raise NotImplementedError

    def usage_bump(self, caller: int, kind: str) -> None:
        raise NotImplementedError


class FakePolicies(Policies):
    """For proofs: policies keyed by (caller, datname), the audit kept in memory."""

    def __init__(self, table: dict, inactive: set | None = None):
        self.table = table
        self.inactive = inactive or set()
        self.statements: list[dict] = []
        self.runs: list[dict] = []
        self.usage: dict = {}

    def get(self, caller, on_behalf_of, datname) -> Policy:
        d = self.table.get((caller, datname))
        if d is None:
            return Policy(ok=False, refusal={"rule": "unknown", "message": "Unknown member or database."})
        d = dict(d)
        d.setdefault("ok", True)
        d.setdefault("limits", DEFAULT_LIMITS)
        return Policy.from_json(d)

    def member_active(self, member):
        return member not in self.inactive

    def run_open(self, p):
        self.runs.append(dict(p))
        return len(self.runs)

    def statement_log(self, p):
        if p.get("id"):
            self.statements[int(p["id"]) - 1].update(p)
            return int(p["id"])
        self.statements.append(dict(p))
        return len(self.statements)

    def run_close(self, run_id, p):
        self.runs[run_id - 1].update(p)

    def usage_bump(self, caller, kind):
        self.usage[(caller, kind)] = self.usage.get((caller, kind), 0) + 1


class SqlPolicies(Policies):
    """Production: the tool's own database, as `developer_meta` (a callable returning a fresh psycopg connection to it)."""

    def __init__(self, connect):
        self._connect = connect

    def _one(self, q, args):
        with self._connect() as conn:
            conn.autocommit = True
            # developer_meta's role default is a read-only transaction (it is the catalog tier on every target); on the tool's OWN
            # database the door writes its audit through dx_door_* functions, so this one connection turns the default off. The
            # owner's ROOT_STEPS can say the same per database: ALTER ROLE developer_meta IN DATABASE <own> SET
            # default_transaction_read_only = off.
            conn.execute("SET default_transaction_read_only = off")
            row = conn.execute(q, args).fetchone()
            return row[0] if row else None

    def get(self, caller, on_behalf_of, datname) -> Policy:
        d = self._one("SELECT dx_door_policy(%s, %s, %s)", (caller, on_behalf_of, datname))
        if isinstance(d, str):
            d = json.loads(d)
        p = Policy.from_json(d or {})
        p.limits = {**DEFAULT_LIMITS, **(p.limits or {})}
        return p

    def member_active(self, member):
        return bool(self._one("SELECT dx_door_member_active(%s)", (member,)))

    def run_open(self, p):
        return int(self._one("SELECT dx_door_run_open(%s::jsonb)", (json.dumps(p),)))

    def statement_log(self, p):
        return int(self._one("SELECT dx_door_statement_log(%s::jsonb)", (json.dumps(p),)))

    def run_close(self, run_id, p):
        self._one("SELECT dx_door_run_close(%s, %s::jsonb)::text", (run_id, json.dumps(p)))

    def usage_bump(self, caller, kind):
        self._one("SELECT dx_door_usage_bump(%s, %s)::text", (caller, kind))
