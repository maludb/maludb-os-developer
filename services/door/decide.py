"""Decide (design §6.1 step 5): the statement's class × the target's ceiling × the caller's rights and level × the open window choose a
tier — or a refusal in a sentence for the person. Pure: no I/O, so every rule is proven by table tests.

    d = decide(classification, policy)
    d.tier      → 'read' | 'read_masked' | 'workbench' | 'own' | None
    d.wrap      → 'read_only' (BEGIN READ ONLY … COMMIT) | 'rollback' (BEGIN … ROLLBACK: EXPLAIN ANALYZE of a write, workbench only) | None
    d.refusal   → the sentence, when tier is None
    d.rule      → a short machine word for the refusal (for the audit and the UI)

Typed SQL never reaches the write tier: a data change on an installed application is a grid change set (kind `apply`, composed by the
tool) or a migration draft — the editor is not a side door (R86).
"""
from __future__ import annotations

from dataclasses import dataclass

from door.classify import Classification
from door.policy import Policy


@dataclass
class Decision:
    tier: str | None
    wrap: str | None = None
    refusal: str | None = None
    rule: str | None = None


def _no(rule: str, sentence: str) -> Decision:
    return Decision(None, None, sentence, rule)


APP_DML = ("This changes data in an installed application: edit the rows in the grid (in a write window), or save it as a "
           "migration draft.")
APP_DDL = ("This changes the schema of an installed application: save it as a migration draft, or rehearse it on a workbench.")


def decide(c: Classification, p: Policy) -> Decision:
    if not p.ok:
        r = p.refusal or {}
        return _no(r.get("rule") or "policy", r.get("message") or "You may not use this database.")
    if p.frozen:
        return _no("frozen", "The tool is frozen by a super-admin.")
    if c.cls == "refused":
        return _no("statement", (c.reason or "This statement is not offered.").rstrip(".") + ".")
    cls_t = (p.target or {}).get("class")
    if cls_t in (None, "", "system", "unclassified"):
        return _no("target", "This database is not one the tool may reach.")
    if cls_t == "kernel":
        return _no("kernel", "The kernel's database is structure only — use the object pages.")
    if cls_t == "memory":
        return _no("memory", "Memory databases are read through the memory section.")

    explain_plain = c.cls == "explain" and not c.analyze
    reads_rows = c.cls == "read" or (c.cls == "explain" and c.analyze and c.wraps == "read")

    if cls_t == "workbench":
        wb = p.workbench or {}
        if p.is_agent:
            return _no("agent", "Agents do not work on workbenches; they rehearse proposals on a throwaway copy.")
        if wb.get("suspended"):
            return _no("quota", "This workbench is over its size quota — shrink it or drop it.")
        if wb.get("owner_member_id") != p.caller.get("member_id"):
            return _no("owner", "This workbench is someone else's.")
        if reads_rows or explain_plain:
            if not p.has("workbench.use"):
                return _no("right", "Workbenches are an Engineer's.")
            return Decision("workbench", "read_only" if c.cursorable else None)
        if not p.has("workbench.apply"):
            return _no("right", "Changing a workbench is an Engineer's.")
        if c.cls == "explain" and c.analyze:
            return Decision("workbench", "rollback")
        return Decision("workbench", None)

    if cls_t == "own":
        if (reads_rows or explain_plain) and p.has("audit.read"):
            return Decision("own", "read_only")
        return _no("own", "The tool's own database is read by the admin through its screens.")

    if cls_t not in ("application", "development"):
        return _no("target", "This database is not one the tool may reach.")

    grants = (p.target or {}).get("grants_state")
    private = bool((p.target or {}).get("private_by_design"))
    window_read = (p.window or {}).get("read")

    if explain_plain:
        if not p.has("plans.explain"):
            return _no("right", "Plans are a Viewer's right, and you hold none here.")
        if grants not in ("in_place", "partial"):
            return _no("grants", "The owner has not granted this database to the tool yet.")
        tier = "read_masked"
        if (not p.is_agent and p.has("data.read") and p.level == "rows" and p.has("data.unmask")
                and (not private or window_read)):
            tier = "read"
        return Decision(tier, "read_only")

    if reads_rows:
        if p.is_agent:
            return _no("agent", "Agents read no rows (version 1) — ask for the plan, or hand the SQL to the person.")
        if not p.has("data.read"):
            return _no("right", "Reading rows is an Engineer's.")
        if p.level not in ("masked", "rows"):
            return _no("level", "Structure only for you on this database — ask an admin for a level.")
        if grants not in ("in_place", "partial"):
            return _no("grants", "The owner has not granted this database to the tool yet.")
        if private and not window_read:
            return _no("window", "This database is private by design: open a read window first.")
        tier = "read" if (p.level == "rows" and p.has("data.unmask")) else "read_masked"
        return Decision(tier, "read_only")

    if c.cls == "dml" or (c.cls == "explain" and c.wraps == "dml"):
        if cls_t == "development":
            return _no("development", "Development databases are rebuilt by their application's tests — not changed here.")
        return _no("app_dml", APP_DML)
    if c.cls == "ddl" or (c.cls == "explain" and c.wraps == "ddl"):
        if cls_t == "development":
            return _no("development", "Development databases are rebuilt by their application's tests — not changed here.")
        return _no("app_ddl", APP_DDL)
    return _no("workbench_only", "Transactions, settings and utility statements run only on a workbench.")


def decide_apply(p: Policy) -> Decision:
    """A grid change set's apply (kind `apply`, composed statements with bound values — design §6.6)."""
    if not p.ok:
        r = p.refusal or {}
        return _no(r.get("rule") or "policy", r.get("message") or "You may not use this database.")
    if p.frozen:
        return _no("frozen", "The tool is frozen by a super-admin.")
    if p.is_agent:
        return _no("agent", "Agents never apply changes; a person does.")
    if (p.target or {}).get("class") != "application":
        return _no("target", "Row changes are applied only to an installed application's database.")
    if not p.has("data.write"):
        return _no("right", "Applying row changes is a DBA's.")
    if not (p.window or {}).get("write"):
        return _no("window", "Open a write window on this database first.")
    if (p.target or {}).get("grants_state") not in ("in_place", "partial"):
        return _no("grants", "The owner has not granted this database to the tool yet.")
    return Decision("write", None)
