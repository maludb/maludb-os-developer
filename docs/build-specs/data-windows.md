# Build spec: data — the grid, the row page, change sets of rows and windows (slice 5)

What exists at the end: **the grid** — a table's or a view's rows a page at a time **at the person's level** on that database (masked or
rows; structure-only people see the structure tab instead), filtered by a builder, a raw `WHERE` and "filter by this value", sorted, the
generated SQL always shown, an estimated count with an exact count on request, foreign-key cells linking to the referenced row, long and
binary values cut with a way to the whole; **the row page** — one record as a full page with NULL, empty and DEFAULT distinct and the rows
that reference it, grouped by foreign key; **staged edits** — inserts, changes and deletes held on the server in a change set that survives
a reload, a sort, a filter, paging and an expired session; **read and write windows** — asked after a fresh sign-on from the launcher,
approved by a super-admin (their own at once, the others told), ended, expired, frozen, with the red **WRITE MODE** bar on every screen while
a write window lasts; and **Apply** inside the person's own write window — one transaction as the write tier, every statement composed with
bound values and keyed by identity and `xmin`, exactly the rows expected, the side-effect check, before-images and one-click **Undo**, the
caps and the backup gate. Design §6.6; change-review.md is the review and state machine; ddl-generators' quoting composes the display SQL.

It replicates slice 4's change path for rows: the grid stages into a change set (origin `grid`), `review-rows` is that change set's rows'
view of the review page, and `change_set_apply` (slice 4's handler) gains the rows branch here.

Schema (db/006, db/010, db/011, db/012): `access_windows`, `dx_window_request()`, `dx_window_decide()`, `dx_window_end()`,
`dx_windows_expire()`, `dx_notify_self_approved_window()`, `change_sets` / `change_set_items` (origin `grid`), `row_images`,
`dx_last_backup()`, `mcp_access_windows`. The door: `grid_page`, `row_get`, `row_value`, `exact_count`, `pick_rows`, `apply`, `undo`, and the
named queries `table_identity` (the primary key or a NOT NULL unique key), `table_write_effects` (triggers and cascading foreign keys),
`relation_sizes`, `fk_graph`.

## Divergences from the design
1. **The staged values need a column: `change_set_items.payload jsonb`** — `{op, schema, table, key, xmin, values}` (the changed columns
   only). db/010 has no such column; **the planning model's additive migration appends it** (never exposed by `mcp_change_set_items`, which
   lists its columns by name; the before-images and the payload are the only stored values, both kept `undo_days` and both behind no read
   role). The item's `statement` keeps the display text with `$n` placeholders.
