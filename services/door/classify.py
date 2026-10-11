"""Classify one statement by an ALLOW-LIST of parse-tree node types — anything not on it is refused (design §6.1 step 3, D7).

    c = classify(text)            # text: ONE statement (pgquery.split's Part.text)
    c.cls       → 'read' | 'explain' | 'dml' | 'ddl' | 'tx' | 'utility' | 'refused'
    c.node      → the top node type ('SelectStmt', …)
    c.wraps     → for 'explain': the class of the statement EXPLAIN wraps ('read', 'dml', 'ddl', …) — classified recursively
    c.analyze   → for 'explain': True when ANALYZE is among the options (it executes)
    c.cursorable→ True when the statement may sit inside DECLARE … CURSOR (a plain SELECT / VALUES / TABLE without INTO or FOR UPDATE)
    c.workbench_only → True for what only a workbench admits (DDL, DML, utility, tx)
    c.reason    → for 'refused': a sentence for the person
    c.alter_subtypes → for ALTER TABLE: the AT_* subcommands (for the rule table, change-review spec)

Classification is NOT safety (02-postgres §4.9): it chooses a tier and refuses what no tier may run; the tier's privileges and READ ONLY
are the walls. What is never admitted anywhere — database-level and role statements, ALTER SYSTEM, LOAD, typed COPY, cursors and prepared
statements, LISTEN/NOTIFY, CHECKPOINT, DISCARD, tablespaces, subscriptions and publications, foreign servers, event triggers, security
labels, SET ROLE / SET SESSION AUTHORIZATION, PREPARE TRANSACTION, an ownership change — is refused here with its reason.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from door import pgquery

READ_NODES = {"SelectStmt", "VariableShowStmt"}
DML_NODES = {"InsertStmt", "UpdateStmt", "DeleteStmt", "MergeStmt"}
# DDL a workbench's own role may run on its own database (the server still decides what the role may do).
DDL_NODES = {
    "CreateStmt", "AlterTableStmt", "DropStmt", "IndexStmt", "ViewStmt", "CreateTableAsStmt", "CreateSeqStmt", "AlterSeqStmt",
    "CreateFunctionStmt", "AlterFunctionStmt", "CreateTrigStmt", "CreatePolicyStmt", "AlterPolicyStmt", "CommentStmt", "RenameStmt",
    "CreateEnumStmt", "AlterEnumStmt", "CompositeTypeStmt", "CreateDomainStmt", "AlterDomainStmt", "CreateRangeStmt", "DefineStmt",
    "TruncateStmt", "CreateSchemaStmt", "AlterObjectSchemaStmt", "RefreshMatViewStmt", "CreateExtensionStmt", "AlterExtensionStmt",
    "RuleStmt", "CreateStatsStmt", "AlterStatsStmt", "ReindexStmt", "ClusterStmt", "GrantStmt", "AlterDefaultPrivilegesStmt",
    "CreateCastStmt", "CreateOpClassStmt", "CreateOpFamilyStmt", "AlterOpFamilyStmt", "AlterTSDictionaryStmt",
    "AlterTSConfigurationStmt", "CreatePLangStmt",
}
TX_NODES = {"TransactionStmt", "ConstraintsSetStmt"}
UTILITY_NODES = {"VariableSetStmt", "DoStmt", "CallStmt", "VacuumStmt", "LockStmt"}

NEVER = {
    "CreatedbStmt": "creating a database is the door's own lifecycle (a workbench), never a statement",
    "DropdbStmt": "dropping a database is the door's own lifecycle, never a statement",
    "AlterDatabaseStmt": "database-level settings are the owner's", "AlterDatabaseSetStmt": "database-level settings are the owner's",
    "AlterDatabaseRefreshCollStmt": "database-level changes are the owner's",
    "CreateRoleStmt": "roles are the owner's and the installer's", "AlterRoleStmt": "roles are the owner's and the installer's",
    "AlterRoleSetStmt": "roles are the owner's and the installer's", "DropRoleStmt": "roles are the owner's and the installer's",
    "GrantRoleStmt": "role membership is the owner's", "ReassignOwnedStmt": "ownership changes are the owner's",
    "DropOwnedStmt": "ownership changes are the owner's", "AlterOwnerStmt": "ownership changes are the owner's",
    "AlterSystemStmt": "server settings are the owner's", "LoadStmt": "loading a library is the owner's",
    "CopyStmt": "COPY runs only as the door's own import and export", "ListenStmt": "LISTEN is not offered",
    "NotifyStmt": "NOTIFY is not offered", "UnlistenStmt": "LISTEN is not offered",
    "PrepareStmt": "prepared statements are not offered — run the statement", "ExecuteStmt": "prepared statements are not offered",
    "DeallocateStmt": "prepared statements are not offered", "DeclareCursorStmt": "cursors are the door's own",
    "FetchStmt": "cursors are the door's own", "ClosePortalStmt": "cursors are the door's own",
    "CheckPointStmt": "CHECKPOINT is the owner's", "DiscardStmt": "DISCARD is the door's own",
    "CreateTableSpaceStmt": "tablespaces are the owner's", "DropTableSpaceStmt": "tablespaces are the owner's",
    "AlterTableSpaceOptionsStmt": "tablespaces are the owner's", "AlterTableMoveAllStmt": "tablespaces are the owner's",
    "CreateSubscriptionStmt": "replication is the owner's", "AlterSubscriptionStmt": "replication is the owner's",
    "DropSubscriptionStmt": "replication is the owner's", "CreatePublicationStmt": "replication is the owner's",
    "AlterPublicationStmt": "replication is the owner's", "CreateFdwStmt": "foreign servers are the owner's",
    "AlterFdwStmt": "foreign servers are the owner's", "CreateForeignServerStmt": "foreign servers are the owner's",
    "AlterForeignServerStmt": "foreign servers are the owner's", "CreateUserMappingStmt": "foreign servers are the owner's",
    "AlterUserMappingStmt": "foreign servers are the owner's", "DropUserMappingStmt": "foreign servers are the owner's",
    "ImportForeignSchemaStmt": "foreign servers are the owner's", "CreateForeignTableStmt": "foreign servers are the owner's",
    "CreateEventTrigStmt": "event triggers are the owner's", "AlterEventTrigStmt": "event triggers are the owner's",
    "SecLabelStmt": "security labels are the owner's", "CreateConversionStmt": "conversions are the owner's",
    "CreateTransformStmt": "transforms are the owner's", "CreateAmStmt": "access methods are the owner's",
    "AlterCollationStmt": "collations are the owner's", "AlterOperatorStmt": "operators are the owner's",
    "AlterTypeStmt": "type internals are the owner's",
}
NEVER_SET = {"role", "session_authorization", "default_transaction_read_only", "transaction_read_only", "session_replication_role",
             "default_transaction_isolation"}


@dataclass
class Classification:
    cls: str
    node: str
    reason: str | None = None
    wraps: str | None = None
    analyze: bool = False
    cursorable: bool = False
    workbench_only: bool = False
    alter_subtypes: list[str] = field(default_factory=list)
    tree: dict | None = None


def _walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from _walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from _walk(v)


def has_modifying_cte(tree) -> bool:
    """Any CommonTableExpr anywhere whose query is INSERT/UPDATE/DELETE/MERGE — the data-modifying CTE trap (02-postgres §4.9)."""
    for d in _walk(tree):
        cte = d.get("CommonTableExpr")
        if isinstance(cte, dict):
            q = cte.get("ctequery") or {}
            if any(k in DML_NODES for k in q):
                return True
    return False


def classify_node(stmt: dict) -> Classification:
    node = next(iter(stmt))
    v = stmt[node] or {}
    if node in NEVER:
        return Classification("refused", node, NEVER[node] + ".")
    if node == "SelectStmt":
        if v.get("intoClause"):
            return Classification("ddl", node, workbench_only=True)                   # SELECT … INTO is CREATE TABLE AS
        if has_modifying_cte(v):
            return Classification("dml", node, workbench_only=True)
        if v.get("lockingClause") or any("LockingClause" in d for d in _walk(v)):
            return Classification("dml", node, "a locking read (FOR UPDATE / FOR SHARE) takes row locks", workbench_only=True)
        return Classification("read", node, cursorable=True)
    if node == "VariableShowStmt":
        return Classification("read", node)
    if node == "ExplainStmt":
        inner = classify_node(v.get("query") or {"Unknown": {}})
        opts = {(o.get("DefElem") or {}).get("defname") for o in (v.get("options") or [])}
        analyze = "analyze" in opts
        if inner.cls == "refused":
            return Classification("refused", node, inner.reason, wraps="refused", analyze=analyze)
        c = Classification("explain", node, wraps=inner.cls, analyze=analyze)
        c.workbench_only = analyze and inner.cls != "read"
        return c
    if node in DML_NODES:
        return Classification("dml", node, workbench_only=True)
    if node in DDL_NODES:
        if node == "AlterTableStmt":
            subs = [((c.get("AlterTableCmd") or {}).get("subtype") or "") for c in (v.get("cmds") or [])]
            if "AT_ChangeOwner" in subs:
                return Classification("refused", node, "ownership changes are the owner's.")
            return Classification("ddl", node, workbench_only=True, alter_subtypes=subs)
        if node == "GrantStmt" and v.get("targtype") != "ACL_TARGET_OBJECT" and v.get("targtype") != "ACL_TARGET_ALL_IN_SCHEMA":
            return Classification("refused", node, "this grant is the owner's.")
        if node == "CreateTableAsStmt" and has_modifying_cte(v):
            return Classification("ddl", node, workbench_only=True)
        return Classification("ddl", node, workbench_only=True)
    if node in TX_NODES:
        if node == "TransactionStmt" and v.get("kind") in ("TRANS_STMT_PREPARE", "TRANS_STMT_COMMIT_PREPARED",
                                                            "TRANS_STMT_ROLLBACK_PREPARED"):
            return Classification("refused", node, "two-phase commit is not offered.")
        return Classification("tx", node, workbench_only=True)
    if node in UTILITY_NODES:
        if node == "VariableSetStmt":
            name = (v.get("name") or "").lower()
            if v.get("kind") == "VAR_RESET_ALL" or name in NEVER_SET:
                return Classification("refused", node, f"setting {name or 'everything'} is not offered.")
        return Classification("utility", node, workbench_only=True)
    return Classification("refused", node, f"{node} is not a statement this tool runs.")


def classify(text: str, tree: dict | None = None) -> Classification:
    """Classify ONE statement. A text holding several statements is refused (one statement per execution, design §6.1 step 5)."""
    if tree is None:
        tree = pgquery.parse(text)
    stmts = tree.get("stmts") or []
    if len(stmts) != 1:
        return Classification("refused", "", "one statement at a time." if stmts else "there is no statement.", tree=tree)
    c = classify_node(stmts[0].get("stmt") or {"Unknown": {}})
    c.tree = tree
    return c
