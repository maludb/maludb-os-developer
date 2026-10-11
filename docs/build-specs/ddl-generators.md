# Build spec: the DDL generators, the rule table and the forms' SQL (a build spec — slices 2, 4, 5 and 8 build on it)

What exists at the end: **every object family of PostgreSQL 17 reads back as DDL** — from the server's `pg_get_*def` where PostgreSQL has
one, from **our own PHP generators** everywhere else — each with a commented `DROP`; **every form of slice 4 emits its SQL through the same
generators**, in the safe form by default; **one rule table** (`app/developer/rule_table.json`) says, per statement kind and `ALTER TABLE`
subcommand, the lock each relation takes, whether the table is rewritten or scanned, whether the statement may run in a transaction block,
and the safe form, keyed by `server_version_num`; and **the records server's bridge** (`html/internal/ddl.php`) lets the records MCP's
`object_ddl` use the same generators, so there is one implementation, golden-tested once. Design §6.3, §6.5 (forms); research
`docs/research/02-postgres.md` §1–§3.

**The rule this spec exists for (S9, T10):** no SQL is assembled from unchecked input. Identifiers go through one quoting function with the
server's rules; types through `to_regtype()` / `to_regtypemod()` on the target; values are bound parameters or, in DDL where PostgreSQL takes
no parameter (a default expression, a check), **parsed by the door** and refused unless they are exactly one expression of the kind
expected. An identifier is never placed inside a string literal; a relation passed to a function is a `::regclass` of its OID inside the
door's named queries, never a name in a literal (pgAdmin CVE-2026-12044's fix).

## Divergences from the design
1. **The generators render; they never read.** PHP cannot reach a target. The facts a generator needs come from **one door named query,
   `object_ddl`**, which answers the catalog rows of one object (`facts`) and the server's `pg_get_*def` outputs (`defs`) as JSON; PHP
   renders text from them (`dx_ddl_render()`). The worker's snapshots use `object_ddl_batch` (every object of a schema, paged) and the same
   renderer — so a snapshot's sha256 and the object page's DDL are the same text.
2. **The bridge holds no member and reads nothing.** `html/internal/ddl.php` takes the `object_ddl` parts the records server already got
   through the door (which judged the caller) and returns the rendered text. It is a pure function behind an HMAC; it opens no database
   connection, not even the tool's own. That is narrower than Inventory's bridge, which acts as a member.
