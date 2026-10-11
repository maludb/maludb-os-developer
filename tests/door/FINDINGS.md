# The door proof — findings (Phase 0, 2026-10-11)

`tests/door/run.sh` — **174 checks, 174 ok** (about 51 s on this host), re-run green from `main` after the merge; and
`tests/integration/sql_policy.sh` — **11 checks, 11 ok**: the door's own `SqlPolicies` and `decide()` against the real `dx_door_policy()`
and the four audit functions of db/006–011. The proof runs on scratch cluster roles `dx_proof_*` and scratch databases `dx_door_*`
(the owner's leave, design §15 (d)), and drops everything it made unless `KEEP=1`. Design §6.13 carries what these findings changed.

## Versions

| Piece | Version | Note |
|---|---|---|
| libpg_query | **17-6.2.5** (PostgreSQL 17 grammar), sha256-pinned in `deploy/build-libpg_query.sh`, builds in about 20 s with gcc 13 | 18.1.0 exists but parses PG 18 syntax the 17.11 server rejects (`NOT NULL … NOT VALID`); the door classifies what the server will run, so the grammars match. Move the pin with the server's major. |
| psycopg | 3.3.6 (binary wheel, libpq 18) | runs on this CPU (no AVX); `cancel_safe()` present |
| squawk | 2.68.0 (`squawk-cli` wheel) | runs on this CPU; flagged a test migration with `prefer-bigint-over-int`, `prefer-robust-stmts`, `require-concurrent-index-creation`, `require-lock-timeout`, `require-statement-timeout` |

## Findings that changed the design

1. **PostgreSQL 16+ needs `CREATEDB` on the role that creates a database, and the creator must be able to act as the owner.** The rolemaker
   creates the workbench role, grants itself `SET` (not `INHERIT`) on it, creates the database `OWNER dxw_<n>`, and drops both acting as
   that role. (§6.1, §6.5.)
2. **libpg_query's JSON leaves typed fields unwrapped** — `CallStmt.funccall`, `AlterTableStmt.relation` and others are bare objects, not
   `{"FuncCall": …}` nodes. `CALL f()` slipped past the function screen until every tree walker handled both shapes. **Phase 1's
   `the-door.md` states the rule: every walker visits wrapped and unwrapped nodes.**
3. **`xmin` needs its own column grant** (`GRANT SELECT (xmin) ON t TO tier`). With column-level masks, no tier ever holds table-level
   `SELECT` — which would open every column, secrets included — so the grants service grants `xmin` beside the readable columns, or
   the grid's optimistic concurrency check fails. (§6.1, §6.6, §6.9.)
4. **`pg_stat_xact_user_tables` in PG 17 counts a session's earlier, unflushed transactions too.** The side-effect check takes a baseline
   before the change set and compares deltas. (§6.6.)
5. **`pg_dump --exclude-extension=maludb_core` leaves its schemas behind**, so a clone also excludes `maludb*` and `mc2db`; on restore,
   `COMMENT ON EXTENSION` fails for a non-owner — expected, and filtered. A co-located-memory application (the cidery's shape) clones in
   about 0.8 s. (§6.5.)
6. **The function screen is load-bearing.** No tier may rely on the estate's function privileges alone — *an estate finding, withheld from
   the public copy (2026-10-11): reported privately to the owner; it will be published once fixed.* The deny-list gained the `query_to_xml` family (it runs SQL from a string),
   `nextval`, `setval` and `txid_current`. (§6.1 step 4.)
7. **`developer_meta` defaults to read-only transactions but writes the audit on the tool's own database.** The door lifts the default on
   that one connection, and `deploy/own-database.sql` says it once: `ALTER ROLE developer_meta IN DATABASE <own> SET
   default_transaction_read_only = off`. (§6.1.)
8. **A grid edit on a table whose triggers write elsewhere is always refused in v1** — audit and history tables included — so the grid says
   so up front ("this table's triggers write to …; edit it through a migration") instead of failing at Apply. (§6.6.)
9. **Table-level `MAINTAIN` on the ops role admits `pg_dump`'s locks**, so schema clones work without `SELECT`; a workbench role that
   changes its own password loses only that workbench, and **Reset credential** recovers it. (§6.1, §6.5.)

## Integration (the main session's fit of the schema to the door)

- `dx_door_policy()` answers the door's contract exactly (`ok`, `refusal{rule,message}`, `frozen`, `caller{member_id,is_agent,active,
  is_super_admin}`, `on_behalf_of`, `target{…}`, `rights[]`, `level`, `window{read,write}`, `workbench{id,owner_member_id,role,suspended}`,
  `limits{…}`), plus `ceiling` and `tiers` for the screens.
- `mcp_grant_plan(datname, schema_name, table_name, column_name, class, cleared_secret)` with one `table_name IS NULL` row per granted
  target; `dx_grants_pass_log(datname, jsonb)` records each pass in `grants_passes`.
- `query_runs` keeps the Data Lake's per-request grain with `status` widened by `running`; `door_statements` is the per-statement child.

## Timings (scratch fixtures on this host — not the largest installed database)

| Operation | Time |
|---|---|
| A fresh loopback connection (sslmode disabled) | 29–37 ms |
| Split and classify 45 statements | 0.6 ms |
| A 1,000-row page through the door | 37–68 ms |
| A catalog page (the tables of HR's schema) | 40–62 ms |
| A completion map (every column of HR — 466) | 11–20 ms |
| A grants pass (5 tables) | 56–204 ms |
| A schema clone of HR's real migrations | 1.6–2.0 s |
| A rehearsal of 3 statements on an application's schema | 1.0–1.8 s |

## Stand-ins in the proof (production differs)

- The scratch meta role holds no `pg_monitor` (granting it would expose the real applications' live query texts to a scratch login), so
  activity screens were proven on the proof's own sessions; production's `developer_meta` holds `pg_monitor`.
- A scratch `BYPASSRLS` auditor stood in for `maludb_memory_auditor`.
- A stand-in `dx_signal()` without the refusal of `developer`-named sessions (`deploy/own-database.sql` carries the real one).
- Workbench and rehearsal prefixes in the proof were `dx_door_wb_` / `dx_door_rh_`; production uses `dxw_` / `dxr_`.
