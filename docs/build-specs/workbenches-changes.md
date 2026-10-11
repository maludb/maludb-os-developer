# Build spec: workbenches, forms, Change review and migration drafts (slice 4 — THE SECOND EXEMPLAR)

What exists at the end: **workbenches** — a person's own database `dxw_<n>` with its own login role, empty or a schema-only clone of a
database they may see, renewable, dropped by name, its credential reset by a super-admin, a CSV loaded into one of its tables; **the forms**
for every changeable family (ddl-generators "The forms' fields"), each a full page whose submit is **Review**; **change sets** with the rule
table's annotations, squawk's lint and the literals list; **rehearsals** measured on a throwaway clone; **Apply on a workbench** with lock
timeouts and the blockers; **migration drafts** downloaded as the application's next numbered file; **Export a workbench as a migration**;
and **observed applied** marked by the worker. Design §6.5; **`docs/build-specs/change-review.md` is this slice's engine** — its state
machine, page, lint, rehearsal, Apply and draft rules are built here; `docs/build-specs/ddl-generators.md` builds the SQL.

**This slice is Developer's second exemplar** — the change-control path every later change copies: a form → `change_set_prepare` → Change
review → Rehearse → the class's one button. Slice 5's grid edits, slice 8's health fixes, slice 3's "Review as a change set" and every
agent's proposal end on this slice's review page and go through its state machine; their specs name only what differs. The handler order is
slice 1's (`dx_handler_begin()` → `require_right()` → `require_human()` on a people row → `dx_require_target()` → `dx_guard()` around the
database function or the door's client → `log_activity()` → `emit_action_status()` → `dx_done()`).

