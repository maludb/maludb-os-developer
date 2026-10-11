---
name: draft-an-index
description: Runbook for proposing an index — justify it from the plan and the statistics, choose the columns and the type, write it in the safe form (CREATE INDEX CONCURRENTLY), propose it on a workbench or draft it as a migration for an installed application, rehearse it, and report the cost. Use when a plan, a health finding or a person asks for an index.
kind: runbook
---
# Draft an index

**Reads**: `table_describe`, `index_advice`, `explain`, `ddl_cost`, `get_rehearsal`. **Writes**: `change_set_propose` (a workbench),
`migration_draft_create` + `rehearsal_run` (an installed application). Never creates an index anywhere itself.

1. **Justify it** from evidence, in one sentence: the plan's sequential scan with a selective filter, the unindexed foreign key the
   health page found, the sort an index would avoid. No evidence, no index.
2. **Check what exists** (`table_describe`, `index_advice`): an existing index that already covers the columns (a leading-column
   match), an invalid one left by a failed `CONCURRENTLY` (drop it first — `DROP INDEX CONCURRENTLY`), a duplicate you would create.
3. **Choose**:
   - columns in the order the query filters by equality first, then range, then sort;
   - btree unless the operator needs otherwise (`gin` for jsonb containment, arrays and trigram search; `gist` for ranges and
     geometry; `brin` for huge append-only tables ordered by time; pgvector's `hnsw` for vectors);
   - partial (`WHERE deleted_at IS NULL`) when the query always filters the same way;
   - `INCLUDE (…)` for an index-only scan when the extra columns are few;
   - a name: `<table>_<columns>_idx`, within 63 bytes.
4. **Write it in the safe form**, as its own statement, never inside a transaction:
   ```sql
   CREATE INDEX CONCURRENTLY IF NOT EXISTS invoices_customer_id_idx ON gl.invoices (customer_id);
   ```
   `CONCURRENTLY` takes SHARE UPDATE EXCLUSIVE (reads and writes continue) and scans the table twice; a failure leaves an invalid index
   that must be dropped. `ddl_cost` gives the table's size so you can say how long a build might take.
5. **Where**:
   - a workbench → `change_set_propose` on it;
   - an installed application → `migration_draft_create` (header: why, from which evidence, drafted by you) then `rehearsal_run`.
     Report the rehearsal: the build succeeded on the clone; the lock comes from the rule table (`CONCURRENTLY` cannot be measured in a
     transaction) — say so.
6. **Tell the person** what you proposed, the evidence, the cost, and that a DBA reviews it and the owner applies the migration.

**Never**: build an index in a transaction, use `CREATE INDEX` without `CONCURRENTLY` on a table with data, put a value from the data in
a partial index's `WHERE` (only structural constants like `IS NULL`), or propose more than one index for one finding.
