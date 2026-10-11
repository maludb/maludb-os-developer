# Build spec: health, history, compare and diagrams (slice 8)

What exists at the end: **health** — deterministic checks per database with a severity and **each fix as a change set** that opens in Change
review (never a run button); **bloat estimates** and **index advice**; **snapshots** — nightly per application, kernel and own database, on
demand by a DBA — giving every object's **DDL history**, **"what changed in this database since …"** with each change attributed to a
change set, a migration draft, the grants service, or marked **unexplained**, and **drift** (the unexplained ones across the estate, a
person's note to explain one); **compare** of two databases, a database and a workbench, or one database at two snapshots — the object
inventory and a per-object normalised-DDL diff; **focused ER diagrams** drawn by Graphviz on the server with saved layouts, the list of
foreign keys at 375; and **backups** — each database's last recorded backup and WAL archiving. Design §6.7; the snapshots hash the DDL the
generators render (`ddl-generators.md`), so history, drift, compare and the draft's observed-applied check (change-review.md) agree.

It replicates slice 2's reading screens (the object page's shell and tabs, crumbs, `?back=`) and slice 4's change path for fixes:
`health_fix_prepare` makes a change set (origin `health_fix`) on the finding's database and lands on `/changes/{id}`.

Schema (db/007, db/011, db/012): `catalog_snapshots`, `snapshot_objects`, `dx_object_history()`, `backup_marks`, `dx_last_backup()`,
`diagram_layouts`, `mcp_schema_changes`, `mcp_backup_marks`. The door: `snapshot` (every object's address and its `object_ddl` parts, paged
— the worker renders and hashes), and the named queries `health_checks`, `index_advice`, `bloat_estimate` (**read tier** — `pg_stats` shows a
column only to a role with `SELECT` on it), `fk_graph`, `archiver`, `relation_sizes`.

## Divergences from the design
1. **A person's explanation of drift needs columns db/007 lacks.** `snapshot_objects.explained_by` admits `change_set`, `migration_draft`,
   `grants`, `none`; `drift_explain` needs **`person`** and the note and who. **db/013 (the Phase 1 fixes)** widens the check
   with `person` and appends `explained_note text` (≤ 500), `explained_member_id bigint`, `explained_at timestamptz`. The `snapshot_object`
   param is the triple (`snapshot_id`, address) the page carries.
2. **Diagram layouts keep positions in `tables`.** `diagram_layouts.tables` holds `[{address, x, y}]` (at most 60); the manifest's
   `tables` param fills it. `detail` is `names`, `keys` or `columns` in the schema and the manifest alike
   (the handler maps it); `hops` is 1–4 in the form though the column admits 0–5.