2. **Undo covers inserts and deletes, not only updates.** The door's Phase 0 `undo` reverses UPDATEs alone, and an insert's image has no
   identity. In this slice the door's `apply` answers each inserted row's identity (`RETURNING` the key columns and `xmin`), and `undo`
   deletes an inserted row (by identity and its `xmin`) and re-inserts a deleted one (from its before-image, the readable columns; a row
   whose unreadable columns had values cannot be re-inserted — that change set's undo is `blocked`, and the page says why before Apply).
3. **Triggers are named up front, cascades refused up front; the side-effect check stays the last word.** Whether a trigger writes
   elsewhere cannot be known without running it (most of the estate's tables carry a `touch_updated_at` trigger that writes nothing else).
   The grid therefore: (a) **refuses deletes up front** on a table referenced by a foreign key with `ON DELETE CASCADE`, `SET NULL` or `SET
   DEFAULT` ("deleting here would change {tables} — use a migration"), and updates of a key column referenced with `ON UPDATE CASCADE`; (b)
   **names a table's user triggers** in the pending bar ("Apply refuses if a trigger writes to another table"); (c) after a refusal for side
   effects, keeps the table's address in **`target_databases.side_effect_tables text[]`** (appended by the same additive migration as Divergence 1) so the grid says it up front next time. The
   door's `pg_stat_xact_user_tables` delta check at Apply is unchanged.
4. **No transaction spans requests** (R45): the only state that does is the staged change set, always visible in the pending bar.

## Who may do what
| Action / screen | Right | Rule |
|---|---|---|
| `grid`, `row-view` | `data.read` (people) | my level on the target is `masked` or `rows` (structure → the page says "structure only for you here — ask an admin" and links the object page); a private-by-design target needs my open **read** window; never kernel, memory, own-for-non-admins, system |
| `row-add`, `row-edit`, `row_stage`, `row_unstage`, `row_resolve_conflict` | `data.write` (people) | a table with an identity (primary key, or a unique key whose columns are all NOT NULL); not a view that is not auto-updatable (`pg_relation_is_updatable`); not an extension member; on a workbench: its owner holding `workbench.apply` (the same grid, applied live) |
| `change_set_apply` (rows) | `data.write` | the trigger: origin `grid`, every item `dml`, my own open write window on this target, the caps; frozen → refused |
| `change_set_undo` | `data.write` | inside my open write window on that target; `undo_state = 'available'`; no later change touched the rows (the door, by `xmin`) |
| `window_request` | `window.request` (people) | the step-up: the session's hand-off within `step_up_minutes` (10); a read window only on a private-by-design target, a write window only on an `application` target; ≤ `window_max_minutes`; one live per person, target and mode |
| `window_decide` | `window.approve` (a super-admin) | never one's own (a super-admin's own opens at once, self-approved, every other super-admin notified) |
| `window_end` | the holder, or `window.approve` | — |
| `window_withdraw` | the holder | only while `requested` |
| `windows-list`, `window-view` | `window.request` (mine) or `window.approve` (all) | — |

## Screens (tables for rows; 1280 for the grid, which becomes one record per card at 375; the row page, the windows and review-rows read at 375 first)
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `grid` | `/db/{datname}/o/{address}/data?where=&filter[]=&sort=&page=` | header: the target's class badge, colour and **my level** ("masked: personal columns hidden"), the WRITE MODE bar if open; **the filter builder** (column, operator — `=`, `<>`, `<`, `>`, `<=`, `>=`, `is null`, `is not null`, `like`, `ilike`, `in` —, value; rows of conditions joined by AND), **the raw WHERE box**, "filter by this value" on a cell's menu, sort by a column head; **the generated SQL** in a `<details>` open by default (display text with values shown as escaped literals, a note "runs with bound values"); a table of `grid_page_rows` (50, at most 200) rows: masked columns as *masked* (not selected at all), long text cut at `cell_chars` with "show all" (`row_value`), binary as "bytea · 12.4 kB" with a link to the row page, NULL as a muted `NULL`, a foreign-key cell a link to the referenced row; the count "≈ 38,201 rows (estimated)" and **Count exactly** (capped: "more than 100,000"); with `data.write`: per row Edit / Delete (stage), **New row**, and **the pending bar** "N pending — Review · Discard · Apply" (sticky, from the change set held on the server); a keyless or non-updatable table says why it is read-only |
| `row-view` | `/db/{datname}/o/{address}/rows/{key}` | one row: every readable column as a definition list — NULL, empty string and DEFAULT shown distinctly; generated columns marked read-only; jsonb pretty-printed (escaped); bytea as size + a 256-byte hex preview + Download; a foreign key as a link to its row; **Referenced by** — per foreign key that points here, a table of up to 10 referencing rows with a link to the rest (the grid filtered); Edit / Delete with `data.write`. `{key}` is the identity, URL-encoded JSON of `{column: value}` |
| `row-add` | `/db/{datname}/o/{address}/rows/new` | a field per insertable readable column: typed inputs from the catalog (enum and domain choices from the catalog, booleans as a three-way NULL/true/false, numeric and timestamp as text the server casts, jsonb as a text area the server casts), **Set NULL** and **Set DEFAULT** explicit on each; a foreign key through **the record picker over the referenced table** (`pick_rows` at my level; the display column the referenced table's first readable `text`/`varchar` column, else the key); identity `ALWAYS` needs "Override the identity" ticked (logged); Stage |
| `row-edit` | `/db/{datname}/o/{address}/rows/{key}/edit` | the row's fields as `row-add`, filled; **only fields I change are sent** (each field carries its original value and a changed flag; an unchanged field is never in `values`), the `xmin` read with the row carried hidden; Stage |
| `review-rows` | `/changes/{id}/rows` | the change set's rows: new (green), changed (amber, each changed column old → new), deleted (red), against their before-images as read at staging; the count and the caps — at or under 1,000 "Apply 2 changes", above it **type the count**, above 10,000 refused; the backup gate ("last backup of subello_gl 3 h ago" or the refusal); the side-effect warnings; **Apply** inside my write window (✔ naming the database), Discard, Back to the grid |
| `conflict` | `/changes/{id}/conflict` | for each conflicting item: **mine** (what I staged) beside **theirs** (the row as it is now, read at my level) and what changed; **Keep mine** (re-stage on their `xmin`) or **Drop mine** |
| `windows-list` | `/windows?state=&datname=` | mine (state, database, mode, reason, minutes left); for a super-admin, **Awaiting approval** first (who, where, why, the step-up time, Approve / Refuse with a note) and every open window |
| `window-add` | `/windows/new?datname=&mode=` | the target (picker: application targets for write; private-by-design targets for read), mode, minutes (default `window_default_minutes`, at most `window_max_minutes`), reason (500); **when my hand-off is older than `step_up_minutes`**, the form is replaced by "Sign in again from the launcher to open a window" and a link to the kernel's `/launch/{application id}` with a return path — the step-up |
| `window-view` | `/windows/{id}` | who, where, mode, why, requested, decided by (self-approved said), starts, expires (minutes left), ended (by whom: the person, expiry, freeze, a super-admin); the change sets applied under it (links); **End now** |

**The WRITE MODE bar** — `app/views/shared/write-mode.php`, built here and included by the shell's layout on every screen when the person has
an open write window: `bg-danger text-white`, "WRITE MODE · subello_gl · 47 min · **End now**" (one bar per open write window), refreshed
by `HX-Trigger: windowChanged` and a minute's poll of `GET /windows/mine.partial`.

## Files (exactly these)
- `html/db/object-data.php` (the grid), `html/db/object-rows.php` (row-view, row-add, row-edit by `?key=`/`new`/`edit`), `html/db/object-rows-page.php`
  (the grid's page partial door), `html/db/object-row-value.php` (the long-value door)
- `html/data/{stage,unstage,resolve}.php`, `html/changes/{rows,conflict,undo}.php` (and the rows branch inside slice 4's `html/changes/apply.php`)
- `html/windows/{index,form,view,request,decide,end,withdraw,mine}.php` (`mine.php` the bar's partial)
- `app/features/data/{grid,rows,stage,apply,undo,present}.php`, `app/features/windows/{queries,present,write}.php`
- `app/views/data/{grid,row,row-form,review-rows,conflict}.php` + `app/views/data/partials/{filters,sql,page,cell,pending-bar,referenced-by,field,masked}.php`
- `app/views/windows/{index,form,view}.php` + `partials/{row,approval,step-up}.php`; `app/views/shared/write-mode.php`
- `app/pickers.php` gains `referenced_row` (rows of the referenced table through the door's `pick_rows`, at my level; params `datname`, `table`)
- `tests/phase3/slice5/{run.sh,lib.php,grid.php,rows.php,stage.php,apply.php,undo.php,conflict.php,caps.php,windows.php,stepup.php,walls.php,json.php,browser.mjs}`

## Query functions / door calls (signatures fixed)
- `grid_page(string $datname, string $address, array $filters, ?string $where, ?string $sort, int $page, int $size, int $memberId): array{columns, rows, masked, sql_display, estimate, identity, write_effects}` — door `grid_page`: the door composes `SELECT <readable columns>, xmin::text FROM <t> WHERE <builder> AND (<raw>) ORDER BY … LIMIT/OFFSET` with `psycopg.sql.Identifier`, the builder's values bound; **the raw WHERE** is parsed inside the carrier `SELECT 1 FROM <t> WHERE <raw>` and refused unless it is exactly that one `SelectStmt` with only a `whereClause`, its functions screened (no subquery naming another relation the tier cannot read gets further than PostgreSQL's own refusal); run at my tier inside `READ ONLY` with `screen_timeout_seconds`
- `exact_count(string $datname, string $address, array $filters, ?string $where): array{count, capped}` — `SELECT count(*) FROM (SELECT 1 … LIMIT 100001)`
- `row_get(string $datname, string $address, array $key): ?array{row, xmin, referenced_by}` · `row_value(string $datname, string $address, array $key, string $column): array{value, length, binary}`
- `pick_rows(string $datname, string $table, string $q, int $page): array` — the referenced table's rows by its display column, at my level
- `row_stage(PDO $pdo, int $by, string $datname, string $address, string $op, ?array $key, ?string $xmin, array $values, bool $overrideIdentity): int` —
  finds or makes my one open grid change set on that target (`draft`, origin `grid`), appends an item with `payload` and the display
  `statement`; refuses a column I may not write, a generated column, a key change referenced with `ON UPDATE CASCADE`, a delete refused up
  front (Divergence 3)
- `row_unstage(PDO $pdo, int $itemId, int $by): void` · `row_resolve_conflict(PDO $pdo, int $itemId, int $by, string $keep): void`
- `change_set_apply_rows(PDO $pdo, int $id, int $by, ?int $typedCount): array{status, rows, conflicts?, side_effects?}` — PHP: the change set
  `reviewed` (marking it if still `draft`), `row_count` set, the backup gate above the confirm cap (`dx_last_backup()` newer than
  `backup_max_age_hours`), then change-review's "Apply" order: the state set to `applied` with `window_id` in an open transaction (the
  trigger), the door's `apply` with the payloads, commit on `ok` with the before-images written to `row_images` and `undo_state = 'available'`;
  a `conflict` answer → rollback, the items marked, the `conflict` screen; a `side_effects` answer → rollback, `failed` with the tables named
- `change_set_undo(PDO $pdo, int $id, int $by): array{status}` — a new change set (origin `grid`, `undo_of` = the original) applied in my
  window through the door's `undo` with the images; the images marked `undone_at`, the original `undo_state = 'used'`; refused `changed_since`
  → `blocked`
- `window_request(PDO $pdo, int $by, string $datname, string $mode, int $minutes, string $reason): int` — `dx_window_request()` with the
  session's recorded hand-off time; a super-admin's own → `dx_notify_self_approved_window()`; else every super-admin gets a `window_request`
  notification (and a K6 text if opted in)
- `window_decide(PDO $pdo, int $id, int $by, bool $approve, ?string $note): void` · `window_end(PDO $pdo, int $id, int $by): void` · `window_withdraw(PDO $pdo, int $id, int $by): void`
- `my_open_write_windows(PDO $pdo, int $memberId): array` — the bar's model

## MCP tools this slice makes real
`windows`.

## Manifest rows claimed
Screens (9): `grid`, `row-view`, `row-add`, `row-edit`, `review-rows`, `conflict`, `windows-list`, `window-add`, `window-view`
Actions (8): `row_stage`, `row_unstage`, `row_resolve_conflict`, `change_set_undo`, `window_request`, `window_withdraw`, `window_decide`, `window_end`

## Activity log events
`row.stage` (op, the table's address, the count of changed columns — **never a value, never the key's values**: the key is logged as its
column names), `row.unstage`, `row.resolve_conflict` (keep), `change_set.apply` (rows, the window id, ms; the before-images' count),
`change_set.undo`, `window.request` (mode, minutes; the reason's length), `window.decide` (approve, self-approved), `window.end` (by kind),
`window.withdraw`, `window.expired` (source `cron`), `grid.view` (the address, the level, rows shown — every grid page on a private-by-design
target also names the window), `row.view` (the address, the window on a private target), `row.value` (a long value opened — the column's
name). Every row carries `target_database_id`.

## Status vocabulary
Levels: `structure` `text-bg-light border`, `masked` `text-bg-warning`, `rows` `text-bg-danger` "rows (unmasked)". Pending: new
`table-success`, changed `table-warning` (the changed cell bold), deleted `table-danger` with strike-through. *masked* in `text-muted fst-italic`.
`NULL` `text-muted`. Windows: `requested` `text-bg-warning`, `open` `text-bg-danger` (write) / `text-bg-warning` (read), `refused`
`text-bg-secondary`, `ended`/`expired`/`withdrawn` `text-bg-light border`, "self-approved" `text-bg-info`. Undo: `available`, `used`,
`blocked` `text-bg-warning`, `expired`. Ids: `grid-filter-{n}`, `grid-where`, `grid-sql`, `grid-row-{n}`, `grid-cell-{n}-{column}`,
`grid-count-exact`, `grid-new-row`, `pending-bar`, `pending-review`, `pending-discard`, `pending-apply`, `row-field-{column}`,
`row-field-{column}-null`, `row-field-{column}-default`, `row-referenced-{constraint}`, `review-rows-typed-count`, `review-rows-apply`,
`conflict-keep-{item}`, `conflict-drop-{item}`, `window-request`, `window-approve-{id}`, `window-refuse-{id}`, `window-end-{id}`,
`write-mode-bar`, `write-mode-end-{id}`, `step-up-launch`.

## Requirements claimed
MUSTs (31): R21, R22, R23, R25, R26, R27, R28, R29, R30, R31, R32, R36, R45, R67, R68, R69, R70, R72, T13, T17, T18, T19, S6, S10, S16, S17, S23, S24, S26, E11, E16

(R36: "edit all matching rows" is never offered in the grid — the page links to slice 4's form, which drafts a migration with the exact
count. R70: an `application` target's grid is read-only until a write window, every write confirmed, the window short. T13: the door's
cursor caps the page. S17: the backup gate above the confirm cap. S26: personal columns are unselectable at `masked` by the tier's privileges.)

## Out of scope for this slice
Typed `INSERT`/`UPDATE`/`DELETE` against an installed application (never — the editor offers the grid or a draft, slice 3); CSV import into
an application's tables (Extended); editing through a view's `INSTEAD OF` trigger (refused — a trigger writes elsewhere); large objects
(`lo_*` refused by the function screen); side effects applied knowingly (Extended).

## Proof (`tests/phase3/slice5/run.sh`: scratch database `dx_dev5`; php -S on 9401, the fake kernel on 9402, the fakes on 9403; then the user-level Apache on 9407; Playwright from /var/www/web/node_modules; scratch roles `dx_proof_*` and scratch targets `dx_t5_app` (an application with personal and secret columns, a cascade, a `touch_updated_at` trigger and a trigger writing an audit table) and `dx_t5_mail` (private by design), a running scratch door and grants service; the registry `--check`)
1. The grid per level: Priya (`masked`) sees `email` as *masked* and `WHERE email LIKE 'a%'` refused by PostgreSQL in the person's words;
   Dana (`rows`) sees `email` but never `password_hash`; Bea (structure) sees the structure-only page; the kernel's database refuses.
2. Filters, raw WHERE (a `; DROP TABLE` refused by the carrier's parse; a function on the deny-list refused), "filter by this value",
   sort, paging; the generated SQL shown; count estimated then exact; a 10,000-character text cut and shown whole; bytea as size + hex.
3. Staging survives a reload, a sort, a filter, paging and a new session; only changed columns are in the payload; NULL/empty/DEFAULT round
   trip; numeric `0.1000`, jsonb key order and a timestamptz with microseconds are written back exactly when untouched (never).
4. Apply outside a window → the trigger's sentence; the step-up: a hand-off 20 minutes old cannot request; after a fresh hand-off Dana
   requests 30 minutes; Marco (admin role, not super) cannot approve; the owner approves; the WRITE MODE bar shows on every screen.
5. Apply: 2 rows ok, before-images written; a row changed by a second session → the conflict screen → keep mine applies; the audit-writing
   trigger's table → `side_effects` refused naming the audit table, then refused up front next time; a delete on a table with a cascade
   refused up front; 1,500 rows needs the typed count and a backup mark newer than 24 h; 12,000 refused.
6. Undo: an update undone; a delete re-inserted; an insert deleted; a row changed after the apply → `blocked`.
7. Windows: a read window on `dx_t5_mail` lets Dana read masked rows; ended → structure again; expired by the worker; frozen → every window
   ends and the bar goes; a super-admin's own window opens at once and the second super-admin is notified.
8. Agents: every action and screen of this slice refuses an agent's token (`people`); `windows` (MCP) answers an agent nothing.
9. JSON mode; 375 px — the grid as cards, the row page, review-rows and the windows without horizontal scroll.

## Decisions taken here
1. `change_set_items.payload` holds the staged values (Divergence 1 — an additive migration).
2. Undo covers inserts and deletes; a deleted row with unreadable values cannot be undone and says so before Apply.
3. Cascading deletes are refused up front; triggers are named and judged by the side-effect check, a refused table remembered.
4. One open grid change set per person per target.

## Open questions
None.
