# Build spec: the door and the grants service

2026-10-11 · **Phase 1, for the checkpoint.** The one path from Developer to any database but its own (design §6.1, the developer
exception K50) and the service that keeps the tiers' column privileges in step with the classifications (§6.9). Every slice that reads or
changes a target calls the door; none opens a connection to a target. This spec fixes the protocol, the classification, the function
screen, the decision table, the execution rules, the audit, **the named-query library**, the composed operations, the PHP and Python
clients, the grants service's pass and the proof. Read with `tests/door/FINDINGS.md` (what Phase 0 settled) and design §6.13.

**Where things live.** `services/door/` (Python 3.12, psycopg 3.3, the door), `services/grants/` (the grants service), one virtualenv
`services/.venv` (psycopg, `squawk-cli` 2.68.0 — the `squawk` binary at `services/.venv/bin/squawk`), libpg_query **17-6.2.5** built by
`deploy/build-libpg_query.sh` into `services/vendor/lib/libpg_query.so` (sha256-pinned; the pin moves with the server's major). Units:
`developer-door.socket` (the socket, group `developer`), `developer-door.service` (user `developer-door`), `developer-grants.service`
(user `developer-grants`). Neither holds a key or a password in the repository; their passfiles are root's (`deploy/ROOT_STEPS.sh`).

## What Phase 0 built, and what Phase 3 adds

| Module | Phase 0 (built, `tests/door/run.sh` 174 checks) | Phase 3 adds (slice) |
|---|---|---|
| `server.py` | the socket (systemd fd 3 or a bound path), `SO_PEERCRED`, HMAC + `ts` + replay, `dx_door_member_active`, dispatch for `ping` `run` `cancel` `named` `memory` `apply` `undo` `workbench_create` `workbench_drop` `workbench_reset` `rehearse` | `explain` (6), `classify` and `lint` (4), `signal` and `maintenance` (7), `snapshot` (8), `export` (3) and `import` (4), `workbench_size` (4), the full named library (1, 2, 7, 8), the memory library (9) |
| `pgquery.py` | the ctypes binding: `parse`, `split`, `fingerprint`, `normalize`, `server_version_num` | — |
| `classify.py` | the allow-list, `EXPLAIN` by what it wraps, data-modifying CTEs as DML, `AlterTableStmt` subtypes | the rule-table keys for each `AT_*` subtype (4 — `docs/build-specs/ddl-generators.md` §5 owns the table) |
| `functions.py` | the function screen and the deny-list | — |
| `decide.py` | class × ceiling × level × window → tier or a sentence; `decide_apply` | `decide_explain` (6), `decide_ops` (7) |
| `execute.py` | one statement per message, settings re-asserted, READ ONLY, cursor caps, values as text, `cancel_safe()`, `mask_message` | notices and the error position for every kind (3) |
| `run.py` | the pipeline, the per-person concurrency cap, the audit round trip | the leading comment (3) |
| `named.py` | four queries (`databases`, `tables`, `columns_map`, `activity`) | the library of §4 — the Phase 0 names are renamed (`databases` → `discovery`, `tables` → `family_page`, `columns_map` → `completion_map`) |
| `memory_queries.py` | three queries and the static secret test | the library of §5 |
| `apply.py` | grid applies with bound values, `xmin`, side-effect deltas, before-images, undo | — (slice 5 wires it) |
| `workbench.py`, `clone.py`, `rehearse.py` | the lifecycle as the rolemaker, schema clones, measured rehearsals | quota measurement (4) |
| `policy.py` | `SqlPolicies` over `dx_door_policy()` and the four audit functions | — |
| `services/grants/` | a pass: column privileges from `mcp_grant_plan`, `xmin` on its own, secret patterns never granted | — (slice 1 runs it under systemd) |

## 1. The protocol

**Transport.** A Unix stream socket, `DX_DOOR_SOCKET` (`/run/developer/door.sock`), mode 0660, group `developer` (members
`developer-web` and `developer-mcp`). In production systemd passes the listening socket as fd 3 (`LISTEN_FDS`/`LISTEN_PID`); the door's own
user is not in the group. **One request per connection**: one line of UTF-8 JSON in (at most 1 MB), one line out. No TCP listener, ever.

**On accept**, in this order, each failure an answer with its `refusal_rule` and nothing else done:

| Check | Refusal rule |
|---|---|
| `SO_PEERCRED` uid is `developer-web` or `developer-mcp` (`DX_DOOR_ALLOWED_USERS`) — never the web server's shared uid | `peer` |
| the line is at most 1 MB and parses as a JSON object | `too_long`, `bad_request` |
| `mac` = HMAC-SHA256 under `DX_DOOR_KEY` of the canonical JSON of the request without `mac` (sorted keys, no spaces, UTF-8) | `mac` |
| `ts` (seconds) within 60 s of the door's clock | `stale` |
| `request_id` non-empty and not seen in the last 120 s | `replay` |
| `caller` is an active member of the mirror (`dx_door_member_active`) — every kind but `ping` | `inactive` |

**Request fields** (every kind): `kind`, `request_id` (a uuid the caller makes; also the cancel handle), `ts`, `mac`, `caller` (member
id), `on_behalf_of` (K38's person, or null), `agent_run_id` (or null), `is_eval` (true under an evaluation run), `source` (`editor`,
`grid`, `form`, `screen`, `worker`, `rehearsal`, `memory`, `mcp`), `datname`. **A caller never sends a level, a tier, a right, a role,
a host, a port or a connection string** — the door computes everything else from `dx_door_policy(caller, on_behalf_of, datname)`.

**Kinds**:

| Kind | Fields beyond the common ones | What it does | Tier | Slice |
|---|---|---|---|---|
| `ping` | — | answers `{status: ok, grammar, version}`; no member check | — | 2 |
| `run` | `sql`, `params` (text values for `$1…$n` — a saved query's parameters; a one-statement script only, bound through the extended protocol) | typed SQL through the pipeline of §3 | read, read_masked, workbench, own | 3 |
| `cancel` | `target_request_id` | cancels a run **the same caller** started (libpq cancel, `cancel_safe()`), answered beside the run — and a running maintenance job for its requester or any holder of `maintenance.run` | — | 3, 7 |
| `named` | `name`, `params` | one query of the named library (§4), bound parameters only | meta (bloat: read_masked) | 1, 2, 7, 8 |
| `memory` | `name`, `schema`, `params` | one query of the memory library (§5), on a `memory` target or on an `application` target's co-located memory schema (one of the policy's `target.memory_schemas`) | memory (`SET ROLE` the auditor inside) | 9 |
| `explain` | `sql`, `options` {`analyze`, `buffers`, `verbose`, `settings`, `serialize`, `memory`, `generic`} | `EXPLAIN (FORMAT JSON, …)` of one statement (§3.7) | read_masked or the person's tier; workbench | 6 |
| `classify` | `sql` | splits, parses, classifies; per statement the class, the node, the `AT_*` subtypes, the relations touched, the refusal a `run` would give — **nothing executes and no target connection is opened** | — | 4 |
| `lint` | `sql` | squawk 2.68.0 over the statements (`--pg-version=17 --reporter=json`, stdin, no file), its findings by statement | — | 4 |
| `apply` | `change_set_id`, `items` | a grid change set (§6.1) | write | 5 |
| `undo` | `change_set_id`, `images` | a change set's before-images (§6.2) | write | 5 |
| `workbench_create` | `title`, `source` (a target, or null for empty), `template` | the lifecycle (§6.3) and, with `source`, the schema clone (§6.4) — **a clone is this kind with a source, not a kind of its own** | rolemaker, ops | 4 |
| `workbench_drop` | — (`datname` is the workbench) | drops the database and its role | rolemaker | 4 |
| `workbench_reset` | — | a new password for the workbench's role (a super-admin's) | rolemaker | 4 |
| `workbench_size` | — | `pg_database_size()` of every workbench, for the worker's quota pass | meta | 4 |
| `rehearse` | `change_set_id`, `statements` | a throwaway clone, the statements measured (§6.5); refused under `is_eval` | rolemaker, ops, the clone's role | 4 |
| `signal` | `pid`, `signal` (`cancel` or `terminate`) | `dx_signal(pid, kind)` in the tool's own database (§6.6) | ops | 7 |
| `maintenance` | `job_id`, `operation`, `object` | starts one maintenance job (§6.7) and answers at once; the door's own thread runs it and reports through `dx_door_job_update()` | ops | 7 |
| `snapshot` | — | the nightly snapshot pass of one target (§6.8) | meta | 8 |
| `export` | `export_id`, `kind`, `sql` or `object`, `format` | `COPY (…) TO STDOUT` at the person's level into the export's file (§6.9) | read, read_masked | 3 |
| `import` | `workbench`, `object`, `file`, `mapping`, `on_error` | `COPY … FROM STDIN` into a workbench table (§6.10) | workbench | 4 |

