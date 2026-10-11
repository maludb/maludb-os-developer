# Developer Action Manifest

2026-10-11 · **Phase 1, for the checkpoint**

> The registry the command bar (through the kernel's chat endpoint), the kernel's Actions MCP and the screens resolve against. A screen
> or action missing here cannot be reached by voice or by an agent — unfinished design, like a question with no tool. Pairs with `db/`
> (tables and functions), `docs/developer-mcp-tool-surface.md` (the read tools) and the specs in `docs/build-specs/`.
> `bin/build_action_registry.php` generates `mcp/action_registry.json` from this file; an action whose file does not exist yet is
> registered but not exposed. **The approval categories here ARE `maludb-os.json` `approvals[]` — and there are none** (design §5): an
> agent's risky action is **refused** (the Agent column says `people`, the handler calls `require_human()`, and the right's `held_by` says
> the same in SQL), never paused. `php bin/build_action_registry.php --check` (in every proof) fails when the registry or the approvals are
> stale. The installer reads the resolve block from `deploy/kernel-registry-developer.json`.

## Conventions

### Screens
- **Ids** are kebab-case: `{entity}-list`, `{entity}-add`, `{entity}-view`, `{entity}-edit`, plus named screens.
- **A target is named by its database name** (`{datname}`, `^[a-z0-9_]+$` — wall 1); **an object by its address** (`{address}`): the
  object's type and its identity as `pg_identify_object_as_address()` gives them, written `<type>:<identity>` and URL-encoded —
  `table:public.invoices`, `index:public.invoices_customer_idx`, `function:public.post_entry(bigint,date)`, `column:public.invoices.memo`.
  An address survives a restore; an OID never leaves a request (design §6.3). Saved queries, change sets, workbenches, drafts, runs,
  plans, windows, jobs and exports are integer ids.
- **Canonical URLs** need the rewrites in `deploy/apache-developer.conf` (and `tests/dev_router.php`), Phase 2:
  `/db/{datname}` → `db/view.php?datname=`; `/db/{datname}/{page}` → `db/{page}.php?datname=` (`sql`, `activity`, `health`, `history`,
  `diagram`, `bloat`, `indexes`, `vacuum`, `classifications`, `join-path`, `changes`); `/db/{datname}/s/{schema}` → `db/schema.php`;
  `/db/{datname}/s/{schema}/{family}` → `db/family.php`; `/db/{datname}/o/{address}` → `db/object.php` and
  `/db/{datname}/o/{address}/{page}` → `db/object-{page}.php` (`ddl`, `dependencies`, `privileges`, `statistics`, `impact`, `history`,
  `data`, `rows/{key}`); `/forms/{datname}/{family}/{verb}` → `forms/form.php`; `/memory/{datname}/{schema}[/{page}]` →
  `memory/tenant.php` / `memory/{page}.php`; `/roles/{role}` → `roles/view.php`; and the estate's `/{x}/new` → `form.php`, `/{x}/{id}/edit`
  → `form.php?id=`, `/{x}/{id}` → `view.php?id=`, `/{x}/{id}/{page}` → `{page}.php?id=`.
- **Reading screens are designed at 375 px first** (the estate, objects, DDL, dependencies, activity, the plan table, history, change
  review); **the editor, the grid, the forms, compare and the diagram are desk screens at 1280 px** that still render at 375 without
  horizontal scroll (the grid becomes one record per card; the diagram becomes the list of foreign keys). No screen is a modal: the record
  picker and `hx-confirm` are the two sanctioned exemptions.
- **Every screen that names a target shows its class badge, colour and the person's level on it** in the header and in every confirmation;
  **the red WRITE MODE bar** (`WRITE MODE · subello_gl · 47 min · End now`) stands on every screen while the person's write window lasts.
- **Prefill params** become query-string values the GET controller reads.
- **Every screen partial stamps** `data-screen`, `data-entity`, `data-record-id`, and **`data-datname` and `data-address`** where it names a
  target or an object, on `#page-content` — so "what depends on this", "explain this", "draft an index for this" resolve against the page
  the person is on. The editor also stamps the statement at the cursor's position (`data-sql-at`, never the whole script) for the command bar.
