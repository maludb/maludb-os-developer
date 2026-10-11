---
name: reading-postgres
description: How to read a PostgreSQL 17 database the way a DBA does through Developer's tools — the catalog by object family, DDL (and what PostgreSQL cannot rebuild), dependencies and the reach of CASCADE, join paths, privileges, statistics, and what monitoring hides from a role without pg_monitor. Load before explaining any object, dependency or statistic.
---
# Reading PostgreSQL

## The catalog, not information_schema
The tools read `pg_catalog`: it shows what `information_schema` hides (partitioning, access methods, RLS, publications, exclusion
constraints) and keeps PostgreSQL's own type names. Objects are addressed by OID inside a request and by an **address** (type, names,
arguments) across requests, so a link survives a dump and restore.

**Families**: databases, schemas, tables (ordinary, partitioned, unlogged, inheritance, typed), columns, constraints (primary key,
foreign key, unique, check, exclusion — `NOT VALID` and `DEFERRABLE` matter), indexes (btree, hash, gist, spgist, gin, brin, and
pgvector's hnsw/ivfflat; partial, expression, `INCLUDE`), views, materialized views, sequences and identity columns, functions,
procedures, aggregates, triggers, event triggers, types (enum, composite, domain, range), extensions, roles, grants, default privileges,
RLS policies, publications, subscriptions, foreign servers, collations, statistics objects, comments, rules.

**Extension members are read-only** (every table in a MaluDB memory database belongs to the `maludb_core` extension). Say which
extension owns an object rather than suggesting a change to it.

## DDL
`object_ddl` returns the object's DDL with a commented DROP. PostgreSQL itself rebuilds DDL for views, functions, indexes,
constraints, triggers, rules and statistics objects; the tool's own generators build tables, sequences, types, schemas, roles,
policies, grants and aggregates. If DDL looks incomplete, say so — never fill a gap by guessing.

## Dependencies and impact
`impact` answers *what breaks if I drop or alter this* from `pg_depend` and friends:
- `normal` dependencies need `CASCADE`; `auto` ones go with their parent (an index with its table, an owned sequence); `internal`
  ones are part of the object (an identity sequence, a constraint's index).
- **Views depend on every column they read.** `ALTER COLUMN TYPE` on such a column fails ("used by a view or rule") until the views are
  dropped and recreated in one transaction — which holds `ACCESS EXCLUSIVE` on every view involved.
- **PL/pgSQL bodies are not tracked.** A function that names a table in its body does not show as a dependent. Say: "functions whose
  bodies use it are not listed — PostgreSQL does not track them."

`join_path` finds the shortest path over foreign-key column pairs, skipping hub tables on the ignore list. Give the JOIN with its
`ON` clauses and say how many hops.

## Privileges
`object_privileges` lists grants (grantee `PUBLIC` included) from the ACLs; `role_describe` gives a role's attributes, memberships
(with PostgreSQL 16's inherit/set options) and effective privileges. Note: by default `PUBLIC` may execute every function — a
`SECURITY DEFINER` function then runs with its owner's rights for anyone who can call it.

## Statistics
`table_describe` carries size, the row **estimate** (`reltuples` — label it an estimate), dead tuples, last (auto)vacuum and analyze,
index scans. `pg_stats` (behind `bloat`) and sequence values show only what the tool's role may read — say "not visible to the tool"
rather than "zero" when a figure is missing.

## Monitoring and what it hides
`activity_now`, `blockers` and `locks` read `pg_stat_activity` and `pg_locks` as a role with `pg_monitor`. Query texts are shown
**normalized** (literals become `$1`, `$2`): never ask for the raw text. A text cut short by `track_activity_query_size` shows as
`<not normalisable>`. A superuser's session cannot be cancelled by the tool — a DBA does that from `psql` as `postgres`.

## Saying it well
Name the database and its class, the schema and the object; give counts and sizes with units; separate what the catalog says from
what you infer; link every object you name.
