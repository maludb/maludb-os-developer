---
name: design-a-table-on-a-workbench
description: Runbook for designing a schema change the graphical way — on a workbench (an empty database or a schema-only clone of an application's), through Change review, then exported as the next numbered migration for that application's repository. Use when a person wants to add or change tables, columns, constraints or indexes for an installed application.
kind: runbook
---
# Design a table on a workbench

**For people**: the whole flow. **For you (an agent)**: you write the SQL, propose it and rehearse it; the person creates the
workbench, applies on it and exports. Workbenches, applying and exporting are refused to agents.

## The flow (what to tell the person)
1. **Clone** the application's database into a workbench (Workbenches → New → "clone of subello_gl"): a schema-only copy — no data —
   owned by its own role, expiring in 14 days. A co-located MaluDB schema is never cloned.
2. **Design** with the forms (create or alter a table, column, constraint, index, view, function, trigger, type, policy): each ends on
   **Change review** with the exact SQL, the lock and rewrite cost, squawk's lint, and Rehearse. Apply it on the workbench — live.
3. **Export as a migration**: the workbench's change log (or a range of it) becomes one draft for the application — the next
   `db/NNN_<slug>.sql`, statements in the safe forms, a verify query last.
4. **Commit and apply**: download or copy the draft into the application's repository, commit it; the owner applies it as `postgres`.
   The next nightly snapshot marks the draft applied.

## What you do
1. Understand the change in words; ask what the column means, whether it may be NULL, what references it.
2. Read the current structure (`table_describe`, `object_ddl`, `impact` for anything you alter, `join_path` for new foreign keys).
   Follow the estate's shapes: identity `bigint` primary keys, `timestamptz` with `DEFAULT now()`, foreign keys with an index, `CHECK`
   constraints for enumerations, `text` over `varchar(n)`, comments on every new table and column.
3. Write the SQL in the safe forms (skill `safe-ddl`): no volatile default on a new column, `NOT VALID` then `VALIDATE`,
   `CONCURRENTLY` for indexes on existing tables, NOT NULL through a validated check.
4. **Additive only** for an installed application: new tables, new nullable columns, new indexes and constraints. A rename, a type
   change or a drop is a multi-step plan (new column, dual write, backfill, swap) — say so and draft only the first step.
5. Propose: `change_set_propose` on the person's workbench, or `migration_draft_create` for the application directly; then
   `rehearsal_run` and report each statement's measured (or rule-table) lock and whether anything rewrote.

## Never
- Data in the SQL: no seed rows copied from a database, no comments quoting data, no defaults made of values you read.
- Anything touching a co-located `memory` schema, roles, grants to roles, or `DROP DATABASE`.
- Claim the change is live on the application: it is live only when the owner applies the migration.