**The answer** (every kind): `{"status": "ok"|"refused"|"error"|"timeout"|"cancelled", "refusal_rule"?, "message"?, "run_id"?, …}` plus
the kind's own fields (`statements[]` for `run`, `rows[]`/`columns[]`/`truncated` for `named` and `memory`, `plan` and `flags` for
`explain`, …). `message` is a sentence for the person; a traceback never leaves the door (an `error` answers `refusal_rule: door` and
the exception's class name; the journal has the rest).

**The refusal rules** (the machine word beside each sentence; the UI and the audit use them):

| Group | Rules |
|---|---|
| the socket | `peer`, `too_long`, `bad_request`, `mac`, `stale`, `replay`, `inactive` |
| the policy (`dx_door_policy`) | `member`, `unregistered`, `on_behalf_of`, `own`, `workbench`, `frozen` |
| the statement | `syntax` (with `position`), `empty`, `statement` (not on the allow-list, with the reason), `tiers` (a script needing two tiers), `function` (the screen) |
| the decision | `target`, `kernel`, `memory`, `development`, `agent`, `right`, `level`, `grants`, `window`, `owner`, `quota`, `app_dml`, `app_ddl`, `workbench_only`, `eval` |
| execution | `busy` (the per-person cap), `connect`, `credential` (a workbench's password changed from inside), `cap` (an export over its row or byte cap), `named` (an unknown named query) |
| the door | `door` (a fault), and on the PHP side `door_unavailable` (no answer within the client's timeout) |

## 2. Classification — the allow-list (`classify.py`)

Classification **chooses a tier and refuses what no tier may run; it is not the wall** (the tier's privileges and READ ONLY are). A
statement whose top node is not listed is refused.

| Class | Top nodes | Notes |
|---|---|---|
| `read` | `SelectStmt` without `intoClause` and without a locking clause; `VariableShowStmt`; `VALUES` and `TABLE` (a `SelectStmt`) | `cursorable` when it may sit in `DECLARE … CURSOR` |
| `explain` | `ExplainStmt` | classified by the statement it wraps, recursively (`wraps`); `analyze` when ANALYZE is an option |
| `dml` | `InsertStmt`, `UpdateStmt`, `DeleteStmt`, `MergeStmt`; **any statement holding a data-modifying CTE** | |
| `ddl` | `CreateStmt`, `AlterTableStmt`, `DropStmt`, `IndexStmt`, `ViewStmt`, `CreateTableAsStmt` (and `SELECT … INTO`), `CreateSeqStmt`, `AlterSeqStmt`, `CreateFunctionStmt`, `AlterFunctionStmt`, `CreateTrigStmt`, `CreatePolicyStmt`, `AlterPolicyStmt`, `CommentStmt`, `RenameStmt`, `CreateEnumStmt`, `AlterEnumStmt`, `CompositeTypeStmt`, `CreateDomainStmt`, `AlterDomainStmt`, `CreateRangeStmt`, `DefineStmt`, `TruncateStmt`, `CreateSchemaStmt`, `AlterObjectSchemaStmt`, `RefreshMatViewStmt`, `CreateExtensionStmt`, `AlterExtensionStmt`, `RuleStmt`, `CreateStatsStmt`, `AlterStatsStmt`, `ReindexStmt`, `ClusterStmt`, `GrantStmt`, `AlterDefaultPrivilegesStmt`, `CreateCastStmt`, `CreateOpClassStmt`, `CreateOpFamilyStmt`, `AlterOpFamilyStmt`, `AlterTSDictionaryStmt`, `AlterTSConfigurationStmt`, `CreatePLangStmt` | live only on a workbench, as the workbench's own role (which can do no more than its own database allows) |
| `tx` | `TransactionStmt` (not `PREPARE TRANSACTION`), `ConstraintsSetStmt` | a workbench only, inside one run |
| `utility` | `VariableSetStmt` (planner settings only — never `role`, `session_authorization`, `default_transaction_read_only`, `transaction_read_only`, `session_replication_role`, `default_transaction_isolation`), `DoStmt`, `CallStmt`, `VacuumStmt`, `LockStmt` | a workbench only |
| refused everywhere, with the reason | database and role statements, `ALTER SYSTEM`, `LOAD`, typed `COPY`, `PREPARE`/`EXECUTE`/`DEALLOCATE`, cursors, `LISTEN`/`NOTIFY`, `CHECKPOINT`, `DISCARD`, tablespaces, publications, subscriptions, foreign data wrappers, servers and user mappings, event triggers, security labels, conversions, transforms, access methods, ownership changes, `ALTER TYPE` internals, `PREPARE TRANSACTION` | the sentences are `classify.NEVER` |

**THE WALKER RULE** (finding 2): libpg_query's JSON wraps a node in its type name only where the field is a generic `Node`; a **typed
field holds the body unwrapped** (`CallStmt.funccall`, `AlterTableStmt.relation`, `IndexStmt.relation`, …). **Every tree walker in the
door visits both shapes** — recognising a node by its own keys (a `FuncCall` by `funcname` + `funcformat`, a `RangeVar` by `relname`) —
and every new walker gets a test with a typed-field case. `CALL f()` slipped past the screen until this held.

## 3. The pipeline of a `run` (`run.py`)

1. **Who and where** — the socket checks; then `dx_door_policy(caller, on_behalf_of, datname)` once per request (frozen → `frozen`).
2. **Split and parse** the whole script with libpg_query before anything runs (dollar quotes, `E''`, quoted identifiers, nested comments,
   `BEGIN ATOMIC`); a psql meta-command is a syntax error, never interpreted. The error's character position is the script's.
3. **Classify** every statement (§2), **decide** every statement (§3.5), and refuse the whole run if any statement is refused — a script
   never half-runs because its fifth statement is not allowed. A script needing two tiers is refused (`tiers`).
4. **Screen the functions** of every statement on the target, before the first runs (`functions.py`): every `FuncCall` resolved by name
   (in its schema, or on the tier's search path when unqualified); refused when **any** function of that name is `SECURITY DEFINER` and
   not owned by the tier, or the name is on the deny-list. **The deny-list** (exact): `set_config`, `pg_notify`, `pg_sleep`,
   `pg_sleep_for`, `pg_sleep_until`, `pg_read_file`, `pg_read_binary_file`, `pg_stat_file`, `pg_terminate_backend`, `pg_cancel_backend`,
   `pg_reload_conf`, `pg_rotate_logfile`, `pg_promote`, `pg_create_restore_point`, `pg_switch_wal`, `pg_backup_start`, `pg_backup_stop`,
   `pg_log_backend_memory_contexts`, `pg_import_system_collations`, `pg_file_write`, `pg_file_rename`, `pg_file_unlink`, `pg_file_sync`,
   `pg_logdir_ls`, `query_to_xml`, `query_to_xmlschema`, `query_to_xml_and_xmlschema`, `table_to_xml`, `table_to_xmlschema`,
   `table_to_xml_and_xmlschema`, `cursor_to_xml`, `cursor_to_xmlschema`, `schema_to_xml`, `schema_to_xmlschema`,
   `schema_to_xml_and_xmlschema`, `database_to_xml`, `database_to_xmlschema`, `database_to_xml_and_xmlschema`, `nextval`, `setval`,
   `txid_current`, `pg_current_xact_id`; (prefix) `pg_advisory*`, `pg_try_advisory*`, `lo_*`, `dblink*`, `pg_ls_*`, `pg_replication_*`,
   `pg_logical_*`, `pg_drop_replication*`, `pg_create_logical*`, `pg_create_physical*`. The screen applies to `EXPLAIN` too (the planner
   folds immutable calls). **What it cannot see**, said in the screen's own help: a function reached through an operator, a cast, a view's
   definition or a column default — the tier's privileges bound those, and K53 revokes `PUBLIC EXECUTE` on the applications'
   `SECURITY DEFINER` functions. Until K53, the screen is load-bearing (finding 6).
5. **Decide** (`decide.py`) — the target's class × its ceiling × the caller's rights and level × the open window:

| Class of statement | `application` / granted `development` | `workbench` (its owner only; never an agent) | `kernel` | `memory` | `own` |
|---|---|---|---|---|---|
| `read` | `data.read` and level `masked` → **read_masked**; level `rows` + `data.unmask` → **read**; private-by-design needs an open read window (`window`); grants not in place → `grants`; an agent → `agent`; no level → `level` | `workbench.use` → workbench (READ ONLY when cursorable) | `kernel` — "structure only — use the object pages" | `memory` — "use the memory section" | `audit.read` → read (the admin's screens) |
| `explain` without ANALYZE | `plans.explain` → read_masked (Viewers and agents), the person's own tier for an Engineer at `rows` | workbench | `kernel` | `memory` | as `read` |
| `explain ANALYZE` | as `read` (it executes; agents refused) | `workbench.apply` → workbench wrapped `BEGIN … ROLLBACK` for a write | `kernel` | `memory` | as `read` |
| `dml` | `app_dml` — "This changes data in an installed application: edit the rows in the grid (in a write window), or save it as a migration draft." (a development database: `development`) | `workbench.apply` → workbench | `kernel` | `memory` | `own` |
| `ddl` | `app_ddl` — "This changes the schema of an installed application: save it as a migration draft, or rehearse it on a workbench." | `workbench.apply` → workbench | `kernel` | `memory` | `own` |
| `tx`, `utility` | `workbench_only` | `workbench.apply` → workbench | `kernel` | `memory` | `own` |

   The policy's `frozen` refuses everything but `ping`; the workbench tier is also refused while frozen. A suspended workbench (over
   quota) refuses all but reads (`quota`).
6. **Execute** (`execute.py`): a **fresh connection per request** (never carried from one person or agent run to another) as the tier's
   login — **the session user is the tier**; `SET ROLE` is never used around typed SQL. Before **each** statement the door re-asserts the
   tier's settings with `SET` of `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `transaction_timeout` and
   `default_transaction_read_only` (a workbench role can change its own defaults). One statement per protocol message, the extended
   protocol where it can be prepared. Reads inside `BEGIN READ ONLY … COMMIT`, fetched through a cursor — **at most `show_rows` (1,000) rows
   and `show_bytes_mb` (8 MB)**, fetched n+1 so the truncation is known and said; each cell over `cell_chars` (2,000) characters cut with its
   full length shown; values as PostgreSQL's own text (numeric, jsonb, timestamps round-trip exactly). Notices collected. On error:
   SQLSTATE, message, detail, hint and the **character position** in the script. A column the tier may not read comes back as PostgreSQL's
   refusal (42501), which the door words: *"`email` is personal — masked for you on this database"*. A transaction a workbench script
   leaves open at the end of the run is rolled back and said so.
7. **Explain** (kind `explain`, `decide_explain`): one statement; the options become `EXPLAIN (FORMAT JSON, BUFFERS, VERBOSE, SETTINGS,
   SERIALIZE, MEMORY, GENERIC_PLAN)` as chosen; without `analyze` nothing executes, inside `BEGIN READ ONLY … ROLLBACK`; `analyze` follows
   the `read` column of the table above, and on a workbench a write is wrapped `BEGIN … ROLLBACK` and labelled *executed and rolled back*.
   `generic` takes a normalized statement with `$n` placeholders (the shape `pg_stat_statements` gives). The answer carries the plan JSON;
   the flags are computed by PHP (`docs/build-specs/plans.md`) and by the records server from the same rules.
8. **Audit** — §7.

**Cancel** (kind `cancel`): the registry holds each running request's connection; a cancel from **the same caller** with the running
request's id sends a libpq cancel (`cancel_safe()`), answered at once, beside the run; nobody else's run is cancelled. **PHP releases its
session lock before it asks the door** (`session_write_close()` in the client), so Cancel is never queued behind the run it cancels.

**Limits** — read from `dx_settings` through the policy's `limits` on every request: `screen_timeout_seconds` (30 s for a screen, an
editor run and the MCP servers), `workbench_timeout_seconds` (300 s for a workbench script and a rehearsal), `show_rows`, `show_bytes_mb`,
`cell_chars`, `runs_per_person` (**2** concurrent runs per person, `busy` beyond), `door_pool_max` (**8** connections the door holds at once
— a request beyond waits up to 5 s for one, then answers `busy`). **The connection budget**: the door's 8, the PHP-FPM pool's 6, the MCP
servers' 2, the grants service's 1 and the worker's 1 — **18** of the cluster's 100.

## 4. The named-query library (`named.py`, run as `developer_meta` unless said)

Fixed code, bound parameters only (`%(name)s`), each query with its row cap; a caller sends a name and parameters, never SQL. Counted per
caller per day in `door_usage` (`named:<name>`), not rowed. Every query that names an object takes it as schema + name (+ arguments) and
resolves it to an OID **inside the query** (`to_regclass`, `to_regprocedure`, `pg_identify_object_as_address` back) — an identifier never
sits inside a string literal (S9). A query reading `pg_stat_activity` returns query texts **normalized** by libpg_query (literals → `$n`;
a text cut by `track_activity_query_size` that does not parse reads `<not normalisable>`); raw text only through `session_text`.

| Name | Purpose | Params | Max rows | Used by |
|---|---|---|---|---|
| `discovery` | every database of the cluster: name, size, connectable, template — read in the tool's own database | — | 2,000 | the worker's discovery pass (slice 1) |
| `extensions` | a target's extensions with version and the host's default version (`pg_available_extensions`); whether `maludb_core` is there and its schemas | — | 500 | discovery (1), `database_overview`, `memory_estate` |
| `grants_check` | per table and view of the target, whether each tier holds its privileges (`has_table_privilege`, `has_column_privilege` for read, read_masked, write, ops), tables not created by `postgres` | — | 20,000 | the worker → `target_databases.grants_state` / `grants_detail` (1) |
| `catalog_index_pass` | every object's type, identity, owner, comment, extension, system flag, and a relation's columns and types | `since_xid` (optional) | 200,000 | the worker's catalog index pass (1) |
| `completion_map` | `pg_get_keywords()` and every function's signature (schema, name, argument types, result) — read by the catalog index pass; the relations and columns of the editor's map come from `catalog_index.columns`, filtered per level by `column_classes` | — | 50,000 | the catalog index pass (1); `GET /db/{datname}/complete.json` (3) |
| `database_overview` | schemas with owner, bytes and objects per family; extensions vs defaults; settings whose source is not `default` | — | 500 | `database_overview`, `database-view` (1) |
| `schema_families` | one schema's object counts by family | `schema` | 40 | `schema-view` (1) |
| `family_page` | one family's objects in a schema, filtered and paged (name, owner, comment, size, estimate) | `schema`, `family`, `q`, `owner`, `limit` (≤ 200), `offset` | 200 | `family-list` (1) |
| `table_describe` | a relation's columns, constraints, indexes, triggers, policies, partitions, size, estimate, comments and referencing constraints | `schema`, `name` | 2,000 | `table_describe`, `object-view` (1, 2) |
| `object_describe` | any family's own fields (function signature, language, volatility, security, `proconfig`; type labels; sequence limits; trigger timing; policy expressions …), owner, comment, extension | `type`, `identity` | 500 | `object_describe`, the object tabs (2) |
| `object_ddl` | `pg_get_*def` where PostgreSQL has one; for the generator families the catalog parts the PHP generators take (`docs/build-specs/ddl-generators.md`) | `type`, `identity` | 2,000 | `object_ddl`, `object-ddl` (2) |
| `object_dependencies` | `pg_depend`, `pg_shdepend`, `pg_rewrite`, `pg_constraint`, `pg_trigger`, `pg_policy`, defaults and owned sequences — both directions | `type`, `identity`, `direction` | 2,000 | `object_dependencies`, `object-dependencies` (2) |
| `impact` | the full reach of CASCADE from an object or a column, with depth, and the views to drop and recreate in order | `type`, `identity`, `column`, `verb` | 2,000 | `impact`, `object-impact` (2) |
| `fk_graph` | every foreign key's tables and column pairs | — | 20,000 | `join_path`, `join-path`, the diagram (2, 8) |
| `object_privileges` | `aclexplode` of an object's ACL (or `acldefault`), its owner, the default privileges that apply | `type`, `identity` | 2,000 | `object_privileges`, `object-privileges` (2) |
| `roles` | the cluster's roles with their attributes (no password column is read) | `q` | 2,000 | `roles-list` (2) |
| `role_describe` | one role's attributes, memberships with inherit/set/admin, members, per database CONNECT and ownership | `role` | 2,000 | `role_describe`, `role-view` (2) |
| `relation_sizes` | bytes, estimated rows, `n_mod_since_analyze` and the last (auto)analyze of named relations | `relations[]` (schema.name) | 200 | `ddl_cost`, Change review's annotations (4), the plan flags' stale statistics (6) |
| `ddl_fingerprints` | the live side of a compare: every object's type, identity and its normalized definition parts | `family` | 200,000 | `schema_compare`, `compare` (8) |
| `snapshot_pass` | the same parts for the nightly snapshot, with each object's DDL source | — | 200,000 | kind `snapshot` (8) |
| `sequences_limits` | `pg_sequences`: last value against the type's and the sequence's limit (meta holds `SELECT` on sequences) | — | 20,000 | `health_checks`, `db-health` (8) |
| `health_checks` | the fixed checks of design §6.7 — missing primary keys, unindexed foreign keys, duplicate / overlapping / unused / invalid indexes, sequences near their limit, wraparound age, RLS enabled without a policy, `SECURITY DEFINER` without a fixed `search_path` or executable by `PUBLIC`, long idle-in-transaction sessions, constraints left `NOT VALID` — each row `{check, severity, address, detail}` | `checks[]` | 5,000 | `health_findings`, `db-health`, `health-all` (8) |
| `index_advice` | unused (`idx_scan = 0`, `last_idx_scan`), duplicate and overlapping (same key prefix), invalid (`indisvalid`), foreign keys without a leading index | `schema` | 5,000 | `index_advice`, `index-advice` (8) |
| `bloat_estimate` | the ioguix estimates over `pg_stats` for tables and indexes; exact `pgstattuple` when installed and asked — **run as `developer_read_masked`**, which sees the statistics of what it may read | `schema`, `exact` | 5,000 | `bloat`, `bloat` screen (8) |
| `vacuum_state` | `age(datfrozenxid)`, `mxid_age`; per table dead tuples, last (auto)vacuum and analyze, `age(relfrozenxid)`; sessions holding the horizon (`backend_xmin`) | — | 5,000 | `vacuum_state`, `vacuum` (7) |
| `activity` | `pg_stat_activity` client backends (and the tool's own marked by `application_name LIKE 'developer:%'`): state, waits (`pg_wait_events` descriptions), transaction and query age, the normalized text — **no text for a session on the kernel's or a memory database** | `datname`, `state` | 500 | `activity_now`, `sessions`, `db-activity`, `session-view` (7) |
| `blocking` | `pg_blocking_pids` for every waiting session; the root blockers and the chains | `datname` | 500 | `blockers`, the root blocker on `sessions` (7) |
| `locks` | `pg_locks` joined to sessions and to the object's identity | `datname`, `object` | 2,000 | `locks`, `locks` screen (7) |
| `session_text` | one session's raw query text — a DBA's, logged `session.text_open`; refused for the kernel's and the memory databases' sessions | `pid` | 1 | `session_text_open` (7) |
| `progress` | `pg_stat_progress_vacuum`, `_analyze`, `_create_index`, `_cluster` for a pid or a relation | `pid` | 50 | `maintenance_jobs`, the job's progress door (7) |
| `top_statements` | `pg_stat_statements` (in the tool's own database, covering the cluster) by total time, mean, calls, rows, I/O; `stats_since`; `not_installed` when absent | `datname`, `order`, `limit` (≤ 100) | 100 | `top_statements`, `statements` (7) |
| `server_stats` | `pg_stat_io`, `pg_stat_checkpointer`, `pg_stat_wal`, the predefined roles the meta login holds (what is hidden, T21) | — | 500 | `server` (7) |
| `archiver` | `archive_mode`, `archive_command` set or not (never its text), `pg_stat_archiver` | — | 1 | `backup_posture`, `backups` (8) |

**What the named library never does**: read a row of a target's table; read `pg_authid`; name a column of a table outside `pg_catalog`
and `information_schema` except through the statistics views; call a function on the deny-list.

## 5. The memory library (`memory_queries.py`, as `developer_memory`)

Each query runs `BEGIN READ ONLY; SET LOCAL ROLE maludb_memory_auditor; <query>; COMMIT` on a `memory` target, or on an `application`
target whose co-located memory schema the request names (the cidery's and ProcessCore's shape — `dx_door_policy()` gains
`target.memory_schemas` and `target.has_maludb` in slice 9's migration, appended to the JSON it answers; the schema is bound, never
interpolated, and the query runs with `search_path` set to it) (that role holds
`BYPASSRLS` once set — the reason the library is fixed code). Bounded: every list `LIMIT`ed and paged, walks at depth ≤ 3 and ≤ 200
nodes. **The static secret test** (`tests/door/test_memory_secrets.py`, run in every proof): every query is parsed with libpg_query and the
test fails if any names a `malu$secret*`, `malu$auth_token*` or `malu$secret_master_key` relation, a `value_encrypted` column, a column
named like a token hash, or calls a `*_claim` function or any function that writes (`forbidden_references()`).

| Name | Purpose | Kind | Max rows | Used by |
|---|---|---|---|---|
| `estate` | the extension's version, each tenant schema with its facade version and flags (facades behind the extension, a tenant in the bootstrap, scratch) | state | 500 | `memory_estate`, `memory-estate` |
| `tenant_health` | counts per family, the embedding backlog (count, oldest, by kind), never/long-ago indexed documents, the extraction queue, `malu$event` and audit growth, table sizes, facades failing a `LIMIT 0` probe, embedder/extractor configured, "no worker has drained this queue in N days" | state | 500 | `memory_health`, `memory-tenant` |
| `episode_stats` | episode counts by kind, application, day, sensitivity, scope — **never a payload column** | state | 2,000 | `memory_episode_stats`, `memory-episodes` |
| `graph_stats` | stores, relations, node-type counts, god-node count, communities, import namespaces — **never a subject** | state | 500 | `memory_graph_stats`, `memory-graph-stats` |
| `model_config` | per namespace: provider, alias, prompt template, **the `secret_ref` name** | state | 500 | `memory_model_config`, `memory-config` |
| `skills` | name, version, enabled, review state | state | 500 | `memory_skills`, `memory-config` |
| `facades` | `malu$enabled_schema_object.object_purpose`, kind, writable | state | 500 | `memory_facades`, `memory-config` |
| `isolation` | database `CONNECT` grants, members of the `maludb_*` groups, `BYPASSRLS` logins, FORCE RLS state — **as `developer_meta`** (catalog only) | state | 2,000 | `memory-isolation` |
| `graph_search` | subjects by name, alias, type | **content** | 100 | `memory-graph` |
| `subject` | one subject: verbs, attributes, statements with provenance and valid time, relationships | **content** | 500 | `memory-graph` |
| `neighbours` | a subject's neighbours | **content** | 200 | `memory-graph` |
| `walk` | a bounded walk (depth ≤ 3, ≤ 200 nodes) | **content** | 200 | `memory-graph` |
| `path` | a path between two subjects (depth ≤ 3) | **content** | 50 | `memory-graph` |
| `documents` | document, chat and note metadata: source type, namespace, size, indexed when — never text | **content** | 200 | `memory-documents` |
| `reveal_episode` | one episode's payload | **reveal** | 1 | `memory_reveal` |
| `reveal_document` | one document's text | **reveal** | 1 | `memory_reveal` |

**State** queries need `memory.read` (anyone, agents included — the records server's seven memory tools) and are counted in `door_usage`.
**Content** queries need `memory.content` (people only) and are rowed in `query_runs` with `source = 'memory'` (the name and the subject's
id, never the content). **Reveal** queries need `memory.reveal` (a super-admin) and a reason, are rowed the same way, and the content is
answered to the screen once — never logged, never cached by PHP, never sent to an MCP server.

## 6. The composed operations

1. **`apply`** (`apply.py`, `developer_write`, inside the person's open write window — `decide_apply`): the change set's items arrive as
   `{op, schema, table, key, xmin, values}`; the door composes each statement itself with bound values (`INSERT`, `UPDATE … WHERE <key> AND
   xmin = $n`, `DELETE … WHERE <key> AND xmin = $n`) in **one transaction**; each must touch exactly the rows expected (else `conflict`
   with the row); **before commit** it compares `pg_stat_xact_user_tables` against the baseline taken at the start (finding 4): any table
   other than the target changed — a cascade, a trigger writing elsewhere — rolls everything back and names the tables. Then it reads the
   before-images (the rows as they were, selected inside the transaction before each change) and answers them with the new `xmin`s; PHP
   stores them in `row_images`.
2. **`undo`**: the before-images re-applied in one transaction, each keyed by the identity and the `xmin` the apply left; a row changed since
   → nothing is undone and the table and row are named.
3. **The workbench lifecycle** (`workbench.py`, `developer_rolemaker`): the next free `dxw_<n>`; `CREATE ROLE dxw_<n> LOGIN PASSWORD
   <random 32 bytes>` with its fixed settings; the rolemaker grants itself `SET` (not `INHERIT`) on it (finding 1); `CREATE DATABASE dxw_<n>
   OWNER dxw_<n>` (from `dx_template` when asked); `REVOKE CONNECT … FROM PUBLIC`; the password kept in the door's workbench store (0600,
   `developer-door`). Drop: terminate its sessions (it owns them), `DROP DATABASE`, `DROP ROLE`. Reset: a new password.
4. **The schema clone** (`clone.py`): `pg_dump --format=custom --schema-only --lock-wait-timeout=5s --exclude-schema=memory
   --exclude-schema='maludb*' --exclude-schema=mc2db --exclude-extension=maludb_core` as `developer_ops` (table-level `MAINTAIN` admits the
   dump's locks), the connection string built from the registry's validated name and passed as an argument — **never a shell** — then
   `pg_restore --no-owner --no-privileges` as the workbench's role; `COMMENT ON EXTENSION` failures filtered (finding 5). A database using
   an untrusted extension clones only from `dx_template`.
5. **`rehearse`** (`rehearse.py`): a throwaway clone `dxr_<n>` made as a workbench is; each statement that can run in a transaction is run
   with the own-pid `pg_locks` read before commit (**the locks it took**) and `pg_relation_filenode()` before and after (**whether it
   rewrote**), its time on empty tables, its error; `CONCURRENTLY` statements run on their own, checked for success, labelled "lock from the
   rule table". The clone and its role are dropped at the end (the worker drops any older than an hour). Refused under `is_eval` (`eval`).
   Agents may rehearse (design D10).
6. **`signal`**: `SELECT dx_signal($pid, $kind)` as `developer_ops` in the tool's own database. `dx_signal` (owned by
   `developer_signaller`, `pg_signal_backend`) refuses a superuser's session, a session whose `application_name` starts `developer`, and a
   session on a database that is not `application`, `development` or a workbench of the registry.
7. **`maintenance`** (the worker asks; the door runs it): `VACUUM`, `VACUUM (ANALYZE)`, `ANALYZE`, `REINDEX INDEX CONCURRENTLY`, `REFRESH
   MATERIALIZED VIEW CONCURRENTLY` composed for one object (resolved with `to_regclass` and quoted with `format('%I')`) as `developer_ops`
   with `statement_timeout 0` and `lock_timeout 10s`. The door answers `{status: started, pid}` at once and runs the job on a thread of its
   own (counted against `door_pool_max`); every 2 s that thread reads `progress` on a meta connection and writes the job's status, progress,
   pid and outcome through **`dx_door_job_update(job_id, jsonb)`** (a `dx_door_*` function, so `deploy/own-database.sql` grants it to
   `developer_meta`; slice 7's migration creates it). At most one running job per target; a door restart marks its running jobs `failed`
   ("the door restarted") on start. `VACUUM FULL` and `CLUSTER` are never composed.
8. **`snapshot`** (the worker, nightly per `application`, `kernel` and `own` target): `snapshot_pass`; PHP normalizes and fingerprints (the
   generators), writes `catalog_snapshots` / `snapshot_objects`, marks each change explained by a change set, a draft or the grants service.
9. **`export`** (the worker): the statement re-run at the person's level — never a re-send of what the screen showed — as `COPY (<statement>)
   TO STDOUT (FORMAT csv|text)` streamed into the export's file under `storage/exports/` (written by the door; the setgid directory makes it readable by `developer-web`),
   capped at `export_max_rows` and `export_max_mb` (`cap`). CSV cells starting `=`, `+`, `-`, `@`, a tab, CR or LF, or their full-width forms,
   are prefixed with `'`. JSON is one object per row; SQL is `INSERT`s composed with `quote_literal`.
10. **`import`** (into a workbench only): `COPY schema.table (cols) FROM STDIN (FORMAT csv, HEADER, ON_ERROR ignore|stop)` as the workbench's
    role, streamed from the uploaded file the door reads from `storage/imports/` — never a server path in SQL.

## 7. The audit

- **`query_runs`** — one row per request of kind `run`, `explain`, `apply`, `undo`, `rehearse`, `export`, `import`, `signal` and
  content/reveal `memory` (refusals and timeouts included): opened by `dx_door_run_open()` as the request starts, closed by
  `dx_door_run_close()` on every way out, with the caller, `on_behalf_of`, `agent_run_id`, the source, the target, the level, the tier, the
  window, the change set or rehearsal, the SQL's sha256 and the SQL (nulled after `sql_text_days`).
- **`door_statements`** — per statement an **intent row** (`status = 'running'`) written before it executes, then its result: class, tier,
  libpg_query fingerprint, SQLSTATE, rows affected, ms, backend pid, and the error **masked** (`mask_message`: every quoted fragment and
  parenthesised key value replaced by `•••`). The person saw the whole message once, on the screen, capped at 500 characters.
- **`door_usage`** — `named:<name>` and `memory:<name>` (state) counted per caller per day.
- **Attribution** — every connection's `application_name` is `developer:<member>:<request_id>` (at most 63 bytes) and every typed or
  composed statement is sent after a leading comment `/* developer: <member display or agent> run <request_id> */` — so
  `pg_stat_activity` and the server log say who (R71). The comment is added by the door, not by the caller.
- **The server's own record** (D14): pgaudit per tool role, set by the owner (`write` on `developer_write`, `ddl, misc` on `developer_ops`,
  `role, ddl` on `developer_rolemaker`); `developer_write` runs only bound statements, so no value reaches the server log.
- PHP's `log_activity()` writes the action events (`sql.run`, `change_set.apply`, …) with ids, classes and counts — never SQL text, never a
  value (each slice lists its events).

## 8. The clients

**PHP — `app/developer/door.php`** (Phase 2 writes it; every slice calls it; it never opens a socket to PostgreSQL):

```
door_ask(string $kind, array $fields, float $timeout = 35.0): array      // signs, sends one line, reads one line
door_ping(): array                                                         // timeout 2 s
door_run(string $datname, string $sql, string $source, ?string $requestId = null, array $params = []): array   // 35 s; a workbench: 310 s
door_cancel(string $runRequestId): array                                   // 5 s
door_named(string $datname, string $name, array $params = []): array       // 20 s
door_memory(string $datname, string $name, array $params = []): array      // 20 s
door_explain(string $datname, string $sql, array $options): array          // 35 s
door_classify(string $datname, string $sql): array                         // 10 s
door_lint(string $sql): array                                              // 20 s
door_apply(string $datname, int $changeSetId, array $items): array         // 35 s
door_undo(string $datname, int $changeSetId, array $images): array         // 35 s
door_workbench(string $op, string $datname, array $fields = []): array     // create / drop / reset / size — 310 s
door_rehearse(string $datname, int $changeSetId, array $statements): array // 310 s
door_signal(string $datname, int $pid, string $signal): array              // 10 s
```

`door_ask()` fills `request_id` (uuid v4 unless given), `ts`, `caller` (`current_member_id()`), `on_behalf_of` and `agent_run_id` (from
`run_facts()` under an action token), `is_eval`, and calls **`session_write_close()` before it connects**. It connects with
`stream_socket_client('unix://' . DX_DOOR_SOCKET)` and `stream_set_timeout()`; a refused connect, a timeout or an empty answer returns
`['status' => 'error', 'refusal_rule' => 'door_unavailable', 'message' => 'The database door is not answering — try again in a moment.']`
and the screen renders that sentence in its result area, never an error page. The key is `env('DX_DOOR_KEY')` (`config/.env`, readable by
`developer-web` alone). The worker (`bin/worker.php`, user `developer-web`) uses the same client.

**Python — `mcp/door_client.py`** (Phase 4): `ask(kind, fields, timeout)` with the same signing as `services/door/server.ask`; the records
server passes the verified bearer's member, K38's `requested_by_member_id` as `on_behalf_of`, the run id and `source = 'mcp'`; a
`door_unavailable` becomes the tool's `{"ok": false, "error": {"code": "door_unavailable", "retry": true}}`.

## 9. The grants service (`services/grants/`)

Every minute (`developer-grants.service`, `--once` for one pass), as `developer_grantor` with its own passfile: read `mcp_grant_plan` in the
tool's own database (one row per classified column of every granted `application` / `development` target, plus one `table_name IS NULL`
row per target); for each target connect as the grantor and run `run_pass()`: per table and view, grant column `SELECT` to
`developer_read` on every column not classified `secret`, to `developer_read_masked` on every column neither `secret` nor `personal`, and
column `SELECT, INSERT, UPDATE` to `developer_write` on non-`secret` columns (table `DELETE`); **`xmin` granted on its own** to every tier
that reads (finding 3); revoke what the plan no longer gives. **Independently of the plan, a column whose name matches the built-in secret
patterns (`services/grants/patterns.py`) is never granted** unless `cleared_secret` (a super-admin cleared it). Never a table-level
`SELECT`; never `TRUNCATE`, `REFERENCES`, `TRIGGER`; never a `memory` schema or an extension member. A table not created by `postgres` is
reported "not granted to the tool" until the owner re-runs `deploy/grant-target.sh`. Each pass is recorded by `dx_grants_pass_log(datname,
jsonb)` (`grants_passes`) so drift marks the ACL changes explained. A pass on one target takes 56–204 ms for five tables (FINDINGS).

## 10. The proof

`tests/door/run.sh` (Phase 0: 174 checks) is extended by each slice that adds a kind or a named query — never replaced: slice 1 the
discovery, grants and catalog-index queries; slice 2 the structure queries on HR's real migrations (`impact` and `fk_graph` over a fixture
with a view chain); slice 3 `run` end to end with the leading comment and `application_name` read back from `pg_stat_activity`, cancel, the
caps, `export`; slice 4 `classify`, `lint`, `import`, `workbench_size`; slice 5 nothing new (Phase 0 proved `apply`/`undo`); slice 6
`explain` with every option and the ANALYZE rules; slice 7 `activity`, `blocking`, `locks`, `session_text`, `signal` (a scratch session
blocked and cancelled), `maintenance` with `progress`; slice 8 the health checks on a fixture with each defect, `snapshot`; slice 9 the
memory library on a scratch memory database (`dx_t9_memory`, `maludb_core` installed by the proof as Phase 0 did) and the static secret
test. Every check runs on `dx_proof_*` roles and `dx_door_*` / `dx_t<N>_*` databases (the owner's leave) and drops what it made unless
`KEEP=1`. `tests/integration/sql_policy.sh` keeps proving the door's code against the real `dx_door_policy()`.

## Requirements claimed

MUSTs (52): R39, R40, R42, R44, R45, R55, R67, R68, R71, R72, R86, R93, R102, R103, R104, R105, T1, T11, T12, T13, T14, T15, T16, T20, T22, T23, T25, T28, T29, T30, T31, T32, T33, E5, E6, E7, E8, E18, E19, S1, S2, S3, S5, S6, S7, S9, S11, S12, S14, S18, S22, MR2

## Decisions taken here

1. **`clone` is `workbench_create` with a `source`**, not a kind of its own; a rehearsal clones internally.
2. **`classify` and `lint` open no target connection** — Change review and the editor's refusals use them freely.
3. **The leading comment is the door's**, never the caller's, so it cannot be forged into a person's name.
4. **`bloat_estimate` runs as `developer_read_masked`**: the design said `developer_read`; the masked tier sees the statistics of every
   column a Viewer's plan may touch, and no estimate needs a personal column's histogram. Exact `pgstattuple` stays `developer_ops`'s.
5. **Phase 0's named queries are renamed** (`databases` → `discovery`, `tables` → `family_page`, `columns_map` → `completion_map`) in slice 1,
   with the door proof's checks updated in the same commit.
6. **Exports and imports pass through files under `storage/exports/` and `storage/imports/`** — directories owned by `developer-door`, group
   `developer`, mode 2770 (setgid, so every file the door writes is readable by `developer-web` without the door joining the group) — never
   through the socket's 1 MB line.

## Open questions

1. `pg_stat_statements` lives in the tool's own database (one installation covers the cluster) — the owner creates it (ROOT_STEPS); until
   then `top_statements` answers `not_installed`. No decision needed unless the owner prefers the `postgres` database.
2. `storage/exports/` and `storage/imports/` (`developer-door:developer`, 2770) are a root step `ROOT_STEPS.sh` does not hold yet — owed to
   Phase 5, recorded in the report.
