# Build spec: the SQL workspace through the door (slice 3 — THE FIRST EXEMPLAR)

What exists at the end: **the SQL editor on one database** (`/db/{datname}/sql`) — the CodeMirror 6 island with PostgreSQL highlighting,
completion from the catalog index filtered to what the person may read, Format, **Run** (the statement at the cursor, the selection or the
script), **Cancel** while it runs, results bounded by rows and bytes with the truncation said, masked columns named, a messages panel with
notices, rows affected, time and **the error's position marked in the editor**; the target's class badge, colour and the person's level on
the editor; **a refused statement that names its rule and offers the way that exists** (the grid in a write window, a migration draft, a
workbench); my run history; one run's page; saved queries with named parameters — private or shared, never run implicitly, verified by a DBA,
the verification dropped by itself when the SQL changes; and **result exports** (CSV, JSON, SQL `INSERT`s) as worker jobs that re-run the
statement at the person's level. Without JavaScript the editor is a `<textarea>` and Run still works.

**This slice is THE FIRST EXEMPLAR**: the door's whole pipeline used by a person end to end (`docs/build-specs/the-door.md` §1–§3, §7) —
split, parse, classify by the allow-list, screen functions, decide, execute at the level, cap, audit, cancel. Every later screen that sends
SQL through the door (the grid's page in 5, plans in 6, the activity screen's signals in 7, the health fixes in 8) copies **its request
shape (`door_run()` after `session_write_close()`), its refusal rendering (the rule's sentence + the offer), its audit (the door's
`query_runs`/`door_statements`, PHP's `log_activity()` with counts only) and its proof**. It replicates the Data Lake's editor
(`/srv/apps/datalake/docs/build-specs/query-service-editor.md` and its built files — read them first): the same screen shapes, the same saved
queries table and trigger, the same export rows.

Schema (db/005, 009, 011, 012, never modified): `query_runs`, `door_statements`, `door_usage`, `dx_door_run_open()`, `dx_door_run_close()`,
`dx_door_statement_log()`, `dx_query_runs_prune()` (db/009 — written by the door, read here); `saved_queries`, `dx_saved_queries_before()`
(an agent's always private; the badge drops when the SQL changes), `dx_saved_query_verify()` (db/009); `exports`, `dx_exports_before()`
(people only; `expires_at` from `export_keep_hours`) (db/011); `catalog_index`, `column_classes` (db/007, 008 — slice 1 fills them);
`mcp_saved_queries`, `mcp_target_databases` (db/012); the settings `screen_timeout_seconds`, `workbench_timeout_seconds`, `show_rows`,
`show_bytes_mb`, `cell_chars`, `runs_per_person`, `sql_text_days`, `export_max_rows`, `export_max_mb`, `export_keep_hours` (db/005).
**The door is the referee**: whether a statement runs, at which tier, with which columns readable — PHP never decides a class, a tier or a
mask.

## Divergences from the design
1. **A run is a synchronous request with a side door for Cancel.** `POST /sql/run.php` waits for the door's answer (at most
   `screen_timeout_seconds` + 5 s on an application target, `workbench_timeout_seconds` + 10 s on a workbench) and swaps the result in. The
   editor page renders a fresh `request_id` (uuid, kept in a hidden field and re-issued after every run); the JS posts it with the run and,
   while it waits, shows *Running… n s · Cancel*. **The poll door is `GET /sql/runs/poll?request={request_id}`** (the manifest's conventions
   name `/sql/runs/{id}/poll`; the run's id is not known until the door opens its row, so the request id is the handle) — it answers the
   `query_runs` row's status for a run of the caller's, so a run cancelled from another tab or timed out reads right. Without JavaScript there
   is no Cancel; the statement timeout bounds the wait.
2. **The completion map is built by PHP from `catalog_index`**, not by a door call per keystroke: relations and their columns from
   `catalog_index.columns`, filtered by `column_classes` for the person's level on the target (`masked`: neither `secret` nor `personal`;
   `rows`: not `secret`; `structure`: names of relations only, no columns), functions and keywords from the catalog index pass's
   `completion_map` named query (`the-door.md` §4). `GET /db/{datname}/complete.json` answers it with `Cache-Control: private, max-age=60`
   and an `ETag` from the index's `indexed_at`. A column added since the last grants pass may be listed and still refused — the refusal says
   "grants pending, under a minute".
3. **`SELECT *` at the masked level is refused by PostgreSQL** when the relation has a column the tier may not read (column privileges are all
   or nothing for `*`). The door words the 42501 (*"`email` is personal — masked for you on this database"*) and the result area offers
   **Expand \*** — the JS rewrites the `*` of the statement at the cursor into the columns the completion map says the person may read, in the
   editor, for the person to run. PHP never rewrites SQL it sends.
4. **The download door of an export is built here** (`GET /exports/{id}/download`, the maker once, `Content-Disposition: attachment`,
   `X-Content-Type-Options: nosniff`, `text/csv; charset=utf-8` / `application/json` / `application/sql`); the exports list (`exports-list`)
   and `export_delete` are slice 10's. Here the run's page shows the export's state and its Download link.
5. **Format is the island's** (`sql-formatter`, the PostgreSQL language, keywords upper-cased, two-space indent); without JavaScript there is
   no Format button.
6. **Saved queries' named parameters are `$1…$n`** with a name, a type hint and an optional default per position in `saved_queries.parameters`
   (`[{"position": 1, "name": "since", "type": "date", "default": null}]`); the values are bound by the door (`run`'s `params` —
   `the-door.md` §1), a one-statement query only. Opening a saved query fills the editor and a parameters form; **it never runs** until Run.

## Who may do what
| Action / screen | Right | Rule (enforced by the door and the database) |
|---|---|---|
| `sql` (open the editor) | `catalog.read` | the target visible (`dx_require_target`); Run is shown only with `data.read` (an application or development target at `masked` or `rows`) or `workbench.use` (the owner's workbench) — otherwise the button reads "Reading rows is an Engineer's" and Explain (slice 6) stays |
| `sql_run` | `data.read` or `workbench.apply` | people only (`require_human()`); the door decides per statement (`the-door.md` §3.5) — the kernel's and memory databases refuse every row; DML and DDL on an application target are refused with the offer |
| `sql_cancel` | own | the door cancels only the caller's own run |
| `sql-history`, `query-run` | own | `audit.read` sees everyone's (the `member` filter appears for an auditor only); the SQL is shown while kept (`sql_text_days`) |
| `saved_query_save` | `queries.save` | agents too (always private — the trigger); `target` optional |
| `saved_query_update`, `saved_query_delete` | own | a shared query is changed only by its owner — copy it |
| `saved_query_verify` | `queries.verify` | people (DBA, admin) |
| `export_make` | `exports.make` | people only; the target visible and the person's level allows the read (`masked` or `rows`); the door re-runs the statement at that level |

## Screens
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `sql` | `/db/{datname}/sql?sql=&saved=&run=` | **desk-first; renders at 375 with the editor full width and each result row as a card.** The header: crumbs Databases › {datname} › SQL, **the class badge in its colour and my level** ("masked for you"), the WRITE MODE bar when it stands (slice 5's partial; Run never writes through it). Left (1280) or above (375): a collapsible list of the schemas and relations I may read (from the completion map), a click inserts the name. The editor (`<textarea name="sql" data-sql-editor>`, the island mounts on it); the toolbar **Run** (Ctrl/⌘-Enter — the statement at the cursor; Shift-Ctrl-Enter the script; with a selection, the selection), **Explain** (slice 6's `plan_explain`; disabled with "Built by slice 6" until then), **Format**, **Save** (→ `saved-add` prefilled), **Export** (a format select; `export_make` for the statement at the cursor). The result area (`#sql-result`): per statement a tab — its status chip, the table (columns with types, each cell escaped, NULL shown as a grey `NULL`, a cut cell "… 12,431 characters — open the full value"), the caps said ("Showing the first 1,000 rows — refine the query or export"), "masked for you" on a refused personal column with **Expand \***; the messages panel (notices, rows affected, time, the tier "read at your masked level"); **an error** — SQLSTATE, message, detail, hint (capped at 500 characters, escaped), the position marked in the editor; **a refusal** — the rule's sentence and the offer: `app_dml` → *Edit these rows in the grid* (the table's grid if one relation is named) · *Save as a migration draft* (`change_set_propose` → slice 4's review, from the editor's text); `app_ddl` → *Save as a migration draft* · *Rehearse on a workbench* (`workbench-add` prefilled with this target as the source); `level` → *Ask an admin for a level* (a mailto-free sentence naming the admins); `window` → *Request a read window* (`window-add`); `kernel` / `memory` → the object pages / the memory section; `function` → the function's name and why. Below: **my last 10 runs on this database** (status, time, first line of SQL, re-open) |
| `sql-history` | `/sql/history?datname=&status=&q=&member=` | my runs as a table (time, database with its badge, status, statements, rows, ms, the first 80 characters of the SQL while kept — searchable by `q` over the kept text); an auditor's `member` filter; paged 50; each row opens `query-run` |
| `query-run` | `/sql/runs/{id}` | one run: who (and on whose behalf, the agent run), the database, source, tier, level, window, status, ms; the SQL while kept (else "SQL text expired after 90 days"), **Open in the editor**; each statement from `door_statements` (class, status, rows, ms, the masked error); the export made from it, if any, with its state and Download. **Results are never stored** — *Run again* re-opens the editor with the SQL |
| `saved-list` | `/saved?q=&datname=&verified=` | saved queries as **cards** (title, database badge or "any database", owner, shared/private chip, **Verified** badge with who and when, or "Unverified — the SQL changed" with the reason); verified first; mine and shared |
| `saved-view` | `/saved/{id}` | the query: title, description, the SQL (read-only, highlighted by the island when present), its parameters, the verification; **Open in the editor** (fills the editor and the parameters form — never runs), Edit, Delete (✔), Verify / Unverify (a DBA) |
| `saved-add` | `/saved/new?sql=&datname=` | `page-header-form`: title (200), description (2,000), the database (the `target` picker over my visible targets, optional), the SQL (the island), parameters (rows of position, name, type hint, default — added when the SQL holds `$n`), shared (a switch) |
| `saved-edit` | `/saved/{id}/edit` | the same form; the owner only; a notice "Saving a change to the SQL drops its verification" when verified |

## Files (exactly these)
- `html/db/sql.php` (the `sql` screen, rewritten from `/db/{datname}/sql`), `html/db/complete.php` (`/db/{datname}/complete.json`)
- `html/sql/{run,cancel,poll,history}.php`, `html/sql/runs/view.php` (`/sql/runs/{id}`)
- `html/saved/{index,view,form,save,update,delete,verify}.php`
- `html/exports/{make,download}.php`
- `app/features/sql/{queries,present,run,completion}.php`, `app/features/saved/{queries,present,write}.php`,
  `app/features/exports/{queries,write}.php` (slice 10 adds its list to the same feature)
- `app/views/sql/{editor,history,run}.php` + `app/views/sql/partials/{result,statement,refusal,messages,recent,catalog-list}.php`,
  `app/views/saved/{index,view,form}.php` + `app/views/saved/partials/card.php`
- `client/editor/{index.ts,completion.ts,format.ts,expand.ts,cancel.ts}` (TypeScript), `client/package.json` + `client/package-lock.json`
  (exact versions: `@codemirror/state`, `@codemirror/view`, `@codemirror/commands`, `@codemirror/language`, `@codemirror/autocomplete`,
  `@codemirror/lang-sql`, `sql-formatter`, `esbuild` — each pinned to a release at least two weeks old at build time), `client/build.mjs`
- `html/assets/developer/{editor.js,editor.css,manifest.json}` — **the committed bundle** (Boards' rule, T26): `manifest.json` records the
  source tree's sha256, every package's version and the build time; `bin/check_bundle.php` fails when the source hash differs from the
  committed bundle's (run by every proof); no CDN, no Node on a server
- `bin/check_bundle.php`
- the worker's `export_jobs` pass in `bin/worker.php` (the skeleton's placeholder filled: queued → `door_ask('export', …)` → done/failed,
  the file under `storage/exports/`, a notification to the maker; expired files deleted by `retention`)
- `tests/phase3/slice3/{run.sh,lib.php,editor.php,refusals.php,cancel.php,history.php,saved.php,exports.php,json.php,browser.mjs}`

## Query functions (signatures fixed)
- `sql_target(PDO $pdo, string $datname): ?array` — the `mcp_target_databases` row as the person (class, colour, label, `my_level`), or null
  → 404 (the same nothing as a database that does not exist)
- `sql_completion(PDO $pdo, int $targetId, string $level): array` — `{schemas: {name: {relations: {name: {kind, columns: [[name, type]]}}}},
  functions: [[schema, name, args]], keywords: [...]}` (the masked rule of divergence 2)
- `sql_run(string $datname, string $sql, string $scope, string $requestId, array $params = []): array` — `door_run()` with `source = 'editor'`,
  after `session_write_close()`; returns the door's answer unchanged for `present_run()`
- `present_run(array $answer, array $target): array` — the view model: per statement columns, rows (escaped in the view), caps, notices, the
  error and its position, the refusal and its offer (a fixed map from `refusal_rule` to the offers above)
- `sql_runs(PDO $pdo, int $memberId, array $filters, int $page): array{rows, total}` · `sql_run_find(PDO $pdo, int $id): ?array` (with its
  statements; the caller's own, or `audit.read`)
- `sql_run_status(PDO $pdo, string $requestId, int $memberId): ?string` — the poll
- `find_saved_queries(PDO $pdo, array $filters, int $page): array{rows, total}` (over `mcp_saved_queries`) · `find_saved_query(PDO $pdo, int $id): ?array`
- `saved_query_write(PDO $pdo, array $fields, ?int $id): int` · `saved_query_delete(PDO $pdo, int $id): void` (sets `deleted_at`) ·
  `saved_query_verify(PDO $pdo, int $id, bool $verified, ?string $reason): void` (wraps `dx_saved_query_verify()` in `dx_guard()`)
- `export_make(PDO $pdo, array $fields): int` — inserts the `exports` row (`kind` result or table, `format`, the SQL or the object address,
  `target_database_id`); the trigger refuses an agent

## MCP tools this slice makes real
`find_saved_queries`, `get_saved_query` (over the saved-queries view; the first is the resolver for a saved query). The records server
sends no typed SQL in this slice: **an agent never runs SQL** (it explains in slice 6 and proposes in slice 4).

## Manifest rows claimed
Screens (7): `sql`, `sql-history`, `query-run`, `saved-list`, `saved-view`, `saved-add`, `saved-edit`
Actions (7): `sql_run`, `sql_cancel`, `saved_query_save`, `saved_query_update`, `saved_query_delete`, `saved_query_verify`, `export_make`

## Activity log events
`sql.run` — `{target, request_id, run_id, status, statements, by_class: {read: n, …}, tier, level, rows, truncated, ms, refusal_rule}` —
**never the SQL, never a value**; `sql.cancel` `{run_id}`; `saved_query.save` / `.update` `{saved_query_id, shared, target, parameters: n,
sql_changed}`; `saved_query.delete` `{saved_query_id}`; `saved_query.verify` `{saved_query_id, verified}`; `export.make` `{export_id,
target, kind, format}` and the worker's `export.done` / `export.failed` `{export_id, rows, bytes, truncated, refusal_rule}` (source `cron`).
Screen views are logged as the kit logs them (`log_screen_view()`), with the target.

## Status vocabulary
A run: `running`, `ok`, `refused`, `error`, `timeout`, `cancelled` (db/009). A statement: the same. An export: `queued`, `running`, `done`,
`failed` (db/011), and on the screen *expired* when `expires_at` has passed. A saved query: **Verified** / **Unverified** (with
`unverified_reason`).

## Out of scope for this slice
Explain and plans (slice 6 — the button is present and disabled until then); the grid and row edits (slice 5 — the refusal's *Edit these rows
in the grid* link opens the grid's placeholder until then); change review and drafts (slice 4 — *Save as a migration draft* creates the change
set through `change_set_propose` once slice 4 exists; until then the offer is shown disabled with "Built by slice 4"); transactions held
open across clicks (Extended); running SQL for an agent (never in version 1); the exports list and deletion (slice 10).

## Proof (`tests/phase3/slice3/run.sh`: scratch `dx_dev3`; php -S on 9401, the fake kernel on 9402, the fakes on 9403; then the user-level Apache on 9407; a scratch door on a scratch socket with `dx_proof_*` roles and scratch targets `dx_t3_app` (an application with a personal and a secret column, a `SECURITY DEFINER` function owned by postgres, a view), `dx_t3_dev` (development, not granted), a workbench made through the door; Playwright and headless Chromium from /var/www/web/node_modules; the registry `--check`; `bin/check_bundle.php`)
- **The pipeline end to end, by the screen**: a `SELECT` of readable columns at `masked` returns rows; the same `SELECT *` is refused with the
  worded 42501 and **Expand \*** rewrites it (browser); at `rows` the personal column reads and the secret one never does; a 2,000-row result
  shows 1,000 and says so; a 9 MB result stops at 8 MB and says so; a 5,000-character cell is cut with its length.
- **Refusals with their offers**: `UPDATE` and `ALTER TABLE` on `dx_t3_app` (the offers' links present), anything on `certstudy`-classed and
  memory-classed fixtures, `SELECT` on a private-by-design target without a read window, `SELECT query_to_xml(…)` and the `SECURITY DEFINER`
  function (rule `function`), `COPY`, `SET ROLE`, `CREATE ROLE`, a psql `\d` (syntax), a script whose third statement is refused (nothing
  ran — `door_statements` has no row for statements 1–2).
- **A workbench script** with `BEGIN … COMMIT`, DDL and DML runs live as the workbench's role; a script ending inside a transaction is rolled
  back and said so.
- **The error marker**: a syntax error in the fourth line of a script marks the right character (browser).
- **Cancel**: `SELECT pg_sleep(…)` is refused by the deny-list, so the long run is a cross join on `generate_series` — Cancel from the page ends
  it as `cancelled` within a second (browser), the run row says so; a second person's cancel of it is refused; a third concurrent run of the
  same person answers `busy`.
- **The audit**: `query_runs` and `door_statements` rows for every run above, refusals included; `pg_stat_activity` showed
  `application_name = developer:<member>:<request>` and the leading comment while the long run ran; `activity_log` rows carry no SQL text
  and no value (a regex over `before`/`after` for the fixture's personal values finds none).
- **Saved queries**: save with `$1` named, open (nothing runs — `query_runs` count unchanged), run with a bound value; a shared query seen by
  another Engineer, a private one not; verify by a DBA, edit the SQL, the badge drops; an agent's `saved_query_save` through the JSON door is
  private whatever it asks; an Engineer's verify refused.
- **Exports**: CSV of a result at `masked` (no personal column in the file), a formula-looking cell neutralised, the cap honoured, JSON and
  SQL `INSERT`s parse back; downloaded once by its maker, refused to another member; an agent's `export_make` refused in SQL.
- **JSON mode**: every action answers `emit_action_status()` with `record_id` (the run, the saved query, the export).
- **375 and 1280** screenshots of `sql` (a result, a refusal), `sql-history`, `query-run`, `saved-list`; no horizontal scroll at 375.
- **The door down**: with the socket gone, Run answers *The database door is not answering* in the result area — never an error page.

## Requirements claimed
MUSTs (40): R7, R38, R39, R40, R41, R42, R43, R45, R46, R67, R68, R69, R71, R72, R86, R88, R91, R94, R101, R102, R103, R104, T11, T12, T13, T14, T15, T20, T23, T26, T27, T31, T41, E16, E17, E18, E19, E20, S8, S10

## Decisions taken here
1. **R43's confirmation** for destructive typed statements applies where they can run — a workbench: a script holding `DROP`, `TRUNCATE`,
   `DELETE`/`UPDATE` without `WHERE` or `ALTER … DROP COLUMN` is classified first (`door_classify`), and the page asks *"This drops
   `public.t` on dxw_3 — type its name to run"* before sending it. On an application target such statements never run (they are offered as
   drafts), so no confirmation is needed there.
2. **E17 is satisfied by the committed bundle** the owner approved with the design (D12): CodeMirror 6, not Monaco; the `<textarea>` fallback
   keeps every function but Format and Cancel.
3. **The result is never stored** — re-running is explicit; the history holds the SQL (while kept) and the counts.
4. **The editor's recent list and the history show the first line of SQL only to its own caller** (and an auditor); a DBA sees another
   person's run as counts.

## Open questions
None — the protocol and the rules are fixed by `the-door.md` and the design.
