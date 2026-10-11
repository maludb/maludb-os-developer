# Build spec: structure, DDL and dependencies (slice 2)

What exists at the end: every object family's page tabs beyond slice 1's skeleton — **DDL** (from the generators, with the commented DROP,
Copy and Open in the editor), **Dependencies** (what it uses, what uses it), **Impact** (what breaks if I drop or alter this object or
column: the full reach of CASCADE and the views to drop and recreate, in order), **Privileges** (owner, grants, the default privileges that
apply), **Statistics** (size, row estimate, scans, dead tuples, last vacuum and analyze, column statistics), the **join path** between two
tables emitted as a JOIN into the editor, **the danger zone** at the foot of every object page made real (TRUNCATE · DROP · DROP CASCADE,
each listing what it reaches, each opening slice 4's form), and **roles** read-only (the list; a role's attributes, memberships with their
inherit and set options, effective privileges per database). Design §6.3, §6.7 (roles); `docs/build-specs/ddl-generators.md` is this
slice's engine and its golden and hostile-name suites run here first. **Everything in this slice is read**: no action; every change it
offers opens a form or Change review (slice 4).

It replicates slice 1's object page (the CRUD exemplar): the same page shell, header (the target's class badge, colour and my level), crumbs
`Databases › {datname} › {schema} › {family} › {name}`, tab bar, `?back=` handling and handler order. **Read slice 1's built files first.**

