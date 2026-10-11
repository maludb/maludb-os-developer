# Developer — Phase 1 consistency record

2026-10-11 · **for the owner's checkpoint.** Phase 1 is the tool surface, the action manifest and its registry, three build specs and
eleven slice specs (the shell and ten slices), with the schema completed by db/012–013 — approved together before any feature PHP is
written (design §10). This record lists what Phase 1 decided where the design was silent, what it changed in Phase 0's files, the
requirements no slice holds, and how the documents are proven consistent.

## The documents

| Document | What it fixes |
|---|---|
| `docs/developer-mcp-tool-surface.md` | 50 records tools (5 resolvers and `app_roles` among them) and 4 activity tools; every target read through the door's named library, the own tables through `mcp_*` views; the coverage of every question of design §7 |
| `docs/developer-action-manifest.md` → `mcp/action_registry.json` | 95 screens, 64 actions; **exactly five admit an agent** (`change_set_propose`, `migration_draft_create`, `rehearsal_run`, `saved_query_save`, `dba_note_post`), the other 59 are people-only and refused, never paused; no `approvals[]` |
| `deploy/kernel-registry-developer.json` | the five resolvers the kernel's actions server names: target, workbench, change set, saved query, draft |
| `docs/build-specs/the-door.md` | the protocol and its kinds, the allow-list and the walker rule, the function screen, the decision table, execution, the audit, the named-query library (41) and the memory library (16) with the static secret test, the composed operations, the clients, the grants service, the proof per slice |
| `docs/build-specs/ddl-generators.md` | the families and their generators, quoting, the golden and hostile-name suites, the rule table (JSON, shared by PHP, the records server and the door), the safe forms, every form's fields, the records server's bridge to PHP's generators |
| `docs/build-specs/change-review.md` | the state machine as db/010 keeps it, the review page, lint, the literals list, rehearsals, Apply per class, the draft file, observed-applied, export as a migration |
| `docs/build-specs/{sso-shell, estate-browser, structure-ddl, sql-workspace, workbenches-changes, data-windows, plans, activity-maintenance, health-compare, memory-section, agents-admin}.md` | the eleven slices, each claiming its manifest rows, naming its tools and claiming its MUSTs; **the exemplars are slice 1 (the estate — CRUD), slice 3 (the SQL workspace — the door end to end) and slice 4 (workbenches and change review)** |
| `db/012_phase1_reads.sql` | `dba_notes`, `dx_caller_may()` (K38's intersection for the tool's own tables), `dx_address()`, nineteen `mcp_*` views over one visible-targets set |
| `db/013_phase1_fixes.sql` | what the slice specs found the Phase 0 schema lacked (below) |

## How consistency is proven

