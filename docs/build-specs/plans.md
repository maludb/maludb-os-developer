# Build spec: plans (slice 6)

What exists at the end: **Explain** in the editor (and from the statements list, the health page and the grid's generated SQL) with the
options of PostgreSQL 17 — `BUFFERS`, `VERBOSE`, `SETTINGS`, `SERIALIZE`, `MEMORY`, `GENERIC_PLAN`, and `ANALYZE` behind a warning that it
runs the statement; **without execution by default**; every plan **kept** with its query and an optional comment; **a server-rendered plan
tree** that works without JavaScript and at 375 px — per node the type, relation, estimated and actual rows with the misestimate factor
coloured, exclusive and inclusive time, loops, buffers — with **the deterministic flags first**; **PEV2** as a second view at 1280 (a
committed Vue 3 + PEV2 bundle mounted in one `<div>`); **Copy JSON** the only export. The records tool `explain` (an agent's and the
command bar's) answers the same plan and flags without execution.

Schema (db/009, 012, never modified): `explain_plans` (member, target, run, SQL, options, executed, plan, flags, comment), `query_runs` /
`door_statements` (the door writes the explain's run), `mcp_explain_plans` (the caller's own plans, db/012). Door: kind `explain`
(`the-door.md` §1, §3.7) and the named query `relation_sizes` (the stale-statistics flag).

## Divergences from the design
1. **The flag rules live in one file read by PHP and by the records server**: `app/features/plans/flags.json` — each flag's key, the node
   fields it reads, its threshold and its sentence. `app/features/plans/flags.php` and `mcp/plan_flags.py` both evaluate it; a proof feeds
   both the same plans and compares their output. No rule is written twice.
2. **A plan's SQL and plan JSON are kept `sql_text_days` (90 days)**, then the row is deleted by the worker's `retention` pass (a VERBOSE plan
   holds the query's literals and output expressions). A plan with a comment is kept the same 90 days — the comment says why it was kept,
   not that it is kept forever.
3. **Plans are their maker's**: `mcp_explain_plans` shows the caller's own; there is no shared plan in version 1 (to share, copy the JSON).
   The surface's "own or shared plan" for `get_plan` reads "own" (reported).
4. **`plan_delete` needs `DELETE` on `explain_plans` for `developer_rw`**, which db/009 does not grant — this slice's migration
   db/013 (the Phase 1 fixes) grants it.

## Who may do what
| Action / screen | Right | Rule |
|---|---|---|
| `plan_explain` without `analyze` | `plans.explain` | people (an agent uses the records tool `explain`); the door refuses the kernel's and memory databases; runs as `developer_read_masked` for a Viewer, the person's own tier for an Engineer at `rows` |
| `plan_explain` with `analyze` | `plans.explain` + `data.read` | the door's `read` rules (level, window, grants); a write only on a workbench (`workbench.apply`), wrapped `BEGIN … ROLLBACK` and labelled *executed and rolled back*; an agent never |
| `plan_comment`, `plan_delete` | own | — |
| `plans-list`, `plan-view` | `plans.explain` | own plans |

## Screens
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `plans-list` | `/plans?datname=&q=` | my kept plans as a table: when, database badge, the first line of the query, total cost, executed or not, the worst flag, the comment; paged 50 |
| `plan-view` | `/plans/{id}?view=tree|visual` | **the tree (default, 375 first)**: a header with the database badge, the options used, *executed* / *executed and rolled back* / *not executed*, planning and execution time, the comment (editable inline, `plan_comment`), **Copy JSON** (`GET /plans/{id}/json`, `Content-Disposition: attachment`), Delete (✔), **Open in the editor**; then **the flags** as a list (each: the sentence, the node it points at — a link down the page — and the hint, e.g. "estimated 12 rows, got 48,310 — ANALYZE public.invoices or raise its statistics target"); then the nodes as an indented list (a `<details>` per node, open to depth 3): node type and relation, estimated → actual rows with the factor chip (neutral under 10×, amber 10–100×, red over 100×, either direction), exclusive time and its share (amber over 30 %, red over 60 %), inclusive time, loops, shared hit/read, temp read/written, the filter and index condition text (escaped), rows removed by the filter. Without `analyze` the actual columns read "not executed". **The visual view** (`view=visual`, a link shown at 1280): the PEV2 island in `<div id="pev2" data-plan-url="/plans/{id}/json">`; at 375 the link is absent and the tree stays |

The editor's **Explain** button (slice 3's toolbar) opens an options strip (checkboxes `BUFFERS` (on), `VERBOSE`, `SETTINGS`, `SERIALIZE`,
`MEMORY`, `GENERIC_PLAN`; `ANALYZE` with the warning *"ANALYZE runs this statement"* and, for a write on a workbench, *"…and rolls it
back"*) and posts `plan_explain` for the statement at the cursor; the answer lands on `plan-view`.

## Files (exactly these)
- `html/plans/{index,view,json,explain,comment,delete}.php`
- `app/features/plans/{queries,present,write,flags.php,flags.json,tree.php}`
- `app/views/plans/{index,view}.php` + `app/views/plans/partials/{flags,node,options}.php`
- `mcp/plan_flags.py` (the records server's evaluator of `flags.json`; Phase 4 wires it into `explain` and `get_plan`)
- `client/plan/{index.ts}` with `pev2` and `vue` pinned exactly in `client/package.json` (a PEV2 release at or after the fix of its 1.22 HTML
  injection — read its changelog when pinning), built by `client/build.mjs` into `html/assets/developer/{plan.js,plan.css}` and recorded in
  `html/assets/developer/manifest.json`; `bin/check_bundle.php` covers it
- no migration: `GRANT DELETE ON explain_plans TO developer_rw` is db/013's (the Phase 1 fixes)
- `tests/phase3/slice6/{run.sh,lib.php,explain.php,flags.php,flags_parity.py,json.php,browser.mjs}` and fixture plans
  `tests/phase3/slice6/plans/*.json` (each flag at least once, captured from the proof's own targets)

## Query functions (signatures fixed)
- `plan_explain(PDO $pdo, string $datname, string $sql, array $options): array{plan_id, answer}` — `door_explain()` after
  `session_write_close()`; on `ok`, computes the flags (`plan_flags()`, with `door_named($datname, 'relation_sizes', …)` for the relations
  the plan scans) and inserts `explain_plans` (options as the canonical names, `executed`, the run's id)
- `plan_flags(array $planJson, array $relationStats): array` — `[{key, severity, node_path, sentence, hint}]` from `flags.json`
- `plan_tree(array $planJson): array` — the nodes flattened with depth, exclusive time (inclusive minus children's, times loops) and the factor
- `find_plans(PDO $pdo, array $filters, int $page): array{rows, total}` · `find_plan(PDO $pdo, int $id): ?array` (over `mcp_explain_plans`)
- `plan_comment(PDO $pdo, int $id, string $comment): void` · `plan_delete(PDO $pdo, int $id): void`

**The flags** (`flags.json`, in this order): `misestimate` (actual/estimated ≥ 10 either way on a node with ≥ 100 actual rows) · `disk_sort`
(`Sort Space Type` = Disk) · `hash_batches` (`Hash Batches` > 1) · `lossy_bitmap` (`Lossy Heap Blocks` > 0) · `slow_seq_scan` (a Seq Scan
over a relation estimated ≥ 100,000 rows whose filter removes ≥ 90 % of what it reads) · `stale_statistics` (a scanned relation whose
`n_mod_since_analyze` exceeds 20 % of its estimated rows, or never analyzed) · `heap_fetches` (an Index Only Scan with heap fetches > 10 % of
its rows) · `never_executed` (`Actual Loops` = 0) · `jit` (JIT time > 10 % of execution) · `parallel_short` (fewer workers launched than
planned). Without `analyze`, only the flags that need no actual numbers are evaluated (`slow_seq_scan` on estimates, `stale_statistics`).

## MCP tools this slice makes real
`explain`, `get_plan`. The records server's explain sends the door's explain kind **never with ANALYZE** (an agent never executes), as the
agent on behalf of the person (K38), and answers the plan with the flags from the shared rules file; nothing is stored. The second reads the
caller's kept plans (people's, through the command bar's expert on behalf of the person — the plans view reads `app.on_behalf_of`).

## Manifest rows claimed
Screens (2): `plans-list`, `plan-view`
Actions (3): `plan_explain`, `plan_comment`, `plan_delete`

## Activity log events
`plan.explain` `{plan_id, target, executed, options: [...], flags: n, run_id}` (never the SQL); `plan.comment` `{plan_id}`; `plan.delete`
`{plan_id}`.

## Status vocabulary
A plan: *not executed* · *executed* · *executed and rolled back*. A flag's severity: `warning` (amber) · `critical` (red).

## Out of scope for this slice
hypopg what-if indexes (Extended, T45); a hosted visualiser of any kind (never — R55); sharing a plan; plans over time (Extended); the
statements list itself (slice 7 — its rows link here with `GENERIC_PLAN`).

## Proof (`tests/phase3/slice6/run.sh`: scratch `dx_dev6`; php -S on 9401, the fake kernel 9402, the fakes 9403; the user-level Apache on 9407; the scratch door with `dx_proof_*` roles; targets `dx_t6_app` (a table of 200,000 rows never analyzed, an index, a personal column) and a workbench; Playwright from /var/www/web/node_modules; `bin/check_bundle.php`; the registry `--check`)
- Explain without analyze on `dx_t6_app` returns a plan and runs nothing (`pg_stat_user_tables.seq_scan` unchanged); every option is passed
  and recorded; `GENERIC_PLAN` of a `$1` statement works.
- Explain analyze of a read executes inside READ ONLY at the person's level; of a write on the application target is refused (`app_dml`);
  of a write on the workbench runs and is rolled back (the row count unchanged) and is labelled so; a Viewer's analyze is refused (`right`);
  a statement naming a personal column at `masked` is refused by PostgreSQL even without analyze (planning checks privileges).
- Every flag fires on its fixture plan in PHP **and** in `mcp/plan_flags.py` with the same output (`flags_parity.py`).
- The tree renders without JavaScript at 375 (no horizontal scroll; a plan with a 2,000-character filter wraps); the factor chips and time
  shares colour at their thresholds; a relation or filter text holding `<script>` renders escaped (and in PEV2 too, browser).
- PEV2 mounts at 1280 from `/plans/{id}/json` with no inline script (the CSP header unchanged), and is absent at 375.
- Copy JSON downloads the plan; nothing in the page or the bundle calls an outside host (a request log during the browser run).
- Comment and delete as the owner; another member's plan is a 404; an agent's `plan_explain` through the JSON door is refused
  (`require_human()`); the records tool `explain` with `analyze` in its arguments is refused by the schema (`extra="forbid"` has no such field).
- The worker's retention deletes a plan older than `sql_text_days`.

## Requirements claimed
MUSTs (12): R51, R52, R55, R72, R103, T16, T26, T27, T37, E17, S8, S19

## Decisions taken here
1. **The records tool `explain` never takes `analyze`** — its schema has no such field, so no prompt can ask for execution.
2. **Every Explain from a screen is kept** (the history of what one looked at), deleted after `sql_text_days`.
3. **Thresholds** are the depesz convention (10× and 100× for misestimates) and the shares above; they live in `flags.json`, not in code.

## Open questions
None.
