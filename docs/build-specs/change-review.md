# Build spec: Change review — change sets, lint, rehearsals, Apply and migration drafts (a build spec — slices 4, 5 and 8 build on it)

What exists at the end: **one page every graphical change ends on** (`/changes/{id}`, R12): the exact SQL, each statement's lock, rewrite
and scan with where the figure came from, squawk's findings and the overrides they need, every string literal and comment listed, the
agent marking, **Rehearse**, and **the one button the target's class allows** — Apply on a workbench, Apply of rows inside a write window
on an installed application, **Save as migration draft** for any other change to an installed application, nothing (with the reason) on a
development, kernel or memory database. Design §6.5, §6.6 (the apply side); the state machine is db/010's trigger, the second wall.

The page is the same for a person's form (slice 4), a grid's staged rows (slice 5's `review-rows` is its rows' view), a health fix (slice 8),
an editor's "Review as a change set" (slice 3), a workbench export and an agent's proposal. **PHP never decides who may apply**: it moves the
change set's state and the trigger refuses or admits.

## Divergences from the design
1. **squawk 2.68.0 names two timeout rules, not one.** The design names `require-timeout-settings`; squawk 2.68.0 reports
   `require-lock-timeout` and `require-statement-timeout` (the door proof, `tests/door/FINDINGS.md`). Both are errors on a migration draft
   (every draft begins with both settings, so they fire only when someone removed them) and are not run on a workbench change set (Apply
   sets both itself).
2. **Apply holds the change set's row while the door runs.** PHP opens a transaction on the tool's own database, takes the change set
   `FOR UPDATE`, sets `state = 'applied'` (the trigger judges the person, the class, the window, the caps and the freeze **before anything
   runs on the target**), asks the door, and commits only if the door reports success — else it rolls back and records `failed` in a
   second short transaction. Two people pressing Apply at once: the second waits on the row, then finds the state moved and is told.
3. **An agent's change set is always `agent_proposal` or `health_fix`** (the trigger refuses any other origin for an agent): the action
   `change_set_propose` maps an agent's `origin = editor` to `agent_proposal`.
4. **A workbench change set is not rehearsed** — the door refuses a rehearsal of a workbench (`rehearse` takes application and
   development targets only); a workbench *is* the place to try. Its review shows the rule table's figures.

## The state machine (db/010 `dx_change_sets_before()`, never re-implemented in PHP)

| From → to | Who and when |
|---|---|
| (new) → `draft` | `change_set_prepare` (a person's form), `change_set_propose` (a person's editor or an agent), `health_fix_prepare`, `row_stage` (the first staged row), `workbench_export` |
| `draft` → `reviewed` | `change_set_review` — the person read the page; every lint error has an override with a reason (else refused with the rule names) |
| `draft`/`reviewed`/`rehearsed` → `rehearsed` | `rehearsal_run` finished `ok` (a failed rehearsal leaves the state where it was and keeps the rehearsal) |
| `reviewed`/`rehearsed` → `applied` | `change_set_apply` by a person: a workbench's owner holding `workbench.apply`; or row edits (origin `grid`, every item `dml`) by a holder of `data.write` inside their own open write window, within the caps; never an agent; never frozen |
| `rehearsed` → `drafted_as_migration` | `migration_draft_create` — only for an `application` target |
| `draft`/`reviewed`/`rehearsed`/`failed` → `discarded` | `change_set_discard` (the author, or a holder of `changes.prepare`) |
| `reviewed`/`rehearsed` → `failed` | the door reported an error at Apply (the failure text masked — no value) |

A draft is edited (`change_set_update`) only in `draft`; any edit of a `reviewed` or `rehearsed` change set is refused — discard it and make
another (the review a person saw is the review that is applied).