3. **The rule table is JSON, not PHP**, because three readers need it: PHP (the review page, the forms), the records server (`ddl_cost`) and
   the door (the rehearsal's "rule table" label for a `CONCURRENTLY` statement). `app/developer/rule_table.php` loads and caches it.
4. **A 64-byte name and an invalid-UTF-8 name are refused by the form, not quoted.** The server truncates an identifier to 63 bytes
   (NAMEDATALEN − 1) with only a NOTICE, so such a name would not round-trip; invalid UTF-8 cannot exist in the server's encoding. The
   hostile-name suite proves the refusal (T10, S9).

## The families and where their DDL comes from

| Family (`catalog_index.family`) | Source of the DDL | The generator file | Notes |
|---|---|---|---|
| database | generator (no server function on 17) | `app/developer/ddl/database.php` | `CREATE DATABASE … WITH OWNER … ENCODING … LOCALE_PROVIDER … LOCALE …`; shown, never offered as a form (database statements are refused everywhere — the door's lifecycle makes workbenches) |
| schema | generator | `schema.php` | owner, comment, grants |
| table (ordinary, partitioned, unlogged, typed, inheritance, partition) | generator | `table.php` | columns with types (`format_type`), defaults (`pg_get_expr`), identity, generated, collation, storage, compression, NOT NULL; `PARTITION BY` (`pg_get_partkeydef`), `PARTITION OF … FOR VALUES` (`pg_get_expr(relpartbound)`), `INHERITS`, `OF type`, `USING am`, `WITH (reloptions)`, `TABLESPACE`, `REPLICA IDENTITY`, RLS enable/force; then constraints, indexes, triggers, policies, rules, statistics, comments, grants, owner — **in pg_dump's order** |
| column | part of `table.php` (`dx_ddl_column()`) | — | the column page shows its `ADD COLUMN` and its comment |
| constraint (p, f, u, c, x; a domain's check) | `pg_get_constraintdef(oid, true)` wrapped in `ALTER TABLE ONLY … ADD CONSTRAINT …` | `constraint.php` | `NOT VALID`, `DEFERRABLE`, `NULLS NOT DISTINCT` come in the server's text |
| index (every access method, partial, expression, INCLUDE) | `pg_get_indexdef(oid)` | `index.php` | an index owned by a constraint is shown under the constraint; `indisvalid = false` is said |
| view | `pg_get_viewdef(oid, true)` | `view.php` | `CREATE OR REPLACE VIEW … WITH (check_option, security_barrier, security_invoker) AS …` |
| materialized view | `pg_get_viewdef(oid, true)` | `matview.php` | `WITH [NO] DATA`, its indexes, storage parameters |
| sequence (and identity) | generator | `sequence.php` | `AS type`, increment, min, max, start, cache, cycle, `OWNED BY`; an identity sequence is shown under its column |
| function, procedure | `pg_get_functiondef(oid)` | `routine.php` | |
| aggregate | generator (the server's function refuses aggregates) | `aggregate.php` | from `pg_aggregate`: `SFUNC`, `STYPE`, `FINALFUNC`, `COMBINEFUNC`, `INITCOND`, `MSFUNC`…, `SORTOP`, `PARALLEL` |
| trigger | `pg_get_triggerdef(oid, true)` | `trigger.php` | internal (FK) triggers skipped; `ENABLE REPLICA/ALWAYS` and `DISABLE` from `tgenabled` |
| event trigger | generator | `event_trigger.php` | events include `login` (17) |
| type: enum, composite, domain, range, multirange, base | generator | `type.php` | enum labels in `enumsortorder`; a domain's default, NOT NULL and checks; a range's subtype, opclass, canonical, subdiff; a base type is shown as a comment that names its I/O functions (never offered as a form) |
| extension | generator | `extension.php` | `CREATE EXTENSION … SCHEMA … VERSION …`; members read-only and listed |
| role (cluster-wide) | generator | `role.php` | attributes, memberships with PG 16's `INHERIT`/`SET`/`ADMIN` options, per-database settings; **never a password**; read-only in v1 (DS14) |
| grants (any object) | generator over `aclexplode(coalesce(acl, acldefault(…)))` | `grant.php` | grantee 0 = `PUBLIC`; column grants; `WITH GRANT OPTION` |
| default privileges | generator over `pg_default_acl` | `grant.php` (`dx_ddl_default_privileges()`) | `ALTER DEFAULT PRIVILEGES [FOR ROLE r] [IN SCHEMA s] GRANT …`; read-only in v1 |
| RLS policy | generator over `pg_policy` with `pg_get_expr(polqual)` / `pg_get_expr(polwithcheck)` | `policy.php` | `AS PERMISSIVE/RESTRICTIVE`, `FOR`, `TO`, `USING`, `WITH CHECK` |
| publication | generator | `publication.php` | row filters and column lists (`prqual`, `prattrs`) |
| subscription | generator | `subscription.php` | `CONNECTION` shown as `'…'` — `subconninfo` is never read (privileged, and it holds a password) |
| foreign data wrapper, server, user mapping, foreign table | generator | `foreign.php` | user mapping options never shown (they hold passwords); a foreign table as `table.php` with `SERVER` and `OPTIONS` |
| collation | generator | `collation.php` | provider `c`/`i`/`b` (17's builtin) |
| statistics object | `pg_get_statisticsobjdef(oid)` | `statistics.php` | |
| rule | `pg_get_ruledef(oid, true)` | `rule.php` | a view's `_RETURN` rule skipped |
| comment | generator (`COMMENT ON … IS …`) | part of every file (`dx_ddl_comment()`) | the comment's text is a **bound value rendered as a literal by `dx_ddl_literal()`** — the one place a string literal is written, and it holds the comment, never an identifier |
| tablespace | generator | `tablespace.php` | the location shown as text; never offered as a form |
| cast, operator, opclass/opfamily, text search, conversion | **browse only** (T47 is Extended) | — | the object page shows its catalog row, no DDL tab |

**Extension members** (`pg_depend.deptype = 'e'`) and system schemas show their DDL read-only, with "Member of extension `x`" and no form,
no danger zone (T4).

## Quoting, types and values (`app/developer/ddl/quote.php`)
- `dx_ident(string $name): string` — the server's `quote_ident()` rules: unquoted only when the name is lower-case `[a-z_][a-z0-9_$]*` and
  not a keyword of category `R`, `T` or `C` in `pg_get_keywords()`; else `"` + name with every `"` doubled + `"`. The keyword list is the
  data file `app/developer/ddl/keywords.php`, written by `bin/dx_keywords.php` from the server's `pg_get_keywords()` (491 keywords, 78
  reserved, measured); the golden suite fails when the file and the server disagree.
- `dx_qualified(?string $schema, string $name): string` — `schema.name`, each part through `dx_ident()`.
- `dx_name_ok(string $name): ?string` — the refusal sentence or null: empty; a NUL; not valid UTF-8; over **63 bytes**; starting with
  `pg_` for a schema (reserved by the server). Every form field that names an object calls it first.
- `dx_ddl_literal(string $text): string` — `E'…'` with `\` and `'` escaped, used **only** for a comment's text and an enum label; a
  generator that wants any other literal is a defect the hostile-name suite catches.
- **Types**: a form's type field is resolved by the door's named query `type_resolve` on the target — `SELECT format_type(to_regtype($1),
  to_regtypemod($1))` inside a sub-transaction that turns a syntax error into "not a type" (to_regtype raises on `int; drop table x`,
  measured) — and the generator writes the **server's** spelling, never the person's.
- **Expressions** (a default, a check, a generated column, an index expression or predicate, a policy's `USING`/`WITH CHECK`, a view's
  query, a function's body): sent to the door's `classify` wrapped in a fixed carrier statement (`SELECT (<expr>)` for an expression,
  `CREATE VIEW x AS <query>` for a view, the whole `CREATE FUNCTION` for a routine); the door answers exactly one statement of the carrier's
  node kind with the functions it calls screened, or the form is refused with the door's sentence. The generator then writes the
  expression's text as the person wrote it.

## The generator's interface (`app/developer/ddl/render.php`)
- `dx_ddl_render(array $parts): array{ddl: string, drop: string, source: 'pg_get_def'|'generator'|'mixed', version: string}` — `$parts` is
  the door's `object_ddl` answer (`{family, address, facts, defs, server_version_num}`); `drop` is the commented drop
  (`-- DROP TABLE public.invoices;`, with `-- … CASCADE` and the count of dependants when `impact` found any); `version` is the generator
  set's version string (`ddl-gen/1`) kept beside a snapshot's sha256 so a generator change is not read as drift.
- `dx_ddl_normalise(string $ddl): string` — what the golden suite and the snapshots hash: comments and `SET` lines dropped, whitespace
  collapsed, grants sorted by grantee then privilege, default storage options omitted, `OWNER TO` kept on its own line.
- **The forms' builders** (slice 4) live beside the readers, one per family: `dx_ddl_build_create(string $family, array $fields, bool $safe):
  list<string>`, `dx_ddl_build_alter(string $family, array $facts, array $fields, bool $safe): list<string>`, `dx_ddl_build_drop(string
  $family, array $facts, bool $cascade): list<string>`, `dx_ddl_build_truncate(array $facts, bool $restartIdentity, bool $cascade): list<string>`.
  Each returns **one statement per element** and never a script; each element is later parsed by the door, which refuses anything that is
  not exactly the statement kind it was told to expect on the object it was told (design §6.1, "What PHP still does itself").

## The safe forms (T8, R15) — what the builders emit by default
The person may tick **Use the plain form** (`safe=no`); the review then says what the plain form costs (the rule table's row for it).

| Asked for | Emitted by default (each line one statement, in order) |
|---|---|
| a new index on a table that holds rows (`reltuples > 0` or unknown) | `CREATE INDEX CONCURRENTLY …` — alone, outside any transaction block |
| drop an index | `DROP INDEX CONCURRENTLY …` |
| a check constraint | `ALTER TABLE … ADD CONSTRAINT c CHECK (…) NOT VALID` → `ALTER TABLE … VALIDATE CONSTRAINT c` |
| a foreign key | `… ADD CONSTRAINT f FOREIGN KEY (…) REFERENCES … NOT VALID` → `VALIDATE CONSTRAINT f` |
| `SET NOT NULL` | `ADD CONSTRAINT <t>_<c>_nn CHECK (c IS NOT NULL) NOT VALID` → `VALIDATE CONSTRAINT` → `ALTER COLUMN c SET NOT NULL` → `DROP CONSTRAINT <t>_<c>_nn` |
| a primary key or unique constraint | `CREATE UNIQUE INDEX CONCURRENTLY <name>_idx ON … (cols)` → `ALTER TABLE … ADD CONSTRAINT <name> PRIMARY KEY USING INDEX <name>_idx` (refused into the plain form — and said — on a partitioned table, a partial or expression index, or a non-btree method, which `USING INDEX` does not take) |
| a new column with a **volatile** default (`clock_timestamp()`, `random()`, `gen_random_uuid()`, any function the door reports `provolatile = 'v'`) | `ADD COLUMN c type` (nullable, no default) → `ALTER COLUMN c SET DEFAULT …` → the review's note "existing rows stay NULL: backfill in batches in a later migration" |
| a new column with a non-volatile default | as asked (free since PostgreSQL 11 — no rewrite) |
| `REFRESH MATERIALIZED VIEW` | `… CONCURRENTLY` when the view has a unique index; else the plain form, said |
| `DETACH PARTITION` | `… CONCURRENTLY` (not with a default partition — then the plain form, said) |

Every built change set is prefixed, at Apply and in a draft, by `SET lock_timeout` and `SET statement_timeout` (change-review "Apply").

## The rule table (`app/developer/rule_table.json`, T7, R13)
**Shape.** `{"version": "rules/1", "server_version_num": {"min": 170000, "max": 179999}, "rules": [{key, statement, subcommand?, condition?,
locks: [{on, mode}], rewrite: "no"|"yes"|"unless_binary_coercible"|"unless_check", scan: "no"|"yes"|"unless_valid_check", in_tx: bool,
safe_form?: key, source: "<doc URL> · tablecmds.c:<line>", note?}]}`. `on` is `table`, `referenced`, `parent`, `partition`,
`default_partition` or `index`. A rule outside its version range does not apply — PG 18 gets a new block (`NOT NULL … NOT VALID`, NOT NULL
as `pg_constraint` rows; T48 is Extended). **The key** is computed from the door's `classify` answer: the parse tree's node
(`IndexStmt`, `AlterTableStmt`, …), each `AlterTableCmd.subtype` (`AT_AddColumn`, `AT_AlterColumnType`, …), and the facts the door adds —
`concurrent`, the default's volatility, generated/identity, whether a type change is binary-coercible (the named query
`type_change_rewrites`: same type with a wider `varchar` or to `text`, or a `pg_cast` with `castmethod = 'b'` and no changing `USING`),
whether a valid `CHECK (c IS NOT NULL)` exists. **An operation the table does not know reads "ACCESS EXCLUSIVE, cost unknown"** and its
`lock_source` is `unknown` (T7).

**The annotation** each change-set item carries (`change_set_items.annotations`, per relation): `{relation, lock, rewrite, scan, in_tx,
size_bytes, rows, safe_form}` — size and rows from the named query `relation_sizes` (`pg_total_relation_size`, `reltuples`) — rendered as
"rewrite 4.2 GB, ~38 M rows under ACCESS EXCLUSIVE". Source PostgreSQL 17 docs (`sql-altertable.html`, `explicit-locking.html`,
`sql-createindex.html`, `sql-reindex.html`) and `src/backend/commands/tablecmds.c` (`AlterTableGetLockLevel()` at 4482; rewrite flags at
5016/5031 persistence, 7371/8474 default, 12978 type, 14954 access method), `policy.c:627/806`, `trigger.c:211` — research §2.2.

| key | Statement | Locks | Rewrite | Scan | In a transaction block | Safe form |
|---|---|---|---|---|---|---|
| `add_column` | `ADD COLUMN`, no default or a non-volatile one | table ACCESS EXCLUSIVE (brief) | no | no | yes | — |
| `add_column_volatile` | `ADD COLUMN … DEFAULT <volatile>` | table ACCESS EXCLUSIVE | **yes** (table + indexes) | — | yes | `add_column` + `set_default` + backfill note |
| `add_column_generated` | `ADD COLUMN … GENERATED ALWAYS AS (…) STORED` | table ACCESS EXCLUSIVE | **yes** | — | yes | none (a trigger-kept column, a migration) |
| `add_column_identity` | `ADD COLUMN … GENERATED … AS IDENTITY` / serial | table ACCESS EXCLUSIVE | **yes** | — | yes | none |
| `drop_column` | `DROP COLUMN` | table ACCESS EXCLUSIVE | no | no | yes | — (squawk `ban-drop-column`: an override with a reason) |
| `alter_column_type` | `ALTER COLUMN … TYPE` | table ACCESS EXCLUSIVE | **unless_binary_coercible** (+ index rebuild) | — | yes | new column, dual write, backfill, swap (a migration) |
| `set_default` / `drop_default` / `drop_not_null` / `drop_constraint` / `rename` | | table ACCESS EXCLUSIVE | no | no | yes | — |
| `set_not_null` | `ALTER COLUMN … SET NOT NULL` | table ACCESS EXCLUSIVE | no | **unless_valid_check** | yes | `add_check_not_valid` → `validate_constraint` → `set_not_null` → `drop_constraint` |
| `add_check` | `ADD CHECK` | table ACCESS EXCLUSIVE | no | yes | yes | `add_check_not_valid` → `validate_constraint` |
| `add_check_not_valid` | `ADD CHECK … NOT VALID` | table ACCESS EXCLUSIVE (brief) | no | no | yes | — |
| `add_foreign_key` | `ADD FOREIGN KEY` | table **and referenced** SHARE ROW EXCLUSIVE | no | yes | yes | `add_foreign_key_not_valid` → `validate_constraint` |
| `add_foreign_key_not_valid` | `… NOT VALID` | table and referenced SHARE ROW EXCLUSIVE (brief) | no | no | yes | — |
| `validate_constraint` | `VALIDATE CONSTRAINT` | table SHARE UPDATE EXCLUSIVE; referenced ROW SHARE | no | yes (concurrent with writes) | yes | — |
| `add_primary_key` / `add_unique` | `ADD PRIMARY KEY` / `UNIQUE` | table ACCESS EXCLUSIVE | no (index build; a NOT NULL scan for a PK) | yes | yes | `create_unique_index_concurrently` → `add_constraint_using_index` |
| `add_constraint_using_index` | `ADD … USING INDEX` | table ACCESS EXCLUSIVE (brief) | no | no (a PK still checks NOT NULL) | yes | — |
| `add_exclusion` | `ADD EXCLUDE` | table ACCESS EXCLUSIVE | no (index build) | yes | yes | none documented |
| `create_index` | `CREATE INDEX` | table SHARE (blocks writes) | no (build) | yes | yes | `create_index_concurrently` |
| `create_index_concurrently` | `CREATE INDEX CONCURRENTLY` | table SHARE UPDATE EXCLUSIVE | no (two scans) | yes | **no** | — (a failure leaves an invalid index to drop) |
| `drop_index` | `DROP INDEX` | table and index ACCESS EXCLUSIVE | no | no | yes | `drop_index_concurrently` |
| `drop_index_concurrently` | `DROP INDEX CONCURRENTLY` | SHARE UPDATE EXCLUSIVE | no | no | **no** | — |
| `reindex` | `REINDEX` | table SHARE; index ACCESS EXCLUSIVE | rebuild | yes | yes | `reindex_concurrently` |
| `reindex_concurrently` | `REINDEX CONCURRENTLY` | SHARE UPDATE EXCLUSIVE | rebuild | yes | **no** | — |
| `set_storage_params` | `SET STATISTICS`, attribute options, fillfactor / autovacuum / toast parameters, `parallel_workers`, `CLUSTER ON` | table SHARE UPDATE EXCLUSIVE | no | no | yes | — |
| `set_persistence` | `SET LOGGED` / `UNLOGGED` | table ACCESS EXCLUSIVE | **yes** | — | yes | none (schedule it) |
| `set_access_method` / `set_tablespace` / `set_expression` | `SET ACCESS METHOD`, `SET TABLESPACE`, `ALTER COLUMN … SET EXPRESSION` (17) | table ACCESS EXCLUSIVE | **yes** (a file copy for the tablespace) | — | yes | none |
| `create_trigger` / `enable_trigger` / `disable_trigger` | | table SHARE ROW EXCLUSIVE | no | no | yes | — |
| `create_policy` / `alter_policy` / `enable_rls` / `force_rls` | | table ACCESS EXCLUSIVE | no | no | yes | — |
| `attach_partition` | `ATTACH PARTITION` | parent SHARE UPDATE EXCLUSIVE; partition and default partition ACCESS EXCLUSIVE | no | yes (skipped by a matching valid check) | yes | add the matching check first |
| `detach_partition` | `DETACH PARTITION` | parent ACCESS EXCLUSIVE | no | no | yes | `detach_partition_concurrently` |
| `detach_partition_concurrently` | `… CONCURRENTLY` | parent SHARE UPDATE EXCLUSIVE | no | no | **no** | — |
| `refresh_matview` | `REFRESH MATERIALIZED VIEW` | ACCESS EXCLUSIVE | rebuild | yes | yes | `refresh_matview_concurrently` |
| `refresh_matview_concurrently` | `… CONCURRENTLY` | EXCLUSIVE | rebuild | yes | yes | — (needs a unique index) |
| `truncate` | `TRUNCATE` | ACCESS EXCLUSIVE (and every table it cascades to) | new file | no | yes | — |
| `vacuum_full` / `cluster` | | ACCESS EXCLUSIVE | **yes** | — | no | refused by the tool (D15); `pg_repack` Extended |
| `create_table` / `create_view` / `create_function` / `create_type` / `create_sequence` / `create_schema` / `comment` | creating a new object | none on existing relations (a view: ACCESS SHARE on what it reads) | no | no | yes | — |
| `create_or_replace_view` | `CREATE OR REPLACE VIEW` | the view ACCESS EXCLUSIVE | no | no | yes | — (a column cannot be dropped or retyped: drop and recreate the dependants — `impact`) |
| `drop_object` | `DROP <object>` | ACCESS EXCLUSIVE on it and on every table it is attached to | no | no | yes | — (squawk `ban-drop-*`: an override) |

## The forms' fields (slice 4 builds the screens; the builders above emit the SQL)
Every form is a full page whose submit is **Review** (`change_set_prepare`), never Run. **Bold** = required. Names go through `dx_name_ok()`;
types through `type_resolve`; expressions through `classify` with a carrier. A field that names an existing object is the record picker over
the target's catalog index (family-filtered), never a `<select>` of every row.

| Family | create | alter | drop / truncate |
|---|---|---|---|
| schema | **name**, owner (a role picker), comment | rename, owner, comment | drop (restrict / cascade) |
| table | **schema**, **name**, columns[] (**name**, **type**, nullable, default, identity always/by default, generated expression, collation, comment), primary key columns, unlogged, partition by (range / list / hash + key expression), partition of (parent + bounds), comment | rename; set logged/unlogged; storage parameters; replica identity; enable/force RLS; comment | drop (restrict / cascade, the reach from `impact`); **truncate** (restart identity, cascade) |
| column | **table**, **name**, **type**, nullable, default, identity, generated, collation, comment | rename, type (+ `USING`), set/drop default, set/drop not null, statistics target, storage, compression, comment | drop column |
| constraint — primary key / unique | **table**, **columns[]**, name, nulls not distinct (unique), deferrable | rename | drop |
| constraint — foreign key | **table**, **columns[]**, **referenced table**, **referenced columns[]**, on delete, on update, match full, deferrable, name | rename; validate | drop |
| constraint — check | **table**, **expression**, name, no inherit | rename; validate | drop |
| constraint — exclusion | **table**, **method**, **elements[]** (column or expression + operator), where, name | rename | drop |
| index | **table**, **columns[]** (column or expression, opclass, asc/desc, nulls first/last), method (btree, hash, gist, spgist, gin, brin, hnsw/ivfflat where pgvector is installed), unique, nulls not distinct, include[], where, name | rename; storage parameters; reindex (concurrently) | drop (concurrently) |
| view | **schema**, **name**, **query**, check option, security barrier, security invoker, comment | replace query (same columns, added at the end), rename, options, comment | drop |
| materialized view | **schema**, **name**, **query**, with data, comment | rename, storage, comment; refresh (concurrently) | drop |
| sequence | **schema**, **name**, as type, increment, min, max, start, cache, cycle, owned by | the same, restart | drop |
| function / procedure | **schema**, **name**, arguments[] (mode, name, **type**, default), returns (function), **language** (sql, plpgsql), **body**, volatility, strict, security invoker/definer, **search_path** (required when security definer — `pg_catalog, pg_temp` proposed), parallel, cost, comment | create or replace (same signature); rename; owner; security; search_path; comment | drop (by signature) |
| trigger | **table**, **name**, **timing** (before/after/instead of), **events[]**, for each row/statement, when, **function**, referencing (transition tables) | rename; enable/disable | drop |
| type — enum | **schema**, **name**, **labels[]** | add label (before/after), rename label, rename type | drop |
| type — composite | **schema**, **name**, **attributes[]** (name, type) | add/drop/alter attribute, rename | drop |
| type — range | **schema**, **name**, **subtype**, opclass, canonical, subdiff | rename | drop |
| domain | **schema**, **name**, **base type**, default, not null, checks[] | set/drop default, set/drop not null, add/drop/validate check, rename | drop |
| RLS policy | **table**, **name**, permissive/restrictive, command (all/select/insert/update/delete), roles[], using, with check | rename, roles, using, with check | drop |
| comment | **object**, **text** (empty = remove) | — | — |
| extension | **name** (from `pg_available_extensions` on the target), schema, version — **a workbench only**; on an installed application it is a draft for the owner (an untrusted extension needs a superuser) | update to version | drop |
| grants | **object**, **grantee** (a role or PUBLIC), **privileges[]**, with grant option — **a workbench only, or a draft** (R64; the grant wizard ends in Change review) | — | revoke |

## The records server's bridge (`html/internal/ddl.php`)
- **POST only**, from **loopback only** (`REMOTE_ADDR` `127.0.0.1`/`::1`), on the internal vhost only — the public vhost answers 404 under
  `/internal/` (Phase 2's vhost already refuses it). Header `X-DX-Bridge: {ts}.{hex hmac}` = HMAC-SHA256 over `"{ts}.{raw body}"` under
  **`DX_BRIDGE_KEY`** (64 hex, in `config/.env`, written once by `deploy/ROOT_STEPS.sh` step 0 beside `DX_DOOR_KEY`; the records server reads
  it from its unit's `EnvironmentFile`), `ts` within 60 s; `hash_equals()`. Anything else → 401 with no detail.
- Body `{"op": "render", "parts": {…}}` — the `object_ddl` answer the records server got from the door. The bridge calls `dx_ddl_render()`
  and answers `{"ok": true, "ddl", "drop", "source", "version"}`, or `{"ok": false, "error": {"code": "unrenderable", "message"}}`. **It
  opens no database connection and starts no session** (`header_remove('Set-Cookie')`, no `session_start()`); its only state is the key.
  Request body at most 2 MB; answer `Cache-Control: no-store`.
- The records server's `object_ddl` tool: door `named` `object_ddl` (the door judges the caller and the target) → if `defs` alone suffice
  (`source = pg_get_def`), it renders those without the bridge; else POST to `http://127.0.0.1:${APP_INTERNAL_PORT}/internal/ddl.php`;
  a bridge failure answers `door_unavailable` with `retry: true`.

## Files (exactly these)
- `app/developer/ddl/{quote,render,keywords,database,schema,table,constraint,index,view,matview,sequence,routine,aggregate,trigger,event_trigger,type,extension,role,grant,policy,publication,subscription,foreign,collation,statistics,rule,tablespace,builders}.php`
- `app/developer/rule_table.json`, `app/developer/rule_table.php` (`dx_rule(string $key): ?array`, `dx_rule_key(array $classified): string`, `dx_annotate(array $classified, array $sizes): array`)
- `html/internal/ddl.php`, `app/developer/bridge.php` (`dx_bridge_verify(string $raw, string $header, string $remote, int $now): ?string`)
- `bin/dx_keywords.php`
- `mcp/ddl_bridge.py` (the records server's client: sign, post, parse) and `mcp/rule_table.py` (loads the JSON for `ddl_cost`)
- `tests/fixtures/ddl/{001_tables,002_partitions,003_types,004_routines,005_constraints_indexes,006_views,007_rls_grants,008_sequences_identity,009_misc,010_hostile}.sql`, `tests/fixtures/ddl/README.md` (the known cosmetic differences, each with its reason)
- `tests/ddl/{run.sh,golden.php,hostile.php,rules.php,bridge.php}`

## Requirements claimed
MUSTs (19): T1, T2, T3, T4, T6, T7, T8, T10, T48, R9, R11, R13, R15, R64, R65, R103, R105, S9, E19

(T48 only as far as the rule table is keyed by version so PostgreSQL 18's rows are a new block — the PG 18 catalogue itself is Extended.
E19: the door's sentence for a refused expression is shown to the person who typed it, capped at 500 characters, never logged.)

## Proof (`tests/ddl/run.sh` — run by slices 2 and 4 and again at Phase 4)
Scratch database `dx_golden_a` and `dx_golden_b`, scratch roles `dx_golden_*` (the owner's leave, design §15 (d)); `sudo -n -u postgres`.
1. **Golden, round-trip (T3)**: build `dx_golden_a` from `tests/fixtures/ddl/0*.sql` (partitioning — range, list, hash, default, sub-partitions;
   unlogged; inheritance; typed tables; identity always and by default; generated stored columns; every constraint form incl. `NOT VALID`,
   deferrable, `NULLS NOT DISTINCT`, exclusion; every index form — six methods, partial, expression, `INCLUDE`, descending, opclass; views
   with every option, materialized views; sequences; enums, composites, domains, ranges; functions, procedures, aggregates, triggers,
   event triggers, rules, statistics objects; RLS permissive and restrictive; grants on every object kind incl. columns and `PUBLIC`;
   default privileges; publications; a foreign server and a user mapping on a dummy wrapper; collations; comments on everything). Fetch
   every object's parts with the same SQL the door's `object_ddl` runs (as postgres, in the harness), render each with `dx_ddl_render()`,
   run the concatenation — in `pg_dump`'s own order — into the empty `dx_golden_b`; `pg_dump --schema-only` both; after `dx_ddl_normalise()`
   **the two dumps are identical**.
2. **Golden, per object**: each rendered object equals pg_dump's text for it after normalisation, except the differences listed in
   `tests/fixtures/ddl/README.md` (each named and reasoned); a new difference fails.
3. **Keywords**: `app/developer/ddl/keywords.php` equals the server's `pg_get_keywords()`.
4. **Hostile names (S9, T10)**: every builder of the forms table and every reader, rendered with a schema, table, column, constraint, index,
   type, label, role and comment named `o'brien`, `a"b`, `x;drop table t`, `line\nbreak`, `back\slash`, `Mixed Case`, `select`, a 63-byte
   name and an emoji: each output is **exactly one statement** by the door's `classify` (libpg_query), of the expected node kind, whose
   object identity in the parse tree equals the name; run on a scratch workbench database, `pg_identify_object_as_address()` reads the same
   name back. A 64-byte name and an invalid-UTF-8 name are **refused** by `dx_name_ok()` with their sentences. A comment holding `'); DROP
   TABLE t; --` round-trips as a comment.
5. **Rules**: every row's `source` names a document section; every key the builders emit has a row; a statement `classify` cannot map reads
   "ACCESS EXCLUSIVE, cost unknown"; `alter_column_type` from `varchar(20)` to `varchar(40)` and to `text` reads no rewrite, to `integer`
   from `text` a rewrite; the rehearsal's measured locks agree with the table for `add_column`, `add_check_not_valid`, `validate_constraint`,
   `set_not_null` with a valid check, `create_trigger`.
6. **Bridge**: a valid call renders; a wrong HMAC, a stale `ts`, a non-loopback address (`REMOTE_ADDR` forged in php -S is not possible —
   proven under the user-level Apache on 9407 from a second address) and a GET are 401/405; the public vhost answers 404 under `/internal/`;
   the bridge sets no cookie and opens no connection (a run with the database stopped still renders).

## Decisions taken here
1. One renderer for screens, snapshots and the records MCP (through the bridge), so a DDL text has one meaning and one hash.
2. The rule table is JSON, shared by PHP, the records server and the door.
3. Names that would not round-trip are refused, never quoted.
4. Extensions and grants are forms on a workbench and drafts elsewhere; database, tablespace, role and default-privilege forms do not
   exist in v1 (DS14).

## Open questions
None — the version-keyed rows for PostgreSQL 18 are added when the server moves (T48 Extended).
