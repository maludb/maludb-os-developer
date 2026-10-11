---
name: explaining-plans
description: Reading a PostgreSQL 17 EXPLAIN plan for a person — the deterministic flags first (misestimates, disk sorts, hash batches, lossy bitmaps, slow sequential scans, stale statistics, heap fetches, never-executed nodes), then a short explanation; why the agent's explain never executes; what ANALYZE, BUFFERS, SERIALIZE and GENERIC_PLAN add. Load before explaining any plan.
---
# Explaining plans

## Your explain never executes
`explain` plans the statement without running it — so it reads no data and changes nothing. You get estimates (rows, cost), not
actual times. Planning still checks privileges: a statement naming a column the tool may not read is refused, and you say so.
`EXPLAIN ANALYZE` executes the statement; it is a person's choice on the Plan screen (reads only on an installed application's
database; on a workbench a write is wrapped in a rolled-back transaction and labelled). When a person shares a plan with actual
times (`get_plan`), read those.

## Flags first
Read the plan node by node, deepest first, and name these before anything else:
| Flag | Sign in the plan | Usually means |
|---|---|---|
| Misestimate | actual rows ÷ estimated rows beyond ×10 either way | stale or missing statistics, correlated columns (an extended statistics object), a function hiding a column |
| Disk sort | `Sort Method: external merge  Disk: …` | `work_mem` too small for this sort, or a sort an index could avoid |
| Hash batches | `Batches: N` > 1 | the hash spilled to disk |
| Lossy bitmap | `Heap Blocks: lossy=…` | the bitmap exceeded `work_mem`; rechecks on whole pages |
| Slow sequential scan | `Seq Scan` on a large table with a selective filter, `Rows Removed by Filter` large | a missing or unusable index |
| Stale statistics | `last_analyze` / `last_autoanalyze` old against `n_mod_since_analyze` | run ANALYZE (a DBA's maintenance job) |
| Heap fetches | `Index Only Scan … Heap Fetches` large | the visibility map is behind — vacuum |
| Never executed | `(never executed)` | a branch the data never took — not a problem, but not evidence either |
| Nested loop over many rows | `Nested Loop` with a large outer side and an inner scan per row | a misestimate upstream, or a missing index on the inner side |

## Then explain, briefly
Two or three sentences: where the time (or the estimated cost) goes, why, and what would change it. Use the node names the person
sees. Exclusive time (the node minus its children) points at the culprit; inclusive time at the subtree. Loops multiply: an inner node's
time is per loop.

## What the options add (PostgreSQL 17)
- `BUFFERS`: shared hits and reads — reads mean disk or OS cache. `track_io_timing` is off on this server, so there are counts, no I/O
  times.
- `SERIALIZE` and `MEMORY` (new in 17): the cost of turning rows into output, and the planner's memory.
- `SETTINGS`: non-default planner settings in force.
- `GENERIC_PLAN`: a plan for a `$1`-parameterized statement — what `top_statements` gives you, normalized.

## Next steps you may offer
- An index → runbook `draft-an-index` (proposed or drafted, never created by you).
- Statistics → say a DBA can run ANALYZE from the Maintenance screen; an extended statistics object is DDL (a proposal).
- A rewrite of the query → put it in the person's editor; they run it.
Never claim a speed-up you have not seen measured; say "should" and why.