Schema (db/010, db/012, never modified here except by an additive migration the planning model writes): `workbenches`, `change_sets`,
`change_set_items`, `rehearsals`, `migration_drafts`, the trigger `dx_change_sets_before()`; `mcp_workbenches`, `mcp_change_sets`,
`mcp_change_set_items`, `mcp_rehearsals`, `mcp_migration_drafts`. The door: `workbench_create`, `workbench_drop`, `workbench_reset`,
`rehearse`, `run` (a workbench's change set), `classify`, `lint`, `import`, and the named queries `object_ddl`, `relation_sizes`,
`type_resolve`, `type_change_rewrites`, `blocking`, `migration_ledger`.

## Divergences from the design
1. **CSV import runs in the worker, not in the request** (R102, T24): `workbench_import` stores the uploaded file under
   `storage/imports/{change_set_id}.csv` (0600, the web user's), records a change set (origin `import`, the one item `COPY … FROM STDIN`,
   state `reviewed`) and the worker's new pass **`imports`** applies it through the door's `import` as the owner (`app.member_id` = the
   owner — the trigger's "applied by the person acting"), then deletes the file. The page polls the change set's state. **bin/worker.php gains
   the `imports` pass** (the fourteenth).
2. **A workbench's `kind = clone` needs the source's grants in place** (the door refuses a source whose `grants_state` is not `in_place` or
   `partial`: the clone dumps as `developer_ops`, which holds `MAINTAIN` only once `grant-target.sh` ran). The form says so and names the
   owner's root step.
3. **Workbench titles are 80 characters in the form** (the manifest's) though the column takes 200.
4. **Agents have no workbenches and no forms** — `workbench_*`, `change_set_prepare`, `change_set_apply` are people rows; an agent's change
   arrives through `change_set_propose` (and is marked an agent's everywhere).
5. **Rehearsal results carry the created and altered objects' DDL fingerprints** (`objects: [{address, ddl_sha256}]`) — the door's
   `rehearse` gains that answer in this slice (change-review "Rehearse"); the observed-applied check needs it.

## Who may do what
| Action | Right | Rule (the trigger's or the door's) |
|---|---|---|
| `workbench_create` | `workbench.use` (people) | at most `workbenches_per_person` (5) — the trigger; a clone's source visible to me with grants in place — the door; a database using an untrusted extension clones only through `dx_template` |
| `workbench_renew` | the owner | up to `workbench_expiry_days` from now |
| `workbench_drop` | the owner, or `registry.manage` (a super-admin) | the workbench's name typed back exactly |
| `workbench_reset_credential` | `registry.manage` (a super-admin) | the door's lifecycle resets the role's password; the workbench is reachable again |
| `workbench_import` | the owner + `workbench.apply` | a table of that workbench; the file ≤ `export_max_mb` |
| `workbench_export` | the owner + `migrations.draft` | the workbench cloned from an `application` target |
| `change_set_prepare` | `changes.prepare` (people — the forms are a person's screens) | the target visible to me; the family changeable (not an extension member, not a system schema) |
| `change_set_propose` | `changes.prepare` (people and agents) | an agent's becomes `agent_proposal`; a kernel, memory or own target refused by the door |
| `change_set_update` | the author | state `draft` only |
| `change_set_review`, `change_set_override` | `changes.prepare` | every lint error overridden with a reason before review |
| `rehearsal_run` | `changes.prepare` (people and agents) | application or development target with grants in place; never `is_eval` |
| `change_set_apply` | `workbench.apply` (a workbench's owner) or `data.write` (rows, slice 5) | the trigger, the freeze, the typed name for DROP/TRUNCATE |
| `change_set_discard` | the author, or `changes.prepare` | not once applied or drafted |
| `migration_draft_create` | `migrations.draft` (people and agents) | the change set `rehearsed` on an `application` target |
| `migration_draft_update` | `migrations.draft` (people) | the number and slug; the body is never edited (discard and draft again) |
| `migration_draft_withdraw` | the author, or `migrations.draft` | not once observed applied |

## Screens (cards for workbenches and drafts; tables for change sets and items; 375 px first for the reading screens, the forms at 1280 that still render at 375)
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `workbenches-list` | `/workbenches?owner=` | `RecordCard`s: title, `dxw_<n>`, "clone of subello_gl" or "empty", size against quota (a bar), expires {relative} (`text-bg-warning` within 2 days), suspended (`text-bg-danger`, over quota); mine — every workbench for a super-admin; **New workbench** |
| `workbench-add` | `/workbenches/new?source=&title=` | title (80), kind (empty / clone), source (the record picker over `find_databases`, classes application and development, grants in place) — the root step named when grants are pending; the quota and expiry from settings stated; Create → the workbench page with "Creating…" polling until `ready` |
| `workbench-view` | `/workbenches/{id}` | header (title, the workbench class badge, source, created, size/quota, expiry); **Open SQL** (`/db/dxw_<n>/sql`), **Browse** (`/db/dxw_<n>`); **the change log** — its applied change sets in order (a table: when, title, statements, by, origin); Renew (days), **Export as a migration** (a range of the change log: from / to), **Import a CSV**, Reset credential (super-admin, ✔), **Drop** (✔ + the name typed back) |
| `workbench-import` | `/workbenches/{id}/import` | step 1: the table (picker over the workbench's tables) and the file; step 2: the preview (first 20 rows parsed by PHP's `fgetcsv`, escaped), the column mapping (each CSV column → a column of the table, or skip), header row yes/no, delimiter, `ON_ERROR` stop / ignore (type errors only — constraint violations still abort); Load → the change set's state polled |
| `change-form` | `/forms/{datname}/{family}/{verb}?object=&safe=` | the family's form (ddl-generators' fields) as a full page: the target's class badge and colour in the header; on an installed application a banner *"This becomes a migration draft for gl's repository, rehearsed first — nothing runs on subello_gl"*; **Use the plain form** (unticked); a field that names an existing object is a record picker; **Review** submits `change_set_prepare` |
| `changes-list` | `/changes?datname=&state=&origin=&author=` | a table: title (link), database (badge), origin chip, state badge, author (the agent chip), statements, updated; chips Open · Applied · Drafted · Discarded · Failed · Proposed by agents |
| `change-review` | `/changes/{id}` | change-review "The review page" |
| `change-edit` | `/changes/{id}/edit` | a draft's title and statements (one statement per text area, add/remove/reorder); Save re-lints (`change_set_update`) |
| `rehearsal-view` | `/rehearsals/{id}` | per statement: locks taken (relation, mode), rewrote, ms, the error; the clone's name and that it was dropped; the status polling while `running` |
| `drafts-list` | `/drafts?application=&state=` | `RecordCard`s grouped by application: the file name, the title, state (`drafted` / `downloaded` / `observed applied` with when / `abandoned`), the agent chip, created |
| `draft-view` | `/drafts/{id}` | the file in a `<pre>` (escaped), **Download** (`GET /drafts/{id}/download`), **Copy**, the number and slug (edit: `migration_draft_update`), the observed-applied state with the objects seen and not yet seen, Withdraw (✔) |

## Files (exactly these)
- `html/workbenches/{index,form,save,view,renew,drop,reset,import,export}.php` (`import.php` serves the import screen on GET and the action on POST)
- `html/forms/form.php`, `html/changes/{index,view,edit,prepare,propose,update,review,override,rehearse,apply,discard}.php`,
  `html/rehearsals/{view,progress}.php`, `html/drafts/{index,view,save,update,withdraw,download}.php`
- `app/features/workbenches/{queries,present,write,import}.php`, `app/features/forms/{fields,validate}.php`,
  `app/features/changes/{queries,present,write,review,draft}.php` (change-review "Files"), `app/features/drafts/{queries,present,write}.php`
- `app/views/workbenches/{index,form,view,import}.php` + `partials/{card,change-log,quota-bar}.php`; `app/views/forms/{form}.php` + one
  partial per family `app/views/forms/families/{schema,table,column,constraint,index,view,matview,sequence,routine,trigger,enum,composite,range,domain,policy,comment,extension,grants}.php`;
  change-review's views; `app/views/rehearsals/view.php`; `app/views/drafts/{index,view}.php` + `partials/card.php`
- `bin/worker.php` gains the passes' bodies `applied_drafts` and `imports`
- `app/pickers.php` gains `workbench_table` (a workbench's tables) and uses slice 2's `catalog_object`
- `tests/phase3/slice4/{run.sh,lib.php,workbenches.php,forms.php,review.php,lint.php,rehearse.php,apply.php,drafts.php,export.php,import.php,observed.php,walls.php,json.php,browser.mjs}`

## Query functions / door calls (signatures fixed)
- `find_workbenches(PDO $pdo, array $filters, int $page): array{rows, total}` (`mcp_workbenches`) · `find_workbench(PDO $pdo, int $id): ?array`
- `workbench_create(PDO $pdo, int $by, string $title, string $kind, ?string $source): int` — inserts the row (`creating`; the trigger's cap),
  asks the door's `workbench_create` (`source` for a clone), registers the `target_databases` row (class `workbench`, `grants_state =
  'not_needed'`), sets `ready` or `failed` with the door's sentence
- `workbench_renew(PDO $pdo, int $id, int $by, int $days): void` · `workbench_drop(PDO $pdo, int $id, int $by, string $typedName): void` (door
  `workbench_drop`; the row `dropped`, `dropped_by_kind`; the registry row marked gone) · `workbench_reset(PDO $pdo, int $id, int $by): void`
- `workbench_import_start(PDO $pdo, int $id, int $by, string $table, string $tmpFile, array $mapping, bool $header, string $delimiter, string $onError): int` (the change set id)
- `workbench_export(PDO $pdo, int $id, int $by, ?int $from, ?int $to): array{draft_id?, change_set_id, rehearsal}` (change-review "Export")
- `change_set_prepare(PDO $pdo, int $by, string $datname, string $family, string $verb, array $fields, bool $safe): int` — validate the fields
  (`app/features/forms/validate.php`: `dx_name_ok`, `type_resolve`, expressions through `classify` with their carrier), build the statements
  (`dx_ddl_build_*`), `classify` each (exactly the expected node on the expected object — else refused), annotate (`dx_annotate` +
  `relation_sizes`), `lint`, insert the change set and its items
- `change_set_propose(PDO $pdo, int $by, string $datname, string $title, string $sql, ?string $reason, string $origin): int` — the door's
  `classify` splits and classifies; DDL and DML items annotated and linted the same way; the literals listed
- `change_set_update(PDO $pdo, int $id, int $by, ?string $title, ?array $statements): void` · `change_set_review(PDO $pdo, int $id, int $by): void`
  · `change_set_override(PDO $pdo, int $itemId, int $by, string $rule, string $reason): void` · `change_set_discard(PDO $pdo, int $id, int $by): void`
- `rehearsal_run(PDO $pdo, int $changeSetId, int $by, bool $isEval): int` (the rehearsal id)
- `change_set_apply_workbench(PDO $pdo, int $id, int $by, ?string $typedName): array{status, items, blockers?}` (change-review "Apply on a workbench")
- `migration_draft_create(PDO $pdo, int $changeSetId, int $by, ?int $number, ?string $slug): int` · `migration_draft_update(PDO $pdo, int $id, int $by, array $fields): void`
  · `migration_draft_withdraw(PDO $pdo, int $id, int $by, ?string $reason): void` · `migration_draft_download(PDO $pdo, int $id, int $by): array{name, body}`
- `drafts_observe(PDO $pdo, int $snapshotId): int` (the worker's `applied_drafts` pass; drafts marked)

## MCP tools this slice makes real
`find_change_sets` (the change-set resolver), `get_change_set`, `ddl_cost`, `get_rehearsal`, `find_migration_drafts` (the draft resolver),
`get_migration_draft`, `find_workbenches` (the workbench resolver), `get_workbench`.

## Manifest rows claimed
Screens (11): `workbenches-list`, `workbench-add`, `workbench-view`, `workbench-import`, `change-form`, `changes-list`, `change-review`, `change-edit`, `rehearsal-view`, `drafts-list`, `draft-view`
Actions (17): `workbench_create`, `workbench_renew`, `workbench_drop`, `workbench_reset_credential`, `workbench_import`, `workbench_export`, `change_set_prepare`, `change_set_propose`, `change_set_update`, `change_set_review`, `change_set_override`, `rehearsal_run`, `change_set_apply`, `change_set_discard`, `migration_draft_create`, `migration_draft_update`, `migration_draft_withdraw`

(`change_set_apply` is claimed here; its row-edit branch is built by slice 5 inside the same handler — `html/changes/apply.php` dispatches
on the target's class.)

## Activity log events
`workbench.create` (kind, source datname), `workbench.renew` (days), `workbench.drop` (by kind), `workbench.reset_credential`,
`workbench.import` (table address, rows loaded, rows skipped), `workbench.export` (range, change set, draft), `change_set.prepare` (family,
verb, safe, statement counts by class), `change_set.propose` (origin, counts; `source = agent` under a run token), `change_set.update`,
`change_set.review`, `change_set.override` (the rule — the reason's length, not its text), `rehearsal.run` (status, statements, rewrites
seen), `change_set.apply` (class, statements ok/failed, ms), `change_set.discard`, `migration_draft.create` (file name, application,
agent-authored), `migration_draft.update`, `migration_draft.withdraw`, `migration_draft.download`, `migration_draft.observed` (source
`cron`), `screen.view`. **Never SQL text, never a literal, never a CSV value**; every row carries `target_database_id`.

## Status vocabulary
Change-set states: `draft` `text-bg-light border`, `reviewed` `text-bg-info`, `rehearsed` `text-bg-primary`, `applied` `text-bg-success`,
`drafted_as_migration` `text-bg-success` "Drafted", `discarded` `text-bg-secondary`, `failed` `text-bg-danger`. "Proposed by an agent"
`text-bg-warning`. Workbench: `creating` spinner, `ready`, `failed` `text-bg-danger`, "expires {date}", "Suspended — over quota"
`text-bg-danger`. Draft: `drafted`, `downloaded` `text-bg-info`, `observed applied` `text-bg-success`, `abandoned` `text-bg-secondary`.
Ids: `workbench-card-{id}`, `workbench-drop`, `workbench-drop-name`, `workbench-export`, `form-field-{name}`, `form-safe`, `form-review`,
`change-item-{position}`, `change-lint-{position}-{rule}`, `change-override-{position}`, `change-literals-banner`, `change-rehearse`,
`change-mark-reviewed`, `change-apply`, `change-draft`, `change-discard`, `apply-blockers`, `apply-retry`, `draft-card-{id}`,
`draft-download`, `draft-number`.

## Requirements claimed
MUSTs (35): R11, R12, R13, R14, R15, R17, R43, R44, R72, R82, R86, R91, R94, R101, R102, T6, T7, T8, T9, T10, T20, T24, T32, T33, S10, S11, S13, S14, S15, S20, S22, E11, E12, E13, E16

(E12: a workbench's `dxw_<n>` role is the tool's own, made and dropped by the door's lifecycle; no installation-managed role is ever
altered. S11/T20: the CSV goes through `COPY … FROM STDIN` by the door — never a server path.)

## Out of scope for this slice
Row edits and windows (5); health fixes (8 — they arrive as change sets here); the editor's "Review as a change set" button (3 — it calls
`change_set_propose`); compare-to-script (Extended); CSV import into an installed application's tables (Extended); typed DML against an
installed application (never — a draft).

## Proof (`tests/phase3/slice4/run.sh`: scratch database `dx_dev4`; php -S on 9401, the fake kernel on 9402, the fakes on 9403; then the user-level Apache on 9407; Playwright from /var/www/web/node_modules; scratch roles `dx_proof_*`, scratch targets `dx_t4_*` and scratch workbenches `dx_t4_wb_*` with the owner's leave; a running scratch door; the registry `--check`)
1. Workbenches: Priya makes an empty one and a clone of `dx_t4_app` (HR's real migrations as fixtures); a sixth refused with the trigger's
   sentence; a Viewer refused; an agent's token refused (`people`); renew; another person's drop 404; the owner's drop needs the exact name;
   a super-admin resets a credential after the workbench role changed its own password (the door reaches it again).
2. Forms → review → Apply on the workbench, for every family of ddl-generators' table (create, alter, drop): each statement as built; a
   hostile name from ddl-generators' list in each form round-trips; a 64-byte name refused on the field.
3. The safe forms: a new index on a table with rows is `CONCURRENTLY`; SET NOT NULL is four statements; a PK through `USING INDEX`; the
   plain form ticked shows its rewrite/scan.
4. Change review per change-review's proof list (transitions, lint override, literals, rehearsal, 55P03 and Retry, the typed name).
5. On the application target: the form's banner; the only button is Save as migration draft after Rehearse; Apply refused by the trigger
   when forged.
6. Drafts: the file; the number from a scratch `schema_migrations`; download; applying it as postgres then a snapshot pass marks it observed.
7. Export: two workbench change sets → one draft, rehearsed ok; an empty workbench's export refused.
8. CSV import: 1,000 rows loaded by the worker's `imports` pass; a type error stops (stop) or is skipped (ignore, the count said); a
   constraint violation aborts with the masked error; the file is gone afterwards.
9. Agents: the Expert's `change_set_propose` (origin `editor` → `agent_proposal`), `rehearsal_run` and `migration_draft_create` succeed
   and are marked an agent's on every screen and in the file's header; its `change_set_apply`, `workbench_create`, `change_set_prepare` are
   refused (`people`); under `is_eval` its `rehearsal_run` is refused.
10. Frozen: no Apply, no workbench made, no rehearsal for an agent.
11. JSON mode and the four MCP tools of the slice answer what the screens show; 375 px on the lists, review and draft pages.

## Decisions taken here
1. CSV import is a worker job applied as the owner (Divergence 1).
2. A clone needs the source's grants in place.
3. `change_set_apply` is one handler dispatching on the class; this slice builds the workbench branch, slice 5 the rows branch.

## Open questions
None.