- **Doors that are not screens** have no row here:
  - `GET /sql/runs/{id}/poll` — a running statement's status every second, with the Cancel button's state (slice 3);
  - `GET /db/{datname}/complete.json` — the editor's completion map from the catalog index, only what the person may read (slice 3);
  - `GET /db/{datname}/o/{address}/data/rows?page=` — the grid's page partial (slice 5); `GET /db/{datname}/o/{address}/rows/{key}/value?column=`
    — one long or binary value in full, at the person's level (slice 5);
  - `GET /sessions/poll?datname=` — the activity screen's 5-second refresh (slice 7); `GET /maintenance/{id}/progress` and
    `GET /rehearsals/{id}/progress` — progress by polling (slices 7, 4);
  - `GET /drafts/{id}/download` — the draft as `NNN_<slug>.sql` (slice 4); `GET /exports/{id}/download` — once, to its maker (slice 10);
  - `GET /plans/{id}/json` — "Copy JSON", the plan's only export (slice 6); `GET /diagrams/svg?…` — the Graphviz SVG (slice 8);
  - `GET /pick/{table}` — the record picker over a referenced table (slice 5) and over members (slice 1); `/sso`, `/sso/logout`,
    `/api/v1/health`.

### Actions
- **Name** `{entity}_{verb}`. The **log event** `{entity}.{verb}` is what the handler writes with `log_activity()` — with
  `target_database_id` on every row that concerns a target and never SQL text or a value (design §6.10). No action pauses, so no log
  event needs keeping apart from another for the kernel's policies; they stay distinct anyway.
- **Endpoints** are POST to the file given, with `dx_handler_begin()` (`require_post()`, `require_login()`, `verify_csrf()` or the relayed
  action token), the right (`require_right()`), **`require_human()` on every `people` row**, and — where the action names a target —
  `dx_require_target($datname)`, which answers 404 for a target the person's class and level do not show (the same nothing as a database
  that does not exist). Every handler wraps the database's own function in `dx_guard()` (`dx_window_request()`, `dx_classify_confirm()`,
  the change-set triggers …) **or the door's client** (`app/developer/door.php`, which never opens a database connection to a target),
  then calls `log_activity()`, `emit_action_status()` and `dx_done()`.

  **PHP never re-implements a rule the database or the door keeps:** the class ceilings, the levels, the windows and the step-up, the
  change-set state machine, the caps, the classifier, the freeze, which tier runs a statement. A create's `location` ends in the new
  record's id.
- **Params:** **bold** = required; `[]` = repeated; parentheses = a hint (no comma or semicolon inside; no note after the last parameter).
  A param named for a record accepts an id or a name, resolved through the tool surface's resolvers: `target` (a database name),
  `workbench`, `change_set`, `saved_query`, `draft`. These are ids or literal values only: `object` (an address), `item`, `window`, `run`,
  `plan`, `job`, `export`, `notification`, `finding`, `snapshot_object`, `layout`, `pid`. `any field of X` means X's fields, all optional: a
  partial update.
- **Who** is enforced in the endpoint: **a right** held through `dx_has_right()` (design §3, db/004 — `catalog.read`, `data.read`,
  `workbench.apply`, `data.write`, `access.manage`, …), **`own`** (the caller's own), or **`owner`** (a workbench's owner). Rights held
  `super_admins` are a super-admin's whatever roles they hold; rights held `people` are never an agent's. The target's class and the
  person's level are checked by the database and the door, not by this column.
- **Agent**: `yes` admits an agent's run token; `people` means the handler calls `require_human()` and the right is `people`- or
  `super_admins`-held, so an agent is refused twice. **Exactly five actions are `yes`** (design §5): `change_set_propose`,
  `migration_draft_create`, `rehearsal_run`, `saved_query_save` and the Advisor's `dba_note_post`. An evaluation run (`is_eval`) is refused
  every one of them by the kernel's actions server and again by the handler (rehearsals included — design §5).
- **Undo** is the inverse; `restore prior` means the same action with the earlier values; `—` means it cannot be undone and the reply says
  so. A change set applied to rows is undone by `change_set_undo` while no later change touched those rows (design §6.6).