3. **The diagram's SVG is served as an image, not inlined.** `GET /diagrams/svg?…` answers `image/svg+xml` with `Content-Security-Policy:
   default-src 'none'; style-src 'unsafe-inline'` and `X-Content-Type-Options: nosniff`, shown through `<img>` (a script in an SVG never runs
   in an `<img>`); the DOT is built only by our writer and the SVG is passed through an allow-list of elements and attributes (`svg`, `g`,
   `title`, `polygon`, `polyline`, `path`, `ellipse`, `text`, `a` without `href`) before it is cached. The table list below the image carries
   the links.
4. **Vacuum and wraparound are slice 7's** (`vacuum`, `vacuum_state`); this slice's health checks read wraparound age as a finding only.

## Who may do what
| Action / screen | Right | Rule |
|---|---|---|
| `health-all`, `db-health`, `bloat`, `index-advice`, `backups` | `health.read` | the target visible to me; a check the tool's roles cannot see (the kernel's, a memory database's) is shown *not visible to the tool* |
| `db-history`, `object-history`, `drift`, `compare`, `compare-object` | `catalog.read` | both sides of a compare visible to me (a workbench: its owner); the DDL text while kept (`snapshot_ddl_days` 90) |
| `diagram` | `catalog.read` | ≤ 60 tables; at 375 the foreign-key list |
| `health_fix_prepare` | `changes.prepare` (people — a form-like screen; an agent proposes the same fix through `change_set_propose`, origin `health_fix`) | the finding still present (re-checked); the fix's change set on its database (application → a draft after rehearsal; workbench → Apply) |
| `drift_explain` | `maintenance.run` (a DBA) | an `unexplained` change |
| `snapshot_take` | `maintenance.run` | an application, kernel or own target; one running per target |
| `diagram_layout_save` / `diagram_layout_delete` | `catalog.read` / own | — |

## The health checks (`health_checks`, deterministic; each `{check, severity, address, detail, fix}`)
| Check | Severity | Fix (a change set unless said) |
|---|---|---|
| `missing_primary_key` — a table with no PK and no NOT NULL unique key | warning | none generated (a key is a design decision) — "add a primary key through the table's form" |
| `unindexed_foreign_key` — an FK whose columns lead no index | warning | `CREATE INDEX CONCURRENTLY <t>_<cols>_idx ON t (cols)` |
| `duplicate_index` — same table, columns, opclass, predicate | warning | `DROP INDEX CONCURRENTLY <the newer>` |
| `overlapping_index` — one index's columns a leading prefix of another's | info | `DROP INDEX CONCURRENTLY <the shorter>` (noted: check queries first) |
| `unused_index` — `idx_scan = 0` since the statistics reset, not unique, not a PK, older than 7 days | info | `DROP INDEX CONCURRENTLY` |
| `invalid_index` — `indisvalid = false` | critical | `DROP INDEX CONCURRENTLY` + the index's own `CREATE INDEX CONCURRENTLY` |
| `sequence_near_limit` — `last_value` over 75 % of `max_value` (from `pg_sequences`, read by `developer_meta`, never a table scan) | critical over 90 % | `ALTER SEQUENCE … AS bigint` with a note that the column's type must widen too (a migration) |
| `wraparound_age` — `age(datfrozenxid)` over 1 billion | critical | none — "a VACUUM of the oldest tables (slice 7)" |
| `rls_enabled_no_policy` | warning | none (a policy is a design decision) |
| `security_definer_no_search_path` | critical | `ALTER FUNCTION … SET search_path = pg_catalog, pg_temp` |
| `security_definer_public_execute` | critical | `REVOKE EXECUTE ON FUNCTION … FROM PUBLIC` |
| `idle_in_transaction` — over 10 minutes | warning | none (slice 7's cancel) |
| `constraint_not_valid` — `convalidated = false` | info | `ALTER TABLE … VALIDATE CONSTRAINT …` |
| `unexplained_change` — drift since the last snapshot | warning | none — explain it (`drift_explain`) or draft the matching migration |

A finding's key is `{check}:{address}` — stable across runs, so the Advisor skips a fix proposed and discarded in the last 30 days.

## Screens (tables for findings, changes and diffs; 375 px first except compare and the diagram)
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `health-all` | `/health?severity=&check=` | findings across the databases I may see: counts by severity per database (a table), then the findings (database badge, check, severity, object link, detail, **Prepare the fix** where one exists); the checks not visible to the tool listed per database |
| `db-health` | `/db/{datname}/health` | one database's findings with their fixes; the last run's time; Run now (re-reads, no write) |
| `bloat` | `/db/{datname}/bloat?schema=&min_ratio=` | tables and indexes: size, estimated bloat bytes and ratio (the ioguix estimate), method (`estimate`, `pgstattuple` where installed — "an exact figure scans the table" said); a link to slice 7's maintenance for a `VACUUM` or `REINDEX CONCURRENTLY` |
| `index-advice` | `/db/{datname}/indexes?schema=` | four tables — unused, duplicate, overlapping, invalid — and the foreign keys without an index with the suggested index; each row's **Prepare the fix** |
| `db-history` | `/db/{datname}/history?since=` | the snapshots (time, objects, changed, unexplained) and the changes since the date: object link, family, added / changed / removed, explained by (a change set link, a draft link, the grants service, a person's note) or **unexplained**; Take a snapshot now (`snapshot_take`) |
| `object-history` | `/db/{datname}/o/{address}/history` | the object's snapshots: when, change, explained by; select two → the normalised-DDL diff (added lines green, removed red, escaped); "DDL text no longer kept" past 90 days (the hashes remain) |
| `drift` | `/drift` | every unexplained change across the databases I may see, newest first; **Explain** (a note, `drift_explain`) or **Draft a migration that matches** (opens slice 4's form for the object) |
| `compare` | `/compare?a=&b=&at_a=&at_b=` | pick two sides (a database, a workbench, a snapshot time each); the inventory — only in A, only in B, differ, same (count) — by family; each differing object links to `compare-object`; "renames are never guessed" stated; a live side is read through the door's `snapshot` at the moment (not stored) |
| `compare-object` | `/compare/object?a=&b=&object=` | one object's normalised DDL on both sides as a line diff |
| `diagram` | `/db/{datname}/diagram?start=&hops=&detail=&layout=` | start table (picker), hops 1–4, detail names / keys / all columns, the tables kept (≤ 60 — "the diagram stops at 60 tables" said); the SVG image (Divergence 3) with SVG download; Save layout (title) and my saved layouts; at 375 (and without Graphviz) the foreign keys as a list `invoices.customer_id → customers.id`; "Graphviz is not installed — the owner's root step" when `dot` is absent |
| `backups` | `/backups` | per database I may see: the last recorded backup and its kind (from `backup_marks`, written by the owner's `bin/backup_mark.php`), "none recorded" in `text-bg-warning`; WAL archiving — mode, last archived, failures (`pg_stat_archiver`); the gate stated: "row changes over 1,000 need a backup newer than 24 hours" |

## Snapshots (the worker's `snapshots` pass — built here)
Nightly at 02:30 per `application`, `kernel` and `own` target (and on `snapshot_take`): a `catalog_snapshots` row (`running`); the door's
`snapshot` pages every object's parts (as `developer_meta`); PHP renders each with `dx_ddl_render()`, normalises (`dx_ddl_normalise()`),
hashes (sha256), writes `snapshot_objects` (the DDL text kept `snapshot_ddl_days`), and compares with the previous `ok` snapshot: `added`,
`changed`, `removed`, `same`. **Attribution**, in order: an applied change set or an observed draft whose rehearsal `objects` match the
address and sha (`change_set` / `migration_draft`); a grants pass that changed the object's ACL within the interval and the only difference
is in the grant lines (`grants`); else `none` — **unexplained**, counted in `unexplained_count`, a finding, the Advisor's note. A generator
version change (`render.version`) recomputes the previous snapshot's hashes before comparing, so it is never read as drift. Then the
`applied_drafts` pass (change-review) runs on the snapshot.

## Files (exactly these)
- `html/health/{index,fix}.php`, `html/db/{health,bloat,indexes,history}.php`, `html/db/object-history.php`, `html/drift.php`,
  `html/history/{explain,snapshot}.php`, `html/compare/{index,object}.php`, `html/db/diagram.php`, `html/diagrams/{svg,save,delete}.php`, `html/backups.php`
- `app/features/health/{checks,fixes,present}.php` (`fixes.php`: `dx_health_fix(array $finding): ?array{title, statements}` — the fix
  table above, built with ddl-generators' builders), `app/features/history/{snapshots,attribution,present}.php`,
  `app/features/compare/{inventory,present}.php`, `app/developer/diff.php` (a line diff — Myers, no library), `app/features/diagrams/{graph,dot,svg,present}.php`
  (`dot.php`: the DOT writer — HTML-like labels with every character escaped, no attribute from data; `svg.php`: `proc_open(['prlimit',
  '--as=268435456', '--', 'dot', '-Tsvg'], …)` with an argument array (no shell), a 5-second timeout, the allow-list filter),
  `app/features/backups/queries.php`
- `app/views/health/{index,db}.php` + `partials/{finding,counts}.php`, `app/views/bloat/index.php`, `app/views/indexes/index.php`,
  `app/views/history/{db,object,drift}.php` + `partials/{change,diff}.php`, `app/views/compare/{index,object}.php`, `app/views/diagrams/{view,fk-list}.php`, `app/views/backups/index.php`
- `bin/worker.php` gains the `snapshots` pass's body; `bin/backup_mark.php` (the owner's cron calls it: `<datname> <kind>`)
- `tests/phase3/slice8/{run.sh,lib.php,health.php,fixes.php,bloat.php,indexes.php,snapshots.php,drift.php,compare.php,diagram.php,backups.php,walls.php,json.php,browser.mjs}`

## Query functions / door calls (signatures fixed)
- `health_findings(?string $datname, array $filters): array` — door `named health_checks` per visible target (the worker caches the last
  run per target in `worker_passes`' detail for the home's counts)
- `health_fix_prepare(PDO $pdo, int $by, string $datname, string $findingKey): int` — re-runs the check for that object, builds the fix,
  `change_set_propose(…, origin 'health_fix')` (slice 4)
- `index_advice(string $datname, ?string $schema): array` · `bloat(string $datname, ?string $schema, ?float $minRatio): array`
- `snapshot_take(PDO $pdo, int $targetId, ?int $by): int` · `schema_changes(PDO $pdo, string $datname, ?string $since, bool $unexplainedOnly): array` (`mcp_schema_changes`)
  · `object_history(PDO $pdo, string $datname, string $address): array` (`dx_object_history()`) · `drift_explain(PDO $pdo, int $snapshotId, string $address, int $by, string $note): void`
- `compare_inventory(PDO $pdo, array $a, array $b): array{only_a, only_b, differ, same}` — each side `{datname, at?}`: a stored snapshot by
  time, or live through the door's `snapshot` · `compare_object(PDO $pdo, array $a, array $b, string $address): array{a_ddl, b_ddl, diff}`
- `diagram_graph(string $datname, string $start, int $hops, string $detail): array{tables, edges}` (door `named fk_graph`, BFS ≤ 60) ·
  `diagram_svg(array $graph): ?string` · `diagram_layout_save(PDO $pdo, int $by, string $datname, array $fields): int` · `diagram_layout_delete(PDO $pdo, int $id, int $by): void`
- `backup_posture(PDO $pdo, ?string $datname): array` (`mcp_backup_marks` + door `named archiver`)

## MCP tools this slice makes real
`object_history`, `schema_changes`, `schema_compare`, `index_advice`, `bloat`, `health_findings`, `backup_posture`.

## Manifest rows claimed
Screens (11): `health-all`, `db-health`, `bloat`, `index-advice`, `db-history`, `object-history`, `drift`, `compare`, `compare-object`, `diagram`, `backups`
Actions (5): `health_fix_prepare`, `drift_explain`, `snapshot_take`, `diagram_layout_save`, `diagram_layout_delete`

## Activity log events
`health.fix_prepare` (check, address, the change set), `drift.explain` (the address — the note's length, not its text), `snapshot.take`
(by a person; `snapshot.done` from `cron` with objects/changed/unexplained counts), `diagram_layout.save` / `.delete`, `compare.view` (the two
sides), `screen.view`. Every row carries `target_database_id`; never DDL text.

## Status vocabulary
Severity: critical `text-bg-danger`, warning `text-bg-warning`, info `text-bg-info`. Changes: added `text-bg-success`, changed
`text-bg-warning`, removed `text-bg-danger`. Explained by: change set / draft / grants / a person `text-bg-light border`; **unexplained**
`text-bg-danger`. "Not visible to the tool" `text-bg-secondary`. Backups: "none recorded" `text-bg-warning`, older than 24 h
`text-bg-warning`. Ids: `finding-{check}-{n}`, `finding-fix-{n}`, `history-change-{n}`, `history-snapshot-now`, `drift-explain-{n}`,
`compare-a`, `compare-b`, `compare-row-{address}`, `diff-line-{n}`, `diagram-start`, `diagram-hops`, `diagram-detail`, `diagram-svg`,
`diagram-save`, `fk-row-{n}`, `backup-row-{datname}`.

## Requirements claimed
MUSTs (17): R10, R72, R78, R82, R103, R105, T3, T5, T24, T34, T35, T36, T39, T40, S8, S12, S17

(T34, T36, T39, T40 are SHOULDs in the research that this design builds; T34's "dependency-ordered migration for the safe subset" is
Extended — compare here is the inventory and the per-object diff, and a fix or a draft is made through slice 4's forms. S12: the snapshots'
attribution marks every change the tool or the grants service made, so an unexplained one is a hand change.)

## Out of scope for this slice
Script generation from a diff (Extended — T34's migration part, T44); vacuum and maintenance jobs (7); the Advisor's note (10 — it reads
these tools); diagram-driven design (Extended); `pg_repack` (Extended).

## Proof (`tests/phase3/slice8/run.sh`: scratch database `dx_dev8`; php -S on 9401, the fake kernel on 9402, the fakes on 9403; then the user-level Apache on 9407; Playwright from /var/www/web/node_modules; scratch roles `dx_proof_*` and scratch targets `dx_t8_app` (seeded with one of every finding) and `dx_t8_app2` (its copy, then changed), a running scratch door; Graphviz present or the test says it skipped the image and proves the list; the registry `--check`)
1. Every check fires once on `dx_t8_app` and not on a clean copy; each fix opens Change review with the expected statements; a finding that
   went away refuses its fix; a duplicate index's fix drops the newer one.
2. Bloat and index advice against hand-made bloat and indexes; `pgstattuple` absent → the estimate only, said.
3. Snapshots: night one; a change set applied on a workbench target is explained `change_set`; a draft applied by hand as postgres is
   explained `migration_draft` and observed; a grants pass changing an ACL is `grants`; a hand `ALTER TABLE` is **unexplained**, a finding
   and in `/drift`; `drift_explain` marks it with the note; a generator version bump does not produce drift.
4. Object history shows the diff between two snapshots; past `snapshot_ddl_days` the text is gone and the hashes stay.
5. Compare `dx_t8_app` with `dx_t8_app2`: only-in, differ and same counts right; a workbench as the B side; one database at two snapshots.
6. Diagram: 2 hops from `invoices`; a table named `<script>` and a column named `"><svg onload=…>` render as text (the DOT and the SVG
   filter); 61 tables stop at 60 with the sentence; the SVG response carries its CSP and nosniff; `dot` killed at 5 s; at 375 the list.
7. Backups: a mark recorded by `bin/backup_mark.php`; "none recorded" otherwise; archiving off said.
8. Walls: a Viewer reads every screen; `drift_explain` and `snapshot_take` refused to an Engineer and to an agent (`people`); another
   person's workbench as a compare side 404; the kernel's database: health checks needing privileges shown *not visible to the tool*.
9. JSON mode and the seven MCP tools answer what the screens show; 375 px on the reading screens.

## Decisions taken here
1. Drift is explained by a person's note in new columns (Divergence 1 — an additive migration).
2. The SVG is an image behind a strict CSP, filtered by an allow-list (Divergence 3).
3. Snapshots attribute in the order change set → draft → grants → unexplained; a generator change is never drift.

## Open questions
None.
