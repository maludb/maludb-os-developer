"""The function screen (design §6.1 step 4): every function a statement calls, resolved on the target, refused when it is SECURITY DEFINER
and not owned by the tier, or on the deny-list.

Why: PUBLIC holds EXECUTE on every function by default, and the applications' SECURITY DEFINER functions were created by `postgres` —
from a plain SELECT a read tier would run superuser code with arguments it chose. READ ONLY is not a wall there ("a high-level notion
of read-only"): COPY … TO PROGRAM inside such a function, pg_notify(), advisory locks and set_config() are not on its list.

    refs = called_functions(tree)                 # [FuncRef(schema, name)] from every FuncCall node, wherever it sits (FROM included)
    refusal = screen(conn, refs, tier_role)       # None, or a sentence

Overloads are not resolved by argument types: if ANY function of that name (in that schema, or on the search path when unqualified) is
SECURITY DEFINER and not owned by the tier, the call is refused — a person can always ask for the plan instead. What the screen cannot
see, said plainly: functions reached through an operator, a cast, a view's definition or a column default — the tier's privileges bound
those, and the estate hardening item (K53) revokes PUBLIC EXECUTE on the SECURITY DEFINER functions.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

DENY_EXACT = {
    "set_config", "pg_notify", "pg_sleep", "pg_sleep_for", "pg_sleep_until", "pg_read_file", "pg_read_binary_file", "pg_stat_file",
    "pg_terminate_backend", "pg_cancel_backend", "pg_reload_conf", "pg_rotate_logfile", "pg_promote", "pg_create_restore_point",
    "pg_switch_wal", "pg_backup_start", "pg_backup_stop", "pg_log_backend_memory_contexts", "pg_import_system_collations",
    "pg_file_write", "pg_file_rename", "pg_file_unlink", "pg_file_sync", "pg_logdir_ls",
    # these run SQL given as a string — a way around the node allow-list and this very screen
    "query_to_xml", "query_to_xmlschema", "query_to_xml_and_xmlschema", "table_to_xml", "table_to_xmlschema",
    "table_to_xml_and_xmlschema", "cursor_to_xml", "cursor_to_xmlschema", "schema_to_xml", "schema_to_xmlschema",
    "schema_to_xml_and_xmlschema", "database_to_xml", "database_to_xmlschema", "database_to_xml_and_xmlschema",
    "nextval", "setval", "txid_current", "pg_current_xact_id",
}
DENY_PREFIX = ("pg_advisory", "pg_try_advisory", "lo_", "dblink", "pg_ls_", "pg_replication_", "pg_logical_", "pg_drop_replication",
               "pg_create_logical", "pg_create_physical")


@dataclass(frozen=True)
class FuncRef:
    schema: str | None
    name: str


def _walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from _walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from _walk(v)


def called_functions(tree: dict) -> list[FuncRef]:
    """Every FuncCall in the tree. libpg_query's JSON wraps a node in its type name only where the field is a generic Node
    ({"FuncCall": {…}} in a target list); a TYPED field holds the body unwrapped (CallStmt.funccall) — so the body is recognised by its
    own keys (`funcname` + `funcformat`), which finds both."""
    out: list[FuncRef] = []
    seen = set()
    for fc in _walk(tree):
        if not (isinstance(fc, dict) and "funcname" in fc and "funcformat" in fc):
            continue
        parts = [((p.get("String") or {}).get("sval") or "") for p in (fc.get("funcname") or [])]
        parts = [p for p in parts if p]
        if not parts:
            continue
        ref = FuncRef(parts[-2].lower() if len(parts) >= 2 else None, parts[-1].lower())
        if ref not in seen:
            seen.add(ref)
            out.append(ref)
    return out


def denied(ref: FuncRef) -> bool:
    if ref.schema not in (None, "pg_catalog"):
        return False
    return ref.name in DENY_EXACT or ref.name.startswith(DENY_PREFIX)


_RESOLVE = """
SELECT n.nspname, p.proname, p.prosecdef, pg_get_userbyid(p.proowner) AS owner
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE p.proname = %(name)s
   AND (CASE WHEN %(schema)s::text IS NULL THEN n.nspname = ANY (current_schemas(true)) ELSE n.nspname = %(schema)s::text END)
"""


def screen(conn, refs: list[FuncRef], tier_role: str) -> str | None:
    """None when every call may run as `tier_role`; else the refusal sentence. `conn` is a psycopg connection to the target (catalog
    reads only — run before the statement)."""
    for ref in refs:
        if denied(ref):
            return f"the function {ref.name}() is not offered here."
        if not re.fullmatch(r"[a-z_][a-z0-9_$]*", ref.name):
            # a quoted, unusual name: resolve it all the same (bound parameter), never interpolate
            pass
        rows = conn.execute(_RESOLVE, {"name": ref.name, "schema": ref.schema}).fetchall()
        for nsp, name, secdef, owner in rows:
            if secdef and owner != tier_role:
                where = f"{nsp}.{name}"
                return (f"{where}() runs with its owner's rights (SECURITY DEFINER) — the tool does not call it; "
                        f"ask for its plan, or read its definition on the object page.")
            if nsp == "pg_catalog" and denied(FuncRef("pg_catalog", name)):
                return f"the function {name}() is not offered here."
    return None