## The review page (`change-review`, `/changes/{id}`)
Header: the title, the target's class badge, colour and my level, the origin chip, the author — **"Proposed by an agent: Database Expert"**
as a `text-bg-warning` chip when `author_is_agent`, everywhere the change set appears (lists, the draft's header, notifications) — the state
badge, the window it applied under.

Body, one card per item, in position order:
1. **The statement** in a `<pre>` (escaped; a value staged by the grid is never in it — the grid composes `$n` placeholders), Copy, **Open in
   the editor** (`/db/{datname}/sql?change_set={id}` — slice 3 loads the statements; the person may edit and propose again, R12).
2. **The annotations** per relation (ddl-generators "The rule table"): lock mode, rewrite, scan, transaction block allowed, size and rows —
   "rewrite 4.2 GB, ~38 M rows under ACCESS EXCLUSIVE" — and **the source**: `rule table` (`text-bg-light border`), `measured` after a
   rehearsal (`text-bg-info`), or `unknown` ("ACCESS EXCLUSIVE, cost unknown", `text-bg-warning`). The safe form, when the statement is not
   in it, with **Use the safe form** (a new change set from the same form fields, `safe=yes`).
3. **Lint** — squawk's findings for that statement (rule, message, help link text, never a fetch). **Error rules needing an override with a
   reason** (`change_set_override`): `ban-drop-column`, `ban-drop-table`, `ban-drop-database`, `renaming-column`, `renaming-table`,
   `changing-column-type`, and on a draft `require-lock-timeout`, `require-statement-timeout`; the rest are warnings. An override names the
   rule, the person and the reason (≤ 500 characters) in `lint_summary.overrides`.
4. **The literals list** — every string literal and comment text in the statement (from the door's `classify`), each shown escaped. A
   `text-bg-warning` banner when the change set came from an agent **or** will become a migration: *"A migration may be committed to a public
   repository — no data belongs in it."* An agent's literal longer than 40 characters is flagged on its line and copied to the draft's
   `literal_flags`.
5. **The rehearsal's measurement** for that statement when one ran: the locks taken, rewrote yes/no, time on empty tables, the error.

Foot: **Rehearse** (application and development targets; disabled with its reason elsewhere), **Mark reviewed**, the class's one button,
**Discard**. The buttons a person lacks the right for are not offered; the trigger refuses a forged POST with its sentence.

**The class's one button** (from the target's class and the items — never from a role):

| Target | Items | Button | Needs |
|---|---|---|---|
| `workbench` | any | **Apply** | its owner; `workbench.apply`; the typed name for a `DROP`/`TRUNCATE` |
| `application` | origin `grid`, every item `dml` | **Apply** (slice 5's review-rows page) | `data.write`; my own open write window on it; the caps |
| `application` | anything else (DDL, a typed data fix) | **Save as migration draft** (after a rehearsal) | `migrations.draft` |
| `development`, `kernel`, `memory`, `own` | — | none — *"Changes to a development database come from its application's tests; the kernel's database and memory databases change only by their owners' migrations."* | — |

## Lint (through the door)
The door's `lint` kind runs squawk 2.68.0 from the services' virtual environment (`services/.venv/bin/squawk --pg-version=17 --reporter=json`,
the statements written to a file in the door's private temporary directory, `--assume-in-transaction` off); it answers per statement
`[{rule, level: error|warning, message, line, column}]`. PHP never execs squawk. Lint runs when a change set is created and again after
`change_set_update`; the findings are stored in `change_set_items.lint` and the counts in `change_sets.lint_summary`.

## Rehearse (`rehearsal_run`, through the door's `rehearse`)
A `rehearsals` row (`running`) is written, the door makes a throwaway schema-only clone `dxr_<n>` of the target with its own role (as a
workbench is), applies the change set statement by statement — inside `BEGIN … COMMIT` for each statement that may run in a transaction,
recording the relation locks its own backend holds before COMMIT (`pg_locks`) and whether a relation's file changed
(`pg_relation_filenode()` before and after — a rewrite, even on an empty table) — and runs a `CONCURRENTLY` statement on its own, checked for
success, its lock **from the rule table and labelled so**. It stops at the first error. The clone and its role are dropped whatever happens
(the worker drops any `dxr_*` older than an hour). The door also answers, for every object the change set creates or alters, **its
normalised DDL's sha256 on the clone** (`objects: [{address, ddl_sha256}]`, the renderer of ddl-generators) — the draft's observed-applied
check reads it. Results go to `rehearsals.results` and each item's `rehearsal`; the item's `lock_source` becomes `measured`. **An evaluation
run (`is_eval`) may not rehearse** (the door refuses; S22). Agents may (design §5, D10). The page polls `GET /rehearsals/{id}/progress`.

## Apply on a workbench (`change_set_apply`, target class `workbench`)
1. PHP: `require_human()`, the owner's `workbench.apply` (the trigger checks again), the typed name for any item that is a `DropStmt` or
   `TruncateStmt` (the object's name, compared exactly), releases the session lock, opens the transaction and sets `applied` (Divergence 2).
2. The door's `run` kind on the workbench tier with `change_set_id` and `stop_on_error = true`: before each statement it sets
   `lock_timeout = '5s'` and `statement_timeout` from `workbench_timeout_seconds`; each statement's outcome (status, rows, ms, SQLSTATE,
   the masked error) goes to its `change_set_items` row.
3. **A lock timeout (55P03)**: the door answers the blocking sessions (`pg_blocking_pids` of its backend, read by the named query
   `blocking`, texts normalised); the page shows them and **Retry** (the same change set, from the failed statement on). The change set is
   `failed` until a Retry applies it (`failed` → a Retry makes a new change set with the remaining statements, `origin` kept — the failed one
   stays as the record).
4. Success: commit; the change set becomes part of the **workbench's change log** (its applied change sets in order); `undo_state` stays
   `none` (a workbench's DDL is undone by another change set, never by before-images).

## Apply of rows (`change_set_apply`, target class `application`, origin `grid`)
Slice 5 (`data-windows.md` "Apply") — the write tier, one transaction, identity and `xmin`, the side-effect check, before-images, undo, the
caps, the backup gate. This page shows the rows' summary and links to `review-rows`.

## Migration drafts (`migration_draft_create`)
A rehearsed change set on an `application` target becomes a draft: `state = 'drafted_as_migration'` and a `migration_drafts` row in one
transaction. A draft touching a co-located `memory` schema is refused (the door's `classify` names every relation's schema). **The file**:

```sql
-- 021_invoices_customer_idx.sql — An index for invoices(customer_id)
-- Application: gl · database subello_gl · drafted 2026-10-11 by Priya Shah through Developer (change set 412)
-- PROPOSED BY AN AGENT: Database Expert (run 8812) — reviewed and drafted by Priya Shah        ← only when the author is an agent
-- Why: the foreign key invoices_customer_id_fkey has no index; seq scans on invoices dominate top statements.
-- Rehearsal: ok on a schema clone, 2026-10-11 10:02 UTC — locks: invoices SHARE UPDATE EXCLUSIVE (rule table); rewrites: none
-- Lint (squawk 2.68.0): clean · overrides: none
-- No data belongs in a migration: this file may be committed to a public repository.
SET lock_timeout = '5s';
SET statement_timeout = '15min';

CREATE INDEX CONCURRENTLY invoices_customer_id_idx ON public.invoices (customer_id);

-- verify
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indexrelid = to_regclass('public.invoices_customer_id_idx') AND i.indisvalid) THEN
        RAISE EXCEPTION 'invoices_customer_id_idx is missing or invalid';
    END IF;
END $$;
```

- The statements are the change set's, in order; statements that may run in a transaction are grouped in `BEGIN; … COMMIT;` blocks and a
  `CONCURRENTLY` statement stands alone between them (the estate's migrations run `psql -v ON_ERROR_STOP=1 -f`).
- **The verify block** asserts each created or altered object exists in the state the rehearsal left (an index valid, a constraint
  validated, a column with its type) — generated per statement kind by `dx_draft_verify()`.
- **`NNN`** is the application's next number: read from the target's `schema_migrations` by the named query `migration_ledger` where the
  application keeps one (the cidery, ProcessCore, the Data Lake); from the installer's ledger once **K51** exists; else typed by the person
  (`migration_draft_update file_number`) — until then the file is `NNN_<slug>.sql`. The tool never reads or writes an application's
  repository (`shared-schema.md:65-68`): the draft is **downloaded** (`GET /drafts/{id}/download`, `state` → `downloaded`) or copied, and
  **applied by the existing route** (as postgres, by the owner).
- The slug defaults from the title (lower-case words joined by underscores, ≤ 60).
- `migration_draft_withdraw` sets `state = 'abandoned'` with the reason in the activity log; the change set stays `drafted_as_migration`.

## Observed applied (the worker's `applied_drafts` pass)
After each snapshot of an `application` target (slice 8), for every draft `drafted` or `downloaded` on it: when **every** object of the
rehearsal's `objects` appears in the snapshot with the same normalised-DDL sha256, the draft becomes `observed_applied` with the snapshot and
the time, and those snapshot objects are marked `explained_by = 'migration_draft'`, `explained_ref = draft`. A draft half seen stays waiting
and the draft page says which objects are not seen yet. A draft not observed for three days is in the Advisor's note.

## Export a workbench as a migration (`workbench_export`)
For a workbench cloned from an `application` target: the chosen range of its applied change sets (all by default) is concatenated in order
into **one new change set on the source application** (origin `workbench_export`, title "From workbench <title>", author the person),
linted, reviewed (the export is the review of statements already reviewed on the workbench), **rehearsed at once** on a fresh clone of the
application and, when the rehearsal is `ok`, drafted — the action answers the draft. A failed rehearsal answers the change set's review page
with the failure (the person fixes it on the workbench and exports again). A workbench made empty, or cloned from a development database,
cannot be exported ("export needs a workbench cloned from an installed application").

## The caps (settings, D5)
`change_set_confirm_rows` 1,000 (a typed count above), `change_set_max_rows` 10,000 (above it a migration), `backup_max_age_hours` 24 (a
cap-crossing apply needs a recorded backup that new), `workbench_timeout_seconds` 300, `screen_timeout_seconds` 30. The trigger enforces the
row caps; the backup gate is checked by PHP with `dx_last_backup()` and again by the door (slice 5).

## Files (shared by slices 4, 5 and 8 — built in slice 4)
- `app/features/changes/{queries,present,write,review,draft}.php` (`review.php`: `dx_review_model(PDO, int $changeSetId): array` — the page's
  whole model; `draft.php`: `dx_draft_body(array $changeSet, array $items, array $rehearsal, ?int $number, string $slug): string`,
  `dx_draft_verify(array $item): ?string`)
- `app/views/changes/{review,index,edit,rehearsal}.php` + `app/views/changes/partials/{item,annotations,lint,literals,buttons,state-badge,agent-chip}.php`
- `app/views/drafts/{index,view}.php` + `partials/card.php`

## Requirements claimed
MUSTs (24): R12, R13, R14, R15, R43, R44, R72, R82, R86, R91, R94, T6, T9, T32, T33, S13, S14, S15, S20, S22, E9, E11, E13, E19

(R44: the honest dry run is the rehearsal on a clone — never `BEGIN … ROLLBACK` of DDL on a live database; a statement that cannot run in a
transaction is named and run alone on the clone. T32/T33 are SHOULDs in the research that this design makes MUSTs.)

## Proof (the change-review part of `tests/phase3/slice4/run.sh`)
1. Every transition of the table above through the screens and the JSON door, and every forbidden one refused with the trigger's sentence
   (draft → applied; an agent's apply; an edit after review; a draft from a workbench).
2. Lint: a `DROP COLUMN` change set cannot be marked reviewed until an override with a reason exists; the override shows on the page and in
   the draft's header.
3. Literals: an agent's change set holding a 41-character string literal is flagged; the banner shows; the draft's `literal_flags` carries it.
4. Rehearse on `dx_t4_app` (a scratch application target): `ADD COLUMN c int DEFAULT 0` measures ACCESS EXCLUSIVE and no rewrite; `ALTER
   COLUMN c TYPE bigint` measures a rewrite; `CREATE INDEX CONCURRENTLY` is labelled "rule table"; the clone is gone afterwards; `is_eval`
   refused.
5. Apply on a workbench: a held `ACCESS SHARE` lock from a second session → 55P03 → the page names the blocker → Retry after it ends applies.
6. Draft: the file's header, groups, verify block and name (`NNN_` when no ledger; `021_` from a scratch `schema_migrations`); download sets
   `downloaded`; applying the file as postgres to `dx_t4_app` and running the snapshot pass marks it `observed_applied`.
7. Export: a workbench cloned from `dx_t4_app`, two applied change sets → one draft whose rehearsal is ok.

## Decisions taken here
1. Apply judges first and runs second, inside one transaction on the tool's database (Divergence 2).
2. A reviewed change set is immutable; edits make a new one.
3. A workbench change set is not rehearsed; an export is rehearsed at once.
4. A Retry after a lock timeout makes a new change set from the failed statement on; the failed one stays as the record.

## Open questions
None.