Door calls (the-door.md's named library, as `developer_meta`, counted not rowed): `object_ddl`, `object_describe`, `table_describe`,
`object_dependencies`, `impact`, `fk_graph`, `object_privileges`, `role_list`, `role_describe`, `object_statistics`, `column_statistics`
(read tier — `pg_stats` shows a column only to a role with `SELECT` on it), `relation_sizes`. PHP reads nothing of a target itself.

## Divergences from the design
1. **The danger zone's partial is this slice's; slice 1 leaves its slot.** `app/views/objects/partials/danger-zone.php` renders on
   `object-view` (slice 1's screen) from `impact`'s counts: **TRUNCATE** (tables), **DROP**, **DROP … CASCADE** — CASCADE a visibly
   distinct red outline button with the number of objects it reaches; each opens `/forms/{datname}/{family}/drop` (or `truncate`) with
   `object` and `cascade` set. On an installed application the button reads **Draft a migration to drop …**; on a kernel, memory,
   development or extension-member object the zone is not rendered (a sentence says why).
2. **PL/pgSQL bodies are outside `pg_depend`.** Impact and dependencies say so on every routine and on every table a routine might touch:
   *"Function bodies are not tracked by PostgreSQL's dependencies; this list does not include them."* No text scan of bodies (design §6.3).
3. **Column statistics are read on the read tier, not meta**: a column the person may not read at their level shows no statistics
   (*masked*); on a kernel or memory database the Statistics tab shows table-level figures only.

## Who may do what
| Screen | Right | Rule |
|---|---|---|
| every screen of this slice | `catalog.read` | the target visible to me (class: application, development, kernel, own for an admin, workbench for its owner) — else 404 |
| Statistics' column statistics | `catalog.read` + a level of `masked` or `rows` on the target | only the columns I may read |
| the danger zone's buttons | `changes.prepare` (people and agents may prepare; a form is a person's screen) | the class gives a button (workbench: the change; application: a draft) |
| `roles-list`, `role-view` | `catalog.read` | the cluster's roles are names and attributes — never a password (none is readable) |

## Screens (tables for objects, columns, privileges and dependencies; 375 px first — every screen is a reading screen)
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `object-ddl` | `/db/{datname}/o/{address}/ddl` | the DDL in a `<pre>` (escaped, monospace, wrapping at 375), the commented DROP below it, **Copy**, **Open in the editor** (`/db/{datname}/sql?sql=` — a POST-less link carrying no more than 8 kB; a longer DDL opens the editor with `object=` and slice 3 fetches it), the source chip (`pg_get_def` / `generator` / `mixed`) and the generator version; an extension member says "Member of extension `x` — read-only" |
| `object-dependencies` | `/db/{datname}/o/{address}/dependencies?direction=` | two tables, **Uses** and **Used by**: family icon, the object (a link to its page), how (`normal` / `auto` / `internal` / `extension` / `partition`), depth; chips Both · Uses · Used by; the routine note |
| `object-impact` | `/db/{datname}/o/{address}/impact?column=&verb=` | verb chips Drop · Alter type · Rename · Drop NOT NULL (and a column select for a table); **what breaks** — a table of the objects reached with `cascade` / `restrict` / `rewrite`, their depth and family; **the recreate order** — the views to drop (deepest first) and recreate (reverse), one transaction, ACCESS EXCLUSIVE on each named; the routine note; **Prepare this change →** (slice 4's form with the fields filled) |
| `object-privileges` | `/db/{datname}/o/{address}/privileges` | the owner; a table of grantee (a role link, `PUBLIC` in bold), privilege, grantable, grantor; column grants grouped under their column; the default privileges that would apply to a new object here; **Grant or revoke →** (slice 4's grants form — a workbench change or a draft, R64); a `PUBLIC` `EXECUTE` on a `SECURITY DEFINER` function in `text-bg-warning` |
| `object-statistics` | `/db/{datname}/o/{address}/statistics` | a table's or an index's size (total, heap, indexes, toast), row estimate (`reltuples`, labelled *estimated*), seq and index scans, tuples inserted/updated/deleted/HOT, live and dead tuples, last vacuum/autovacuum/analyze/autoanalyze; an index's size, scans, `indisvalid`; the columns' `null_frac`, `n_distinct`, `avg_width`, correlation, most common values **only as counts and widths** (never the values themselves — they are data) |
| `join-path` | `/db/{datname}/join-path?from=&to=&ignore=` | two table pickers (the record picker over the catalog index, family `table`), an ignore list (hub tables, chips); the path as steps `invoices.customer_id → customers.id (invoices_customer_id_fkey)`; the JOIN text with **Open in the editor**; "no path within 6 hops" when none |
| `roles-list` | `/roles?q=&login=` | the cluster's roles: name, login, superuser (`text-bg-danger`), createrole, createdb, replication, bypassrls (`text-bg-warning`), connection limit, valid until, member of (count); the tool's own roles marked "Developer's"; the installer-managed ones ("<key>_rw", …) marked "managed by the installer" |
| `role-view` | `/roles/{role}` | attributes; **Member of** and **Members** with PG 16's `admin` / `inherit` / `set` options; per-database settings; **Databases** — per registered database I may see: `CONNECT`, owner of (count), and the effective privileges on that database's schemas and tables (read by `role_describe` with `has_*_privilege`); read-only in v1 (DS14) |

## Files (exactly these)
- `html/db/object-ddl.php`, `html/db/object-dependencies.php`, `html/db/object-impact.php`, `html/db/object-privileges.php`,
  `html/db/object-statistics.php`, `html/db/join-path.php`, `html/roles/{index,view}.php`
- `app/features/objects/{ddl,dependencies,impact,privileges,statistics}.php`, `app/features/joins/queries.php`, `app/features/roles/{queries,present}.php`
- `app/views/objects/{ddl,dependencies,impact,privileges,statistics}.php` + `app/views/objects/partials/{danger-zone,dep-row,impact-row,grant-row,routine-note,family-icon}.php`
- `app/views/joins/index.php`, `app/views/roles/{index,view}.php`
- `app/developer/ddl/*` and `app/developer/rule_table.*` (ddl-generators' files — built in this slice), `html/internal/ddl.php`
- `app/pickers.php` gains `catalog_object` (the catalog index of one target, by name; params `datname`, `family`) — used by join-path and
  slice 4's forms
- `tests/phase3/slice2/{run.sh,lib.php,ddl.php,dependencies.php,impact.php,privileges.php,statistics.php,joins.php,roles.php,danger.php,walls.php,json.php,browser.mjs}`
  and `tests/ddl/*` (ddl-generators' suites)

## Query functions / door calls (signatures fixed)
- `object_ddl_view(PDO $pdo, string $datname, string $address): array{ddl, drop, source, version, member_of_extension}` — door `named object_ddl` → `dx_ddl_render()`
- `object_dependencies_view(string $datname, string $address, string $direction): array{uses, used_by, routine_note}` — door `named object_dependencies`
- `object_impact_view(string $datname, string $address, string $verb, ?string $column): array{reach, recreate_order, note}` — door `named impact`
- `object_privileges_view(string $datname, string $address): array{owner, grants, column_grants, defaults}` — door `named object_privileges`
- `object_statistics_view(string $datname, string $address): array{table, columns}` — door `named object_statistics` + `named column_statistics` (read tier)
- `join_path_find(string $datname, string $from, string $to, array $ignore): ?array{steps, join_sql}` — door `named fk_graph` (the target's foreign keys as edges), breadth-first search in PHP, at most 6 hops; the JOIN built with `dx_qualified()` and `dx_ident()`
- `roles_list(?string $q, ?bool $login, int $page): array{rows, total}` — door `named role_list` (against the tool's own database's connection, cluster-wide catalogs) · `role_view(string $role): ?array` — door `named role_describe`
- `danger_zone_model(string $datname, array $object, int $memberId): array{buttons, reason}` — from `impact` counts and the class

## MCP tools this slice makes real
`table_describe`, `object_describe`, `object_ddl` (with the bridge), `impact`, `object_dependencies`, `join_path`, `object_privileges`, `role_describe`.

## Manifest rows claimed
Screens (8): `object-ddl`, `object-dependencies`, `object-impact`, `object-privileges`, `object-statistics`, `join-path`, `roles-list`, `role-view`
Actions (0):

## Activity log events
`screen.view` on every screen, with `target_database_id` and the object's address in `after` (`{"address": "table:public.invoices"}`) —
never DDL text, never a statistic's value. The DDL's Copy and Open in the editor are not logged (they read what the page already shows).

## Status vocabulary
Source chips: `pg_get_def` `text-bg-light border`, `generator` `text-bg-light border`, `mixed`. "Member of extension x" `text-bg-secondary`.
Impact: `cascade` `text-bg-danger`, `restrict` `text-bg-warning`, `rewrite` `text-bg-warning`. `PUBLIC` bold. Role attributes: superuser
`text-bg-danger`, bypassrls `text-bg-warning`, "Developer's" `text-bg-info`, "managed by the installer" `text-bg-light border`. Index
`invalid` `text-bg-danger`. Ids: `object-tab-{tab}`, `ddl-copy`, `ddl-open-editor`, `dep-row-{n}`, `impact-verb-{verb}`, `impact-row-{n}`,
`impact-prepare`, `grant-row-{n}`, `join-from`, `join-to`, `join-open-editor`, `role-row-{name}`, `danger-truncate`, `danger-drop`,
`danger-drop-cascade`.

## Requirements claimed
MUSTs (17): R7, R8, R9, R10, R17, R63, R64, R65, R103, R105, T1, T2, T3, T4, T35, T43, S8

(R8 with slice 1, whose object page carries the columns, constraints, indexes, triggers, policies and partitions tabs; R64's grant wizard
ends in slice 4's Change review; R65's policy list is the object page's Policies tab and its editor is slice 4's form.)

## Out of scope for this slice
The forms and Change review (4); history of an object and compare (8); the data tab (5); editing roles, grants or default privileges as
cluster administration (Extended, DS14 — the grants form is slice 4's, on a workbench or as a draft); casts, operators and text search
beyond their catalog row (T47 Extended).

## Proof (`tests/phase3/slice2/run.sh`: scratch database `dx_dev2`; php -S on 9401, the fake kernel on 9402, the fakes on 9403; then the user-level Apache on 9407; Playwright from /var/www/web/node_modules; scratch roles `dx_proof_*` and scratch targets `dx_t2_*` with the owner's leave; the registry `--check`)
1. `tests/ddl/run.sh` green (golden round-trip, per object, keywords, hostile names, rules, bridge).
2. On `dx_t2_app` (the golden fixtures loaded, registered `application`, grants in place): every family's DDL tab renders and equals the
   renderer's output; an extension member is read-only; a routine shows the dependency note.
3. Dependencies and impact: dropping `customers.id`'s table reaches its FK and two views (one through the other) with the recreate order
   deepest first; altering a column used by a view lists the view; the counts agree with `DROP … CASCADE` run on a scratch copy.
4. Privileges: a `PUBLIC` `EXECUTE` on a `SECURITY DEFINER` function is flagged; column grants group under their column.
5. Statistics: an Engineer at `masked` sees no statistics for a `personal` column; values never appear (most common values as counts).
6. Join path: invoices → customers found in one hop; with `customers` ignored, through `orders` in two; no path → the sentence; the JOIN
   opens in the editor and parses (door `classify`).
7. Roles: the list marks the tool's and the installer's roles; a role page shows PG 16 membership options; no password field exists.
8. Walls: a Viewer reads everything here; a member with no role → 403; another person's workbench → 404; the kernel's database shows
   structure with no column statistics; a memory database's objects are not offered here (the memory section's).
9. JSON mode: every screen answers its presenter's whitelist; `object_ddl` through the records MCP equals the screen's DDL (the bridge).
10. 375 px: no horizontal scroll on any screen; a 2,000-line DDL wraps.

## Decisions taken here
1. The danger zone is this slice's partial on slice 1's page; on an installed application it drafts.
2. Most-common values and histograms are never shown — they are rows' values.
3. Join paths stop at 6 hops.

## Open questions
None.
