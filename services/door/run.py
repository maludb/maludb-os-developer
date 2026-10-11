"""One `run` request end to end (design §6.1): who → split → classify → decide → screen functions → execute → audit.

    answer = run_request(cfg, policies, registry, req)

`req` is the parsed request: {request_id, caller, on_behalf_of, agent_run_id, source, datname, sql}. EVERY statement of the script is
classified, decided and screened BEFORE the first one runs — a refusal anywhere refuses the whole run, so a script never half-runs because
its fifth statement is not allowed. One run uses one tier and one connection (a workbench's script keeps its transaction across its
statements); a run that would need two tiers is refused. Statements then execute in order and stop at the first error.

The audit: the query_runs row is OPENED as the request starts (dx_door_run_open) and CLOSED on every way out (dx_door_run_close) —
refusals, errors, timeouts and cancels included; each statement writes its intent row before it runs and its result after
(dx_door_statement_log). Error texts reach the audit masked; the caller sees them whole.
"""
from __future__ import annotations

import hashlib
import threading
import time

import psycopg

from door import classify as classify_mod
from door import connections, decide as decide_mod, execute, functions, pgquery


class Registry:
    """The running requests: cancel by request id (only by the caller who started it), and the per-person concurrency cap."""

    def __init__(self):
        self._lock = threading.Lock()
        self.running: dict[str, tuple[int, execute.Runner | None]] = {}

    def start(self, request_id: str, caller: int, cap: int) -> bool:
        with self._lock:
            if request_id in self.running:
                return False
            if sum(1 for c, _ in self.running.values() if c == caller) >= cap:
                return False
            self.running[request_id] = (caller, None)
            return True

    def attach(self, request_id: str, runner) -> None:
        with self._lock:
            c, _ = self.running[request_id]
            self.running[request_id] = (c, runner)

    def end(self, request_id: str) -> None:
        with self._lock:
            self.running.pop(request_id, None)

    def cancel(self, request_id: str, caller: int) -> bool:
        with self._lock:
            entry = self.running.get(request_id)
        if not entry or entry[0] != caller or entry[1] is None:
            return False
        entry[1].cancel()
        return True


def refused(rule: str, message: str, **extra) -> dict:
    return {"status": "refused", "refusal_rule": rule, "message": message, "statements": [], **extra}


def app_name(caller, request_id) -> str:
    """`developer:<member>:<run>` (design §6.10) — dx_signal() refuses any session whose application_name starts `developer`."""
    return f"developer:{caller}:{request_id}"[:63]


def tier_settings(cfg, policy, tier: str) -> dict:
    lim = policy.limits
    if tier == "workbench":
        return dict(cfg.workbench_settings)
    return {"statement_timeout_ms": lim.get("statement_timeout_ms", 30000), "lock_timeout_ms": lim.get("lock_timeout_ms", 5000),
            "idle_in_tx_ms": lim.get("idle_in_tx_ms", 60000), "transaction_timeout_ms": lim.get("transaction_timeout_ms", 120000)}