- **Confirm (✔)** = the command bar and the screen ask first (`hx-confirm`, the target's class badge in the question): it destroys, it
  widens or narrows who reaches a database, it writes to an installed application, it signals another session, or it freezes the tool.
  A ✔ that destroys a workbench or applies a `DROP`/`TRUNCATE` there also needs the name typed back.
- **record_id** is what the JSON answer's `record_id` names: the record made (a create) or acted on.
- **Refresh:** a target action returns `HX-Trigger: targetChanged`, a change-set action `changeSetChanged`, a window action
  `windowChanged` (the WRITE MODE bar listens), a session action `sessionsChanged`.
- **Log payloads** (`before`/`after`) carry ids, classes, targets, levels, counts by statement class, row counts, tiers and refusal rules —
  **never SQL text, never a value, never a column's content, never a path or a key**.

### Result contract
```json
{"status": "success", "did": "Proposed an index on invoices(customer_id) for subello_gl — awaiting a person's review", "record_id": 412, "refresh": "changeSetChanged"}
{"status": "refused", "did": "This changes the schema of an installed application: save it as a migration draft", "errors": {"target": "subello_gl is an application database"}, "rule": "app_ddl"}
{"status": "refused", "did": "Agents read no rows", "errors": {"agent": "this action is a person's"}, "rule": "agent"}
{"status": "success", "did": "Applied 2 row changes to subello_gl inside your write window (31 minutes left)", "record_id": 77, "undo_id": "change_set_undo:77"}
```

## The shell (Phase 2 — sso-shell)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `home` | `/` | the search box, my favourite and recent objects, my workbenches and their expiry, change sets awaiting me, drafts not yet observed applied, my open windows; a DBA's blocked sessions and findings; an admin's unclassified databases, pending grants, window requests, the door's state and the freeze switch |
| `me` | `/me` | who I am here: my roles and rights, my levels on each database, my open windows |
| `my-trail` | `/me/trail` | my own trail here: what I ran, changed, drafted and opened, on which databases (params: `since`, `datname`) |

Actions: none — the shell changes nothing on its own (no personal tokens in version 1, design §4).

## The estate, access and the object browser (slice 1 — the CRUD exemplar)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `databases-list` | `/databases` | every database I may see, as cards by class: name, application, size, colour, private flag, grants state (params: `class`, `q`, `application`) |
| `database-view` | `/db/{datname}` | one database's overview: version, size by schema, extensions against their defaults, non-default settings, my level, its verb tabs |
| `schema-view` | `/db/{datname}/s/{schema}` | one schema: its object families with counts |
| `family-list` | `/db/{datname}/s/{schema}/{family}` | a paged, filtered table of one family's objects (params: `q`, `owner`, `page`) |
| `object-view` | `/db/{datname}/o/{address}` | one object's page: its tabs — a table's columns, constraints, indexes, triggers, policies and partitions; the danger zone at the foot |
| `search` | `/search` | where is the object called X — names, columns, types and comments across every database I may see (params: `q`, `class`, `family`, `datname`) |
| `favourites` | `/favourites` | my favourite and recent objects |
| `registry-list` | `/admin/registry` | every database the cluster has, proposed and confirmed classes, the root step still owed while grants are pending (params: `class`, `state`) |
| `registry-entry` | `/admin/registry/{datname}` | one database's registry entry: class, application, private flag, colour, label, hidden, notes, grants per table |
| `access-list` | `/admin/access` | who holds which level on which database, people and roles (params: `datname`, `member`) |
| `access-target` | `/admin/access/{datname}` | one database's levels: grant masked or rows to a person or a role, revoke |
| `classifications` | `/db/{datname}/classifications` | the columns of a database classified secret or personal, proposed or confirmed, to confirm or clear (params: `state`, `class`) |

Actions (base `/admin/registry/`, access under `/admin/access/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `registry_confirm` | `/admin/registry/confirm.php` | **target**, **class** (application or development or memory or unclassified), application_key (for application or development) | restore prior | ✔ | | `registry.confirm` | registry.manage | people | the target |
| `registry_update` | `/admin/registry/save.php` | **target**, label (up to 60 characters), colour (a hex colour), private_by_design (yes or no), hidden (yes or no), notes | restore prior | | | `registry.update` | registry.manage | people | the target |
| `registry_discover` | `/admin/registry/discover.php` | — | — | | | `registry.discover` | registry.manage | people | none |
| `access_grant` | `/admin/access/grant.php` | **target**, member (a person — never an agent), role (viewer or engineer or dba or admin), **level** (masked or rows) | access_revoke | ✔ | | `access.grant` | access.manage | people | the access row |
| `access_revoke` | `/admin/access/revoke.php` | **access** (the access row) | access_grant | ✔ | | `access.revoke` | access.manage | people | the access row |
| `classification_confirm` | `/classify/confirm.php` | **target**, **object** (a column address), **class** (secret or personal or none), kind (email or phone or name or address or birth_date or national_id or payment_card or bank_account or ip_address or free_text or compensation or health or other) | restore prior | ✔ | | `classification.confirm` | classifications.confirm (a secret pattern cleared by a super-admin only) | people | the classification |
| `catalog_refresh` | `/catalog/refresh.php` | **target** | — | | | `catalog.refresh` | catalog.read | people | the target |
| `favourite_add` | `/favourites/add.php` | **target**, **object** | favourite_remove | | | `favourite.add` | catalog.read | people | the favourite |
| `favourite_remove` | `/favourites/remove.php` | **favourite** | favourite_add | | | `favourite.remove` | own | people | the favourite |

## Structure, DDL and dependencies (slice 2)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `object-ddl` | `/db/{datname}/o/{address}/ddl` | an object's DDL with its commented DROP, to copy or open in the editor |
| `object-dependencies` | `/db/{datname}/o/{address}/dependencies` | what this object depends on and what depends on it |
| `object-impact` | `/db/{datname}/o/{address}/impact` | what breaks if I drop or alter this object or column: the full reach of CASCADE, the views to drop and recreate in order (params: `column`, `verb`) |
| `object-privileges` | `/db/{datname}/o/{address}/privileges` | who may do what on this object, its owner and the default privileges that apply |
| `object-statistics` | `/db/{datname}/o/{address}/statistics` | a table's or an index's size, row estimate, scans, dead tuples, last vacuum and analyze, column statistics |
| `join-path` | `/db/{datname}/join-path` | how two tables join: the shortest foreign-key path with its column pairs, emitted as a JOIN into the editor (params: `from`, `to`, `ignore`) |
| `roles-list` | `/roles` | the cluster's roles with their attributes (read-only) |
| `role-view` | `/roles/{role}` | one role: attributes, memberships with their inherit and set options, effective privileges per database |

Actions: none — structure is read; every change it offers (the danger zone, a fix) opens a form or Change review (slice 4).

## The SQL workspace (slice 3 — the first exemplar)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `sql` | `/db/{datname}/sql` | the editor on one database: Run, Explain, Format, Cancel; results with the cap and the masks said; messages with the error marker (params: `sql`, `saved`, `run`) |
| `sql-history` | `/sql/history` | my runs (an auditor's: everyone's), searchable by database, class, outcome and text (params: `datname`, `status`, `q`, `member`) |
| `query-run` | `/sql/runs/{id}` | one run: its statements, each statement's status, rows, notices and time, the tier and level it ran at |
| `saved-list` | `/saved` | saved queries, verified first, mine and shared (params: `q`, `datname`, `verified`) |
| `saved-view` | `/saved/{id}` | one saved query, its parameters and its verification — never run implicitly |
| `saved-add` | `/saved/new` | to save a query: title, the SQL, named parameters, the database, shared or private (params: `sql`, `datname`) |
| `saved-edit` | `/saved/{id}/edit` | to change a saved query (the verification drops by itself when the SQL changes) |

Actions (base `/sql/`, saved queries under `/saved/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `sql_run` | `/sql/run.php` | **target**, **sql** (one statement or a script), scope (cursor or selection or script) | — | | | `sql.run` | data.read (a read at my level) or workbench.apply (a workbench) | people | the run |
| `sql_cancel` | `/sql/cancel.php` | **run** | — | | | `sql.cancel` | own | people | the run |
| `saved_query_save` | `/saved/save.php` | **title** (up to 120 characters), **sql**, target, description, shared (yes or no — an agent's are always private) | saved_query_delete | | | `saved_query.save` | queries.save | yes | the saved query |
| `saved_query_update` | `/saved/update.php` | **saved_query**, any field of saved_query_save | restore prior | | | `saved_query.update` | own | people | the saved query |
| `saved_query_delete` | `/saved/delete.php` | **saved_query** | — | ✔ | | `saved_query.delete` | own | people | the saved query |
| `saved_query_verify` | `/saved/verify.php` | **saved_query**, **verified** (yes or no), reason (when no) | restore prior | | | `saved_query.verify` | queries.verify | people | the saved query |
| `export_make` | `/exports/make.php` | **target**, **kind** (result or table), **format** (csv or json or sql), sql (for a result), object (for a table) | export_delete | | | `export.make` | exports.make | people | the export |

## Workbenches, forms, change review and migration drafts (slice 4 — the second exemplar)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `workbenches-list` | `/workbenches` | the workbenches: mine, and every workbench for an admin — cloned from what, size against quota, expiring when |
| `workbench-add` | `/workbenches/new` | a new workbench: empty or a schema-only clone of a database I may see (params: `source`, `title`) |
| `workbench-view` | `/workbenches/{id}` | one workbench: its change log, renew, export as a migration, import a CSV, reset its credential, drop |
| `workbench-import` | `/workbenches/{id}/import` | to load a CSV into a workbench table: the preview, the column mapping, ON_ERROR for type errors |
| `change-form` | `/forms/{datname}/{family}/{verb}` | a form to create, alter or drop a schema, table, column, constraint, index, view, materialized view, sequence, function, procedure, trigger, type, domain, enum, policy or comment — submit is Review (params: `object`, `safe`) |
| `changes-list` | `/changes` | the change log: change sets proposed, reviewed, rehearsed, applied, drafted, discarded or failed (params: `datname`, `state`, `origin`, `author`) |
| `change-review` | `/changes/{id}` | Change review: the SQL, each statement's lock, rewrite and scan with its source, lint, the literals list, Rehearse, the one button the class allows |
| `change-edit` | `/changes/{id}/edit` | to edit a draft change set's title and statements before review |
| `rehearsal-view` | `/rehearsals/{id}` | what a rehearsal measured: per statement the locks taken, whether it rewrote, its time, errors |
| `drafts-list` | `/drafts` | migration drafts as cards per application, observed applied or not (params: `application`, `state`) |
| `draft-view` | `/drafts/{id}` | one draft: the file, Download, Copy, the observed-applied state |

Actions (base `/changes/`, workbenches under `/workbenches/`, drafts under `/drafts/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `workbench_create` | `/workbenches/save.php` | **title** (up to 80 characters), **kind** (empty or clone), source (a database to clone the schema of) | workbench_drop | | | `workbench.create` | workbench.use | people | the workbench |
| `workbench_renew` | `/workbenches/renew.php` | **workbench**, days (up to the setting's expiry) | — | | | `workbench.renew` | owner | people | the workbench |
| `workbench_drop` | `/workbenches/drop.php` | **workbench**, **confirm_name** (the workbench's name typed back) | — | ✔ | | `workbench.drop` | owner or registry.manage | people | the workbench |
| `workbench_reset_credential` | `/workbenches/reset.php` | **workbench** | — | ✔ | | `workbench.reset_credential` | registry.manage | people | the workbench |
| `workbench_import` | `/workbenches/import.php` | **workbench**, **object** (a table address), **file** (a CSV upload), mapping[] (column to field), on_error (stop or ignore) | — | | | `workbench.import` | owner and workbench.apply | people | the workbench |
| `workbench_export` | `/workbenches/export.php` | **workbench**, from_change_set, to_change_set | migration_draft_withdraw | | | `workbench.export` | owner and migrations.draft | people | the draft |
| `change_set_prepare` | `/changes/prepare.php` | **target**, **family**, **verb** (create or alter or drop or truncate), object, fields[] (the form's fields), safe (yes or no) | change_set_discard | | | `change_set.prepare` | changes.prepare | people | the change set |
| `change_set_propose` | `/changes/propose.php` | **target**, **title** (up to 120 characters), **sql** (the statements), reason, origin (editor or health_fix or agent_proposal) | change_set_discard | | | `change_set.propose` | changes.prepare | yes | the change set |
| `change_set_update` | `/changes/update.php` | **change_set**, title, sql (the statements — a draft only) | restore prior | | | `change_set.update` | own | people | the change set |
| `change_set_review` | `/changes/review.php` | **change_set** | — | | | `change_set.review` | changes.prepare | people | the change set |
| `change_set_override` | `/changes/override.php` | **item**, **rule** (the lint rule), **reason** (up to 500 characters) | — | | | `change_set.override` | changes.prepare | people | the change set |
| `rehearsal_run` | `/changes/rehearse.php` | **change_set** | — | | | `rehearsal.run` | changes.prepare | yes | the rehearsal |
| `change_set_apply` | `/changes/apply.php` | **change_set**, typed_count (above the confirm cap), confirm_name (for a DROP or TRUNCATE on a workbench) | change_set_undo | ✔ | | `change_set.apply` | workbench.apply (a workbench, its owner) or data.write (rows in my write window) | people | the change set |
| `change_set_discard` | `/changes/discard.php` | **change_set** | — | ✔ | | `change_set.discard` | own or changes.prepare | people | the change set |
| `migration_draft_create` | `/drafts/save.php` | **change_set** (rehearsed), file_number (the application's next number if known), slug (lowercase words joined by underscores) | migration_draft_withdraw | | | `migration_draft.create` | migrations.draft | yes | the draft |
| `migration_draft_update` | `/drafts/update.php` | **draft**, file_number, slug, notes | restore prior | | | `migration_draft.update` | migrations.draft | people | the draft |
| `migration_draft_withdraw` | `/drafts/withdraw.php` | **draft**, reason | — | ✔ | | `migration_draft.withdraw` | own or migrations.draft | people | the draft |

## Data: the grid, the row page, change sets of rows and windows (slice 5)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `grid` | `/db/{datname}/o/{address}/data` | a table's rows at my level: filters, sort, the generated SQL shown, the pending bar (params: `where`, `filter[]`, `sort`, `page`) |
| `row-view` | `/db/{datname}/o/{address}/rows/{key}` | one row as a full page: values with NULL, empty and DEFAULT distinct, the rows that reference it grouped by foreign key |
| `row-add` | `/db/{datname}/o/{address}/rows/new` | to stage a new row: foreign keys through the record picker, generated columns read-only |
| `row-edit` | `/db/{datname}/o/{address}/rows/{key}/edit` | to stage a change to one row; a value I did not change is never written back |
| `review-rows` | `/changes/{id}/rows` | a change set's rows before Apply: new, changed and deleted, each against its before-image |
| `conflict` | `/changes/{id}/conflict` | a row that changed since I staged it: mine, theirs, keep or drop |
| `windows-list` | `/windows` | my windows, and for a super-admin every request awaiting approval and every window open (params: `state`, `datname`) |
| `window-add` | `/windows/new` | to ask for a read or a write window on one database: mode, minutes, reason — a fresh sign-on first if the last is older than 10 minutes (params: `datname`, `mode`) |
| `window-view` | `/windows/{id}` | one window: who, where, why, who approved, its time left, what it applied |

Actions (base `/data/`, windows under `/windows/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `row_stage` | `/data/stage.php` | **target**, **object** (a table address), **op** (insert or update or delete), key (the row's identity — not for insert), values[] (column to value — only the columns changed) | row_unstage | | | `row.stage` | data.write | people | the change set |
| `row_unstage` | `/data/unstage.php` | **item** | row_stage | | | `row.unstage` | own | people | the change set |
| `row_resolve_conflict` | `/data/resolve.php` | **item**, **keep** (mine or theirs) | — | | | `row.resolve_conflict` | own | people | the change set |
| `change_set_undo` | `/changes/undo.php` | **change_set** | — | ✔ | | `change_set.undo` | data.write (inside my write window) | people | the change set |
| `window_request` | `/windows/request.php` | **target**, **mode** (read or write), **minutes** (up to the setting's maximum), **reason** (up to 500 characters) | window_withdraw | | | `window.request` | window.request | people | the window |
| `window_withdraw` | `/windows/withdraw.php` | **window** | — | | | `window.withdraw` | own | people | the window |
| `window_decide` | `/windows/decide.php` | **window**, **approve** (yes or no), note | — | ✔ | | `window.decide` | window.approve | people | the window |
| `window_end` | `/windows/end.php` | **window** | — | | | `window.end` | own or window.approve | people | the window |

## Plans (slice 6)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `plans-list` | `/plans` | the plans I kept, with their queries and comments (params: `datname`, `q`) |
| `plan-view` | `/plans/{id}` | one plan: the server-rendered tree with the flags first; PEV2 at 1280 (params: `view`) |

Actions (base `/plans/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `plan_explain` | `/plans/explain.php` | **target**, **sql** (one statement), analyze (yes or no — runs it), buffers (yes or no), generic (yes or no — GENERIC_PLAN), comment | plan_delete | | | `plan.explain` | plans.explain (analyze needs data.read) | people | the plan |
| `plan_comment` | `/plans/comment.php` | **plan**, **comment** (up to 500 characters) | restore prior | | | `plan.comment` | own | people | the plan |
| `plan_delete` | `/plans/delete.php` | **plan** | — | ✔ | | `plan.delete` | own | people | the plan |

## Activity and maintenance (slice 7)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `sessions` | `/sessions` | what is running now across the databases I may see: sessions running, waiting and blocking, the root blocker, texts normalized (params: `datname`, `state`) |
| `db-activity` | `/db/{datname}/activity` | the same, for one database |
| `session-view` | `/sessions/{pid}` | one session: its normalized text, waits, the locks it holds and waits on, whom it blocks; cancel and terminate |
| `locks` | `/sessions/locks` | the locks held and awaited, linked to sessions and objects (params: `datname`, `object`) |
| `statements` | `/statements` | the top statements by total time, mean time, calls, rows and I/O, each linking to Explain (params: `datname`, `order`) |
| `server` | `/server` | the server's I/O, checkpointer, WAL and archiver panels |
| `vacuum` | `/db/{datname}/vacuum` | the vacuum and wraparound panel: table ages, dead tuples, last vacuum and analyze, sessions holding the horizon |
| `maintenance-list` | `/maintenance` | maintenance jobs queued, running with their progress, and finished (params: `datname`, `state`) |
| `maintenance-add` | `/maintenance/new` | to queue VACUUM, ANALYZE, REINDEX CONCURRENTLY or REFRESH MATERIALIZED VIEW CONCURRENTLY — the lock it takes said first (params: `datname`, `object`, `operation`) |

Actions (base `/sessions/`, maintenance under `/maintenance/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `session_cancel` | `/sessions/cancel.php` | **target**, **pid** (the backend) | — | ✔ | | `session.cancel` | sessions.cancel | people | none |
| `session_terminate` | `/sessions/terminate.php` | **target**, **pid** (the backend), **reason** (up to 200 characters) | — | ✔ | | `session.terminate` | sessions.terminate | people | none |
| `session_text_open` | `/sessions/text.php` | **target**, **pid** (the backend), **reason** (up to 200 characters) | — | | | `session.text_open` | sessions.cancel | people | none |
| `maintenance_queue` | `/maintenance/queue.php` | **target**, **object** (a table or index or materialized view address), **operation** (vacuum or analyze or vacuum_analyze or reindex_concurrently or refresh_concurrently) | maintenance_cancel | ✔ | | `maintenance.queue` | maintenance.run | people | the job |
| `maintenance_cancel` | `/maintenance/cancel.php` | **job** | — | ✔ | | `maintenance.cancel` | own or maintenance.run | people | the job |

## Health, history, compare and diagrams (slice 8)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `health-all` | `/health` | health findings across the databases I may see, by severity (params: `severity`, `check`) |
| `db-health` | `/db/{datname}/health` | one database's findings, each with its fix as a change set |
| `bloat` | `/db/{datname}/bloat` | bloat estimates for tables and indexes (exact where pgstattuple is installed) |
| `index-advice` | `/db/{datname}/indexes` | unused, duplicate, overlapping and invalid indexes; foreign keys without one |
| `db-history` | `/db/{datname}/history` | what changed in this database since a date, each change attributed to a change set, a draft, the grants service, or unexplained (params: `since`) |
| `object-history` | `/db/{datname}/o/{address}/history` | how an object's definition changed, snapshot by snapshot, with the diff |
| `drift` | `/drift` | unexplained changes across the databases — hand changes nobody made through the tool |
| `compare` | `/compare` | two databases, a database and a workbench, or one database at two snapshots: the inventory and per-object diffs (params: `a`, `b`, `at_a`, `at_b`) |
| `compare-object` | `/compare/object` | one object's normalized DDL on both sides, as a diff (params: `a`, `b`, `object`) |
| `diagram` | `/db/{datname}/diagram` | a focused ER diagram: start from a table, add hops, choose the detail — the list of foreign keys at 375 (params: `start`, `hops`, `detail`, `layout`) |
| `backups` | `/backups` | each database's last recorded backup and WAL archiving state |

Actions (base `/health/`, history under `/history/`, diagrams under `/diagrams/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `health_fix_prepare` | `/health/fix.php` | **target**, **finding** (a finding's key) | change_set_discard | | | `health.fix_prepare` | changes.prepare | people | the change set |
| `drift_explain` | `/history/explain.php` | **snapshot_object** (a change in a snapshot), **note** (up to 500 characters) | restore prior | | | `drift.explain` | maintenance.run | people | the snapshot object |
| `snapshot_take` | `/history/snapshot.php` | **target** | — | | | `snapshot.take` | maintenance.run | people | the snapshot |
| `diagram_layout_save` | `/diagrams/save.php` | **target**, **title** (up to 80 characters), **start** (a table address), hops (1 to 4), detail (names or keys or all), positions (the layout's JSON) | diagram_layout_delete | | | `diagram_layout.save` | catalog.read | people | the layout |
| `diagram_layout_delete` | `/diagrams/delete.php` | **layout** | — | ✔ | | `diagram_layout.delete` | own | people | the layout |

## The memory section (slice 9)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `memory-estate` | `/memory` | every memory database: placement, size, the extension's version against the host's, each tenant's facade version, flags, the owner's printed steps |
| `memory-tenant` | `/memory/{datname}/{schema}` | one memory tenant's health: counts, the embedding backlog and its age, never-indexed documents, the extraction queue, failing facades, configured models |
| `memory-episodes` | `/memory/{datname}/{schema}/episodes` | episode counts by kind, application, day, sensitivity and scope — never a payload |
| `memory-graph-stats` | `/memory/{datname}/{schema}/graph-stats` | the graph's shape: stores, relations, node types, god-node counts, communities and import namespaces |
| `memory-config` | `/memory/{datname}/{schema}/config` | the tenant's models (provider, alias, the secret's name — never a value), skills and the facade reference |
| `memory-isolation` | `/memory/isolation` | the isolation audit: database CONNECT grants, maludb group members, BYPASSRLS logins, FORCE RLS state |
| `memory-graph` | `/memory/{datname}/{schema}/graph` | the graph explorer: subject search, a subject's page, neighbours, a bounded walk, a path — every view logged (params: `q`, `subject`, `walk`, `to`) |
| `memory-documents` | `/memory/{datname}/{schema}/documents` | document, chat and note metadata: source type, namespace, size, indexed when (params: `q`, `kind`) |

Actions (base `/memory/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `memory_reveal` | `/memory/reveal.php` | **target**, **schema** (the tenant schema), **kind** (episode or document), **id** (the episode or document id), **reason** (up to 500 characters) | — | ✔ | | `memory.reveal` | memory.reveal | people | none |

## Agents, exports, notifications, home and admin (slice 10)

Screens:

| Screen id | URL | When the user wants… |
| --- | --- | --- |
| `proposals` | `/proposals` | what the agents proposed — change sets, drafts and notes — and what became of each (params: `agent`, `state`) |
| `notes-list` | `/notes` | the DBA notes the Advisor posted, newest first |
| `note-view` | `/notes/{id}` | one DBA note with its proposals |
| `exports-list` | `/exports` | my exports: made, waiting, ready to download once, expired |
| `notifications` | `/notifications` | my notifications |
| `notification-prefs` | `/me/notifications` | which notices reach me, in-app and by text (opt-in) |
| `admin-settings` | `/admin/settings` | the tool's limits, caps, retention and expiry |
| `audit` | `/admin/audit` | every run through the door, by person, agent, database, class and outcome (params: `member`, `datname`, `status`, `since`) |
| `audit-run` | `/admin/audit/{id}` | one run in full: the SQL (while kept), each statement, the tier, the level, the window |
| `audit-reveals` | `/admin/audit/reveals` | who unmasked, opened a window on or revealed what, when and why |
| `admin-door` | `/admin/door` | the door: its pool, waits, refusals today by rule, its version and libpg_query's |
| `admin-grants` | `/admin/grants` | the grants service: its last pass per database, columns pending, tables not granted to the tool |
| `admin-agents` | `/admin/agents` | the tool's agents: their roles, the targets they may read, their dispatches |
| `admin-worker` | `/admin/worker` | the worker's passes and their outcomes |
| `admin-freeze` | `/admin/freeze` | the freeze switch and its history |

Actions (base `/notifications/`, notes under `/notes/`, exports under `/exports/`, admin under `/admin/`):

| Action | File | Params | Undo | Confirm | Agent approval | Log | Who | Agent | record_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `dba_note_post` | `/notes/post.php` | **title** (up to 120 characters), **body** (markdown — up to 20000 characters), change_sets[] (the proposals it carries) | — | | | `dba_note.post` | health.read | yes | the note |
| `export_delete` | `/exports/delete.php` | **export** | — | | | `export.delete` | own | people | the export |
| `notification_read` | `/notifications/read.php` | **notification** | — | | | `notification.read` | own | people | the notification |
| `notification_read_all` | `/notifications/read-all.php` | — | — | | | `notification.read_all` | own | people | none |
| `notification_prefs_save` | `/notifications/prefs.php` | kinds[] (the notices I want), texts (yes or no — K6 texts for urgent notices) | restore prior | | | `notification.prefs_save` | own | people | none |
| `dispatch_retry` | `/admin/dispatches/retry.php` | **dispatch** | — | | | `dispatch.retry` | settings.manage | people | the dispatch |
| `settings_save` | `/admin/settings/save.php` | screen_timeout_seconds, workbench_timeout_seconds, show_rows, show_bytes_mb, cell_chars, runs_per_person, grid_page_rows, window_default_minutes, window_max_minutes, change_set_confirm_rows, change_set_max_rows, backup_max_age_hours, undo_days, workbench_quota_gb, workbench_expiry_days, workbenches_per_person, sql_text_days, audit_keep_days, export_max_rows, export_max_mb, export_keep_hours | restore prior | ✔ | | `settings.save` | settings.manage | people | none |
| `freeze_on` | `/admin/freeze/on.php` | **reason** (up to 500 characters) | freeze_off | ✔ | | `freeze.on` | freeze | people | none |
| `freeze_off` | `/admin/freeze/off.php` | — | freeze_on | ✔ | | `freeze.off` | freeze | people | none |
