> Research report for `docs/developer-design.md` §0, written 2026-10-11 by a research agent of the planning session.

# 02 — Implementing a graphical PostgreSQL 17 object manager (PHP 8.3, with Python where it helps)

**Scope.** How to build the PostgreSQL side of `maludb-os-developer` on this server: what a DBA manages and how to read it back
as DDL, generating DDL from forms and showing its lock cost, schema compare, running arbitrary SQL from a web request,
editing data, monitoring, the browser editor and ER diagrams, and this server's inventory. Out of scope here, because
sibling reports cover them: the product survey, MaluDB, the estate's conventions, and security / AI-agent safety. Where one
of my findings has a security consequence, I flag it and leave the decision to that report.

**Method.** I read the Data Lake query service and the Boards island precedent. I took the server inventory read-only, as
the kernel's role (`app_rw`, not a superuser), with `default_transaction_read_only=on`. I ran small read-only probes in PHP
8.3 to measure behaviour, not guess it. I checked every library's licence and its latest release through the GitHub, npm
and PyPI APIs on 2026-10-11. Local facts are cited as `path:line`, web facts as URLs.

---

## 0. Key findings

1. **PostgreSQL rebuilds DDL for most objects, but not for tables, sequences, types, schemas, roles, policies, grants or
   databases.** Functions, views, indexes, constraints, triggers, rules and statistics objects each have a `pg_get_*def`
   function. Everything else has to be assembled from the catalogs. PG 19 had added `pg_get_role_ddl()`,
   `pg_get_database_ddl()` and `pg_get_tablespace_ddl()`, but they were **reverted from REL_19_STABLE on 2026-09-13**
   (https://www.postgresql.org/message-id/E1x5ovh-00000000AmY-3ObG@gemulon.postgresql.org), and no version has a
   `pg_get_tabledef`. The usual answers are pg_dump, pgAdmin's Jinja SQL templates, the pure-SQL `ddlx` extension and the
   PL/pgSQL `pg_get_tabledef`. All of them use permissive licences, and all of them are best used as references for a table
   generator we write ourselves.
2. **`pg_dump --schema-only` is not a cheap per-object DDL source.** It must `LOCK TABLE … IN ACCESS SHARE MODE` every table
   it dumps. As the kernel's role it failed on a sibling database with `permission denied for table members`. It took 0.39 s
   on a small database and 1.46 s on a MaluDB memory database (measured). The catalog functions need no table privilege and
   take no table lock.
3. **Arbitrary SQL must not go through PDO on this server.** Measured with PHP 8.3.6 and libpq 18.6:
   - PDO with server-side prepares refuses a multi-statement string (`42601 cannot insert multiple commands into a prepared statement`).
   - With emulated prepares, PDO returns only the last result set, and `nextRowset()` raises `IM001 driver does not support multiple rowsets`.
   - PHP 8.3's PDO has no notice API at all.

   The `pgsql` extension (`pg_send_query` + `pg_get_result`) returns every result set, every notice, the SQLSTATE and the
   error's character position.
4. **PHP cannot hold a transaction across clicks.** Apache runs prefork with 150 workers, PostgreSQL allows 100
   connections, and persistent connections hand a backend to whichever request comes next. Explicit
   `BEGIN … (look) … COMMIT`, "load more" over a server-side cursor, and cancel all need a small stateful Python session
   service. It can be modelled on Data Lake's query service: a Unix socket, `SO_PEERCRED`, JSON lines, cancel answered beside
   the running request. psycopg 3 is the right driver because it keeps every result of a multi-statement call and has
   `cancel_safe()` on libpq ≥ 17. asyncpg returns only a status for a script.
5. **A multi-statement string sent in one simple Query runs as one implicit transaction.** It stops at the first error and
   refuses `CONCURRENTLY` and `VACUUM`. The editor therefore needs a real statement splitter and should send statements one
   at a time.
6. **Lock cost can be shown before running, in three layers.**
   - A static rule table keyed by the operation the form generated, derived from the PG 17 `ALTER TABLE` docs and
     `AlterTableGetLockLevel()`.
   - A parse of typed SQL.
   - Optionally, a measured dry run on a schema-only scratch clone: own-pid `pg_locks`, plus a change of
     `pg_relation_filenode()`, which proves a rewrite.

   squawk (Rust, Apache-2.0 OR MIT, 2.68.0, 2026-10-08, 78 rules, a pip wheel) is the linter to embed for typed scripts.
7. **Statement classification needs libpg_query.** sqlglot, already in the estate, parsed 8 of 16 common PostgreSQL
   statements only as opaque `Command`s. It also classified `WITH x AS (DELETE …) SELECT …` as a plain `Select`, which is the
   data-modifying-CTE trap. The good Python binding, pglast 8.5 (PG 18 parser), is **GPL-3.0-or-later**. That is a licence
   decision for the owner (§4.10).
8. **For schema diff, embed a tool and build a subset.** migra is deprecated (last release 2022-09-18). Atlas Community
   excludes views, functions, triggers and RLS. Stripe's pg-schema-diff (Go, MIT, v1.0.9, 2026-08-06, PG 14–17) and pgschema
   (Go, Apache-2.0, v1.13.1, 2026-09-20, PG 14–18, the broadest object coverage) are the embeddable candidates. A
   catalog-snapshot diff with per-object normalized DDL is realistic to build ourselves. A safe migration *planner* is not.
9. **Use CodeMirror 6 (MIT) as a committed esbuild island, not Monaco.** Monaco's own README answers "No" to mobile support,
   and the guidelines require 375 px screens. CodeMirror's development moved from GitHub to a self-hosted Forgejo in April
   2026, but npm releases continue (`@codemirror/view` 6.43.14, 2026-10-07). PEV2 (PostgreSQL licence, 1.24.0) renders
   EXPLAIN. It needs Vue 3 and Bootstrap CSS, and the nxl theme already provides Bootstrap 5.3.
10. **ER layout has two viable routes.** Graphviz is *not installed* here (apt candidate 2.42.2). The choices are server-side
    Graphviz SVG (an apt install, the owner's) or a client island with ELK.js (`EPL-2.0 OR GPL-3.0-or-later`, 0.12.0) or
    `@dagrejs/dagre` (MIT, 3.1.1).
11. **A non-superuser sees almost nothing in monitoring.** As `app_rw`, 23 of 25 `pg_stat_activity` rows showed NULL
    `backend_type`, `state` and `query`. `pg_stat_statements` is preloaded (`postgresql.conf:773`) but created in no
    database I checked, and creating it needs a superuser. `pg_monitor` and `pg_signal_backend` are the roles that make a
    monitoring screen useful.
12. **MaluDB memory databases are mostly extension objects.** In `certstudy_memory`, all 161 tables and 571 functions belong
    to the `maludb_core` extension (`pg_depend.deptype = 'e'`). The tool must show extension members read-only, or it will
    break MaluDB upgrades.

---

## 1. The object inventory and how to read each object back as DDL

### 1.1 Principles

- **Read `pg_catalog`, not `information_schema`.**
  - `information_schema` hides objects the caller has no privilege on.
  - It lacks PostgreSQL-specific features such as partitioning, access methods, RLS, publications and exclusion constraints.
  - It renames types into SQL-standard spellings.

  Every serious tool reads `pg_catalog`: pgAdmin, postgres-meta, pg_dump.
- **Identify objects by OID within a request, and by a stable address across requests.**
  `pg_identify_object_as_address(classid, objid, objsubid)` returns `(type, object_names[], object_args[])`, which survives a
  reconnect. `pg_get_object_address()` turns it back into an OID. `pg_describe_object()` gives the human label. OIDs change
  across dump and restore, so a saved link or a diff must use the address.
- **Gate queries by `current_setting('server_version_num')::int`.** The server runs 17.11 today. PG 18 changes catalogs the
  tool reads, for example NOT NULL constraints become `pg_constraint` rows with `contype = 'n'`. In 17 they are only
  `pg_attribute.attnotnull`.
- **Quote with the server's rules.** Use `quote_ident()` / `format('%I')` in SQL and `pg_escape_identifier()` in PHP's pgsql
  extension. PDO has no identifier quoting. This server knows 491 keywords, 78 of them reserved (`pg_get_keywords()`,
  measured).

### 1.2 Object-by-object: catalogs and DDL functions

| Object | Catalogs / views to introspect | Server function that rebuilds DDL | Notes for PG 17 |
|---|---|---|---|
| Database | `pg_database` (shared), `pg_db_role_setting`, `pg_shdescription` | **none** (19's `pg_get_database_ddl` reverted) | Visible from any connection, but looking *inside* needs a connection to that database. 17 renamed the locale column to `datlocale` (verified: `datlocprovider`, `datlocale`, `dathasloginevt` present) and added the `builtin` collation provider (2 `b` collations here). `age(datfrozenxid)` for wraparound. |
| Schema | `pg_namespace` | **none** | `nspacl` for grants. Exclude `pg_*`, `information_schema` and `pg_toast*`. |
| Table: ordinary, partitioned, unlogged, temp, inheritance, typed | `pg_class` (`relkind` r/p, `relpersistence` p/u/t, `relispartition`, `reloftype`, `reloptions`, `relam`, `reltablespace`, `relreplident`, `relrowsecurity`), `pg_inherits`, `pg_partitioned_table`, `pg_am`, `pg_tablespace` | **none** | Pieces: `pg_get_partkeydef(oid)`, `pg_get_expr(relpartbound, oid)`, `pg_partition_tree()`, `pg_partition_ancestors()`. 17 allows identity columns and exclusion constraints on partitioned tables. |
| Column | `pg_attribute`, `pg_attrdef`, `pg_collation`, `pg_type` | `format_type(atttypid, atttypmod)`, `pg_get_expr(adbin, adrelid)` | `attidentity` (a/d), `attgenerated` (s), `attstorage`, `attcompression`, `attstattarget`, `attnotnull`, `attisdropped` (skip). Column ACL in `attacl`. |
| Constraint: PK, FK, UNIQUE, CHECK, EXCLUDE | `pg_constraint` (`contype` p/f/u/c/x, `convalidated` = NOT VALID when false, `condeferrable`, `condeferred`, `conindid`, `conislocal`/`coninhcount`) | `pg_get_constraintdef(oid, true)` | The text includes `NOT VALID`, `DEFERRABLE INITIALLY DEFERRED`, `NULLS NOT DISTINCT` and the exclusion operator list. Domain checks live here too (`contypid`). |
| Index: every access method, partial, expression, INCLUDE | `pg_index` (`indisvalid`, `indisready`, `indisunique`, `indisprimary`, `indnullsnotdistinct`), `pg_class`, `pg_am`, `pg_opclass` | `pg_get_indexdef(oid)`, or per column `pg_get_indexdef(oid, n, true)` | `indisvalid = false` marks a failed `CREATE INDEX CONCURRENTLY`. Here: btree, hash, gist, spgist, gin, brin, plus `hnsw` and `ivfflat` from pgvector (measured). Skip indexes owned by a constraint (`conindid`). |
| View | `pg_class` (relkind v), `pg_rewrite`, `reloptions` (`check_option`, `security_barrier`, `security_invoker`) | `pg_get_viewdef(oid, true)` | Rebuild as `CREATE OR REPLACE VIEW … WITH (…) AS …`. A column can be neither dropped nor retyped by REPLACE, so a change means drop and recreate the dependants (§3.3). |
| Materialized view | `pg_class` (m), `relispopulated` | `pg_get_viewdef(oid, true)` | Add `WITH [NO] DATA`, its indexes and storage parameters. |
| Sequence, identity | `pg_sequence`, `pg_sequences` view, `pg_depend` (ownership `a`/`i`) | **none** | `pg_get_serial_sequence(table, col)`, `pg_sequence_last_value()`. An identity sequence is internal (`deptype i`). |
| Function, procedure, aggregate, window | `pg_proc` (`prokind` f/p/a/w), `pg_language`, `pg_aggregate` | `pg_get_functiondef(oid)` (functions and procedures; **refuses aggregates**), `pg_get_function_arguments`, `…_identity_arguments`, `…_result`, `pg_get_function_sqlbody` | Languages present: internal, c, sql, plpgsql (measured). Aggregates must be assembled from `pg_aggregate`. In `certstudy_memory`: f=1033, a=5, p=4. |
| Trigger | `pg_trigger` (`tgisinternal`, `tgenabled` O/D/R/A) | `pg_get_triggerdef(oid, true)` | Exclude internal FK triggers. |
| Event trigger | `pg_event_trigger` | **none** | Events: `ddl_command_start`, `ddl_command_end`, `sql_drop`, `table_rewrite`, and `login` (new in 17). The `event_triggers` setting (17) disables them for debugging. |
| Type: enum, composite, domain, range, multirange, base | `pg_type` (`typtype` e/c/d/r/m/b), `pg_enum`, `pg_range`, `pg_attribute` (via `typrelid`), `pg_constraint` (domain checks) | `format_type()` only | Domain: base type, default, NOT NULL, checks. Range: subtype, opclass, canonical, subdiff. |
| Extension | `pg_extension`, `pg_available_extensions`, `pg_available_extension_versions`, `pg_depend` (`deptype e`) | **none** | Show the installed version against the default. Here pgvector sits at 0.8.3, 0.8.4 and 0.8.7 in different databases (measured). |
| Role, membership | `pg_roles` (`pg_authid` needs superuser), `pg_auth_members` (PG 16+: `admin_option`, `inherit_option`, `set_option`), `pg_db_role_setting` | **none** (19's `pg_get_role_ddl` reverted) | Passwords are never readable. |
| Grants | `relacl`, `attacl`, `proacl`, `nspacl`, `datacl`, `typacl`, `fdwacl`, `srvacl`, `lanacl`, `spcacl` | `aclexplode()`, `acldefault()`, `has_*_privilege()` | Grantee 0 means PUBLIC. |
| Default privileges | `pg_default_acl` | **none** | `ALTER DEFAULT PRIVILEGES [FOR ROLE r] [IN SCHEMA s] GRANT …` |
| RLS policy | `pg_policy`, `pg_policies` view (already gives `qual` / `with_check` text) | **none** (`pg_get_expr(polqual, polrelid)` for the pieces) | There are many: 113 in `certstudy`, 177 in `certstudy_memory` (measured). |
| Publication | `pg_publication`, `pg_publication_rel` (`prqual`, `prattrs`), `pg_publication_namespace` | `pg_get_publication_tables()` (pieces only) | Row filters and column lists since 15. |
| Subscription | `pg_subscription` (`subconninfo` readable only by privileged roles), `pg_stat_subscription`, `pg_stat_subscription_stats` | **none** | `pg_create_subscription` (16) lets non-superusers create them. |
| FDW, server, user mapping, foreign table | `pg_foreign_data_wrapper`, `pg_foreign_server`, `pg_user_mappings` (options hidden unless privileged), `pg_foreign_table` | **none** | `pg_options_to_table()`. `postgres_fdw`, `file_fdw` and `dblink` are available, not installed. |
| Collation | `pg_collation` (`collprovider` c/i/b) | **none** | |
| Statistics object | `pg_statistic_ext`, `pg_statistic_ext_data` | `pg_get_statisticsobjdef(oid)`, `…_columns`, `…_expressions` | |
| Comment | `pg_description`, `pg_shdescription` | `obj_description()`, `col_description()`, `shobj_description()` | |
| Tablespace | `pg_tablespace` | **none** (19's version reverted) | `pg_tablespace_location()` |
| Rule | `pg_rewrite` | `pg_get_ruledef(oid, true)` | Skip each view's `_RETURN` rule. |
| Cast, operator, opclass/opfamily, text search, conversion | `pg_cast`, `pg_operator`, `pg_opclass`, `pg_opfamily`, `pg_ts_*` | **none** | Rarely edited by hand: browse only (LATER). |

The function reference is https://www.postgresql.org/docs/17/functions-info.html (§9.27 "Object Information and Addressing
Functions" and "Get Object DDL Functions").

### 1.3 What has no DDL function, and how others solve it

| Approach | What it is | Fit |
|---|---|---|
| `pg_dump --schema-only [-t …] [--filter file]` (17 added `--filter`) | The reference implementation (C, `dumpTableSchema()`). Output is exact. | A subprocess per call. It must lock every table it dumps (ACCESS SHARE) and needs SELECT on each. **Measured:** as the kernel's role it failed on `hr_dev` (`permission denied for table members`) and took 0.39 s / 1.46 s on two databases. It cannot select a single function, type or policy. **Use it as the golden test** for our generator and for whole-schema exports, not per screen. |
| pgAdmin 4 SQL templates | Jinja templates per object and per server version (`web/pgadmin/browser/server_groups/servers/databases/schemas/tables/templates/tables/sql/{default,15_plus,16_plus,macros}/create.sql`, `properties.sql`, `update.sql`, …), fed by properties queries. PostgreSQL licence; release REL-9_18 tagged 2026-09-15. | The best reference for *forms*: each template pairs a properties query with create, update and delete SQL. Porting to plain PHP templates is mechanical, but the templates are Jinja and must be rewritten, not embedded. |
| Supabase `postgres-meta` | TypeScript REST API over the catalogs; the queries are in `src/lib/sql/*.sql.ts` (`columns.sql.ts`, `table.sql.ts`, `policies.sql.ts`, `views_key_dependencies.sql.ts`, …). Apache-2.0; v0.100.0, 2026-10-06. | **Study the queries**, especially `columns.sql.ts`, which adapts `information_schema.columns` to `pg_catalog`. Its writes (`PostgresMetaColumns.ts`) build plain `ALTER TABLE … ADD COLUMN …` with `pg-format` quoting and no lock awareness. Its README says security is "None". Do not embed (Node service, no auth). |
| `ddlx` (lacanoid/pgddl) | Pure SQL functions (no C, not even PL/pgSQL): `ddlx_create(oid)`, `ddlx_drop`, `ddlx_script` (the object plus dependants, ordered), `ddlx_alter`. PostgreSQL-style licence; version 0.31 (`ddlx.control`, `superuser = false`); last push 2026-09-25. | Excellent reference, and it can be loaded without `CREATE EXTENSION`. But it must live *inside each target database*, and installing functions into other applications' databases is intrusive. Port its logic, or load it only into scratch clones. |
| `pg_get_tabledef` (MichaelDBA) | One PL/pgSQL function: columns, defaults, storage, constraints, indexes, partitions, comments, triggers, owner, grants, policies. MIT; last push 2026-07-28. | Same placement problem. A good cross-check of table features. |

**Recommendation.** Write our own table, sequence, type, role and policy DDL generators in PHP over catalog queries. Port the
queries from postgres-meta and pgAdmin, cross-check against ddlx and pg_get_tabledef, and use the server's `pg_get_*def` for
everything that has one. Prove the generator in the test suite by comparing it with `pg_dump --schema-only` on fixture
databases (T3). Never call pg_dump to render a screen.

### 1.4 Core introspection snippets (PG 17)

```sql
-- Table header ($1 = table oid)
SELECT c.relkind, c.relpersistence, c.relispartition, am.amname AS access_method, ts.spcname AS tablespace,
       pg_get_partkeydef(c.oid) AS partition_key, pg_get_expr(c.relpartbound, c.oid) AS partition_bound,
       (SELECT array_agg(i.inhparent::regclass ORDER BY i.inhseqno) FROM pg_inherits i WHERE i.inhrelid = c.oid) AS parents,
       c.reloftype::regtype AS of_type, c.reloptions, c.relreplident, c.relrowsecurity, c.relforcerowsecurity,
       obj_description(c.oid, 'pg_class') AS comment
FROM pg_class c LEFT JOIN pg_am am ON am.oid = c.relam LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace
WHERE c.oid = $1;

-- Columns
SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull,
       pg_get_expr(d.adbin, d.adrelid) AS default_expr, a.attidentity, a.attgenerated,
       CASE WHEN a.attcollation <> t.typcollation THEN co.collname END AS collation,
       a.attstorage, a.attcompression, col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
LEFT JOIN pg_collation co ON co.oid = a.attcollation
WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum;

-- Constraints and the indexes that are not constraint-owned
SELECT conname, contype, pg_get_constraintdef(oid, true) AS def, convalidated, condeferrable, condeferred
FROM pg_constraint WHERE conrelid = $1 ORDER BY contype, conname;
SELECT i.indexrelid::regclass, pg_get_indexdef(i.indexrelid) AS def, i.indisvalid
FROM pg_index i WHERE i.indrelid = $1
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid AND k.conrelid = $1);

-- Grants, PUBLIC included (grantee 0 = PUBLIC)
SELECT CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS grantee,
       a.privilege_type, a.is_grantable, a.grantor::regrole AS grantor
FROM pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a WHERE c.oid = $1;

-- Is this object an extension member? (then read-only)
SELECT e.extname FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
WHERE d.classid = $1::regclass AND d.objid = $2 AND d.deptype = 'e';

-- Safe type parsing for a form's "type" field (PG 17 has to_regtypemod)
SELECT format_type(to_regtype($1), to_regtypemod($1));   -- 'numeric(12,2)' → numeric(12,2); unknown → NULL
```

Measured on this server: `to_regtype('no_such_type')` returns NULL, but a malformed string such as `int; drop table x` raises
a syntax error. It never executes anything, but the form handler must catch the error.

### 1.5 Extension members and scale (measured 2026-10-11)

| Database | Schemas | Tables | Views | Functions | Triggers | Policies | Extension members |
|---|---|---|---|---|---|---|---|
| `certstudy` (the kernel) | 1 | 90 | 83 | 412 | 56 | 113 | — |
| `certstudy_memory` (MaluDB) | 4 | 161 | 91 | 1,042 | 32 | 177 | `maludb_core` 1,257 (571 functions, 311 relations), `btree_gist` 264, `vector` 237, `pg_trgm` 47, `pgcrypto` 36 |

Every table in the memory database belongs to `maludb_core`. The tenant schema (`certstudy_mem`) holds only 78 views.
Catalog timings, warm, over the PHP pgsql extension:

| Query | `certstudy` | `certstudy_memory` |
|---|---|---|
| Every user column (2,185 / 2,855 rows) | 15 ms | 27 ms |
| `pg_get_viewdef` for every view | 137 ms (83 views) | 4 ms |
| `pg_get_functiondef` for 410 functions | 12 ms | — |

A whole-database autocomplete map is cheap. Rendering every view definition on one page is not, so the object tree must be
lazy.

---

## 2. DDL from forms; lock levels and rewrite cost

### 2.1 The lock primer the screen must explain

Source: https://www.postgresql.org/docs/17/explicit-locking.html.

- **ACCESS EXCLUSIVE** conflicts with everything, including plain `SELECT`.
- **SHARE** blocks writes and allows reads (`CREATE INDEX`).
- **SHARE ROW EXCLUSIVE** blocks writes and other DDL (`CREATE TRIGGER`, `ADD FOREIGN KEY`).
- **SHARE UPDATE EXCLUSIVE** allows reads and writes but conflicts with other DDL and VACUUM (`VALIDATE CONSTRAINT`,
  `CONCURRENTLY`).

The real danger is the **lock queue**. A DDL statement that waits for ACCESS EXCLUSIVE behind one long transaction blocks
every later reader of the table, which is an outage even when the DDL itself would take milliseconds. Hence `lock_timeout`
on every DDL execution.

### 2.2 Operation table

Sources: https://www.postgresql.org/docs/17/sql-altertable.html, sql-createindex, sql-reindex, sql-dropindex; the
PostgreSQL 17 source `src/backend/commands/tablecmds.c` (`AlterTableGetLockLevel()` at line 4482; rewrite flags at 5016 and
5031 persistence, 7371 and 8474 default value, 12978 column type, 14954 access method), `policy.c:627` / `:806`, and
`trigger.c:211`.

| Operation | Lock on the table | Rewrite or scan | Safe pattern |
|---|---|---|---|
| `ADD COLUMN` with no default, or a non-volatile default | ACCESS EXCLUSIVE (brief) | none (the default is stored in metadata) | `lock_timeout` |
| `ADD COLUMN` with a volatile default (`clock_timestamp()`, `random()`, `gen_random_uuid()`) | ACCESS EXCLUSIVE | **rewrite of the table and all its indexes** | Add it nullable with no default, then `SET DEFAULT`, then backfill in batches |
| `ADD COLUMN … GENERATED ALWAYS AS (…) STORED` | ACCESS EXCLUSIVE | rewrite | A column kept by a trigger (strong_migrations) |
| `ADD COLUMN` identity / serial | ACCESS EXCLUSIVE | rewrite (every row needs a value) | A new table and a migration (strong_migrations) |
| `DROP COLUMN` | ACCESS EXCLUSIVE | none (marked dropped) | Application compatibility first |
| `ALTER COLUMN TYPE` | ACCESS EXCLUSIVE | **rewrite plus index rebuild**, unless the change is binary-coercible with no changing `USING` (e.g. `varchar(n)`→`varchar(m>n)` or `text`) | New column, dual-write, backfill, swap |
| `SET` / `DROP DEFAULT`, `DROP NOT NULL`, `DROP CONSTRAINT`, `RENAME` | ACCESS EXCLUSIVE | none | `lock_timeout` |
| `SET NOT NULL` | ACCESS EXCLUSIVE | **full scan**, skipped if a valid `CHECK (col IS NOT NULL)` exists | `CHECK … NOT VALID` → `VALIDATE` → `SET NOT NULL` → drop the check |
| `ADD CHECK` | ACCESS EXCLUSIVE | full scan | `NOT VALID`, then `VALIDATE CONSTRAINT` |
| `ADD FOREIGN KEY` | SHARE ROW EXCLUSIVE **on both tables** | full scan | `NOT VALID`, then `VALIDATE` |
| `VALIDATE CONSTRAINT` | SHARE UPDATE EXCLUSIVE (+ ROW SHARE on the referenced table) | scan, but concurrent with DML | — |
| `ADD PRIMARY KEY` / `UNIQUE` | ACCESS EXCLUSIVE | index build (plus a NOT NULL scan for a PK) | `CREATE UNIQUE INDEX CONCURRENTLY`, then `ADD CONSTRAINT … USING INDEX`. The index must not be partial or have expressions, must be btree in default order, and this is not supported on partitioned tables. |
| `ADD EXCLUDE` | ACCESS EXCLUSIVE | index build | None documented (strong_migrations asks for input) |
| `CREATE INDEX` | SHARE (blocks writes) | build | `CONCURRENTLY`: SHARE UPDATE EXCLUSIVE, two scans, not inside a transaction block, and a failure leaves an `indisvalid = false` index to drop |
| `DROP INDEX` | ACCESS EXCLUSIVE | — | `DROP INDEX CONCURRENTLY` |
| `REINDEX` | SHARE on the table, ACCESS EXCLUSIVE on the index (blocks reads that use it) | rebuild | `REINDEX CONCURRENTLY` |
| `SET STATISTICS`, attribute options, `fillfactor` / autovacuum / toast storage parameters, `parallel_workers`, `CLUSTER ON` | SHARE UPDATE EXCLUSIVE | none | — |
| `SET LOGGED` / `UNLOGGED` | ACCESS EXCLUSIVE | **rewrite** (`AT_REWRITE_ALTER_PERSISTENCE`) | Schedule it |
| `SET ACCESS METHOD`, `SET TABLESPACE`, `ALTER COLUMN … SET EXPRESSION` (17) | ACCESS EXCLUSIVE | rewrite, or a file copy for the tablespace move | Schedule it |
| `CREATE TRIGGER`, `ENABLE` / `DISABLE TRIGGER` | SHARE ROW EXCLUSIVE | none | — |
| `CREATE POLICY`, `ALTER POLICY`, `ENABLE` / `FORCE ROW LEVEL SECURITY` | ACCESS EXCLUSIVE | none | `lock_timeout` |
| `ATTACH PARTITION` | SHARE UPDATE EXCLUSIVE on the parent; ACCESS EXCLUSIVE on the partition and the default partition | scan of the partition, skipped by a matching valid CHECK | Add the matching CHECK first |
| `DETACH PARTITION` | ACCESS EXCLUSIVE on the parent (the ALTER TABLE default) | — | `CONCURRENTLY` (14+; not in a transaction block; not with a default partition), with `FINALIZE` to finish an interrupted one |
| `VACUUM FULL`, `CLUSTER` | ACCESS EXCLUSIVE | rewrite | `pg_repack` (apt candidate 1.5.3, not installed) |
| `REFRESH MATERIALIZED VIEW` | ACCESS EXCLUSIVE | rebuild | `CONCURRENTLY` (needs a unique index) |
| `TRUNCATE` | ACCESS EXCLUSIVE | new file | — |

**A correction to the brief.** "Add column with a volatile default" is the *dangerous* case, not a safe pattern. Since
PostgreSQL 11 a *non-volatile* default is free. A volatile one rewrites the table. strong_migrations' safe alternative is
"add the column without a default, set the default with `change_column_default`, then backfill"
(https://github.com/ankane/strong_migrations).

PG 18 adds `NOT NULL … NOT VALID` constraints. Not on 17: the rule table must be version-keyed.

### 2.3 Safe-pattern templates the forms should emit by default

```sql
SET lock_timeout = '3s';            -- per DDL statement; on 55P03 show the blockers and offer retry
SET statement_timeout = '15min';    -- per statement class; generous for VALIDATE / CONCURRENTLY

-- NOT NULL without the long ACCESS EXCLUSIVE scan
ALTER TABLE s.t ADD CONSTRAINT t_c_nn CHECK (c IS NOT NULL) NOT VALID;
ALTER TABLE s.t VALIDATE CONSTRAINT t_c_nn;            -- SHARE UPDATE EXCLUSIVE
ALTER TABLE s.t ALTER COLUMN c SET NOT NULL;           -- scan skipped
ALTER TABLE s.t DROP CONSTRAINT t_c_nn;

-- Primary key without blocking writes during the build
CREATE UNIQUE INDEX CONCURRENTLY t_pkey_new ON s.t (id); -- own statement, never inside BEGIN
ALTER TABLE s.t ADD CONSTRAINT t_pkey PRIMARY KEY USING INDEX t_pkey_new;
```

### 2.4 Showing a statement's cost before it runs: three layers

1. **A static rule table** keyed by the exact operation the form generated: `{object, subcommand, PG major} → {lock per
   relation, rewrite, scan, transaction-block allowed, notes}`, built from §2.2. This is exact for generated DDL and costs
   nothing. Add the table's size (`pg_total_relation_size`, `reltuples`) so "rewrite" reads as "rewrite 4.2 GB, ~38 M rows".
   An unknown operation shows as "ACCESS EXCLUSIVE, cost unknown".
2. **A parse of typed SQL** with libpg_query. Map `AlterTableStmt.cmds[].subtype` (`AT_AddColumn`, `AT_AlterColumnType`, …)
   to the same rule table. squawk covers the common hazards as lint messages.
3. **A measured dry run (SHOULD)**, as eugene (https://github.com/kaaveland/eugene) does. "Run the statements in a
   transaction and check what effects they have." Do it on a **schema-only scratch clone**, never the live database: on the
   live one a rewrite would really be performed before the rollback.

   ```sql
   BEGIN;
   SET LOCAL lock_timeout = '1s';
   SELECT pg_relation_filenode('s.t');                       -- before
   ALTER TABLE s.t ALTER COLUMN c TYPE bigint;
   SELECT locktype, relation::regclass, mode FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'relation';
   SELECT pg_relation_filenode('s.t');                       -- after: changed ⇒ rewrite
   ROLLBACK;
   ```

   On a clone the tables are empty, so a rewrite costs nothing and the changed filenode proves it.
   - The superuser alternative is a `table_rewrite` event trigger. `pg_event_trigger_table_rewrite_reason()` gives the
     reason bits (persistence, default, type, access method).
   - The clone costs: CREATEDB, extensions installable in the clone, about 1.5 s to dump the schema of a MaluDB memory
     database, plus the restore.

### 2.5 Migration linters and rule sources

| Tool | Language, licence | Status (2026-10-11) | Use |
|---|---|---|---|
| squawk (https://github.com/sbdchd/squawk) | Rust, Apache-2.0 OR MIT | 2.68.0, 2026-10-08. `pip install squawk-cli` ships a manylinux x86_64 wheel. | 78 rules (https://squawkhq.com/docs/rules), e.g. `adding-field-with-default`, `changing-column-type`, `constraint-missing-not-valid`, `require-concurrent-index-creation`, `require-lock-timeout`, `ban-concurrent-index-creation-in-transaction`. `--pg-version`, `--assume-in-transaction`, `--reporter json`. Own CST parser, not libpg_query. Has a language server and a WASM playground. **Embed as a subprocess.** |
| strong_migrations | Ruby, MIT | Active (pushed 2026-09-26) | Rule and safe-alternative reference (§2.2). It recommends `lock_timeout` 10 s and `statement_timeout` 1 h for migrations. |
| eugene | Rust, MIT | 0.8.3, 2026-03-11 | The lock-tracing method (layer 3). Its lint mode uses pg_query.rs. |
| pg-schema-diff hazards | Go, MIT | v1.0.9 | Hazard classes such as `INDEX_BUILD` and `INDEX_DROPPED`, approved with `--allow-hazards`. |
| postgres-language-server (Supabase community) | Rust, MIT | 0.28.1, 2026-10-10 | An LSP built on libpg_query, with type-checking against the database and lint rules. LATER: it needs a socket bridge to the browser. |

---

## 3. Schema diff and compare

### 3.1 What "compare" can mean, from cheapest to hardest

1. **Object inventory diff.** The sets of `pg_identify_object_as_address` present in A and in B: added, removed, both.
2. **Per-object definition diff.** Normalize each object's DDL (§1) and show a text diff per object. This is cheap and
   human-readable. It needs normalization: strip OIDs, sort grants, omit default storage options.
3. **Migration script.** Order the statements by dependency, choose online forms (CONCURRENTLY, NOT VALID), handle renames
   (no tool detects them reliably), and attach hazard warnings. This is where the tools differ.

### 3.2 Tools

| Tool | Language, licence | Status (2026-10-11) | Coverage and notes |
|---|---|---|---|
| migra | Python, Unlicense | **Deprecated.** The README says the final release was Sep 18, 2022. | Superseded by `results`. |
| results (djrobstep) | Python, BSD-3 | Spare-time project, "alpha state"; diffing "reached a certain level of maturity" | `schemadiff_as_sql`. Has `--with-privileges`. No `--unsafe` guard. |
| pg-schema-diff (Stripe) | Go, MIT | v1.0.9, 2026-08-06; PG 14–17 | Models schemas, extensions, enums, tables (columns, checks, policies, privileges), indexes, FKs, sequences, functions, procedures, triggers, views and materialized views (`internal/schema/schema.go:55–66`). The only types it supports are enums. No renames. Plans are online by design and **validated against a temporary database** (CREATEDB needed). A Go library or CLI. |
| pgschema (pgplex) | Go, Apache-2.0 | v1.13.1, 2026-09-20; PG 14–18 | The broadest declarative coverage: tables, partitions, identity, constraints, indexes, views, materialized views, functions, procedures, aggregates, triggers, sequences, enums, composites, domains, RLS, privileges incl. column level, default privileges, comments. Plan and apply with lock timeouts and CONCURRENTLY. Uses "an embedded Postgres instance internally". **Verify** whether that downloads PostgreSQL binaries at run time, which "nothing leaves the server" would forbid. CLI only. |
| Atlas | Go; Apache-2.0 community build, Atlas EULA for the default binaries | v1.3.0, 2026-08-02 | **Community Edition excludes views, materialized views, functions, procedures, triggers, RLS and extensions** (https://www.atlasgo.io/community-edition, https://atlasgo.io/features). A poor fit. |
| sqldef / psqldef | Go, MIT (parser Apache-2.0) | v3.11.26, 2026-10-01 | Diffs DDL files idempotently. Partial PostgreSQL feature coverage. |
| pg-delta (Supabase `pg-toolbelt`) | TypeScript, MIT on npm | `1.0.0-alpha.58`. Supabase CLI v2.115.0 (2026-08-18) made it the default for `db diff`. | Alpha, and Node. Watch it. |
| pgquarrel | C, BSD-3 | Last push 2023-03-27 | Stale. |
| apgdiff | Java, MIT | Last push 2024-01-03 | Stale. |
| pgAdmin Schema Diff | Python, PostgreSQL licence | Active | Tied to pgAdmin's templates. A reference only. |
| `pg_dump -s` text diff | — | — | A quick "what changed" report. Produces no migration. |

### 3.3 Dependency ordering (`pg_depend`)

- **`deptype` values:**
  - `n` normal: a DROP needs CASCADE.
  - `a` auto: dropped with the referenced object, e.g. an index with its table, or an owned sequence.
  - `i` internal: part of the object, e.g. an identity sequence or a constraint's index.
  - `P` / `S`: partition primary and secondary.
  - `e`: extension member.
  - `x`: auto-extension.
- **Views depend through their rewrite rule.** A `pg_rewrite` row has `objid`, and its `ev_class` is the view. Every column
  a view reads is a dependency, which is why `ALTER COLUMN TYPE` fails with "cannot alter type of a column used by a view or
  rule" until the dependants are dropped and recreated in the same transaction. That transaction holds ACCESS EXCLUSIVE on
  every view involved.
- **The method:** topologically sort the objects over `pg_depend` and `pg_shdepend`, roles and tablespaces, the way pg_dump's
  `pg_dump_sort.c` does, breaking loops by splitting an object (e.g. a table and its FK constraints).

```sql
-- Every view (transitively) that depends on table $1, deepest first: the drop order; reverse it to recreate
WITH RECURSIVE deps(oid, depth) AS (
  SELECT DISTINCT r.ev_class, 1
  FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
  WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
    AND d.refobjid = $1 AND r.ev_class <> $1
  UNION
  SELECT DISTINCT r.ev_class, deps.depth + 1
  FROM deps JOIN pg_depend d ON d.refobjid = deps.oid AND d.refclassid = 'pg_class'::regclass
                            AND d.classid = 'pg_rewrite'::regclass
  JOIN pg_rewrite r ON r.oid = d.objid WHERE r.ev_class <> deps.oid
)
SELECT oid::regclass, max(depth) AS depth FROM deps GROUP BY oid ORDER BY depth DESC;
```

### 3.4 Build versus embed

| Build ourselves (realistic) | Embed (when needed) |
|---|---|
| Inventory diff and per-object normalized-DDL diff between two schemas or two databases (reuses §1). A dependency viewer and "what breaks if I drop or alter this". Migrations for a safe subset: add/drop column, index, constraint (online forms); `CREATE OR REPLACE` view or function; drop and recreate dependent views. | A full migration planner: pg-schema-diff (MIT, best online-DDL discipline, narrower types) or pgschema (Apache-2.0, widest coverage). Both are Go **binaries** vendored per release. The estate has no Go toolchain, but a static binary has no AVX dependency (GOAMD64=v1 by default). |

A general, safe migration generator is a multi-year project, as migra's deprecation and Supabase's three diff engines in five
years show. Do not build one.

---

## 4. Running arbitrary SQL safely from a web request

### 4.1 Constraints on this server

| Fact | Value | Source |
|---|---|---|
| Apache MPM, workers | prefork, `MaxRequestWorkers 150` | `/etc/apache2/mods-enabled/mpm_prefork.conf:11` |
| PostgreSQL connection cap | `max_connections = 100`; `superuser_reserved_connections = 3`; `reserved_connections = 0` | `/etc/postgresql/17/main/postgresql.conf:65`; `pg_settings` |
| PHP per-request limits | `memory_limit = 128M`, `max_execution_time = 30` | `/etc/php/8.3/apache2/php.ini:445`, `:419` |
| Persistent pgsql connections | allowed (`pgsql.allow_persistent = On`) | `php.ini:1318` |
| A fresh TLS + SCRAM connection | 31 / 50 / 59 ms (min / median / max of 10, measured). The Boards spike found 35–48 ms. | measured; `/var/www/CLAUDE.md:39` |
| Server-side timeouts | `lock_timeout`, `idle_in_transaction_session_timeout` and `idle_session_timeout` are all 0 (off) | `pg_settings` |

### 4.2 Options for the request model

| Option | How it works | For | Against |
|---|---|---|---|
| **A. Stateless run.** One PHP request = one connection = one run. | The script is split. Each statement autocommits, or the whole run is one explicit transaction committed or rolled back before the response. | Fits PHP. Nothing to leak. Simple. | No transaction across clicks ("UPDATE, look, then COMMIT"). No "load more" over a cursor. A long statement pins an Apache worker. Cancel needs a second request and `pg_cancel_backend(pid)`. |
| **B. Python session service** (Data Lake's pattern) | A long-running service owns one libpq connection per editor tab. PHP talks to it over a Unix socket in JSON lines (Data Lake: `services/query/server.py:6, :62` `SO_PEERCRED`; `:111` a Unix stream server; `:96–97` busy refusal; `:309` cancel beside the running request; `deploy/datalake-query@.service:32–48` the systemd sandbox). | Real transactions, server-side cursors, cancel, notices. Connections are amortized across requests. The Apache worker is freed while a statement runs (PHP can poll). | A new service: idle reaping, a connection budget, and a restart loses sessions (each is an implicit rollback, which is safe). Data Lake's service is stateless (one request per connection, "one request at a time per instance"), so the session table is new code. |
| C. PHP persistent connections | `pg_pconnect` | — | **Reject.** A prefork child keeps the backend. The next request on that child, possibly another person's, inherits its session state or open transaction. 150 children × databases × roles exceeds 100 connections. |
| D. PgBouncer | — | — | Session mode does not give a person affinity to "their" backend across PHP requests. Transaction mode forbids holding one. It does not solve the problem. |

**Recommendation.** Use **B for the SQL editor and data grid**: explicit transactions, cursors, cancel. Use **PHP direct
(short, per request) for catalog browsing and DDL forms**. A is a defensible v1 if the owner wants fewer moving parts, but it
removes features every DBA tool has. The session service needs these rules:
- one connection per tab;
- a global cap (T28);
- per-connection `idle_in_transaction_session_timeout` and `transaction_timeout` as server-side backstops;
- an idle reaper;
- every session bound to the PHP session id and the member;
- a fresh connection per (role, database).

### 4.3 PHP drivers, measured (PHP 8.3.6, libpq 18.6, server 17.11)

```
PDO query("select 1; select 2") with prepares   → 42601 cannot insert multiple commands into a prepared statement
PDO query(…) with ATTR_EMULATE_PREPARES         → returns only [{"b":2}]; nextRowset() → IM001 driver does not support multiple rowsets
PDO exec("select 1; select 2")                  → ok, returns 0 (no rows, no per-statement status)
pgsql pg_send_query("select 1; do $$…raise notice…$$; select 2,3; select nosuchcol from pg_class") + pg_get_result loop
   → result 1 TUPLES_OK 1 row | result 2 COMMAND_OK | result 3 TUPLES_OK 1 row×2 cols | result 4 FATAL_ERROR sqlstate=42703 pos=100
   → pg_last_notice($c, PGSQL_NOTICE_ALL) = ["NOTICE:  hello from notice"]
```

- **pgsql extension.** `pg_send_query` / `pg_get_result` give per-statement results. `pg_result_error_field()` gives
  `PGSQL_DIAG_SQLSTATE`, `…_STATEMENT_POSITION` (for the editor's error marker), `…_MESSAGE_DETAIL`, `…_MESSAGE_HINT` and
  `…_CONTEXT`. `pg_last_notice(…, PGSQL_NOTICE_ALL)` returns the notices. `pg_get_pid()` gives the backend pid to cancel.
  `pg_copy_from` / `pg_copy_to` handle COPY with whole arrays in memory. PHP 8.3 added `pg_set_error_context_visibility()`.
- **PHP 8.4 would add** `pg_set_chunked_rows_size()` (libpq 17 chunked rows), `pg_put_copy_data()` / `pg_put_copy_end()`
  (streaming COPY), `pg_socket_poll()` and `Pdo\Pgsql::setNoticeCallback()`
  (https://www.php.net/manual/en/migration84.new-functions.php). This server runs 8.3, so plan without them.
- **libpq in PHP is 18.6 while the server is 17.11.** That is fine: libpq is backward compatible. Note that
  `pg_version()['client']` reports 18.6.

### 4.4 Statement splitting and the implicit transaction

The PostgreSQL protocol docs say: "When a simple Query message contains more than one SQL statement … those statements are
executed as a single transaction … execution of the Query message stops at the first error". Savepoints are not allowed in
that implicit block (https://www.postgresql.org/docs/17/protocol-flow.html). So:

- **Split the script and send one statement per Query.** Only then are a per-statement status and rows-affected possible,
  partial success is explicit, and `CREATE INDEX CONCURRENTLY`, `VACUUM`, `CREATE DATABASE` and `REINDEX CONCURRENTLY` work.
- **Use a real lexer, not `explode(';')`.** It must handle dollar quotes with tags, `E''` strings, standard strings with
  doubled quotes, quoted identifiers, `--` and nested `/* */` comments, and `BEGIN ATOMIC … END` SQL-standard function
  bodies. psql meta-commands (`\copy`, `\gset`, …) are refused, not interpreted.
  - libpg_query provides `pg_query_split_with_scanner` and `…_with_parser`, and pglast has `split()`.
  - A PHP lexer for splitting only is about 150 lines and testable.
- **Track the transaction state per session** and show it ("in transaction", "transaction aborted, ROLLBACK needed").
  psycopg exposes it as `conn.info.transaction_status`. libpq has `PQtransactionStatus`; in PHP, `pg_transaction_status()`.

### 4.5 Timeouts

| Setting | Use | Note |
|---|---|---|
| `statement_timeout` | Every statement. Default for the editor about 60 s; long-job classes go to the worker. | `SET` per session or `SET LOCAL` per transaction. |
| `lock_timeout` | Every DDL statement (3–10 s) and the editor default | Server default is 0 (off). |
| `idle_in_transaction_session_timeout` | Session service connections (e.g. 5–15 min) | Server default is 0 (off). Kills the session, rolling back. |
| `transaction_timeout` (new in 17) | A hard cap on a held transaction | Confirmed in the 17.0 release notes. |
| PHP `max_execution_time` / `set_time_limit` | Direct PHP runs | 30 s here. A query blocked in libpq is not interrupted by PHP's timer, so `statement_timeout` is the real guard. |

### 4.6 Cancellation

- **`pg_cancel_backend(pid)` from another connection.** Allowed when the caller has "exactly the same role" as the target
  backend, or has privileges of that role, or holds `pg_signal_backend`. That role can never signal a superuser's backend
  (https://www.postgresql.org/docs/17/functions-admin.html, https://www.postgresql.org/docs/17/predefined-roles.html). If the
  tool connects as the person's role, a second request can cancel that person's statement with no extra grant.
- **libpq cancel request.** It uses the backend's cancel key, so no privilege is needed. In psycopg 3, `cancel_safe()` (3.2+)
  uses libpq 17's new non-blocking and encrypted cancel API, and `cancel()` uses the deprecated `PQcancel`
  (https://www.psycopg.org/psycopg3/docs/api/connections.html). Data Lake's equivalent is `service.Control.cancel()`
  (`services/query/service.py:80–100`).
- **PHP's `pg_cancel_query()`** works only inside the request that started the query, so it is useless for a "Stop" button
  under option A. Use `pg_cancel_backend` on the recorded pid.

### 4.7 Row limits and large results

- **libpq buffers the whole result by default**, in both PHP's `pg_query` and psycopg's default cursor. `SELECT * FROM
  big_table` will exhaust PHP's 128 MB.
- **Option A (per request):** `BEGIN READ ONLY; DECLARE c NO SCROLL CURSOR FOR <query>; FETCH FORWARD 501 FROM c; COMMIT;`.
  `DECLARE` accepts only `SELECT` or `VALUES`, so classify first. Then show 500 rows plus "truncated". This mirrors Data
  Lake's `fetchmany(row_limit + 1)` (`service.py:180`) and its byte cap.
- **Option B:** a psycopg named (server-side) cursor in the open transaction, `fetchmany(n)` per "load more", with a byte cap
  per page.
- Cap cell size in the query itself for previews: `left(col::text, 2000)` and `octet_length(col)` (§5).

### 4.8 EXPLAIN and its rendering

- **PG 17 options:** `EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, SERIALIZE, MEMORY, FORMAT JSON)`. `SERIALIZE` and
  `MEMORY` are new in 17. PG 16 added `GENERIC_PLAN`, which explains a `$1`-parameterized statement, such as a normalized
  `pg_stat_statements` query, without values.
- **`EXPLAIN ANALYZE` executes the statement.** For anything that writes, wrap it in `BEGIN; EXPLAIN ANALYZE …; ROLLBACK;` and
  label the run as executing. Even then, sequences advance and side-effecting functions run.
- **`track_io_timing` is off here,** so `BUFFERS` shows counts but no I/O times. Changing it needs a superuser, or
  `GRANT SET ON PARAMETER track_io_timing TO …` (PG 15+), or `ALTER SYSTEM`.
- **PEV2** (https://github.com/dalibo/pev2):
  - PostgreSQL licence; 1.24.0, 2026-09-10.
  - It needs Vue 3, and "PEV2 requires Bootstrap (CSS) to work". The nxl theme is Bootstrap 5.3, so the CSS is already
    there.
  - npm ships `dist/pev2.umd.js` (598 kB) and `pev2.css` (17 kB). Dependencies: Vue, d3, lodash, highlight.js, FontAwesome,
    splitpanes.
  - A standalone `pev2.html` exists, "no installation and no network".
  - **It can ship as a committed island bundle** (an esbuild entry that mounts `<pev2 :plan-source :plan-query>` into one
    `<div>`), exactly as Boards commits its Konva bundle. It renders in the browser (the standalone file works with no
    network), so no plan leaves the server unless someone uses the hosted explain.dalibo.com. Never link to that.
- **A server-rendered fallback (MUST)** is a PHP tree from `FORMAT JSON`, in the style of explain.depesz.com: per node the
  type, relation, estimated and actual rows with the misestimate factor, exclusive time, loops and buffers. It is plain HTMX
  and works at 375 px.

### 4.9 SQL parsing for classification

| Option | Licence | Fidelity | Notes |
|---|---|---|---|
| pglast 8.5 (Python) | **GPL-3.0-or-later** | Exact. libpg_query 18.1 (PG 18 grammar) since 8.0, 2026-07-09; 7.x targets PG 17. Wheels: manylinux2014 x86_64 cp312, 2026-10-04. | AST, `split()`, `prettify()`, fingerprint. The 18 grammar accepts a few things 17 rejects; the server is the final judge. |
| libpg_query (C) with our own thin binding (ctypes / cffi) | BSD-3 | Exact (18.1.0, 2026-09-30) | `pg_query_parse` (JSON tree), `pg_query_split_with_parser`, `pg_query_normalize`, `pg_query_fingerprint`. Needs a C build of the library at install, or a vendored `.so`. |
| flow-php/pg-query-ext (PHP extension) | MIT | Exact (libpg_query) | 0.46.0, 2026-10-04, PHP 8.3–8.5. A compiled PHP extension: root installs it, and it is rebuilt per PHP minor. A subtree split of the flow-php monorepo. |
| PHP FFI over libpg_query | BSD-3 | Exact | FFI is loaded, but `ffi.enable` defaults to `preload` (`php.ini:1963` commented), so under mod_php it needs `opcache.preload`, a php.ini change. |
| sqlglot (Python; in Data Lake) | MIT | **Insufficient** (measured below) | |
| sad_spirit/pg_builder (PHP) | BSD-2 | SELECT, INSERT, UPDATE, DELETE, MERGE only | v3.3.1; 3.4.0-beta on 2026-09-29. No DDL. |
| squawk | Apache-2.0 OR MIT | Own parser, lint-oriented | Gives hazards, not a classification API. |

**Measured with sqlglot 30.22.0 (Data Lake's venv), `read="postgres"`:**
- **Parsed only as an opaque `Command`:** `CREATE POLICY`, `ALTER DEFAULT PRIVILEGES`, `DO`, `VACUUM`, `ALTER TABLE …
  ATTACH PARTITION`, `GRANT … ON ALL TABLES IN SCHEMA`, `CREATE EVENT TRIGGER`.
- **Typed correctly:** select, update, alter add column, alter column type, create index concurrently, create function, create
  table partition by, copy.
- **The trap:** `WITH x AS (DELETE FROM t RETURNING *) SELECT count(*) FROM x` came back as **`Select`**. A root-type check
  would call a deleting statement read-only.

**Classification is not safety.** A `SELECT` can call `pg_terminate_backend()`, `nextval()`, `dblink_exec()` or any
`VOLATILE` function that writes. Only a role's privileges, and `READ ONLY` transactions for what those cover, are boundaries.
Classification drives warnings, the rule table and UI labels. The security sibling decides enforcement.

---

## 5. Data editing

- **Row identity.**
  - Edit only through a primary key, or a unique index whose columns are all NOT NULL.
  - The docs: "a row's `ctid` will change if it is updated or moved by `VACUUM FULL`. Therefore `ctid` should not be used as
    a row identifier" (https://www.postgresql.org/docs/17/ddl-system-columns.html).
  - For keyless tables, `ctid + xmin` catches an update. After a `VACUUM FULL` or `CLUSTER`, though, a ctid can point to a
    *different* row inserted by the same bulk transaction (same xmin). So keyless tables should be read-only, or allow an
    opt-in full-row match that must hit exactly one row.
- **Optimistic concurrency with `xmin`:**

  ```sql
  SELECT xmin::text AS _ver, * FROM s.t WHERE id = $1;                    -- load
  UPDATE s.t SET c = $2 WHERE id = $1 AND xmin = $3::xid RETURNING xmin::text AS _ver, *;   -- save
  -- 0 rows ⇒ changed or deleted since it was loaded: reload and show both versions
  ```

  A BEFORE trigger, or an UPDATE by anyone, changes xmin, which is the intent. xids wrap, but the compared window is
  minutes, far inside the billion-transaction horizon the docs warn about.
- **Values.**
  - Preview large values server-side (`left(c::text, 2000)`, `octet_length(c)`) and fetch the whole value on demand.
  - jsonb: edit as text, validate client-side, cast server-side (`$1::jsonb`) so the server's error is authoritative.
  - Arrays: PostgreSQL literal text (`'{a,b}'`), or `ARRAY[...]` built from parameters.
  - bytea: show hex and size, with download and upload.
  - Large objects (`pg_largeobject_metadata`): `lo_*` via the session service.
  - Generated columns are read-only. Identity `ALWAYS` needs `OVERRIDING SYSTEM VALUE`, which is explicit and logged.
  - Domains and enums: a picker from `pg_enum`, and domain checks reported by the server.
- **Views.** Editable when auto-updatable: `pg_relation_is_updatable(oid, true)` and `pg_column_is_updatable()`. RLS
  silently filters, so an UPDATE that touches 0 rows under RLS must say so ("0 rows: not found, changed, or hidden by a row
  policy").
- **FK lookups.** Use the builder plugin's record picker: a searchable, paged modal over the referenced table
  (`~/htmx-php-builder` 0.8.0, `design-system/references/record-picker.md`), never a `<select>` of every row. The FK comes
  from `pg_constraint` (`confrelid`, `confkey`). The label column is a guess (first text column, or a configured label).
- **Bulk import.**
  - Use `COPY … FROM STDIN (FORMAT csv, HEADER)` inside one transaction, with preview and column mapping first.
  - In PHP 8.3: `pg_copy_from()` takes an array (memory-bound), or `PDO::pgsqlCopyFromFile()` streams a local file. Under
    option B, psycopg's `cursor.copy()` streams in blocks.
  - PG 17 added `COPY … ON_ERROR ignore` and `LOG_VERBOSITY verbose` (17.0 release notes). They skip type-conversion errors
    only; constraint violations still abort.
  - Never `COPY FROM 'server file'`: that needs `pg_read_server_files`.
- **Export.** CSV via `COPY (query) TO STDOUT (FORMAT csv, HEADER)` streamed to a file, then downloaded. JSON via
  `json_agg` / `row_to_json` per batch. SQL INSERTs via our own formatter or `pg_dump --data-only --inserts -t`.
- **pg_dump / pg_restore from a web tool.**
  - The binaries are 17.11, matching the server. pg_dump must be at least the server's major version.
  - Run them as a background job, never in an Apache request. Use a 0600 passfile (`PGPASSFILE`), not an environment
    password. Write into the application's storage and serve the download. Show progress from file size.
  - **pg_dump takes ACCESS SHARE on every table it dumps for the whole run.** Any ACCESS EXCLUSIVE DDL then queues behind
    it, and every later reader queues behind that DDL. Pass `--lock-wait-timeout`.
  - It needs SELECT on every table (measured: denied on `hr_dev` as the kernel's role). `pg_read_all_data` provides that, but
    it does not bypass RLS. RLS-protected tables dump with `--enable-row-security` or need BYPASSRLS.
  - **Restore** (`pg_restore --list` / `--use-list`, `--no-owner`, `--single-transaction`) is destructive. Whether the tool
    offers it at all is an owner decision (Q9).

---

## 6. DBA monitoring

### 6.1 The views (PG 17)

| Need | View / function | Since | Non-superuser without `pg_read_all_stats` |
|---|---|---|---|
| Sessions | `pg_stat_activity`, `pg_wait_events` (17) | — / 17 | **Measured: 23 of 25 rows had NULL `backend_type`, `state` and `query`.** Only the caller's own sessions are visible. |
| Blocking | `pg_locks` + `pg_blocking_pids(pid)` | 9.6 | `pg_locks` is readable by everyone. The docs warn that frequent `pg_blocking_pids` calls need short exclusive access to the lock manager. |
| Statements | `pg_stat_statements` (1.11 here) | ext | Query text and queryid of other users are hidden. **Preloaded** (`postgresql.conf:773`) but not created in the databases checked. `CREATE EXTENSION` needs a superuser (untrusted; `pg_available_extension_versions`). 17 added `stats_since` and `minmax_stats_since` and renamed `blk_read_time` → `shared_blk_read_time`. `compute_query_id = auto`. |
| I/O | `pg_stat_io` | 16 | Readable (35 rows here). |
| Checkpoints | `pg_stat_checkpointer` | 17 (columns moved from `pg_stat_bgwriter`) | Readable. |
| WAL | `pg_stat_wal` | 14 | Readable. |
| Progress | `pg_stat_progress_vacuum` (17 adds `indexes_total` / `indexes_processed`), `_analyze`, `_create_index`, `_cluster`, `_copy`, `_basebackup` | 9.6–14 | Others' rows are partly hidden. |
| Tables and indexes | `pg_stat_user_tables` (`n_dead_tup`, `last_autovacuum`, …), `pg_stat_user_indexes` (`idx_scan`, `last_idx_scan` since 16), `pg_statio_*` | — | Readable. |
| Replication | `pg_stat_replication`, `pg_replication_slots` (`wal_status`, `safe_wal_size`), `pg_stat_subscription`, `pg_stat_subscription_stats` (15), `pg_stat_wal_receiver` | — | Some columns hidden. None configured here (0 slots, 0 publications, 0 subscriptions; `wal_level = replica`). |
| Bloat | Estimates from `pg_stats` (ioguix, BSD-2; pgexperts `pgx_scripts/bloat/*.sql`) or exact `pgstattuple` / `pgstattuple_approx` | ext | pgstattuple needs a superuser to install, and its scan locks (`pg_stat_scan_tables`). |
| Wraparound | `age(datfrozenxid)`, `age(relfrozenxid)`, `mxid_age()` | — | Readable. |
| Settings | `pg_settings` | — | Some hidden: `shared_preload_libraries` gave "permission denied … Only roles with privileges of the "pg_read_all_settings" role". |
| Config files and logs | `pg_hba_file_rules`, `pg_ls_logdir()`, `pg_read_file()` | — | Denied (measured). |

### 6.2 Predefined roles: what a non-superuser can be given

Source: https://www.postgresql.org/docs/17/predefined-roles.html.

| Role | Gives | Fit for the tool |
|---|---|---|
| `pg_monitor` | `pg_read_all_settings` + `pg_read_all_stats` + `pg_stat_scan_tables` | The monitoring role (SHOULD) |
| `pg_signal_backend` | Cancel or terminate non-superuser backends | Activity screen actions |
| `pg_read_all_data` / `pg_write_all_data` | SELECT / DML everywhere, **not** BYPASSRLS | Read-everything for exports. Powerful. |
| `pg_maintain` (17) | `VACUUM`, `ANALYZE`, `CLUSTER`, `REFRESH MATERIALIZED VIEW`, `REINDEX`, `LOCK TABLE` on all relations | Maintenance screens without ownership |
| `pg_checkpoint` (15) | `CHECKPOINT` | Rare |
| `pg_create_subscription` (16) | `CREATE SUBSCRIPTION` with CREATE on the database | Replication screens (LATER) |
| `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program` | File and program access ("could be used to gain superuser-level access") | **Never** |

Still superuser-only:
- `CREATE EXTENSION` for untrusted extensions (pg_stat_statements, pgstattuple, pg_buffercache, amcheck, postgres_fdw,
  maludb_core, vector, …). The trusted ones here are btree_gist, citext, hstore, ltree, pg_trgm, pgcrypto and uuid-ossp.
- Event triggers.
- `ALTER SYSTEM`.
- Most of `pg_authid`.
- Seeing `subconninfo` and user-mapping options.

### 6.3 Snippets

```sql
-- Who blocks whom
SELECT a.pid, pg_blocking_pids(a.pid) AS blocked_by, a.usename, a.datname, a.wait_event_type, a.wait_event,
       now() - a.xact_start AS in_xact_for, left(a.query, 300) AS query
FROM pg_stat_activity a WHERE cardinality(pg_blocking_pids(a.pid)) > 0;

-- Sessions holding back vacuum (old snapshots / idle in transaction)
SELECT pid, usename, datname, state, now() - xact_start AS xact_age, backend_xmin
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL ORDER BY age(backend_xmin) DESC LIMIT 20;

-- Top statements (needs the extension created once)
SELECT queryid, calls, round(total_exec_time) AS total_ms, round(mean_exec_time, 2) AS mean_ms, rows,
       shared_blks_hit, shared_blks_read, stats_since, left(query, 200) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 50;

-- Unused, non-constraint indexes, largest first
SELECT s.relid::regclass AS tbl, s.indexrelid::regclass AS idx, s.idx_scan, s.last_idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
FROM pg_stat_user_indexes s JOIN pg_index i USING (indexrelid)
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- Invalid indexes left by a failed CONCURRENTLY
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;

-- Wraparound headroom per database
SELECT datname, age(datfrozenxid) AS xid_age, mxid_age(datminmxid) AS mxid_age FROM pg_database ORDER BY 2 DESC;
```

---

## 7. A browser SQL editor and ER diagrams under the guidelines

### 7.1 The island precedent

The guidelines keep every screen HTMX and allow a JavaScript island only when "a concrete requirement demands it"
(`~/htmx-php-builder/skills/memory-first-planning/build/tech-stack.md:77–84`; `skills/chat-actions/SKILL.md:114`: "that screen
may take a JS island … the application shell never becomes an SPA"). Boards set the estate's precedent:
- TypeScript bundled by esbuild into `html/assets/boards/boards.<hash>.js`;
- **the built bundle committed**, so "the installer has no npm step, and servers need no Node";
- sources in `client/` with a development-only `package.json`;
- a `bin/check_bundle.php` staleness check;
- no CDNs.

Sources: `/srv/apps/boards/docs/research/tech-stack-decision.md:129–136`; `client/package.json` pins `konva 9.3.22`, `esbuild
0.25.12`, `typescript 5.9.3`; `html/assets/boards/manifest.json` records `source_hash` and `built_at`. A SQL editor and an
EXPLAIN viewer are exactly such islands: one `<div>` each, talking to HTMX panels through DOM events and plain form posts.

### 7.2 Editor: CodeMirror 6 or Monaco

| | CodeMirror 6 | Monaco |
|---|---|---|
| Licence | MIT | MIT |
| Version (2026-10-11) | `@codemirror/view` 6.43.14 (2026-10-07), `@codemirror/lang-sql` 6.10.0, `@codemirror/autocomplete` 6.20.3 | `monaco-editor` 0.57.0 (2026-09-24) |
| Size | Modular. view + state + language + lang-sql unpacked is about 2 MB of sources; a minified basic setup with SQL is a few hundred kB. | 99 MB unpacked, 1,918 files. Needs web workers. |
| Mobile / 375 px | Designed for touch | README: "Is the editor supported in mobile browsers…? **No.**" |
| PostgreSQL | `sql({dialect: PostgreSQL, schema, defaultSchema, upperCaseKeywords})`. `schema` is an `SQLNamespace` tree (schemas → tables → columns, with `Completion` objects) for schema-aware completion. | Generic SQL; PG grammars come from third parties. |
| Maintenance note | Development moved from GitHub (repos archived 2026-04-15) to a self-hosted Forgejo at code.haverbeke.berlin (https://discuss.codemirror.net/t/codemirrors-migration-to-forgejo/9706). npm publishing continues. | Microsoft, GitHub |

**Recommendation: CodeMirror 6.** For autocomplete, serve one JSON schema map per database from PHP (measured 15–30 ms for
every column of a database). Fetch it lazily per database and pass it as `schema`. Function names come from `pg_proc`, and
keywords from `pg_get_keywords()`. Run, explain and cancel are plain form posts or `fetch` calls from the island to PHP
handlers; results render as HTMX partials beside the editor.

### 7.3 ER diagrams

FKs come from `pg_constraint` (`contype = 'f'`, `conrelid`/`conkey` → `confrelid`/`confkey`). Scale: up to 161 tables per
schema here. The diagram therefore needs "selected tables plus k hops" and per-schema views, not the whole database at once.

| Route | Licence, status | For | Against |
|---|---|---|---|
| **Graphviz `dot -Tsvg` server-side** | Graphviz EPL. **Not installed**; apt candidate 2.42.2-9ubuntu0.1. | Pure HTMX: the server returns an inline SVG partial. HTML-like labels draw table boxes. Deterministic. | An apt install (root). Large graphs are slow to lay out. Interaction such as drag needs extra work. |
| **ELK.js in an island** | `EPL-2.0 OR GPL-3.0-or-later` (npm), 0.12.0, 2026-07-17 | The best layered layout with ports, giving orthogonal edges that suit ER diagrams. Runs in a worker. | About 1.5 MB of JS. EPL weak copyleft (file-level) needs a licence note. |
| **@dagrejs/dagre in an island** | MIT, 3.1.1, 2026-08-08 | Small and simple | Weaker edge routing |
| **@viz-js/viz** (Graphviz in WASM) | MIT wrapper around EPL Graphviz, 3.31.0 | Graphviz quality with no server install | About 1.5 MB of WASM |

**Recommendation.** Use server-side Graphviz SVG if the owner accepts the apt package: it is the most guideline-native
option. Otherwise, a committed island bundle with dagre (MIT), with ELK as the upgrade. Avoid AGPL diagram tools (drawDB,
ChartDB) for licence reasons.

### 7.4 Build tooling on this server

Node v24.21.0 and npm 11.19.0 are installed for development builds, as Boards uses them. Playwright with headless Chromium,
under `/var/www/web/node_modules`, already proves Boards' canvas and can prove the editor island the same way. Production
needs neither.

---

## 8. This server's inventory (read-only, 2026-10-11)

| Item | Value |
|---|---|
| PostgreSQL | **17.11** (Ubuntu 17.11-1.pgdg24.04+2), x86_64. Client tools pg_dump, pg_restore, pg_dumpall and psql are 17.11. |
| `shared_preload_libraries` | `pgaudit,pg_stat_statements` (`/etc/postgresql/17/main/postgresql.conf:773`; not readable by the kernel's role through SQL) |
| pgaudit | Preloaded. The config file says `pgaudit.log = 'ddl, role, function'` (`postgresql.conf:850`), but the **effective value is `none`** (`pg_settings`), turned off 2026-10-10 because of log volume. |
| `max_connections` | 100 (`postgresql.conf:65`); `superuser_reserved_connections` 3 |
| Memory settings | `shared_buffers` 128 MB (`postgresql.conf:129`), `work_mem` 4 MB, `maintenance_work_mem` 64 MB |
| Other settings | `wal_level` replica; `track_io_timing` off; `track_functions` none; `compute_query_id` auto; `jit` on; `data_checksums` off; `ssl` on; `password_encryption` scram-sha-256; `lock_timeout`, `idle_in_transaction_session_timeout` and `idle_session_timeout` all 0 |
| Extensions installed (sampled) | `certstudy_memory` / `maludb`: btree_gist, maludb_core 0.106.0, pg_trgm, pgcrypto, plpgsql, vector (0.8.3–0.8.7 by database). `subello_gl`: btree_gist, citext, pg_trgm, pgcrypto, plpgsql. `postgres`: plpgsql only. |
| Extensions available | 49. Contrib: amcheck, bloom, btree_gin, btree_gist, citext, cube, dblink, file_fdw, hstore, pageinspect, pg_buffercache, pg_freespacemap, pg_prewarm, pg_stat_statements 1.11, pg_surgery, pg_trgm, pg_visibility, pg_walinspect, pgcrypto, pgrowlocks, pgstattuple, postgres_fdw, tablefunc, unaccent, uuid-ossp, xml2, … Packaged: maludb_core 0.106.0, pg_partman 5.5.0, pgaudit 17.1, vector 0.8.7. |
| PG add-ons on apt, not installed | hypopg 1.4.3, pg_repack 1.5.3, pldebugger 1.10, pg_qualstats 2.1.4, pg_stat_kcache 2.3.2, pg_squeeze 1.9.4, pgbadger 13.2 |
| Databases | **About 180, 3.0 GB in total** (179 at the start of this survey, 180 at the end). All allow connections. Installed: `certstudy` 134 MB, `certstudy_memory` 299 MB, `maludb` 36 MB, `subello_cidery` 32 MB, `subello_consultant_tracking` 24 MB, `subello_doccloud` 16 MB, `subello_doccloud_memory` 26 MB, `subello_gl` 27 MB, `subello_helpdesk` 23 MB, `subello_hr` 10 MB, `subello_inventory` 14 MB, `subello_knowledge` 12 MB, `subello_knowledge_memory` 25 MB, `subello_pro_appointments` 12 MB, `subello_processcore` 31 MB, `subello_projects` 12 MB, `subello_reservations` 12 MB, `subello_spaces` 33 MB, `subello_txtschedules` 12 MB, `postgres` 7.5 MB, templates. The other ~155 are development and proof scratch databases (`gl_dev*`, `helpdesk_dev*`, `dc_dev*`, `sp_dev*`, `inv_dev*`, `ct_*`, `kn_*`, `si_*`, `dl_*`, `bd_*`, `crm_dev*`, `txtschedules_dev*`, …), 8–30 MB each. |
| Roles | 107: 15 predefined (`pg_checkpoint`, `pg_create_subscription`, `pg_database_owner`, `pg_execute_server_program`, `pg_maintain`, `pg_monitor`, `pg_read_all_data`, `pg_read_all_settings`, `pg_read_all_stats`, `pg_read_server_files`, `pg_signal_backend`, `pg_stat_scan_tables`, `pg_use_reserved_connections`, `pg_write_all_data`, `pg_write_server_files`); 74 can log in; 2 superusers. Families: the kernel's (`app`, `app_rw`, `app_runner`, `app_records_ro`, `app_activity_ro`, `certstudy_mem`); per application `<key>_rw` (or `<key>_app`), `<key>_records_ro`, `<key>_activity_ro`, and `<key>_mem` for memory databases; MaluDB's (`maludb`, `maludb_admin`, `maludb_memory_{admin,auditor,executor,reader}`, `maludb_llm_*`, `maludb_queue_worker`, …); Data Lake's `datalake_lake`, `datalake_query`; scratch (`bd_spike`, `ma_scratch`, `zozocal_adopt`, `pro_appointments_dev`); `postgres`. |
| Kernel role's predefined memberships | none of `pg_read_all_settings`, `pg_monitor` or `pg_read_all_stats` |
| PHP | 8.3.6 (NTS) with `pgsql` and `pdo_pgsql` (libpq **18.6**), FFI (`ffi.enable` default `preload`), OPcache, sockets, pcntl, sodium, zip, mbstring, … |
| Apache | prefork, `MaxRequestWorkers 150`; mod_php 8.3; proxy and proxy_http enabled |
| Python | 3.12.3. Venvs: the kernel's `/var/www/mcp/venv` (asyncpg 0.31.0, mcp 1.30.0); each application's `mcp/venv`; `services/.venv` in cidery, datalake (duckdb 1.5.6, psycopg 3.3.6 + binary, sqlglot 30.22.0) and processcore; the MaluDB API's `.venv` |
| Graphviz | **not installed** (`dot` absent; apt 2.42.2) |
| Node | v24.21.0, npm 11.19.0 (development builds only) |
| CPU | 12 vCPU "QEMU Virtual CPU version 2.5+". Flags include sse4_2 and popcnt but **no avx, avx2, fma or avx512** (`/proc/cpuinfo`). Fine for Go/Rust baseline binaries, manylinux wheels, Graphviz and DuckDB. Default Polars builds crash here (Data Lake finding). |
| Memory | 15 GiB (about 10 GiB available); swap 3.1 GiB (1.0 GiB used) |
| Disk | `/` one LVM volume of 522 GB, 66 GB used, 435 GB free |
| Connection cost | fresh TLS + SCRAM connect plus `select 1`: 31 / 50 / 59 ms |

---

## 9. Build-versus-embed table

| Component | Language | Licence | Maintenance (2026-10-11) | Fit / decision |
|---|---|---|---|---|
| `pg_get_*def`, `format_type`, `aclexplode`, `pg_identify_object_as_address`, … | server | PostgreSQL | core | **Use** for everything they cover |
| Own DDL generators (tables, sequences, types, roles, policies, grants, default privileges, publications, FDW, …) | PHP | ours | — | **Build**. Port queries from postgres-meta and pgAdmin; golden-test against pg_dump. |
| pg_dump / pg_restore 17.11 | C binary | PostgreSQL | core | **Embed as a subprocess** in a worker: exports, golden tests, scratch clones |
| pgAdmin 4 SQL templates | Python / Jinja | PostgreSQL | REL-9_18 (2026-09-15), pushed 2026-10-10 | **Reference / port** |
| postgres-meta | TypeScript | Apache-2.0 | v0.100.0 (2026-10-06) | **Study the queries**; do not run |
| ddlx (pgddl) | SQL | PostgreSQL-style | 0.31, pushed 2026-09-25 | Reference, or load into scratch clones only |
| pg_get_tabledef | PL/pgSQL | MIT | pushed 2026-07-28 | Reference |
| migra | Python | Unlicense | deprecated; last release 2022-09-18 | No |
| results | Python | BSD-3 | alpha | No |
| pg-schema-diff | Go | MIT | v1.0.9 (2026-08-06); PG 14–17 | **Embed candidate** (LATER) for migration plans |
| pgschema | Go | Apache-2.0 | v1.13.1 (2026-09-20); PG 14–18 | **Embed candidate** (LATER); verify its embedded-postgres downloads |
| Atlas | Go | Apache-2.0 core / EULA binary | v1.3.0 (2026-08-02) | No (Community lacks views, functions, triggers, RLS) |
| sqldef (psqldef) | Go | MIT (+ Apache-2.0 parser) | v3.11.26 (2026-10-01) | No (partial PG) |
| pg-delta | TypeScript | MIT | 1.0.0-alpha.58 | Watch |
| pgquarrel / apgdiff | C / Java | BSD-3 / MIT | stale (2023 / 2024) | No |
| squawk | Rust binary | Apache-2.0 OR MIT | 2.68.0 (2026-10-08) | **Embed** (subprocess, pip wheel) to lint typed SQL |
| strong_migrations | Ruby | MIT | active | Rule reference only |
| eugene | Rust | MIT | 0.8.3 (2026-03-11) | Method reference (dry-run lock tracing) |
| postgres-language-server | Rust | MIT | 0.28.1 (2026-10-10) | LATER |
| libpg_query | C | BSD-3 | 18.1.0 (2026-09-30) | The parser underneath |
| pglast | Python (C ext) | **GPL-3.0-or-later** | 8.5 (2026-10-04); PG 18 grammar | Best binding; **licence decision** |
| flow-php/pg-query-ext | PHP C ext | MIT | 0.46.0 (2026-10-04) | Alternative; needs a compiled extension (root) |
| sqlglot | Python | MIT | 30.22.0 | **Not adequate** for PG DDL classification (measured) |
| sad_spirit/pg_builder | PHP | BSD-2 | v3.3.1; 3.4.0-beta (2026-09-29) | DML only; not needed |
| psycopg 3 | Python | LGPL-3.0 | 3.3.6 (in the estate) | **Use** in the session service |
| asyncpg | Python | Apache-2.0 | 0.32.0 | Less suitable (no multi-result scripts) |
| PHP pgsql extension | C (PHP) | PHP | core 8.3.6 | **Use** for every direct PHP query; not PDO for user SQL |
| CodeMirror 6 | TypeScript | MIT | @codemirror/view 6.43.14 (2026-10-07); dev on Forgejo | **Use** (committed island) |
| Monaco | TypeScript | MIT | 0.57.0 | No (no mobile support) |
| PEV2 | Vue 3 | PostgreSQL | 1.24.0 (2026-09-10) | **Use** (island, SHOULD) + PHP tree fallback (MUST) |
| Graphviz | C (apt) | EPL | Ubuntu 2.42.2 | Option A for ER (owner's apt) |
| ELK.js / @dagrejs/dagre / @viz-js/viz | JS | EPL-2.0 OR GPL-3 / MIT / MIT + EPL | 0.12.0 / 3.1.1 / 3.31.0 | Option B for ER (island) |
| Bloat queries (ioguix, pgexperts) | SQL | BSD-2 / (pgexperts unspecified) | stable | **Port** (ioguix) |
| pgstattuple, pg_buffercache, pg_visibility, amcheck | contrib | PostgreSQL | 17 | Optional (superuser installs) |
| hypopg, pg_repack, pldebugger | C ext (apt) | PostgreSQL-style / BSD | apt candidates | LATER |
| Whole tools: pgweb, Adminer, phpPgAdmin | Go / PHP / PHP | MIT / Apache-2.0 or GPL-2.0 / GPL-2.0 | v0.17.0 (2025-11-22) / v6.1.2 (2026-10-10) / last push 2024-07-30 | Not embeddable under the guidelines (own UI, own auth); see the product survey |

---

## 10. Risks

1. **Lock-queue outages.** One ACCESS EXCLUSIVE waiting behind a long transaction stalls every reader. Mitigation:
   `lock_timeout` on every DDL, a blockers view, retry.
2. **Unbounded results.** `SELECT *` on a big table exhausts PHP's 128 MB and pins an Apache worker (one of 150).
   Mitigation: cursors with row and byte caps; long work in a worker.
3. **Held transactions.** An idle editor tab "in transaction" holds locks and the xmin horizon (bloat) and burns a
   connection (100 max, shared by the estate's ~16 installed applications and their services). Mitigation: `idle_in_transaction_session_timeout`,
   `transaction_timeout` (17), a session cap, a visible "in transaction" banner.
4. **Classification mistaken for safety.** Data-modifying CTEs and side-effecting functions inside `SELECT`. Only role
   privileges enforce anything (security sibling).
5. **`SET ROLE` is not a sandbox.** If the tool connects as a privileged login and uses `SET ROLE <person>`, a person's
   `RESET ROLE` escapes. Arbitrary SQL must run on a connection *authenticated* as the role it is meant to have. This is
   flagged for the security sibling, but it constrains the session service's design.
6. **DDL generator drift.** Our table generator can miss a feature (a storage option, a column compression, a replica
   identity), so "copy DDL" would be wrong. Mitigation: golden tests against pg_dump on fixtures that exercise each feature.
7. **Editing extension members or other applications' objects.** That breaks MaluDB (`maludb_core` owns every memory table)
   or an application's migrations. Mitigation: extension members read-only; installed applications' databases a policy
   decision (Q2).
8. **EXPLAIN ANALYZE executes the statement,** including writes, sequences and side effects. Mitigation: rollback wrapper,
   label, default to plain EXPLAIN.
9. **pg_dump locks and privileges.** A long dump blocks DDL, and the role needs SELECT everywhere.
10. **Licences.** pglast is GPL-3.0-or-later; ELK is EPL-2.0 or GPL-3; Graphviz is EPL; psycopg is LGPL-3.0, already accepted
    in the estate. The kernel, the builder and the integration plugin are MIT. The application repositories carry no LICENSE
    file today.
11. **Version skew.**
    - The PHP libpq is 18.6. pglast 8 parses PG 18 syntax that 17 rejects (e.g. `NOT NULL … NOT VALID`).
    - The rule tables must be keyed by server major.
    - PG 19 had not reached general availability by 2026-10-11 (beta 4 announced a release candidate for early October),
      and its `pg_get_*_ddl` were reverted.
12. **Supply chain.** CodeMirror moved forges, and npm-published builds are what we pin. A committed bundle with a recorded
    `source_hash` (Boards' manifest) keeps installs reproducible.
13. **Connection cost when browsing many databases.** Each new database costs a TLS + SCRAM connect (31–59 ms measured). The
    session service can pool per (role, database); PHP direct cannot.
14. **The scratch clone for dry runs** needs CREATEDB, installable extensions (maludb_core needs a superuser) and seconds per
    clone. Without it, layer 3 of §2.4 is unavailable, and the rule table (layer 1) must carry the weight.
15. **Monitoring that looks empty.** Without `pg_monitor`, screens silently show only the tool's own sessions. They must say
    what is hidden.

---

## 11. Technical requirements

**MUST**

- **T1** Target PostgreSQL 17 (17.11 here). Introspect `pg_catalog` by OID, address objects across requests by
  `pg_identify_object_as_address`, and key version-dependent queries and rules by `server_version_num`.
- **T2** Every object type in §1.2 except the LATER row (casts, operators, text search) is browsable with its DDL shown. DDL
  comes from `pg_get_*def` where one exists and from our own PHP generators everywhere else.
- **T3** The DDL generators are proven by golden tests that compare them with `pg_dump --schema-only` on fixture databases
  covering partitioning, unlogged, inheritance, identity, generated columns, every constraint type, every index form, RLS,
  grants and default privileges. pg_dump is never used to render a screen.
- **T4** Extension members (`pg_depend.deptype = 'e'`) and system schemas are read-only and show the owning extension.
- **T5** The object tree is lazy: one catalog query per expanded node, never a whole database per page. The design must hold
  about 180 databases, 1,000+ functions and 180 policies in one database.
- **T6** Every DDL form previews its exact SQL before running. The preview shows, per relation, the lock mode, rewrite
  yes/no, scan yes/no, whether a transaction block is allowed, and the relation's size and estimated rows. The person runs
  exactly the previewed text.
- **T7** A static, version-keyed operation-rule table (from the PG 17 docs and `AlterTableGetLockLevel()`) supplies T6's
  annotations. An unknown operation is shown as ACCESS EXCLUSIVE with unknown cost.
- **T8** Generated DDL uses safe patterns by default, with an explicit opt-out:
  - `CREATE`/`DROP INDEX CONCURRENTLY` as its own statement;
  - `NOT VALID` + `VALIDATE`;
  - `SET NOT NULL` through a validated CHECK;
  - PK/UNIQUE through a concurrently built index + `USING INDEX`;
  - add column without a volatile default.
- **T9** Every DDL execution sets `lock_timeout` and `statement_timeout`. A lock timeout (55P03) shows the blockers
  (`pg_blocking_pids`) and offers a retry.
- **T10** Identifiers go through `pg_escape_identifier` / `format('%I')`, type names through `to_regtype` / `to_regtypemod`
  (catching syntax errors), and values through parameters. No SQL is assembled from unchecked input.
- **T11** User-supplied SQL runs through the PHP pgsql extension or the session service, **never PDO**. On this server PDO
  refuses multi-statement strings with prepares, returns only the last result set with emulation, and has no notices.
- **T12** Scripts are split by a real lexer (dollar quotes, `E''`, quoted identifiers, nested comments, `BEGIN ATOMIC`) and
  sent one statement per Query. psql meta-commands are refused. Each statement reports its own status, rows, notices,
  SQLSTATE, detail, hint and error position.
- **T13** Results are capped by rows and bytes through a cursor (`DECLARE … FETCH n+1`) or chunked fetching, and a truncated
  result says so. No unbounded result enters PHP memory.
- **T14** A running statement can be cancelled from the browser, by `pg_cancel_backend` on the recorded pid (same role) or by
  a libpq cancel from the session service. Each cancellation is logged.
- **T15** Every editor connection has `statement_timeout`, `idle_in_transaction_session_timeout` and `transaction_timeout`
  (17). No held transaction outlives its idle limit, and the UI shows the transaction state.
- **T16** EXPLAIN defaults to not executing. `EXPLAIN ANALYZE` of anything that writes is wrapped in `BEGIN … ROLLBACK` and
  labelled as executing. Plans are stored as `FORMAT JSON`, and a server-rendered plan tree works at 375 px.
- **T17** The data grid edits only rows identified by a PK or a NOT NULL unique key, with `xmin` optimistic concurrency.
  0 rows means a conflict screen. Keyless tables are read-only unless an opt-in exactly-one full-row match is used.
- **T18** Large values are previewed truncated server-side and fetched whole on demand. bytea shows as hex and size with
  download. Generated columns are read-only. Identity ALWAYS overrides are explicit and logged.
- **T19** FK values are chosen with the builder's record picker over the referenced table, never a `<select>` of all rows.
- **T20** CSV import uses `COPY FROM STDIN` streamed in one transaction, after a preview and column mapping. Export uses
  `COPY TO STDOUT` streamed to a download. Server-side file paths are never used.
- **T21** Monitoring screens detect the role's predefined-role memberships and state what is hidden instead of rendering
  empty tables.
- **T22** The activity screen covers `pg_stat_activity`, `pg_blocking_pids` and `pg_wait_events`. Cancel and terminate
  actions are gated and logged.
- **T23** Every executed statement (editor, form, data edit, monitor action) is written to the activity log with who, which
  database and role, the statement (or its policy-defined form), duration and outcome, as the guidelines require.
- **T24** Long jobs run in a worker with progress from `pg_stat_progress_*`, never in an Apache request: pg_dump, pg_restore,
  `VACUUM FULL`, `REINDEX`, large `COPY`, `CREATE INDEX CONCURRENTLY` on big tables.
- **T25** No server-file functions and no `COPY` to or from server paths. `pg_*_server_files` and
  `pg_execute_server_program` are never granted to the tool.
- **T26** Browser code ships as committed esbuild bundles with a recorded source hash and a staleness check, as Boards does
  (CodeMirror 6 for the editor). No CDN. No Node on production servers.
- **T27** The editor, grid and plan views are usable at 375 px. This rules out Monaco.
- **T28** The application caps its total PostgreSQL connections (configurable; about 10–15 suggested) because
  `max_connections = 100` is shared by the estate.
- **T29** PHP persistent connections are never used for user sessions, even though `pgsql.allow_persistent = On`.

**SHOULD**

- **T30** A Python session service (psycopg 3, Unix socket, `SO_PEERCRED`, JSON lines, per-tab connections, idle reaper,
  cancel beside the running request) provides explicit transactions across requests, server-side cursors, notices and
  COPY streaming.
- **T31** Typed SQL is classified with libpg_query (pglast or our own binding, per Q4): DDL/DML/read, data-modifying CTEs,
  and the `AlterTableStmt` subtypes mapped to the T7 rule table.
- **T32** Typed scripts are linted with squawk (`--pg-version=17`, JSON reporter) and its findings shown inline.
- **T33** A measured dry run on a schema-only scratch clone checks own-pid `pg_locks` and the `pg_relation_filenode()`
  change (proof of rewrite).
- **T34** Schema compare between two schemas or databases: inventory diff, per-object normalized-DDL diff, and a
  dependency-ordered migration for the safe subset of §3.4.
- **T35** A dependency viewer (`pg_depend`) answers "what breaks if I drop or alter this", and dependent views are dropped
  and recreated in one transaction when needed.
- **T36** ER diagram per schema, or for selected tables plus k hops, with SVG export. Graphviz server-side or a dagre/ELK
  island, per Q7.
- **T37** A PEV2 visual EXPLAIN island (Vue 3 bundled) beside the server-rendered tree.
- **T38** `pg_stat_statements` screens (top by total time, mean time, calls, I/O; `stats_since`) once the extension is
  created. `GENERIC_PLAN` explain from a normalized query.
- **T39** Bloat estimates via the ioguix queries, with exact `pgstattuple` on request when installed. The scan cost is
  warned.
- **T40** Index advice: unused (`idx_scan = 0`, `last_idx_scan`), duplicate and overlapping, and invalid (`indisvalid =
  false`) indexes.
- **T41** Autocomplete from a per-database JSON schema map (schemas → tables → columns, functions, keywords).
- **T42** A vacuum and wraparound panel: `age(datfrozenxid)`, `n_dead_tup`, last (auto)vacuum and analyze, vacuum progress,
  and sessions holding `backend_xmin`.
- **T43** A role and grant matrix (`aclexplode`, `has_*_privilege`, `pg_auth_members` options), a default-privileges
  editor, and an RLS policy editor whose `USING`/`WITH CHECK` expressions are validated by the server.

**LATER**

- **T44** Embed pg-schema-diff or pgschema (a vendored Go binary) for full migration plans with hazards and temp-database
  validation.
- **T45** hypopg what-if indexes in EXPLAIN, pg_repack for online bloat removal, pldebugger for PL/pgSQL debugging (apt and
  superuser installs).
- **T46** In-editor diagnostics from postgres-language-server.
- **T47** Management, not only browsing, of publications, subscriptions, FDWs and user mappings. Casts, operators and text
  search objects.
- **T48** PG 18/19 catalog additions: NOT NULL constraints in `pg_constraint`, virtual generated columns, `NOT VALID` NOT
  NULL, and `pg_get_*_ddl()` should they return.

That is 48 requirements: 29 MUST, 14 SHOULD, 5 LATER.

---

## 12. Open questions for the owner

1. **Which PostgreSQL identity runs a person's SQL?** Per-person login roles (credentials in the tenant secret store) or a
   service role? `SET ROLE` is escapable (§10 risk 5). Decided with the security report.
2. **Scope.** Every database on the cluster (about 180, mostly scratch), or a registered list (installed applications'
   databases, MaluDB memory databases, named development databases)? May the tool *change* an installed application's
   schema, or only generate a migration for that application's repository? (Ties to the estate's "every table is created by
   the application's own migrations".)
3. **The session service in v1** (explicit transactions, cursors, cancel), or stateless runs first (option A) with the service
   later?
4. **Parser licence.** Is GPL-3.0-or-later pglast acceptable as a dependency of a public repository, or take a permissive
   route (our own ctypes binding to BSD libpg_query, the MIT flow-php PHP extension, or squawk-only linting)?
5. **Superuser one-time steps.**
   - Create `pg_stat_statements` (and pgstattuple?) in the tool's own database.
   - Grant `pg_monitor`, `pg_signal_backend` and perhaps `pg_maintain` to the tool's role.
   - `GRANT SET ON PARAMETER track_io_timing`.
6. **pgaudit for the tool only.** `ALTER ROLE <tool role> SET pgaudit.log = 'ddl, role'` restores a server-side DDL trail
   without the volume that turned pgaudit off.
7. **ER layout.** Install Graphviz by apt (server-side SVG, HTMX-native), or a committed dagre/ELK island?
8. **Schema diff depth.** Build the safe subset only, or also vendor a Go planner? If pgschema, does its embedded PostgreSQL
   download binaries?
9. **pg_dump / pg_restore.** Export only, or restore too? Restore is destructive and needs ownership.
10. **Dry-run clones.** Is CREATEDB for the tool's role acceptable, so that measured lock and rewrite checks run on
    schema-only clones? MaluDB memory databases also need a superuser to install `maludb_core` in a clone.
11. **Connection budget.** What share of the 100 connections may the tool hold, and should `max_connections` or a
    `reserved_connections` slice for operators be revisited? Changing them needs a restart.
