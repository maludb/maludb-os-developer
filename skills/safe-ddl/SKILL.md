---
name: safe-ddl
description: Writing PostgreSQL 17 DDL that does not take a site down — the lock each ALTER takes, which rewrite or scan the table, the safe forms (CONCURRENTLY, NOT VALID then VALIDATE, SET NOT NULL through a check, primary keys through a concurrent index), lock_timeout, and the estate's rule that an installed application's schema changes only by a numbered migration file. Load before proposing or drafting any change.
---
# Safe DDL

## The lock is the danger, the queue is the outage
`ACCESS EXCLUSIVE` conflicts with everything, plain `SELECT` included. A DDL statement **waiting** for it behind one long transaction
blocks every later reader of the table — an outage even when the DDL itself would take milliseconds. So every DDL runs with
`lock_timeout` (a few seconds) and `statement_timeout`; on a lock timeout the person sees the blockers and retries.

## What each operation costs (PostgreSQL 17)
| Operation | Lock | Rewrite / scan | Safe form |
|---|---|---|---|
| `ADD COLUMN`, no default or a non-volatile default | ACCESS EXCLUSIVE (brief) | none | `lock_timeout` |
| `ADD COLUMN … DEFAULT clock_timestamp() / random() / gen_random_uuid()` (volatile) | ACCESS EXCLUSIVE | **rewrites the table and its indexes** | add it with no default, then `SET DEFAULT`, then backfill in batches |
| `ADD COLUMN … GENERATED … STORED`, identity or serial | ACCESS EXCLUSIVE | rewrite | a new column kept by a trigger, or a planned migration |
| `DROP COLUMN` | ACCESS EXCLUSIVE | none (marked dropped) | the application stops using it first |
| `ALTER COLUMN TYPE` | ACCESS EXCLUSIVE | **rewrite + index rebuild** unless binary-coercible (`varchar(n)`→ larger or `text`) | new column, dual write, backfill, swap |
| `SET NOT NULL` | ACCESS EXCLUSIVE | **full scan** (skipped if a valid `CHECK (c IS NOT NULL)` exists) | check `NOT VALID` → `VALIDATE` → `SET NOT NULL` → drop the check |
| `ADD CHECK` | ACCESS EXCLUSIVE | full scan | `NOT VALID`, then `VALIDATE CONSTRAINT` |
| `ADD FOREIGN KEY` | SHARE ROW EXCLUSIVE on **both** tables | full scan | `NOT VALID`, then `VALIDATE` |
| `VALIDATE CONSTRAINT` | SHARE UPDATE EXCLUSIVE | scan, concurrent with writes | — |
| `ADD PRIMARY KEY` / `UNIQUE` | ACCESS EXCLUSIVE | index build | `CREATE UNIQUE INDEX CONCURRENTLY`, then `ADD CONSTRAINT … USING INDEX` |
| `CREATE INDEX` | SHARE (blocks writes) | build | `CREATE INDEX CONCURRENTLY` — its own statement, never in a transaction; a failure leaves an invalid index to drop |
| `DROP INDEX` | ACCESS EXCLUSIVE | — | `DROP INDEX CONCURRENTLY` |
| `REINDEX` | SHARE on table, ACCESS EXCLUSIVE on the index | rebuild | `REINDEX CONCURRENTLY` |
| `SET LOGGED/UNLOGGED`, `SET ACCESS METHOD`, `SET TABLESPACE`, `SET EXPRESSION` | ACCESS EXCLUSIVE | rewrite (or file copy) | schedule it |
| `CREATE TRIGGER`, enable/disable | SHARE ROW EXCLUSIVE | none | — |
| `CREATE/ALTER POLICY`, `ENABLE ROW LEVEL SECURITY` | ACCESS EXCLUSIVE | none | `lock_timeout` |
| `ATTACH PARTITION` | SHARE UPDATE EXCLUSIVE on parent, ACCESS EXCLUSIVE on the partition | scan, skipped by a matching valid CHECK | add the CHECK first |
| `VACUUM FULL`, `CLUSTER` | ACCESS EXCLUSIVE | rewrite | not offered — `pg_repack` is for later |
| `REFRESH MATERIALIZED VIEW` | ACCESS EXCLUSIVE | rebuild | `CONCURRENTLY` (needs a unique index) |

**"Add a column with a volatile default" is the dangerous case, not a safe one.** `ddl_cost` gives the lock, the rewrite, the scan and
the table's size for a statement; quote it ("rewrites 4.2 GB, ~38 M rows under ACCESS EXCLUSIVE").

## The templates
```sql
-- NOT NULL without the long ACCESS EXCLUSIVE scan
ALTER TABLE s.t ADD CONSTRAINT t_c_nn CHECK (c IS NOT NULL) NOT VALID;
ALTER TABLE s.t VALIDATE CONSTRAINT t_c_nn;
ALTER TABLE s.t ALTER COLUMN c SET NOT NULL;
ALTER TABLE s.t DROP CONSTRAINT t_c_nn;

-- a primary key without blocking writes during the build
CREATE UNIQUE INDEX CONCURRENTLY t_pkey_new ON s.t (id);
ALTER TABLE s.t ADD CONSTRAINT t_pkey PRIMARY KEY USING INDEX t_pkey_new;
```

## Where a change may run
- **Workbench** (`dxw_<n>`): live, after Change review. Design here.
- **Installed application**: **never live.** The change becomes a **migration draft** — the next numbered `db/NNN_<slug>.sql` for that
  application's repository: a header (what, why, who drafted it — marked when an agent did — the rehearsal's result, the lint
  findings), the statements in the safe forms, a verify query at the end. A person commits it; the owner applies it as `postgres`.
  Migrations are **additive**: never edit an applied one; a correction is a new file.
- Never in a draft: data read from any database, a role or password, `DROP DATABASE`, anything touching a co-located `memory` schema.

## Rehearsal tells the truth; BEGIN … ROLLBACK does not
On a live database `BEGIN; ALTER …; ROLLBACK;` takes the lock and does the rewrite before rolling back. A **rehearsal** applies the
change set to a throwaway schema-only clone and measures the locks taken and whether a table's file changed (a rewrite). Statements that
cannot run in a transaction (`CONCURRENTLY`) are checked for success and their lock comes from the rule table — say which.

## Lint
squawk's findings come with every review. `ban-drop-*`, `renaming-*`, `changing-column-type` and `require-timeout-settings` are errors a
person must override with a reason. Fix the statement rather than asking for the override.