- `tests/phase1/check_specs.sh`:
  - `bin/build_action_registry.php --check` — the registry is the manifest's, no parse warning;
  - `bin/sync_approvals.php --check` — `maludb-os.json` `approvals[]` is the manifest's (empty);
  - `tests/phase1/check_specs.php` (Boards' port) — every screen and action claimed by exactly one slice; every surface tool named by a
    slice and every named tool in the surface; every agent grant exists; each job description names exactly its grants; the three build
    specs exist; **new for Developer: every MUST of `docs/research/01–05` — 182 of them — claimed by a spec, or held elsewhere by name
    below.**
- `tests/phase0/schema.sh`: the schema proof (127 checks) and **the Phase 1 reads proof, `db/proof/phase1_proof.sql`, read as the read roles
  themselves (39 checks)** — it found a real defect on its first run: the activity wall's `NOT LIKE ANY` admitted every sensitive row
  (fixed to `NOT (… LIKE ANY …)`).
- `tests/phase0/run.sh` (the kit, 102 + both proofs) and `tests/door/run.sh` (174) unchanged and green.

## What Phase 1 changed in Phase 0's files

- **db/013 (the Phase 1 fixes)**: `change_set_items.payload` (a staged grid edit's values, never in the read view); `snapshot_objects`
  explained by a `person` with a note, who and when (`drift_explain`); `target_databases.side_effect_tables` (the grid refuses such a table
  up front — the door proof's finding 8); `DELETE` on `explain_plans` for `plan_delete`; `dx_door_policy()` names a target's
  `has_maludb` and `memory_schemas` (the cidery's and ProcessCore's co-located memory); `dx_door_job_update()` (the door reports a
  maintenance job from its own thread); `dx_settings.blocked_alert_minutes` (design §5's ten minutes as a setting).
- `deploy/own-database.sql` grants `dx_door_job_update` to `developer_meta`; `deploy/ROOT_STEPS.sh` step 0 makes `DX_BRIDGE_KEY`, steps 3
  and 11 make `storage/exports` and `storage/imports` the door's; `maludb-os.json` requires `DX_BRIDGE_KEY` and grants the Advisor
  `dba_note_post`; both job descriptions list their grants; `bin/worker.php` gains the `imports` pass stub (slice 4) and names
  `export_jobs` slice 3's.
- The design: squawk 2.68.0's rules are `require-lock-timeout` and `require-statement-timeout` (it named `require-timeout-settings`);
  `bloat_estimate` runs as `developer_read_masked`.

## Decisions Phase 1 took (★ = the owner may want to look)

1. ★ **A fifth agent action, `dba_note_post`**, with a new table `dba_notes`: design §5 gave the Advisor "a notification" without a name.
   It posts a note (markdown rendered by an allow-list to text, links only to the tool's own paths) to every holder of `maintenance.run`,
   naming the change sets it proposed. Its right is `health.read` (held by anyone). The five free actions are now the four of §5 and this.
2. ★ **The counts moved from the design's estimate**: 95 screens (not ~72) because every object tab, plan, memory page and admin page has
   its own URL; 64 actions (not ~78) because forms share one `change_set_prepare`, applies share one `change_set_apply`, and the grid's
   edits share one `row_stage`; 50 + 4 tools (not ~46 + 5): the five resolvers and `app_roles` are counted, and the activity server's
   guarded search is `activity_search` itself.
3. **The records server never connects to a target**: own tables through `mcp_*` views as `developer_records_ro`, targets through the
   door's named library over its socket; `explain` is the only tool that sends SQL, and the door refuses `ANALYZE` from it (its schema has
   no such field).
4. **`object_ddl` for a generator family goes through a loopback bridge to PHP** (`html/internal/ddl.php`, HMAC under `DX_BRIDGE_KEY`,
   Inventory's shape) — one DDL renderer for screens, snapshots and agents, golden-tested once.
5. **An object is addressed `<type>:<identity>`** (`dx_address()`), URL-encoded; a favourite is keyed by target and address (no id).
6. **Agents see every workbench's title and source** (`find_workbenches`), never its contents — a workbench's structure is its owner's
   target alone. In a person's chat turn, the agent sees what the person sees, the person's own workbench included (K38).
7. **Windows are a person's business**: `windows` and `mcp_access_windows` answer the holder's own, or every one to a super-admin; an
   agent reads none.
8. **The activity wall**: rows on visible targets for a holder of `catalog.read`; the families `access.*`, `window.*`, `memory.reveal`,
   `memory.view`, `session.text_open`, `freeze.*`, `audit.*` and `settings.*` only to an auditor or the person who acted.
9. **Change sets**: a reviewed change set is immutable (an edit makes a new one); a workbench change set is not rehearsed, an export is
   rehearsed at once; a Retry after a lock timeout makes a new change set from the failed statement on; one open grid change set per person
   per target; Apply judges first and runs second.
10. **Undo covers inserts and deletes** (`apply` returns an insert's key); a deleted row with unreadable values cannot be undone, and says so
    before Apply. Cascading deletes are refused up front.
11. **CSV import into a workbench is a worker job** (`imports`) applied as the workbench's owner.
12. **One running maintenance job per target**; the root blocker is the session that blocks others and waits on nobody.
13. **Every Explain from a screen is kept** (deleted after `sql_text_days`); the plan flags' thresholds live in `flags.json`.
14. **Most-common values and histograms are never shown** (they are rows' values); `column_statistics` reads `pg_stats` as the masked tier.
15. **Memory walks and paths are tables**, not a drawn graph (375 px, no JavaScript); MaluDB's per-user model store is not read in v1.
16. **Dispatches** (a blocked session) go through the chat endpoint as the first active DBA until K8 lands.
17. **The poll door for a running statement** is `/sql/runs/poll?request=` (the run's row exists only once the door opens it).
18. **The SVG of a diagram is an image behind a strict CSP**, filtered by an allow-list; the DOT is built only by our writer.

## Open questions for the owner

1. ★ `blocked_alert_minutes` is 10 by default (Admin → Settings) — a different threshold is a setting, not a change.
2. `pg_stat_statements` is created in the tool's own database by ROOT_STEPS (one installation covers the cluster); until then
   `top_statements` answers `not_installed`.

## Requirements not claimed by a slice

Every other MUST of `docs/research/01–05` is claimed by at least one spec's `## Requirements claimed`.

Extended (5): R100, MR21, MR22, T44, T45
Extended by research (2): T46, T47
Held by the kernel (1): E15

- **R100, MR21, MR22** — forgetting, and the model-calling or destructive memory operations, are the curated MaluDB writes design §6.8 and
  D13 put in Extended.
- **T44, T45, T46, T47** — the research's LATER items (script generation from a diff, diagram-driven design, and the rest of §1.2's LATER
  row); T48 is claimed by `ddl-generators.md` only as far as the rule table is keyed by `server_version_num`.
- **E15** — the catalog row: K49, built and applied in the kernel as db/183.

## Owed outside this repository (unchanged by Phase 1)

K50 (the developer exception, the owner's amendment in the plugin), K51 (the installer's migration ledger — until then a draft's number is
read from `schema_migrations` or typed), K52 (optional), K53 (the hardening sweep, private), K54 (the installer's PHP-FPM pool support —
until then ROOT_STEPS restores the group after every apply), K8 (dispatch wake-up), K38 built.