def run_request(cfg, policies, registry: Registry, req: dict) -> dict:
    t0 = time.monotonic()
    rid = str(req.get("request_id") or "")
    caller = int(req.get("caller") or 0)
    datname = req.get("datname") or ""
    sql = req.get("sql") or ""
    try:
        connections.check_name(datname)
    except connections.DoorRefusal as e:
        return refused(e.rule, e.message)
    run_id = policies.run_open({"request_id": rid, "caller": caller, "on_behalf_of": req.get("on_behalf_of"),
                                "agent_run_id": req.get("agent_run_id"), "source": req.get("source") or "screen", "datname": datname,
                                "kind": "run", "sql_sha256": hashlib.sha256(sql.encode()).hexdigest(), "sql": sql})
    state = {"tier": None, "level": None}

    def close(answer: dict) -> dict:
        sts = answer.get("statements") or []
        status = answer.get("status") or "error"
        policies.run_close(run_id, {
            "status": status if status in ("ok", "refused", "error", "timeout", "cancelled") else "error",
            "refusal_rule": answer.get("refusal_rule"), "tier": state["tier"], "level": state["level"],
            "rows_returned": sum(len(s.get("rows") or []) for s in sts), "truncated": any(s.get("truncated") for s in sts),
            "ms": int((time.monotonic() - t0) * 1000),
            "error": execute.mask_message(sts[-1].get("message")) if sts and sts[-1].get("message") else
                     (execute.mask_message(answer.get("message")) if status == "refused" else None)})
        answer["run_id"] = run_id
        return answer

    policy = policies.get(caller, req.get("on_behalf_of"), datname)
    state["level"] = policy.level
    if not policy.ok:
        r = policy.refusal or {}
        return close(refused(r.get("rule") or "policy", r.get("message") or "You may not use this database."))
    try:
        parts = pgquery.split(sql)
    except pgquery.ParseError as e:
        return close(refused("syntax", e.message, position=e.position))
    if not parts:
        return close(refused("empty", "There is no statement."))

    plan = []
    for i, part in enumerate(parts):
        try:
            tree = pgquery.parse(part.text)
        except pgquery.ParseError as e:
            return close(refused("syntax", e.message, position=(part.start + e.position) if e.position is not None else None,
                                 statement_index=i))
        c = classify_mod.classify(part.text, tree)
        d = decide_mod.decide(c, policy)
        if d.tier is None:
            return close(refused(d.rule or "statement", d.refusal or "Not offered.", statement_index=i, statement_class=c.cls))
        plan.append((i, part, tree, c, d))
    tiers = {d.tier for *_, d in plan}
    if len(tiers) != 1:
        return close(refused("tiers", "This script mixes statements that run with different rights — run them separately."))
    tier = tiers.pop()
    state["tier"] = tier

    if not registry.start(rid, caller, int(policy.limits.get("concurrent_runs", 2))):
        return close(refused("busy", "You already have runs in progress — wait for one to finish."))
    results = []
    note = None
    conn = None
    try:
        wb_role = (policy.workbench or {}).get("role") if tier == "workbench" else None
        conn_tier = "read" if tier == "own" else tier
        try:
            conn = connections.connect(cfg, conn_tier, datname, workbench_role=wb_role, app=app_name(caller, rid))
        except connections.DoorRefusal as e:
            return close(refused(e.rule, e.message))
        except psycopg.OperationalError:
            if tier == "workbench":
                return close(refused("credential", "The door cannot sign in to this workbench (its password was changed from inside?) "
                                                   "— a super-admin can reset its credential."))
            return close(refused("connect", "The door could not connect to this database."))
        tier_role = wb_role or cfg.roles.get(conn_tier)
        for i, part, tree, c, d in plan:                                  # the function screen, before anything runs
            why = functions.screen(conn, functions.called_functions(tree), tier_role)
            if why:
                return close(refused("function", why, statement_index=i))
        runner = execute.Runner(conn, tier_settings(cfg, policy, tier), policy.limits)
        registry.attach(rid, runner)
        for i, part, tree, c, d in plan:
            try:
                fp = pgquery.fingerprint(part.text)
            except pgquery.ParseError:
                fp = None
            sid = policies.statement_log({"run_id": run_id, "statement_index": i, "class": c.cls, "tier": tier, "fingerprint": fp,
                                          "status": "running"})
            r = runner.run(i, part.text, c.cls, wrap=d.wrap, cursorable=c.cursorable and d.wrap == "read_only")
            if r.position is not None:
                r.position += part.start
            policies.statement_log({"id": sid, "status": r.status, "sqlstate": r.sqlstate, "rows_affected": r.rows_affected,
                                    "ms": r.ms, "backend_pid": r.backend_pid, "error_masked": execute.mask_message(r.message)})
            results.append(r.as_dict())
            if r.status != "ok":
                break
        note = runner.finish()
    finally:
        registry.end(rid)
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
    status = "ok" if results and all(r["status"] == "ok" for r in results) else (results[-1]["status"] if results else "error")
    return close({"status": status, "tier": tier, "statements": results, "note": note, "ms": int((time.monotonic() - t0) * 1000)})
