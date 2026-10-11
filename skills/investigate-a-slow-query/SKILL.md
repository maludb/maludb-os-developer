---
name: investigate-a-slow-query
description: Runbook for "why is this query slow?" — find the statement, plan it without running it, read the flags, check the table's statistics and indexes, and end with an explanation and at most one proposal. Use when a person asks why a query, a screen or a statement is slow.
kind: runbook
---
# Investigate a slow query

**Reads**: `top_statements`, `explain`, `get_plan`, `table_describe`, `index_advice`, `vacuum_state`, `bloat`, `blockers`.
**Writes**: at most one `change_set_propose` or `migration_draft_create` — only if the person agrees. Never runs the query.

1. **Which statement?** If the person pasted SQL, use it. If they named a screen or a symptom, `top_statements` on that database (by
   total time, then mean time) and pick the matching normalized statement; say which you picked and why.
2. **Is it slow or blocked?** `blockers` — a statement waiting on a lock is not a slow plan. If it is blocked, switch to runbook
   `find-what-is-blocking`.
3. **Plan it**: `explain` (never executes). If the person already ran `EXPLAIN ANALYZE` on the Plan screen, `get_plan` and use the
   actual figures. Read it with skill `explaining-plans`: flags first, deepest node first.
4. **The tables involved**: `table_describe` for each relation the plan scans — rows (estimate), size, dead tuples, last analyze, the
   indexes and how often each is used. `vacuum_state` and `bloat` if heap fetches or dead tuples look high.
5. **Indexes**: `index_advice` — unused, duplicate, invalid, and foreign keys with no index. Check whether an index the plan should use
   exists but is invalid (a failed `CONCURRENTLY`) or does not match (an expression, a different column order, a collation).
6. **Explain** in three to five sentences: where the cost goes, the cause, the fix. Be honest about estimates: without `ANALYZE` the
   plan shows what the planner expects, not what happened.
7. **Offer one fix**, in this order of preference:
   - stale statistics → "a DBA can run ANALYZE on <table> from Maintenance";
   - a missing index → runbook `draft-an-index`;
   - a query rewrite → write it and offer to put it in the person's editor (they run it at their level);
   - a setting (`work_mem` for a disk sort) → say so; changing server settings is the owner's.
8. If the person agrees to an index: on a workbench, `change_set_propose`; on an installed application, `migration_draft_create`, then
   `rehearsal_run` and report the measured lock.

**Never**: run the query, ask for rows to "see the data", promise a speed-up you have not measured, or put a literal value from the
person's query into a draft (normalize it: `$1`).
