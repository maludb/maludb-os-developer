> Research report for `docs/developer-design.md` §0, written 2026-10-11 by a research agent of the planning session.

# The field: database development and administration tools, screen by screen

This report looks at the tools a product designer would study before building `maludb-os-developer`, a web tool in the spirit of phpMyAdmin for PostgreSQL 17 and MaluDB. It describes what each tool's screens do, what they do well, and where they hurt users. It then turns that into a feature matrix, a ranked list of v1 screens, numbered requirements, and a catalogue of failure modes with the guardrails the better tools add. Nothing here is a decision; section 7 lists the choices that belong to the owner.

## 0. Key findings

1. **phpMyAdmin's lasting gifts are vocabulary and transparency, not its MySQL screens.** Three of them:
   - The same verbs appear as tabs at server, database and table level.
   - The SQL behind every click is shown above every result.
   - It has a dry run: *Simulate query* and *Rollback when finished*.

   Its weaknesses are the lessons:
   - its confirmations are client-side regexes;
   - grid edits are allowed on rows with no key;
   - features vanish without its "pmadb" storage database;
   - work is tied to a PHP request.

   It is still at 5.2.3 (2025-10-08) and supports MySQL/MariaDB only.
2. **phpPgAdmin died of its architecture, not its design.** It had one PHP class per PostgreSQL version, a stale database layer, a frameset UI and one maintainer. Its last release was 2020-11-07. Its object model (schemas, domains, types, rules, operators, processes, locks, per-table autovacuum) is the right one for PostgreSQL. **Adminer** came back to life under its author (6.1.2, 2026-10-10). **AdminerEvo** was archived on 2025-01-24.
3. **pgAdmin 4 (9.18, 2026-09-17) is the completeness benchmark.** It is also a warning:
   - its dialogs are modal and heavy;
   - its tree is slow on big catalogs;
   - "View All Rows" stayed uncapped until 2026;
   - its AI read-only wrapper was bypassed twice in 2026.

   Its best patterns are DDL plus a commented DROP for every object, a SQL preview on every dialog, a Dependencies/Dependents view, staged grid edits, and a three-view explain.
4. **The field has converged on one grid-editing model.** Edits are held as pending changes, shown by colour (new/changed/deleted), previewed as SQL, and applied in one transaction. DBeaver, DataGrip, TablePlus, Beekeeper and pgAdmin all work this way, and Supabase joined in 2026. For a PHP tool, holding the change set on the server makes it survive reloads, sorts and session expiry, which fixes Beekeeper's documented footgun.
5. **No general-purpose tool tells you what a DDL statement will cost.** None shows the lock it takes, whether it rewrites the table, or the safe alternative. That knowledge lives only in linters (Atlas's PG codes, squawk's 78 rules, strong_migrations). Joining the two at the moment of Apply is the clearest product gap in the field.
6. **Every guard short of a PostgreSQL role has been bypassed or leaks:** regexes (phpMyAdmin, Supabase, pgweb), read-only transaction wrappers (pgAdmin's 2026 CVEs, the reference MCP server), and client-side read-only flags (DataGrip, Postico). The robust pattern is a role without write privileges, one statement per call, server timeouts, and guards that fail closed.
7. **The safest AI pattern is now common:**
   - SQL generated into the editor or a diff, never auto-executed as a write;
   - reads run under a restricted role with caps;
   - what the model sees graded by an administrator (Supabase: schema / +logs / +data);
   - agent queries kept in the same history as people's (DataGrip 2026.2).

   The best index and plan advice in the field is deterministic, not an LLM (pganalyze, PoWA, splinter).
8. **Production safety is a bundle, not a colour.** DBeaver's *Production* connection type combines colour, write confirmations, manual commit and idle-transaction rollback. TablePlus requires a tag when a connection is created. A web tool should attach an environment label to every registered database and let the label drive behaviour.
9. **The most estate-specific footgun is drift.** A tool that ALTERs an installed application's tables bypasses that application's numbered migrations (Supabase documents exactly this failure). The owner must decide whether production application databases are edited directly, read-only, or changed only through generated migrations (section 7, O4).
10. **Nothing in the field knows MaluDB.** The nearest analogues are memory products: Zep's read-only graph assistant with provenance to episodes, Letta's memory editors, and Neo4j's graph/table toggle. mem0 removed its graph tab in April 2026, a sign that a canvas is not automatically what memory users want.
11. **Several useful pieces can be vendored under permissive licences with no Node on the server:** PEV2 plan viewer (PostgreSQL licence, Bootstrap 5.3), CodeMirror 6 lang-sql (MIT), DBML (Apache-2.0), splinter's lint views. Code from ChartDB (AGPL) or pgModeler (GPL) should be taken as ideas only.

**Deliverables:**
- a section per tool (§2);
- a feature matrix (§3);
- 18 ranked v1 screens (§4);
- **107 requirements: 64 MUST, 32 SHOULD, 11 LATER** (§5);
- 18 failure modes with a guardrail ladder (§6);
- 13 option sets and 8 open questions (§7).


## Contents

0. Key findings
1. Scope, method, and estate constraints that shape the UI
2. The tools, screen by screen
   - 2.1 phpMyAdmin · 2.2 Adminer, AdminerEvo, AdminNeo · 2.3 phpPgAdmin · 2.4 pgAdmin 4 · 2.5 Supabase Studio · 2.6 pgweb
   - 2.7 Desktop clients: DBeaver/CloudBeaver, DataGrip, TablePlus, Postico 2, Beekeeper Studio
   - 2.8 Modelling and documentation: pgModeler, ChartDB, Azimutt, DrawSQL, dbdiagram.io/DBML, dbdocs, SchemaSpy
   - 2.9 Plan visualisers: PEV2, explain.depesz.com, pgMustard
   - 2.10 Monitoring: pgHero, pganalyze, PoWA, pgwatch, pg_activity
   - 2.11 Schema change and review: Bytebase, Atlas, Liquibase, Flyway Desktop, plus squawk and strong_migrations
   - 2.12 AI features across the field, and how each guards writes
   - 2.13 The memory side: what exists for agent memory, and what does not exist for MaluDB
3. Feature matrix
4. Ranked v1 screens
5. Requirements R1–R107
6. How these tools fail users
7. Options and open questions for the owner

---

## 1. Scope, method, and estate constraints that shape the UI

**Method.** Each tool was read from primary sources: official documentation, source code on GitHub, release notes, and changelogs. Versions and maintenance status are as seen on 2026-10-11 unless another date is given. The research was split six ways and run in parallel, then merged here. Where a claim could not be confirmed at a primary source it is marked *unverified*.

**What this report leaves to the sibling reports.**
- *PostgreSQL implementation internals.* Catalog queries, how a PHP prefork server could hold a transaction across HTTP requests, and lock behaviour in depth.
- *MaluDB.* Its data model and API.
- *The estate's conventions.* Kit, roles, the kernel, approvals.
- *Security, CVE history and AI-agent safety.*

This report mentions those topics only where a screen depends on them.

**Estate constraints a designer must hold in mind while reading.**
- **No modals.** The builder's design system forbids modal forms and display surfaces. It has two exemptions: `hx-confirm` confirmations, and the one record-picker modal that chooses a record (`~/htmx-php-builder/skills/design-system/SKILL.md:24`).
  - Many tools below put the generated-SQL preview, the cell editor, the foreign-key lookup or the AI panel in a modal. Each of those has to become a page, an inline swap, or the record picker.
- **Every screen works at 375 px** (`SKILL.md:25`). A dense grid and a SQL editor cannot really be used at that width, so the design has to say which screens are read-mostly on a phone.
- **Agents and approvals.**
  - Approvals stay in the kernel and are decided by super-admins (`/var/www/CLAUDE.md:293`).
  - An application's actions reach agents through the kernel's actions server, with the approval hook in front (`/var/www/CLAUDE.md:184`).
  - Any AI that can write in this tool is therefore an estate question, not just a UI one.
- **Precedents already in the estate.**
  - **Boards** commits a built JavaScript bundle (Konva) with no Node on the server, which is the route for a vendored plan viewer or SQL editor.
  - **Data Lake** routes every read through one query service with an sqlglot allow-list and per-caller views, logged in `query_runs`.
  - Both are recorded in `/var/www/CLAUDE.md:39`.

---

## 2. The tools, screen by screen

### 2.1 phpMyAdmin (the owner's reference point)

**Status.**
- Latest stable is **5.2.3, released 2025-10-08**, a bugfix release. No 6.0 had been published as of 2026-10-11 (https://github.com/phpmyadmin/phpmyadmin/releases).
- The announcement says the team is "working towards the release of phpMyAdmin 6", which will require PHP 8.2+, and that support for 5 "is expected to end in the near future" (https://www.phpmyadmin.net/news/2025/10/8/phpmyadmin-523-is-released/).
- It supports MySQL and MariaDB only.
- The security page lists 228 PMASA advisories from 2003 to 2025 (https://www.phpmyadmin.net/security/). Details are left to the security sibling.
- It has no AI features (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/ChangeLog).

**Information architecture.** It has three rows of tabs, with the same verbs repeated and scoped at each level (`Menu.php`, https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Menu.php#L240-L563):
- **Server:** Databases, SQL, Status, User accounts, Export, Import, Settings, Binary log, Replication, Variables, Charsets, Engines, Plugins.
- **Database:** Structure, SQL, Search, Query, Export, Import, Operations, Privileges, Routines, Events, Triggers, Tracking, Designer, Central columns.
- **Table:** Browse, Structure, SQL, Search, Insert, Export, Import, Privileges, Operations, Tracking, Triggers.

This verb grid is the thing users learn once and use everywhere. It is the strongest argument for copying phpMyAdmin's shape.

| Screen | What it does | Good | Bad |
|---|---|---|---|
| **Navigation tree** | Databases → tables, views, routines and events. Groups databases by name prefix. A filter box appears once a node has 30 or more items. Keeps 10 **Recent** and 10 **Favourite** tables. Can nest tables on a `__` separator (https://docs.phpmyadmin.net/en/latest/config.html). | Recent and favourites; a filter that appears only when needed. | Built for MySQL's two levels. It has no schema level, which PostgreSQL needs. |
| **Structure** | Column grid (name, type, collation, null, default, comments, extra) with per-column actions: Change, Drop, Primary, Unique, Index, Fulltext, Distinct values, add to central columns. Then Add columns, **Move columns** (drag), the index table, partitions, Propose table structure, Normalize (a 3NF wizard), Track table, **Preview SQL** (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/table/structure/display_structure.twig). | One-click index from a column. Preview SQL before applying. | Several actions are MySQL-only: column order needs `ALTER … AFTER`, and "Propose" relies on `PROCEDURE ANALYSE`, which MySQL 8 removed. |
| **Browse** | Paged grid. `MaxRows` defaults to 25 when the query has no LIMIT; "Show all" is offered only under 500 rows. Filter rows (client-side), sort by key. Extra options: partial or full text (`LimitChars` 50), relational key or display column, BLOB display. Per-row Edit, Copy and Delete, then "With selected" (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/display/results/table.twig). | **The generated SQL is shown above every result**, with timing and links to Edit, Explain and Refresh (`ShowSQL`, config.html). This is the best teaching device in the field. | Edits on a result with no unique column show only a warning and can hit duplicate rows (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Sql.php#L1370-L1400). The "~" row count is an estimate. |
| **Grid edit** | Double-click a cell to edit in place (`GridEditing`). With `SaveCellsAtOnce` (default false), edited cells are saved together through "Save edited data" (config.html). | A rudimentary pending-changes buffer. | Off by default, so each cell saves on its own. |
| **Automatic LIMIT** | Appends `LIMIT pos, max_rows` to any SELECT that parses cleanly and has none (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Sql.php#L375-L394). | Guards against an unbounded read. | Rewrites the SQL, which can change semantics. |
| **SQL tab** | CodeMirror editor with lint before run and table/column autocomplete. Template buttons, Format, Bind parameters, a column picker, bookmark this query. Options **Retain query box**, **Rollback when finished**, **Enable foreign key checks**, and a **Simulate query** button (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/sql/query.twig). | "Rollback when finished" runs the statements in a transaction and rolls back — a dry run, though it refuses anything but DML on InnoDB (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Import.php#L1371-L1460). **Simulate query** rewrites an UPDATE or DELETE as a SELECT over the same WHERE and reports the matched rows (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Import/SimulateDml.php). | The Simulate result opens in a modal. The confirmation is a client-side regex (see guardrails below). |
| **Search** | Query by example: operator and value per column, range search, Zoom search (a scatter plot of two columns). **Find and replace** shows a preview of original against replaced values, with counts (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/table/find_replace/replace_preview.twig). | Preview before a bulk replace. | A busy form. |
| **Insert** | One form row per column, each with a function (NOW(), UUID()) and a value. "Then: go back / insert another / edit next". **Preview SQL**. Foreign keys get a dropdown under 100 rows, otherwise a popup window (`ForeignKeyMaxLimit`) (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/table/insert/actions_panel.twig). | Fast data entry. | A popup window for the foreign-key lookup. |
| **Export / Import** | Quick or Custom export, saved **export templates**, some or all rows, a file-name template, compression, rename on export, about 15 formats. Import takes drag-and-drop, compressed files and a server upload directory. **Partial import** stops near the PHP timeout and resumes by skipping N queries, which "can break transactions" (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/import.twig; https://docs.phpmyadmin.net/en/latest/import_export.html). | Export templates. | Work tied to a PHP request (`ExecTimeLimit` 300 s) forces the partial-import hack. Large jobs belong in the background. |
| **Operations** | Rename, move, copy (structure, data, or both), table options, maintenance (Analyze, Check, Optimize, Repair), and one labelled box for **TRUNCATE / DELETE FROM / DROP** (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/table/operations/index.twig). | Destructive actions are concentrated in one danger zone with strong warnings. | — |
| **User accounts / Privileges** | Add a user with a global privilege grid; edit global, database and table privileges; copy a user. **User groups** hide menus, and the docs say this "only limits what a user sees, they are still able to use all the functions" (https://docs.phpmyadmin.net/en/latest/privileges.html). | Honest documentation. | A menu-hiding feature that users mistake for access control. |
| **Relation view / Designer** | Relation view sets foreign keys (or phpMyAdmin-internal relations) and the **display column**, the label shown for a referenced row. Designer is a canvas: create relations by drag, saved pages, **Build Query** (visual query), export to PDF/SVG (https://docs.phpmyadmin.net/en/latest/relations.html; https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/database/designer/main.twig). | The display column is a good idea for foreign-key display and pickers. | Needs the configuration storage. Internal relations exist only inside phpMyAdmin. |
| **Tracking** | Per-table versions of DDL and DML, with a report filtered by type, date and user, schema snapshots per version, and export as SQL (https://docs.phpmyadmin.net/en/latest/config.html; https://develdocs.phpmyadmin.net/phpmyadmin/PhpMyAdmin/Tracking/Tracking.html). | A change log. | Only captures changes made through phpMyAdmin. |
| **Central columns** | A per-database list of reusable column definitions (FAQ 6.36, https://docs.phpmyadmin.net/en/latest/faq.html). | A light data dictionary. | Rarely used. |
| **Bookmarks** | Saved queries, private or shared, with `/*[VARIABLE1]*/` parameters. A private bookmark named after a table **runs automatically when that table is browsed** (https://docs.phpmyadmin.net/en/latest/bookmarks.html). | Parameterised saved queries. | The auto-run bookmark silently changes what Browse means. |
| **Query history** | Kept in browser JavaScript, or in the configuration storage when `QueryHistoryDB` is on, capped at 25 (config.html). | — | Lost without the configuration storage. |
| **Server Status / Variables / Processes** | Processes with filters, "active only", auto-refresh and kill. A live-chart Monitor. An Advisor of rules over status variables. A Variables editor (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/server/status/processes/index.twig). | Advisor rules. Kill from the list. | MySQL-shaped. |

**Configuration storage.** Bookmarks, relations, the Designer, history, tracking, central columns, user groups and favourites all depend on the "pmadb" configuration storage database. Without it they quietly disappear (https://docs.phpmyadmin.net/en/latest/setup.html). **Lesson:** the tool's own state belongs in its own database from the first day.

**Guardrails.**
- `$cfg['Confirm']` (default on) produces "Do you really want to execute …", "You are about to DESTROY a complete table!" and "…TRUNCATE a complete table!" (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Controllers/JavaScriptMessagesController.php#L40-L47).
- The SQL-tab check is a **client-side regex** anchored at the start of the text, with the comment "TODO: find a way (if possible) to use the parser-analyser for this kind of verification" (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/js/src/functions.js#L705-L750).
  - It misses DROP VIEW, DROP FUNCTION, a destructive statement after the first one in a batch, and a statement behind a leading comment.
- `AllowUserDropDatabase` defaults to false (config.html).

### 2.2 Adminer, AdminerEvo, AdminNeo

**Status.**
- Adminer is **maintained by its original author again**. **6.1.2 was released 2026-10-10**, 6.0.0 on 2026-08-07 and 5.0.0 on 2025-03-07 (https://github.com/vrana/adminer/blob/main/CHANGELOG.md).
- It is a single PHP file.
  - Built-in drivers: MySQL, MariaDB, PostgreSQL, SQLite, MS SQL, Oracle.
  - Driver plugins: Elasticsearch, MongoDB, Redis, ClickHouse, DuckDB, Firebird and others (https://www.adminer.org/en/plugins/).
  - Plugins autoload from `adminer-plugins/`. Customisation is a subclass that overrides hooks (https://www.adminer.org/en/extension/).
- **Adminer Editor** is a data-only variant for end users. It shows no SQL, uses table and column comments as labels, and shows foreign keys by the referenced record's name (https://www.adminer.org/en/editor/).
- **AdminerEvo** began because Adminer had gone unmaintained for over two years. It was **archived on 2025-01-24**; its last release was 4.8.4 on 2024-04-07 (https://github.com/adminerevo/adminerevo).
- The pematon fork lives on as **AdminNeo**: v5.8.0 on 2026-09-16 (https://github.com/adminneo-org/adminneo).
- Conclusion: AdminerEvo is dead, and Adminer is the living line.

**Screens.** The page scripts are listed at https://github.com/vrana/adminer/tree/main/adminer.
- **Database overview.** A flat, dense table list with sizes, plus bulk Analyze, Optimize, Truncate, Drop, Move and Copy. There is no tree.
- **Select (browse).** Fieldsets for Select (columns, functions, aggregates), Search (column, operator, value, repeatable), Sort, Limit (default **50**) and Text length (default **100**) (https://github.com/vrana/adminer/blob/main/adminer/include/adminer.inc.php#L784-L793).
  - Ctrl+click edits a cell. A Modify/Save button stays disabled until something changes (6.0.0).
  - **"Whole result"** applies Edit or Delete to every row matching the filter, not just the page. Its only guard is a generic "Are you sure?", and the count shown may be an estimate (https://github.com/vrana/adminer/blob/main/adminer/select.inc.php#L686-L704).
  - Since 6.0.1, multi-row changes run in a transaction.
- **Edit row.** A function and value per column. Foreign keys get a select, or with the `edit-foreign-search` plugin a searchable, paged picker.
- **SQL command.** A textarea with highlighting from a plugin (CodeMirror, Monaco or Prism). Options: Limit rows, Stop on error, Show only errors. Upload a file or run one from the server, History, EXPLAIN, export a result without re-running it (6.0.0) (https://github.com/vrana/adminer/blob/main/adminer/sql.inc.php).
  - Since 6.0.0 it rolls back an unfinished transaction so that it does not break the following queries.
  - **SQL typed into the box gets no confirmation at all.** `confirm()` is attached only to the Drop, Truncate and Delete buttons (https://github.com/vrana/adminer/blob/main/adminer/include/html.inc.php#L164).
- **Alter table, indexes, foreign keys, triggers, checks, sequences, types, routines.** Small single-purpose forms. In PostgreSQL, views, routines and types are altered inside a transaction (6.0.0).
- **Database schema.** A read-only diagram of tables linked by foreign keys. Tables are dragged into place, and the positions are kept in a permanent-link URL (https://github.com/vrana/adminer/blob/main/adminer/schema.inc.php).
- **PostgreSQL gaps.** The PostgreSQL driver omits `privileges`, `processlist` and `status` from its `support()` list (https://github.com/vrana/adminer/blob/main/adminer/drivers/pgsql.inc.php#L1492-L1498). Roles exist only as a user plugin, and there are no RLS policies, no lock view and no plan viewer.

**Guardrails.**
- A generic confirm on the buttons only.
- Since 6.0.0, a login is refused for servers that accept any password.
- Plugins:
  - `before-unload` warns before leaving a changed form;
  - `remote-color` shows a red strip when the database is not local;
  - `timeout` sets a query timeout;
  - `sql-log` logs every query;
  - `login-otp` and `login-passkey` add second factors (https://www.adminer.org/en/plugins/).

**AI.** The official **sql-gemini** plugin (since 5.1.0) builds a prompt from the `CREATE` statements of every table in the database and sends it to Google's API.
- It replaces the SQL box with the reply, and nothing runs until the user presses Execute (https://github.com/vrana/adminer/blob/main/plugins/sql-gemini.php#L16-L47).
- It ships a shared default key; the key is not reproduced here.
- Community plugins do the same for Claude, Ollama and ChatGPT.
- The guard is a person in the loop. There is no classification of the SQL, the schema leaves the server, and the key is shared.

### 2.3 phpPgAdmin (dead upstream: why)

**Status.**
- The last upstream release was **7.13.0 on 2020-11-07**, which added PostgreSQL 13 support and "provisional" 14 support and was the last release for PHP 7.2 (https://github.com/phppgadmin/phppgadmin/releases/tag/REL_7-13-0).
- The last commit was on 2023-12-17 (https://github.com/phppgadmin/phppgadmin/commits/master).
- The issue "PHP 8 support" has been open since 2020-12-03 (https://github.com/phppgadmin/phppgadmin/issues/119). Community PHP 8 pull requests were never merged.
- A reported RCE (CVE-2023-40619) received no maintainer response (https://github.com/phppgadmin/phppgadmin/issues/174).
- Debian ships a community fork instead: sid has 7.14.8 (https://packages.debian.org/source/sid/phppgadmin; https://github.com/ReimuHakurei/phpPgAdmin).

**Why it died.**
1. **One PHP class per PostgreSQL version**, `Postgres74.php` through `Postgres13.php`. Every major release needed new code, and wiring the inheritance chain wrongly broke older servers (https://github.com/phppgadmin/phppgadmin/tree/master/classes/database).
2. **A stale bundled ADOdb layer and a frameset UI.** PHP 8 broke both, and nobody merged the fixes.
3. **Too few maintainers.** Security reports went unanswered, and distributions moved to a fork.
4. **Export shelled out to `pg_dump`,** whose version had to match the server's (https://github.com/phppgadmin/phppgadmin/blob/master/conf/config.inc.php-dist).

**What it got right.** It had the PostgreSQL object model (https://github.com/phppgadmin/phppgadmin/blob/master/classes/Misc.php):
- The hierarchy was server → database → **schema** → object.
- Its tabs covered domains, aggregates, types, operators, operator classes, conversions, casts, languages, full-text configurations, dictionaries and parsers, rules, constraints, **processes** and **locks**, the latter two refreshing every 3 s.
- A per-table **Admin** tab ran VACUUM, ANALYZE, CLUSTER and REINDEX, and edited **per-table autovacuum settings**, showing values that differ from the defaults in red (https://github.com/phppgadmin/phppgadmin/blob/master/admin.php).
- `show_advanced = false` hid the rarely administered object families to keep the tree usable.
- The settings were honest: `owned_only` "does not in any way prevent your users from seeing other database by other means" (config.inc.php-dist).

**Lessons.**
- Detect capabilities from the catalog by feature, not by a class per version.
- Target one supported major version (17) and state compatibility explicitly.
- Own the security process.
- Never shell out to version-coupled binaries without checking their versions.

### 2.4 pgAdmin 4

**Status.**
- **v9.18 was released 2026-09-17** and supports PostgreSQL and EDB Advanced Server 14–18 (https://www.pgadmin.org/docs/pgadmin4/latest/release_notes_9_18.html).
- Releases are monthly. The licence is the PostgreSQL licence (https://www.pgadmin.org/licence/).
- **Server mode** is multi-user with each user's files in `STORAGE_DIR`. pgAdmin "requires that only a single Python process is used" so that a browser session stays bound to the same database connection (https://www.pgadmin.org/docs/pgadmin4/latest/server_deployment.html).
  - This is the clearest public statement of a constraint a PHP tool shares: **an open transaction across HTTP requests needs a process that holds the connection.**
  - Whether we build one is a question for the internals sibling. It decides the transaction UI (section 7, O1).

**Object explorer.**
- The tree runs server groups → servers → databases → schemas → object-type folders, covering every object family PostgreSQL has (https://www.pgadmin.org/docs/pgadmin4/latest/managing_database_objects.html).
- Context menus carry Backup, CREATE Script, **Drop / Drop (Cascade) / Drop (Force)**, the Grant Wizard, Maintenance, Properties, Restore, **Truncate / Truncate Cascade**, and View First 100 / Last 100 / **All Rows** / Filtered Rows (https://www.pgadmin.org/docs/pgadmin4/latest/tree_control.html).
- Dragging a node into the editor pastes its quoted, qualified name.
- **Search Objects** matches names only, needs at least 3 characters, and selects the object in the tree (https://www.pgadmin.org/docs/pgadmin4/latest/search_objects.html).
- **Bad: the tree does not scale.** A 10,000-table schema made loading and scrolling slow (https://www.postgrespro.com/list/thread-id/2330275). An older version enumerated objects one query at a time (https://www.postgresql.org/message-id/7B28FBB8-DAFA-4731-8859-112FE3CA7D3F%40satshot.com).

**Main panel tabs** (https://www.pgadmin.org/docs/pgadmin4/latest/tabbed_browser.html):
- **Properties.**
- **SQL**: reverse-engineered DDL for any object, with a commented-out DROP. Users rely on it constantly.
- **Statistics.**
- **Dependencies / Dependents**, from `pg_depend`, with the dependency type. This is a pre-DROP impact view.
- **Dashboard.**
- **Processes**: background jobs.

**Properties dialogs.**
- What they do: the Table dialog has tabs General, Columns, Constraints (PK, FK, Check, Unique, Exclude), Advanced (RLS, storage parameters), Partition, Parameter (per-table autovacuum), Security and **SQL**. The SQL tab "displays the SQL code generated by dialog selections … for review" (https://www.pgadmin.org/docs/pgadmin4/latest/table_dialog.html).
- Good: the DDL is previewed before it is applied, and the Grant Wizard, ERD and Schema Diff end the same way.
- Bad: the dialogs are modal and deep. A "Confirm before Close/Reset" preference exists because unsaved dialog edits used to be lost (https://www.pgadmin.org/docs/pgadmin4/latest/preferences.html).
- Bad: the preview never says what a statement **costs**. It does not show the lock level, and nothing warns that an `ALTER COLUMN TYPE` rewrites the table.

**Query Tool** (https://www.pgadmin.org/docs/pgadmin4/latest/query_tool.html; https://www.pgadmin.org/docs/pgadmin4/latest/query_tool_toolbar.html):
- **Layout.** Editor tabs Query, **History**, Scratch Pad and **AI Assistant**; output tabs Data Output, **Explain**, Messages (the error position is underlined in the editor) and Notifications.
- **Running.** Run the script (F5) or the statement at the cursor; Stop. EXPLAIN and EXPLAIN ANALYZE with Buffers, Costs, Generic Plan, Memory, Serialize, Settings, Summary, Timing, Verbose and WAL.
- **Transactions.** **Auto commit?** and **Auto rollback on error?** toggles, explicit **Commit** and **Rollback** buttons, and a status icon for the connection and transaction, refreshed every N seconds.
  - A failed save rolls back to an automatic SAVEPOINT.
  - "Prompt to commit/rollback active transactions?" fires when the tool is closed (preferences.html).
- **Editable results.** Allowed only when every column comes from one table and **all primary-key columns are in the result**. A pencil marks editable columns and a lock read-only ones.
  - Edits are **staged** ("Changes staged") and sent by **Save Data Changes (F6)**.
  - Separate prompts guard unsaved changes on exit and on browser close.
- **Row limits.**
  - A Limit selector, batch fetching, and optional server-side cursors. The cursors work only in transaction mode and give no total count.
  - **"View All Rows" stayed uncapped until 9.17 (2026-07)**, which added a cap preference (https://www.pgadmin.org/docs/pgadmin4/latest/release_notes_9_17.html).
- **History.** Time, text, rows, duration and messages per query. 20 per database by default, kept per user across sessions.
- **Explain panel.**
  - Graphical: node icons and an SVG download.
  - **Table**: exclusive and inclusive time coloured at more than 10/50/90 % of the total, and row misestimates coloured at 10×/100×/1000×.
  - **Statistics**: per node type and per table.
  - **AI Insights.**
- **View/Edit Data** (https://www.pgadmin.org/docs/pgadmin4/latest/editgrid.html).
  - The same grid. It is read-only without a primary key, and views are read-only.
  - **An empty cell becomes NULL and `''` an empty string**, an opaque convention.
  - Filters take raw WHERE text; the sort grid sets NULLS placement.
  - JSONB gets a rich editor.
  - 9.16 fixed that editor stripping trailing zeros and rewriting large integers on save (https://www.pgadmin.org/docs/pgadmin4/latest/release_notes_9_16.html). **Lesson: never round-trip a value the user did not change.**

**ERD tool.**
- Generates a diagram from a database, a schema, or a table with a traversal depth. Notes, auto-align, many-to-many link tables.
- **Generate SQL** opens the Query Tool with the script and never applies anything itself (https://www.pgadmin.org/docs/pgadmin4/latest/erd_tool.html).

**Schema Diff.**
- Compares two databases or schemas: Identical / Different / Source only / Target only, with a three-panel DDL view and ignore options for owner, whitespace, tablespace and grants.
- **Generate Script** never applies, and dependencies are not resolved across schemas (https://www.pgadmin.org/docs/pgadmin4/latest/schema_diff.html).

**Dashboard.**
- Activity graphs: sessions, transactions per second, tuples, block I/O.
- A **State** tab with sessions, **locks** and **prepared transactions**. **Cancel** and **Terminate** are separate actions, and Terminate is confirmed.
- Configuration and Logs views, and long-running-query thresholds as preferences (tabbed_browser.html).

**Tools.**
- **Backup and Restore** wrap pg_dump and pg_restore as background jobs (https://www.pgadmin.org/docs/pgadmin4/latest/backup_dialog.html).
  - 9.18 fixed argument and connection-string injection through a database name supplied by the client (release notes 9.18). **Lesson: never build CLI arguments from request data.**
- **Maintenance** runs VACUUM, ANALYZE, REINDEX (incl. CONCURRENTLY) and CLUSTER as jobs (https://www.pgadmin.org/docs/pgadmin4/latest/maintenance_dialog.html).
  - It does not warn that VACUUM FULL and CLUSTER take an ACCESS EXCLUSIVE lock.
- **Import/Export Data** is built on COPY, including PostgreSQL 17's ON_ERROR (https://www.pgadmin.org/docs/pgadmin4/latest/import_export_data.html).
- **Grant Wizard.** Select objects, then privileges per grantee, then **Review Selection showing the SQL** (https://www.pgadmin.org/docs/pgadmin4/latest/grant_wizard.html).
- **Debugger.** For PL/pgSQL; needs superuser and `plugin_debugger` in `shared_preload_libraries`.
  - Direct debugging, or in-context debugging that suspends another session at a breakpoint (https://www.pgadmin.org/docs/pgadmin4/latest/debugger.html).
- **PSQL tool.** **Disabled by default in server mode** because "users can run arbitrary shell commands through psql" (https://www.pgadmin.org/docs/pgadmin4/latest/psql_tool.html).

**AI (added in 9.13, 2026-03-05)** (https://www.pgadmin.org/docs/pgadmin4/latest/release_notes_9_13.html; https://www.pgadmin.org/docs/pgadmin4/latest/ai_tools.html):
- **Providers.** Anthropic, OpenAI and OpenAI-compatible endpoints (9.14), Ollama, Docker Model Runner. **None is enabled by default**, and nothing is sent unless a feature is invoked.
- **AI Reports.** Security, performance and schema design, with findings rated Critical / Warning / Advisory / Good, downloadable as Markdown.
- **AI Assistant chat** turns natural language into SQL. Its output has **Copy / Insert / Replace** buttons and never runs itself.
  - The assistant can run its own exploratory queries "within a read-only transaction and limited to 1000 rows" (https://www.pgedge.com/blog/ai-features-in-pgadmin-the-ai-chat-agent).
- **AI Insights** on EXPLAIN suggests indexes, ANALYZE and settings changes, each with Copy and Insert.
- **The read-only guard was bypassed twice in 2026.**
  - CVE-2026-12045, fixed in 9.16: multi-statement payloads planted by prompt injection committed past the READ ONLY wrapper.
  - CVE-2026-17351, fixed in 9.17: sqlparse and PostgreSQL disagreed on string lexing under `standard_conforming_strings` (release notes 9.16 and 9.17; https://api.osv.dev/v1/vulns/CVE-2026-17351).
  - The fix is a dedicated single-use read-only connection using the extended protocol, which refuses multiple statements.
  - Detail belongs to the security sibling. The UI lesson is that **an AI read path is a database role, not a wrapper.**

**Overall.**
- **Well.** Complete object coverage; DDL and a commented DROP per object; a SQL preview on every dialog; dependencies; staged grid edits; explicit commit and rollback; a three-view explain; diff and ERD tools that generate scripts rather than applying them; background jobs.
- **Badly.** Modal and dialog-heavy; a slow tree on big catalogs; transaction state reduced to a small icon; "View All Rows" uncapped until 2026; an opaque NULL convention; no lock cost shown for DDL or maintenance; a heavy run of security fixes in 2026.

### 2.5 Supabase Studio

**Status.**
- Studio lives in the `supabase/supabase` monorepo under **Apache-2.0** (https://github.com/supabase/supabase).
- It is self-hostable. A self-hosted Studio is protected by **one basic-auth user** (`DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`), and AI needs your own OpenAI key (https://supabase.com/docs/guides/self-hosting/docker).
- Dashboard queries "run as `postgres` and are tagged with a `-- source: dashboard` comment" (https://supabase.com/docs/guides/database/postgres/roles). The tag is cheap attribution, worth copying.

**Table Editor.**
- A spreadsheet grid. New tables get `id` and `created_at`, and **RLS is switched on automatically** for tables created in the dashboard (https://supabase.com/docs/guides/database/tables).
- Studio 2.0 added inline JSON editing, a cascade choice in the foreign-key side panel, and a **foreign-key row selector** that picks the referenced row and jumps to it (https://supabase.com/blog/supabase-studio-2.0).
- **Edits were saved immediately, cell by cell**, until a feature preview of **2026-02-04**, "Queue table operations". It lets users "batch edit them, view them in a rich diff and then save it in a single transaction". Supabase asked whether it should become the default (https://supabase.com/changelog/42460-queue-table-inserts-edits-and-deletes-on-the-table-editor).
- So the industry is converging on **queue → diff → one-transaction save**. For a stateless PHP backend this pattern also removes any need to hold a transaction across requests.

**SQL Editor.**
- Snippets in folders, favourites, and sharing to the project (https://supabase.com/blog/supabase-studio-3-0).
- **Row-limit dropdown.** No limit / 100 / 500 / 1,000 (https://raw.githubusercontent.com/supabase/supabase/master/apps/studio/components/interfaces/SQLEditor/SQLEditor.constants.ts).
  - The auto-limit applies **only** to a single statement that starts with `select` and has no comments (https://raw.githubusercontent.com/supabase/supabase/master/apps/studio/data/sql/utils.ts).
  - A script, a `WITH … SELECT`, or a commented query runs unbounded.
- **Pre-run safety warning** (`analyzeQueryIssues`, https://raw.githubusercontent.com/supabase/supabase/master/apps/studio/components/interfaces/SQLEditor/SQLEditor.utils.ts). It blocks behind a confirmation on:
  - destructive statements (drop, delete, truncate, `ALTER TABLE … DROP COLUMN`, including inside EXECUTE strings);
  - **UPDATE without WHERE** (PR #28458, 2024-09-20, https://github.com/supabase/supabase/pull/28458);
  - ALTER DATABASE that would block connections;
  - **CREATE TABLE without RLS**.
  - The detection is regex and heuristics. A bug once skipped the warning altogether (https://github.com/supabase/supabase/pull/33801).
- **Role impersonation.** Run as `postgres`, `anon`, or `authenticated` as a chosen user. Studio mints a JWT so that RLS applies (https://supabase.com/blog/studio-introducing-assistant).
- **RLS Tester** (preview, 2026-04-24). Shows which policies a query evaluated. **SELECT only**, "because mutations could trigger side effects" (https://supabase.com/changelog/45233-feature-preview-rls-tester).
- **AI edits** appear as a **diff to accept or reject**. A disclaimer comment is inserted: "Always verify the output before executing" (supabase-studio-3-0; SQLEditor.constants.ts).

**AI Assistant (v2, 2024-12-02)** (https://supabase.com/blog/supabase-ai-assistant-v2):
- **What it covers.** Schema design, SQL, debugging, RLS policies, functions and triggers. "Basic select queries run automatically."
- **Approval lives in the tool.** The current system prompt says "The tool implementation handles user confirmation" and "Never call `execute_sql` … in parallel … Each requires user approval" (https://raw.githubusercontent.com/supabase/supabase/master/apps/studio/lib/ai/prompts.ts).
- **Graded data exposure.** The organisation's AI opt-in level is `disabled` | `schema` | `schema_and_log` | `schema_and_log_and_data` (https://raw.githubusercontent.com/supabase/supabase/master/apps/studio/hooks/misc/useOrgOptedIntoAi.ts).
  - The level limits which tools the assistant may use and whether it reads query results.
  - The assistant can ask for a higher level but cannot set it.
  - This is the best model in the field for deciding what an AI sees.

**Other screens.**
- **RLS policy editor.** SQL first, with an AI tuned for policies (https://supabase.com/changelog/19827-dashboard-weekly-updates-11th-dec-18th-dec). Templates are confirmed only by secondary sources (*unverified*).
- **Roles.**
- **Migrations.** When each ran, who ran it, and what changed (supabase-studio-3-0).
- **Schema Visualizer.**
- **Backups.** Restore warns of downtime (https://supabase.com/docs/guides/platform/backups).
- **Advisors** are deterministic lints, each written as a SQL view with a common interface by the open-source **splinter** project (https://github.com/supabase/splinter; https://supabase.com/docs/guides/database/database-advisors).
  - Security lints: RLS disabled in public, SECURITY DEFINER views, `USING (true)` policies, SECURITY DEFINER functions executable by anon, RLS without a policy.
  - Performance lints: unindexed foreign keys, unused and duplicate indexes, no primary key, table bloat, autovacuum disabled, RLS init-plan.
- **Index advisor.** `index_advisor(query)` returns the cost before and after, plus `CREATE INDEX` statements. It needs HypoPG and handles single-column B-tree only, under the PostgreSQL licence (https://supabase.com/docs/guides/database/extensions/index_advisor; https://github.com/supabase/index_advisor).
  - Wired into the Query Performance report, which is built on `pg_stat_statements`.

**Overall.**
- **Well.** A pre-run warning; role impersonation for testing RLS; AI edits as a diff; approval enforced in the tool layer; graded AI exposure; advisors as SQL views; a foreign-key row picker; queued edits with a diff.
- **Badly.** Cell edits are saved immediately by default; the SQL editor runs as `postgres` and so bypasses RLS; auto-limit skips CTEs and scripts; safety checks are regexes; a single shared login when self-hosted.

### 2.6 pgweb

**Status.**
- A Go single binary under MIT that supports PostgreSQL 9.6+ (https://github.com/sosedoff/pgweb).
- The latest release is **v0.17.0 of 2025-11-22**, which added a server-settings view (https://github.com/sosedoff/pgweb/releases). Maintained, but quiet.

**Screens** (https://raw.githubusercontent.com/sosedoff/pgweb/main/static/index.html):
- Tabs Rows, Structure, Indexes, Constraints, Query, History, Activity, Connection. Table sizes are shown.
- The Rows filter is column + operator + value.
- Cell menu: Copy, Display value, **Filter rows by value**, Unique values.
- Table menu: Export CSV/JSON/XML/SQL, Analyze, View definition, **Truncate**, **Delete table**.
- Rows are paged at **100** by default (https://raw.githubusercontent.com/sosedoff/pgweb/main/static/js/app.js).

**No data editing.** The maintainer declined inline editing for lack of bandwidth (https://github.com/sosedoff/pgweb/issues/759).

**`--readonly`.** It sets `default_transaction_read_only=on` before each query and rejects queries that match a keyword regex (https://raw.githubusercontent.com/sosedoff/pgweb/main/pkg/client/client.go). This is a setting the user can change, plus a keyword denylist: the same class of guard as pgAdmin's bypassed one.

**Other flags** (https://raw.githubusercontent.com/sosedoff/pgweb/main/pkg/command/options.go):
- `--query-timeout`, default 300 s;
- `--idle-timeout`;
- `--lock-session`;
- `--bookmarks-only`;
- `--auth-user`, which is basic auth.

**Lesson.** The minimum lovable browser is a table list, a grid with filters, structure, indexes and constraints, a query box with explain, history, activity, and export. It is fast and simple. But it has no editing and no DDL UI, roles or privileges, and no multi-user model.

### 2.7 Desktop clients: the data-grid and session UX

These five clients are where grid editing, transaction state, and production safety are most refined. All facts were checked on 2026-10-11.

**DBeaver** (Community 26.2.2, 2026-10-04, https://dbeaver.io/download/).

- **Editing model.** Inline editing, a cell editor, or a value panel. **Nothing is written until Save** in the bottom toolbar; Cancel reverts.
  - Deleted rows show **red** until saved.
  - "Generate Script" previews the exact SQL (https://dbeaver.com/docs/dbeaver/24.0/Data-Viewing-and-Editing/).
  - "Set to NULL" and "Set to default" are explicit actions.
  - Without a primary key, the user chooses all columns or declares a "virtual key".
- **Filters.** A raw-WHERE box with history, column-header value filters, "filter by value", and saved named filters (https://dbeaver.com/docs/dbeaver/Data-Filters/).
- **Foreign keys.** The **References panel** shows the referenced row for the selected cell and the rows that reference it (https://dbeaver.com/docs/dbeaver/References-Panel/).
- **Paging.** 200 rows by default. "Fetch all" carries a documented warning about out-of-memory errors (https://dbeaver.com/docs/dbeaver/22.1/Navigation/).
- **Transactions** (https://dbeaver.com/docs/dbeaver/Auto-and-Manual-Commit-Modes/).
  - Auto-commit and manual commit, with a "pending" indicator.
  - A transaction log, and a **Pending transactions** view across connections (https://dbeaver.com/docs/dbeaver/Pending-Transactions/).
  - **Smart commit** stays in auto-commit for reads and switches to manual before any data-modifying statement.
  - "Automatically end long idle transactions".
  - The web edition, CloudBeaver, shows **the number of uncommitted statements on the transaction-log button** (https://dbeaver.com/docs/cloudbeaver/Auto-and-Manual-commit-modes/).
- **Production safety: connection types** (https://dbeaver.com/docs/dbeaver/Connection-Types/). The *Production* type is the most complete safety bundle in the field:
  - brick red;
  - **confirm SQL execution** and **confirm data changes**;
  - **auto-commit off**;
  - idle transactions ended after 600 s;
  - idle connections closed after 1 h.
  - Separately, per-connection restrictions offer read-only, restrict data edit, restrict structure edit, restrict script execution and restrict import (https://dbeaver.com/docs/dbeaver/Managing-security-restrictions-for-database-connection/).
- **AI** (https://dbeaver.com/docs/dbeaver/AI-Assistance-settings/).
  - **Providers:** OpenAI, Copilot, Azure, Gemini, Ollama, Claude, Bedrock, Grok.
  - **What it sees:** tables filtered by the connection's scope; samples only through a sample tool (default 10 rows, max 200).
  - **Confirmation per statement class:**

    | Statement class | Default |
    |---|---|
    | SELECT | executes immediately |
    | INSERT / UPDATE / DELETE | **confirmation**, or "disable autocommit" |
    | DDL | **confirmation** |
    | Other | **confirmation** |

  - A mandatory consent per connection comes before any metadata is sent (https://dbeaver.com/docs/dbeaver/AI-Assistance-and-Data-Privacy/).

**DataGrip** (help at 2026.2, https://www.jetbrains.com/help/datagrip/configuring-database-connections.html).

- **Editing model.** Edits go to a local copy and are sent by **Submit**.
  - **Preview Pending Changes** shows the DML.
  - **Revert Selected** undoes one change, a group, or everything (https://www.jetbrains.com/help/datagrip/submitting-and-reverting-changes.html).
- **Transactions.** Tx:Auto or Tx:Manual. In manual mode, Submit puts changes into a transaction that must then be committed. These two stages (pending, then submitted but uncommitted) are powerful and confusing.
- **Paging.** 500 rows by default (https://www.jetbrains.com/help/datagrip/rows.html).
- **Foreign keys.** "Go To | Related Rows" for referenced or referencing rows, for several values at once (https://www.jetbrains.com/help/datagrip/foreign-keys.html).
- **Production safety.**
  - **Data-source colour** on editor tabs, consoles and grids (https://www.jetbrains.com/help/datagrip/2025.3/database-color-settings-dialog.html).
  - **Read-only**, which guards the data editor only. "Data modifications might be possible in the query console if the driver does not support the read-only status" (https://www.jetbrains.com/help/datagrip/data-sources-and-drivers-dialog.html).
  - **A warning on DELETE or UPDATE without WHERE**, with `WHERE TRUE` as the deliberate bypass (https://www.jetbrains.com/help/datagrip/query-execution.html).
- **DDL.** The Modify dialogs show **a preview pane of the exact script**, editable, and non-modal since 2024.3 (https://www.jetbrains.com/help/datagrip/modify-table-dialog.html).
- **AI.**
  - "Explain with AI" and "Fix with AI" on errors, with the fix shown as a diff (https://www.jetbrains.com/help/datagrip/2024.3/use-ai-in-editor.html).
  - 2026.1 added agents (Claude Agent, Codex) and an MCP server, with **four consent types: schema access, data access, schema modification and data modification** (https://www.jetbrains.com/datagrip/whatsnew/2026-1/).
  - 2026.2 puts agent queries in the data source's query history (https://blog.jetbrains.com/datagrip/2026/07/16/datagrip-2026-2-ai-agent-skills-mcp-tools-and-cli-commands-for-data-source-management-bundled-jdbc-drivers-and-improved-session-control/).
  - JetBrains says that guaranteed read-only AI access needs a database user with restricted privileges (https://www.jetbrains.com/help/datagrip/mcp-server.html).

**TablePlus** (Windows 26.10.2, 2026-09-01, https://api.tableplus.com/win/changelog).

- **Editing model.** Edits stay pending until **⌘S Commit** (https://docs.tableplus.com/gui-tools/working-with-table/row).
  - **Code Review** shows the SQL for every uncommitted GUI change, for both data and structure (https://docs.tableplus.com/gui-tools/code-review-and-safemode/code-preview).
- **Filters.** A filter bar with an "SQL" button that shows the generated WHERE. **The foreign-key arrow in a cell opens a quick filter on the referenced table.**
- **Paging.** 300 rows a page, with an "Estimate count" option for big tables (https://docs.tableplus.com/llms-full.txt).
- **Production safety.**
  - **Connection tags** (Local, Testing, Development, Staging, Production) are chosen when the connection is created, and colour the status bar.
  - **Safe mode** has five levels per connection: Silent; warn before every query; warn except SELECT/EXPLAIN; password before every query; password except SELECT/EXPLAIN (https://docs.tableplus.com/gui-tools/code-review-and-safemode/safe-mode).
  - The password modes teach click-through.
  - No read-only mode is documented.
- **AI.** An LLM chat (since 2025-07). The docs say "TablePlus will never send your data records to a language model" (https://docs.tableplus.com/llm-plugin).

**Postico 2** (2.3.4, 2026-09-28, macOS, PostgreSQL only, https://releases.eggerapps.at/postico2/changelog?update_channel=2).

- **Editing model.** Spreadsheet-like keyboard editing; ⌘S saves and Esc discards a field (https://eggerapps.at/postico2/documentation/keyboard-shortcuts.html).
  - A **foreign-key picker** and a row-detail sidebar (https://eggerapps.at/postico2/).
  - Several selected statements run in one implicit transaction (https://eggerapps.at/postico2/documentation/sql-query-view.html).
- **Honest about read-only.** A read-only session "is not going to make this safe". GUI tools send queries you do not control, and row counts and long transactions hurt production. The advice is not to connect to production at all (https://eggerapps.at/postico2/documentation/read-only-connections.html).
- It deliberately leaves out backup, access management and monitoring (https://eggerapps.at/postico2/documentation/what-is-postico.html).
- It has no AI features.

**Beekeeper Studio** (v6.1.6, 2026-10-07; Community Edition GPLv3; Electron + Vue, https://github.com/beekeeper-studio/beekeeper-studio).

As an open-source web-technology UI, it is the most borrowable reference for an HTML grid.

- **Editing model.** Changes are **staged** to be applied in a single transaction (https://docs.beekeeperstudio.io/user_guide/editing-data/).
  - Colours mark them: **green** new, **red** deleted, **orange** updated.
  - **Apply** commits, **Reset** discards, and **Copy to SQL** hands over the statements.
  - Editing needs a primary key.
  - The documented footgun: "Sorting or filtering the table during editing will discard your staged changes."
- **Foreign keys.** Clicking one opens the referenced data in a new tab (https://beekeeperstudio.io/features/table-data).
- **Manual transactions** in the SQL editor (https://docs.beekeeperstudio.io/user_guide/sql_editor/manual-transaction-management/).
  - A connection is **reserved per tab**.
  - After a **10-minute idle timeout** the transaction is rolled back, with a **warning at 9 minutes and an offer to keep it alive**.
- **Read-only mode** became free in 6.1.0 (https://github.com/beekeeper-studio/beekeeper-studio/pull/4737).
- **AI Shell** (paid) is an agent "modeled on Claude Code" (https://docs.beekeeperstudio.io/user_guide/sql-ai-shell/).
  - It sees schema, errors, and the **results of queries the user approved**.
  - It "will always ask for your explicit consent when running SQL". An opt-in setting auto-runs read-only queries.

**What these clients agree on.**
- **Edits are pending until saved.** Four of the five show the SQL before applying it. Every client holds grid edits back; none writes a cell at a time.
- **Two states to show.** Unsaved edits, and an open server transaction. The good tools show a count, and roll back idle transactions after a warning.
- **Production identity** is a label plus a colour, with behaviour bundled to it.
- **Client-side read-only leaks.** DataGrip says so, and Postico calls it unsafe.
- **AI guards classify statements.** Reads may auto-run; writes and DDL need a person.

### 2.8 Modelling and documentation tools

**pgModeler** (stable 1.2.3, 2026-02-06; 2.0.0-beta1, 2026-09-14; https://pgmodeler.io/).

- **Licensing.**
  - A desktop Qt modeller that speaks only PostgreSQL. Community Edition is GPLv3; pre-built binaries are paid.
  - **From 2.0, reverse engineering, diff/sync and the database tool are "Plus" (paid) only** (https://pgmodeler.io/blog/2026/5/20/pgmodeler-200-beta-is-here).
- **Canvas.**
  - **Layers** draw coloured rectangles around grouped tables, and hiding layers is the documented way to work on a large model (https://pgmodeler.io/support/docs/124-layers-management?v=2.0.0).
- **Model validation** (https://pgmodeler.io/support/docs/67-model-validation?v=2.0.0) checks:
  - broken references and creation order;
  - name uniqueness;
  - a unique key that duplicates the primary key;
  - optionally, the SQL against a live server.
- **Diff** (https://pgmodeler.io/support/docs/53-compare-model-and-database?v=2.0.0).
  - Called "experimental".
  - **Renames are not detected**: the old object "will be dropped".
  - CASCADE "can affect more objects than what is listed in the output of the diff preview".
  - "Apply on server" is irreversible.
- **Export.** To a server ("Run in a transaction"), to SQL files in dependency order, to PNG/SVG, and to an **HTML data dictionary** (https://pgmodeler.io/support/docs/51-export-a-model?v=2.0.0).
- **Good.** Native PostgreSQL, and validation before deployment.
- **Bad.**
  - The model file, not the database, is the truth, and the two drift apart.
  - The free edition loses import and diff in 2.0.
  - Desktop only.

**ChartDB** (v1.20.1, 2026-04-07, AGPL-3.0, https://github.com/chartdb/chartdb).

- **How it works.** A web ERD fed by **one "smart query"** the user runs. Its CTEs over `pg_constraint`, `pg_attribute`, `pg_index`, `pg_enum`, `pg_description` and the information schema return the whole schema as one JSON document (https://raw.githubusercontent.com/chartdb/chartdb/main/src/lib/data/import-metadata/scripts/postgres-script.ts).
  - **Comments come back empty by default, and view definitions always do.**
- **Screens.**
  - A canvas built on React Flow.
  - Areas for grouping, sticky notes.
  - A DBML editor.
  - AI export of the DDL into another dialect, which needs an OpenAI key.
- **Good.** One catalog query → one JSON model → the diagram.
- **Bad.**
  - A stale snapshot.
  - AGPL: take the idea, not the code.

**Azimutt** (MIT; last push 2026-08-25; https://github.com/azimuttapp/azimutt).

Built for big schemas.

- **Search** covers names, comments and types.
- **Layouts** start **empty** and you add tables. Coloured icons show the relations still to follow (https://azimutt.pubstack.io/docs/schema-exploration).
- An **overview** shows the central tables.
- **Find path** traverses the graph between two tables, with an ignore list, because hub tables like `users` make the results explode (https://azimutt.pubstack.io/features/find-path).
- **Notes and tags** are stored in Azimutt, outside the database, so they drift from `COMMENT ON`.
- An **analyzer** has 27 named rules (https://api.github.com/repos/azimuttapp/azimutt/contents/libs/models/src/analyze/rules), among them:
  - primaryKeyMissing;
  - indexOnRelation, a foreign key with no index;
  - indexDuplicated and indexUnused;
  - entityUnused;
  - attributeTypeInconsistent, the same column name with different types;
  - relationMissing;
  - queryTooSlow.
- The documentation host has moved, and a Clever Cloud add-on now exists (https://www.clever.cloud/product/azimutt-explorer/).

**DrawSQL** (hosted, closed; https://drawsql.app/).

- Real-time multiplayer diagrams.
- Import by pasting CREATE TABLE; export of DDL and Laravel migrations.
- **Comment threads on a table that stay open until resolved.**
- Version history.
- Free plan: 15 tables per diagram, public only (https://drawsql.app/pricing).
- It is a design island, with no live database behind it.

**dbdiagram.io and DBML** (DBML is Apache-2.0, https://github.com/holistics/dbml).

- **The language** (https://dbml.dbdiagram.io/docs/).
  - `Table` with column settings: pk, not null, unique, default, ref, note.
  - Indexes and checks.
  - `Ref` with `<`, `>`, `-`, `<>` and delete/update actions.
  - `Enum`, `TableGroup` with colour and note, sticky `Note`, and `DiagramView` for subsets of tables (https://dbml.dbdiagram.io/syntax/enrichment-visualization).
  - The CLI (`db2dbml postgres …`) needs Node 18 (https://dbml.dbdiagram.io/cli/).
- **dbdiagram.io** adds:
  - **detail levels**: table names / keys only / all fields (https://docs.dbdiagram.io/diagram-detail-levels);
  - **diagram views**: saved subsets with their own positions (https://docs.dbdiagram.io/diagram-views);
  - an **AI assistant** that shows its changes in a **diff viewer to accept** (https://docs.dbdiagram.io/ai-assistant).
- **Good.** Text is the source of truth; it diffs and versions well.
- **Bad.** Text-first is slow for browsing a live database. The large-schema aids are paid.

**dbdocs** (https://docs.dbdiagram.io/dbdocs/).

- Publishes a documentation site from DBML. **Projects are public by default.**
- Its **Schema Changelog** (https://docs.dbdiagram.io/dbdocs/features/schema-changelog) is an excellent "what changed in my schema" screen:
  - one version per build;
  - changes classified as Add/Remove/Modify on a schema, table, field, index, enum or relationship;
  - an impact summary with counts;
  - a DBML diff.
- The dbdocs CLI stops receiving updates in 2027.

**SchemaSpy** (v7.0.2, 2025-09-20, needs Java 17, LGPL/GPL; https://github.com/schemaspy/schemaspy).

- Generates static HTML: ER diagrams, **implied relationships** (a column whose name and type match a primary key), and **Markdown rendered from comments**.
- An **Anomalies** page lists missing indexes, implied relationships and orphan tables (https://schemaspy.readthedocs.io/en/latest/features.html).
- Routine definitions have been redacted by default since 7.0.
- **Good.** It treats `COMMENT ON` as documentation, and its anomaly page is readable by anyone.
- **Bad.** A batch snapshot with no interaction.

**What a web PostgreSQL tool should take from this group.**
- **Diagram.** Draw it from the live catalog with no separate model file, keeping comments and view definitions. Persist only layouts.
- **Large-schema aids are the core feature, not a premium:**
  - start empty and add N hops of neighbours;
  - an overview of the central tables;
  - search across names, comments and types;
  - detail levels;
  - saved views;
  - coloured groups.
- **Find a join path** with a hub ignore list, and emit the JOIN into the editor.
- **Documentation.** Comments are the documentation: edit `COMMENT ON` and render it as Markdown. Export a data dictionary.
- **Lint.** Run an anomaly and lint page from the catalog plus statistics.
- **Changelog.** Keep a schema changelog by entity.
- **AI.** Its schema changes arrive as a diff to accept, never applied directly.
- **Licences.** ChartDB (AGPL) and pgModeler (GPL) are ideas, not code. DBML (Apache-2.0) and Azimutt (MIT) are permissive.

### 2.9 Plan visualisers

**PEV2, Dalibo** (v1.24.0, 2026-09-10; **PostgreSQL licence**; https://github.com/dalibo/pev2).

- **Recent releases** (https://api.github.com/repos/dalibo/pev2/releases).
  - 1.23 added planning buffers and I/O timings.
  - **1.22 (2026-06-18) "fixes HTML injection in the Output node"**, a reason to pin versions and watch releases.
- **Screens** (https://raw.githubusercontent.com/dalibo/pev2/master/src/components/Plan.vue).
  - Tabs Plan (graph), Grid, Raw, Query, Comment and Stats.
  - A header with execution and planning time, serialisation, JIT, triggers, settings and I/O.
  - A left diagram panel with a per-node bar for **time / rows / estimation / cost / buffers / IO**.
  - Graph highlighting by duration, rows or cost.
- **Node badges**: Slow, cost is high, bad row estimate, rows removed by filter, heap fetches high, never executed.
  - Node detail shows exclusive time as a percentage, actual against planned rows with the "over/under estimated by" factor, buffers, I/O and WAL.
- **Stats tab**: time per table, function, node type and index.
- **Vendoring with no Node on the server is possible.**
  - Each release ships a single-file `pev2.html`, and the npm package has `dist/pev2.umd.js` and `pev2.css`.
  - The README shows use without a build: script tags for Vue 3 (MIT) plus the PEV2 UMD bundle.
  - It depends on Bootstrap ^5.3, the same major as the nxl theme.
  - So three committed static files can mount as a Vue island in an HTMX page, following Boards' precedent of a committed bundle.
- **explain.dalibo.com** warns "The plan will be sent to the server and stored in a database", and points to a standalone local HTML file (https://explain.dalibo.com/).
- **Bad.** The graph is cramped at 375 px, where the Grid tab or a server-rendered table is better.

**explain.depesz.com** (https://explain.depesz.com/; help https://explain.depesz.com/help).

- **A dense text table.**
  - **Exclusive** time against **inclusive** time.
  - **rows x**, the estimate-to-actual factor, with ↓ for under and ↑ for over.
  - Rows removed by filter, loops, buffers.
- **Documented colour thresholds.**
  - Time share: ≤10 % white, 10–50 % yellow, 50–90 % brown, over 90 % red.
  - rows x: 10 / 100 / 1000.
- An **obfuscate** option for sharing.
- The parser is CPAN `Pg::Explain`.
- **Good.** No JavaScript is needed and the thresholds are simple to reproduce in PHP. This is the model for a server-rendered plan view that works at 375 px.
- **Bad.** Plans are stored on a third-party server.

**pgMustard** (commercial, from 95 € a year; https://www.pgmustard.com/).

- **Tips scored 0–5 stars by estimated time saving**, with the best three highlighted.
  - Tip types: index potential, operations on disk, poor row estimates, low cache hit rate, lossy bitmap scans, excessive planning time, rows discarded.
  - It deliberately avoids red herrings such as a sequential scan on a small table.
- **The docs warn that ANALYZE executes the query**, which matters for DML and long queries (https://www.pgmustard.com/docs).
  - They recommend `analyze, buffers, verbose, settings, wal`, plus `serialize, memory` on 17+.
- Plans "are not stored server-side (unless you opt to do so)".
- **Good.** Advice ranked by payoff, in plain language.
- **Bad.** The plan leaves your server, and the product is paid and closed.

**What to take.**
- **Two plan views.**
  - A server-rendered depesz-style table, which works without JavaScript and at 375 px.
  - Optionally PEV2 as a vendored island.
- **Deterministic flags first**, from PEV2's badges and pganalyze's anti-patterns (section 2.10). An agent's ranked, plain-language advice comes on top of them, never instead of them.
- **Never send a plan to an outside service.**
- **Warn that ANALYZE executes the statement**, and run ANALYZE of a write inside a transaction that is rolled back (pgHero's sandbox, section 2.10).

### 2.10 Monitoring dashboards

Release dates below come from each project's GitHub releases page, read on 2026-10-11.

**pgHero** (4.0.1, released 2026-08-15; MIT licence; ships as a Rails engine or a Docker image) (https://github.com/ankane/pghero; https://raw.githubusercontent.com/ankane/pghero/master/CHANGELOG.md).

- **Tabs.** Overview · System · Queries · Space · Connections · Live Queries · Maintenance · Explain · Tune (https://raw.githubusercontent.com/ankane/pghero/master/app/views/layouts/pg_hero/application.html.erb).
- **Overview is a page of pass/fail checks** (https://raw.githubusercontent.com/ankane/pghero/master/app/views/pg_hero/home/index.html.erb):
  - replication lag and inactive slots;
  - long-running queries;
  - cache hit rate;
  - connections and idle-in-transaction sessions;
  - vacuuming;
  - "No columns near integer overflow";
  - invalid indexes and constraints;
  - duplicate, suggested and unused indexes;
  - slow queries.
- **Each failing check shows its fix as text to copy.** Nothing on the page runs it. Examples:
  - `DROP INDEX CONCURRENTLY` followed by `CREATE INDEX CONCURRENTLY` for an invalid index;
  - `VACUUM FREEZE VERBOSE`;
  - "Consider changing columns to bigint".
- **Only two buttons execute anything: Kill and enabling query stats.**
  - 4.0.0 added `disable_kill` ("Disable killing queries and connections"). The controller then answers "Kill not enabled" (https://raw.githubusercontent.com/ankane/pghero/master/app/controllers/pg_hero/home_controller.rb).
  - **Kill All has no confirmation step** in its template.
- **The explain sandbox is the pattern to copy** (https://raw.githubusercontent.com/ankane/pghero/master/lib/pghero/methods/explain.rb; https://raw.githubusercontent.com/ankane/pghero/master/app/views/pg_hero/home/explain.html.erb):
  - it runs in a transaction with a statement timeout and **always rolls back**;
  - it refuses SQL containing an inner `;` or `COMMIT` ("Unsafe statement");
  - ANALYZE is a separate **red button** that must be switched on in configuration;
  - queries with `$1` use `GENERIC_PLAN` on PostgreSQL 16+;
  - raw errors are replaced by "Error explaining query", because "data can be extracted through the Postgres error message".
- **Its database role** (https://raw.githubusercontent.com/ankane/pghero/master/guides/Permissions.md):
  - the role carries `lock_timeout = '1s'`;
  - it holds a few SECURITY DEFINER wrappers: `pg_stat_activity()`, `pg_terminate_backend(pid)` and `pg_stat_statements_reset()`.
- **History** needs scheduled capture jobs: query stats about every 5 minutes, space daily (https://raw.githubusercontent.com/ankane/pghero/master/guides/Docker.md).
- **Index creation is opt-in.** Its sibling tool Dexter uses HypoPG and "will not create indexes unless you pass the `--create` flag" (https://github.com/ankane/dexter).

**pganalyze** (commercial SaaS; https://pganalyze.com/docs).

- **Index advice is deterministic.** The Indexing Engine:
  - extracts scans from the `pg_stat_statements` workload;
  - runs a "What If?" analysis on PostgreSQL's planner code;
  - chooses with a constraint-programming model, explicitly "not machine learning";
  - weighs the write overhead of each index;
  - asks a person to review and benchmark the result (https://pganalyze.com/docs/indexing-engine).
- **Query Advisor** rewrites come from the pg_query parser, with "no LLMs" (https://pganalyze.com/blog/query-advisor-ga).
- **EXPLAIN Plans** collects plans through `auto_explain` and names **eight anti-patterns**: Disk Sort, Hash Batches, Inefficient Index, Large Offset, Lossy Bitmaps, Mis-Estimate, Slow Scan, Stale Stats (https://pganalyze.com/docs/explain).
- **VACUUM Advisor** groups its findings (https://pganalyze.com/docs/vacuum-advisor):
  - bloat: insufficient frequency, blocked by the xmin horizon;
  - freezing: wraparound;
  - performance.
- **Connections**:
  - samples wait events every 10 s;
  - shows lock chains with the "root cause" blocker highlighted;
  - **does not cancel or terminate** — it tells you to run `pg_cancel_backend` (https://pganalyze.com/docs/connections).
- **Log Insights** classifies every log line by SQLSTATE (https://pganalyze.com/docs/log-insights).
- **MCP server** (public preview). Its OAuth scopes are `restricted_read`, `read` and `write_workbooks`, and an API key can never write (https://pganalyze.com/docs/mcp).
  - This mirrors the estate's split between a records server and an actions server.

**PoWA**, Dalibo (powa-web 5.3.0, 2026-08-16; https://github.com/powa-team/powa-web/releases).

- **Components:** archivist, collector and web front end (https://powa.readthedocs.io/en/latest/).
- **Data sources:** `pg_stat_statements`, `pg_qualstats`, `pg_stat_kcache`, `pg_wait_sampling`, `pg_track_settings` and HypoPG.
- **Index suggestions:**
  - a per-query **Predicates** tab, built from the WHERE clauses actually executed, suggests indexes;
  - HypoPG then shows whether "PostgreSQL would use it or not", without building the index (https://powa.readthedocs.io/en/latest/components/hypopg.html);
  - "Optimize this database" proposes the smallest index set that covers every predicate (https://powa.readthedocs.io/en/stable/releases/v3.0.0.html).
- **Weak point:** on a quiet database the suggestions are often empty, because sampling is 1/max_connections by default (https://github.com/powa-team/powa-web/issues/123).

**pgwatch**, CYBERTEC (**v6.0.0, 2026-09-15**; BSD-3-Clause; https://github.com/cybertec-postgresql/pgwatch/releases/tag/v6.0.0).

- **Shape:** a metrics gatherer feeding sinks, with Grafana dashboards (https://pgwat.ch/latest/).
- **Least privilege:** it reads with `GRANT pg_monitor` only (https://github.com/cybertec-postgresql/pgwatch/blob/master/docs/tutorial/preparing_databases.md).
- **Anti-pattern:** its admin web UI is "**not secured** by default — anyone who can reach the port can view and modify the monitoring configuration" (https://github.com/cybertec-postgresql/pgwatch/blob/master/docs/concept/web_ui.md).
- **The `recommendations` preset mixes security with performance** (https://raw.githubusercontent.com/cybertec-postgresql/pgwatch/master/internal/metrics/metrics.yaml):
  - add or drop index;
  - CREATE on the public schema;
  - disabled triggers;
  - nested views;
  - functions without a fixed `search_path`;
  - superusers.
- **Newer statistics views:** the metrics already read `pg_stat_checkpointer` (17) and `pg_stat_io` (16+).
- **Dashboards** include Health Check, Lock Details, Sessions, Change Events and Recommendations (https://github.com/cybertec-postgresql/pgwatch/tree/master/grafana/postgres/v13).

**pg_activity**, Dalibo (v3.6.2, 2026-06-05; PostgreSQL licence; https://github.com/dalibo/pg_activity).

- **Three views**, like top: F1 running, F2 waiting, F3 blocking. Each shows CPU, memory, I/O and duration per backend.
- **Actions:** `C` cancels, `K` terminates, Space tags several processes.
- **Confirmation:** "Confirm {cancel|terminate} action on {process}? (y/n)", in **yellow for cancel and red for terminate** (https://raw.githubusercontent.com/dalibo/pg_activity/master/pgactivity/ui.py).
- **No read-only flag.**
- **3.6.2 removed a header figure it judged misleading:** "tuples returned/s".

**What to take.**
- **The three live views DBAs expect** (pg_activity, pganalyze):
  - running;
  - waiting;
  - blocking, with the root blocker highlighted.
- **Cancel and terminate as separate, colour-graded, confirmed actions.** "Kill all" either does not exist or is confirmed.
- **A health page of deterministic checks.** The fix is SQL to copy into the change path, never a run button.
- **Index advice deterministic and checked by the planner** through HypoPG.
- **Least privilege:** `pg_monitor` plus a few SECURITY DEFINER wrappers.
- **Trends need a collector.** Live `pg_stat_*` views have no history.

### 2.11 Schema change and review products

**Bytebase** (3.23.1, 2026-10-08; MIT core, with enterprise directories under a separate licence; https://github.com/bytebase/bytebase/releases; https://raw.githubusercontent.com/bytebase/bytebase/main/LICENSE).

- **Change flow** (https://docs.bytebase.com/tutorials/first-schema-change):
  - Plan → SQL or **Schema Editor** → automatic checks on the draft → "Ready for review" creates the Issue → approval → **Run** per stage (Dev → Test → Staging → Prod) → Deployed (https://docs.bytebase.com/change-database/change-workflow).
  - Data changes back up first and can be rolled back in one click.
- **SQL review rules for PostgreSQL** (https://docs.bytebase.com/sql-review/review-rules):
  - create index concurrently;
  - no NOT NULL added to an existing column;
  - CHECK NOT VALID;
  - a cap on affected rows, estimated with EXPLAIN;
  - require WHERE;
  - no COMMIT;
  - require a primary key;
  - no column type change.
  - Weakness: "disallow add column with default" ignores that PostgreSQL 11+ needs no table rewrite for a non-volatile default.
- **Approval rules** are written in CEL over risk fields: environment, affected rows, SQL type. First match wins (https://docs.bytebase.com/change-database/approval.md; https://docs.bytebase.com/tutorials/risks-best-practice.md).
- **The SQL Editor is not a side door** (https://docs.bytebase.com/sql-editor/run-queries):
  - without DDL or DML permission it is "effectively read-only", and a write is redirected to a Plan;
  - a CTE that writes, or EXPLAIN ANALYZE of a write, counts as DML;
  - only the first statement runs;
  - results are capped at 100,000 rows or 100 MB;
  - export re-runs the query under the same masking.
- **Admin Mode** is a break-glass tab to "execute arbitrary statements", guarded by a warning only (https://docs.bytebase.com/sql-editor/admin-mode).
- **Just-in-time access** grants one read-only statement, with an expiry and a reason, through approval (https://docs.bytebase.com/security/database-permission/just-in-time).
- **Drift:**
  - live schema compared with the snapshot taken after the last migration;
  - shown in an Anomaly Center as a diff;
  - adopt it as the new baseline, or revert (https://docs.bytebase.com/change-database/drift-detection).
- **AI:**
  - the assistant "only sends the database schema (table and column names)" (https://docs.bytebase.com/ai-assistant);
  - AI agents get identities of their own under the same controls (https://docs.bytebase.com/introduction/what-is-bytebase);
  - a blog post of 2026-09-21 tested TypeSafe's **Jev** for risk-scoring change and access requests — rules catch violations, Jev scores contextual risk, an LLM explains, a person decides (https://www.bytebase.com/blog/jev-database-change-and-access-workflows/);
  - that was an experiment, not a feature, and the estate already grades with JEV.

**Atlas**, Ariga (v1.3.0, 2026-08-02; Apache-2.0 core; https://github.com/ariga/atlas/releases).

- **Licensing:** linting and drift are Pro (https://atlasgo.io/pricing).
- **The most precise PostgreSQL rule catalogue in the field.** Each code names the lock it takes, or whether it rewrites or scans (https://atlasgo.io/lint/analyzers):

  | Code | What it flags |
  |---|---|
  | DS101–103 | drops |
  | BC101–104 | renames, backwards-incompatible changes |
  | MF101–104 | data-dependent changes |
  | PG101 / PG102 | CREATE / DROP INDEX without CONCURRENTLY |
  | PG104 / PG105 | PRIMARY KEY / UNIQUE take ACCESS EXCLUSIVE |
  | PG301 | type change rewrites |
  | PG302 | volatile default |
  | PG303 | SET NOT NULL scans |
  | PG305 | CHECK scans |
  | PG306 | foreign key scans |
  | PG308 | trigger lock |
  | PG309 / PG310 | generated or identity column rewrite |
  | TX101 / TX201 | transaction safety |

- **Review policy:** `lint.review` = ALWAYS / WARNING / ERROR decides when a person must approve. The lint report is posted with an approval link (https://atlasgo.io/declarative/setup-cicd).
- **Drift:** reported as an ERD plus a diff. `migrate drift` never changes the database (https://www.atlasgo.io/monitoring/drift-detection).

**Liquibase** (v5.0.4, 2026-08-20).

- **Licence:** Community moved to **FSL-1.1-ALv2 at 5.0** (2025-09-30); each version reverts to Apache 2.0 after two years (https://www.liquibase.com/blog/liquibase-community-for-the-future-fsl).
- **No web UI:** its only one, **Hub, was shut down** (https://www.liquibase.com/blog/liquibase-hub-sunset).
- **Default policy checks** (https://docs.liquibase.com/secure/user-guide-5-0/what-default-policy-checks-does-liquibase-offer):
  - ChangeDropColumnWarn, ChangeDropTableWarn;
  - ModifyDataTypeWarn;
  - ChangeTruncateTableWarn;
  - SqlGrantWarn, SqlRevokeWarn;
  - **RollbackRequired**;
  - PrimaryKeyOnCreateTable;
  - CheckTablesForIndex.
- **Rollback:** automatic for simple change types; formatted SQL needs explicit `--rollback` lines (https://docs.liquibase.com/workflows/liquibase-community/automatic-custom-rollbacks.html).

**Flyway Desktop**, Redgate (Flyway 13.10.0, 2026-10-08; https://github.com/flyway/flyway/releases).

- **Generating a migration** (https://documentation.red-gate.com/fd/generating-migrations-138347054.html):
  - it compares a shadow database with the schema model;
  - it writes an **undo script** next to the versioned one, which may need manual edits;
  - you **tick a box to consent** before it erases the shadow database.
- **Comparison:** dropping a table raises a high-severity warning (https://documentation.red-gate.com/fd/database-comparisons-273973459.html).
- **Drift is Enterprise-only.** It compares a snapshot of the target with a build of the applied migrations, and can abort a deployment (https://documentation.red-gate.com/fd/check-drift-277578903.html).
- **Code rules:** SQLFluff plus regex rules (https://www.red-gate.com/hub/product-learning/flyway/creating-custom-regex-rules-for-code-analysis-in-flyway). A competitor's review says these miss PostgreSQL locks and rewrites (https://www.bytebase.com/blog/top-postgres-sql-review-tools/) — a secondary source.

**Rule catalogues a web tool could adopt.**

- **squawk** (v2.68.0, 2026-10-08; Apache-2.0; https://github.com/sbdchd/squawk).
  - **78 rules** (https://squawkhq.com/docs/rules), including:
    - require-concurrent-index-creation;
    - adding-not-nullable-field;
    - changing-column-type;
    - constraint-missing-not-valid;
    - renaming-column, ban-drop-column;
    - require-lock-timeout, require-statement-timeout;
    - transaction-nesting;
    - prefer-bigint-over-int, prefer-timestamptz.
  - It knows server versions: a non-volatile default needs no rewrite from PostgreSQL 11 (https://squawkhq.com/docs/adding-field-with-default).
  - Options and outputs: `--pg-version`, a JSON reporter.
  - Delivery: CLI, a GitHub Action, a language server, and a **WASM browser playground**.
- **strong_migrations** (v2.8.0; MIT; https://github.com/ankane/strong_migrations).
  - Every hazard comes with a **safe alternative**, which is good wording for a review screen. Examples:
    - set NOT NULL through a check constraint, validate, then set;
    - build a unique index concurrently, then attach it.
  - "It's extremely important to set a short lock timeout for migrations." It recommends `lock_timeout` 10 s and `statement_timeout` 1 h for migrations.

**What to take.**
- **The loop:** write → automatic lint → policy decides whether a person approves → apply → history → drift check.
- **Rules name the lock and the rewrite**, know the server version, and offer the safe form.
- **Every change carries its rollback** where one can be generated.
- **A graphical edit produces a script, never a direct change.** Bytebase's Schema Editor and Flyway Desktop both do this.
- **The SQL editor must not be a side door around the change path** (Bytebase).
- **Drift is a diff with two exits:** adopt or revert. Nothing is fixed automatically.

### 2.12 AI features across the field, and how each guards writes

| Tool (version seen) | AI features | What the model sees | Can it execute? | Write guard |
|---|---|---|---|---|
| **pgAdmin 4** (9.13+, 2026) | NL→SQL chat, AI Insights on plans, AI Reports (security, performance, schema) | Schema, `pg_settings`, query text, plans; never sent unless invoked; no provider enabled by default (https://www.pgadmin.org/docs/pgadmin4/latest/ai_tools.html) | Its own exploratory reads, in a READ ONLY transaction capped at 1,000 rows | Generated SQL is only Copy/Insert/Replace; a person runs it. **The read-only wrapper was bypassed twice in 2026** (CVE-2026-12045, CVE-2026-17351; release notes 9.16, 9.17) |
| **Supabase Studio** (Assistant v2) | NL→SQL, debug, RLS, functions; edits as a diff | Graded by organisation: disabled / schema / +logs / +data (useOrgOptedIntoAi.ts) | "Basic select queries run automatically"; other SQL after approval enforced in the tool (prompts.ts) | Approval inside `execute_sql`; a regex destructive warning; AI disclaimer comment |
| **DBeaver** (26.x) | Chat, `@ai` in the editor, explain/fix (PRO) | Scoped table list; samples only through a tool (≤200 rows); consent per connection (https://dbeaver.com/docs/dbeaver/AI-Assistance-and-Data-Privacy/) | Yes | Per statement class: SELECT runs, DML/DDL/other confirm (https://dbeaver.com/docs/dbeaver/AI-Assistance-settings/); CloudBeaver confirms "any risky query" (https://dbeaver.com/docs/cloudbeaver/AI-command/) |
| **DataGrip / JetBrains AI** (2026.1–2.2) | Explain/Fix with AI, agents (Claude Agent, Codex), MCP | Schema; a small sample of results | Yes, with consent | Four consent types (schema/data × read/modify); agent queries logged in history; JetBrains says real read-only needs a restricted database user (https://www.jetbrains.com/help/datagrip/mcp-server.html) |
| **TablePlus** | LLM chat | CREATE statements; "never … your data records" (https://docs.tableplus.com/llm-plugin) | Undocumented | Only safe mode |
| **Beekeeper Studio** (6.x) | AI Shell agent (paid) | Schema, errors, results of approved queries only | Yes, after consent | "Always ask for your explicit consent when running SQL"; opt-in auto-run of reads (https://docs.beekeeperstudio.io/user_guide/sql-ai-shell/) |
| **Adminer** (sql-gemini) | NL→SQL into the editor | All CREATE statements, sent to Google | No | A person presses Execute; shared key; no classification (https://github.com/vrana/adminer/blob/main/plugins/sql-gemini.php) |
| **Bytebase** | Text2SQL, explain, find problems | Table and column names only (https://docs.bytebase.com/ai-assistant) | Through the editor's permission model | Writes need per-environment DDL/DML permission, otherwise redirected to a reviewed Plan; classification by effect |
| **Neon** | Generate SQL, Fix with AI | Schema only, through AWS Bedrock (https://neon.com/docs/security/ai-use-in-neon) | No; fixes edit the editor | Suggests running AI SQL on a branch first (https://neon.com/blog/postgres-ai-playground) |
| **MS PostgreSQL for VS Code** (doc 2026-06-08) | `@pgsql`, Explain/Rewrite/Analyze, agent mode | Schema; query text per `autoAttachQuery` | Yes | `accessMode` `ro` or `rw`; **default `rw`**; "Use Read Only for production" (https://learn.microsoft.com/en-us/azure/postgresql/development/vs-code-extension/copilot-integration) |
| **Cloud SQL / AlloyDB Studio** (Gemini) | Help me code, explain, fix | Schema | No; inserts into the editor | Warns that generated DML/DDL can overwrite data; IAM permission (https://docs.cloud.google.com/alloydb/docs/write-sql-gemini) |
| **dbdiagram.io** | DBML generation | The diagram | No | Changes in a diff viewer to accept (https://docs.dbdiagram.io/ai-assistant) |
| **Zep** (memory) | "Ask graph" | One graph | Read only | "It cannot add, update, or delete graph data" (https://help.getzep.com/graph-visualizer-assistant) |
| **Postgres MCP Pro** | Health, index tuning, explain with hypothetical indexes | Whatever it queries | Yes | *Restricted* mode: read-only transactions, pglast parsing that rejects COMMIT/ROLLBACK, time cap (https://github.com/crystaldba/postgres-mcp) |
| **Reference MCP server-postgres** (archived 2025) | Query tool | Whatever it queries | Read-only transaction | **Bypassed by stacked statements** with an injected COMMIT (https://securitylabs.datadoghq.com/articles/mcp-vulnerability-case-study-SQL-injection-in-the-postgresql-mcp-server/) |
| **pganalyze** | Index Advisor, Query Advisor | — | — | **Not an LLM**: planner costing plus constraint programming (https://pganalyze.com/docs/indexing-engine) |

**Incident, headline only.** In July 2025 Replit's coding agent erased a production database during a user's trial, despite instructions not to change anything without approval. Replit answered with automatic separation of development and production databases, a planning-only mode, and one-click restore (https://incidentdatabase.ai/reports/5593/). How "production" that database was is disputed. The security sibling covers agent safety.

**Guard patterns that recur, best first.**
1. **The database role is the wall.**
   - Agent reads run as a PostgreSQL role with no write privileges.
   - Each call carries one statement, using the extended protocol.
   - Rows and time are capped.
   - Evidence: the pgAdmin CVEs, the reference MCP server, Supabase MCP's read-only user, and JetBrains' advice.
2. **Generate into the editor or a diff; never auto-run a write.** pgAdmin, Supabase, Google, Neon, dbdiagram.
3. **Classify statements by effect.** Reads may auto-run; DML, DDL and anything else need a person (DBeaver, Beekeeper, Bytebase).
4. **Send the minimum, graded by an administrator.** Schema only by default; logs, results and data are explicit steps up (Supabase, DBeaver, Beekeeper).
5. **Approval in the tool layer, not the prompt.** Supabase.
6. **Agent queries go into the same history and audit as people's.** DataGrip 2026.2, Bytebase.
7. **An unauthorised write is redirected into the reviewed change path.** Bytebase.
8. **Deterministic advice first.** pganalyze, PoWA, splinter. The model explains; it does not decide.

### 2.13 The memory side: what exists for agent memory, and what does not exist for MaluDB

No database tool in this survey knows MaluDB. A MaluDB tenant database "holds the actual knowledge graph" (`/home/maludb/maludb-python-api-server/README.md:30`). It has documents with vector chunks and graph edges, episodes, principals and scopes (`README.md:254`), and deletion that now "forgets" chunks and edges as well (`README.md:277`). The MaluDB sibling report describes the model. Here are the nearest analogues as products, looked at for their screens.

- **Zep dashboard** (https://help.getzep.com/graph-overview; https://help.getzep.com/graph-visualizer-assistant).
  - Users → a user → **View Graph**, with entities as nodes and facts on edges, plus **View Episodes** to see when data has finished entering the graph.
  - The "Ask graph" assistant is **read-only**. It shows each retrieval step, highlights what it retrieved on the canvas, and can "find which episodes support a fact".
  - It answers "no evidence" rather than from general knowledge.
- **Letta ADE** (https://docs.letta.com/guides/ade/overview).
  - A three-panel environment:
    - **left:** configuration;
    - **centre:** an agent simulator;
    - **right:** agent state — a **context-window viewer**, an editable **core-memory block editor**, and a searchable **archival memory** (vector) panel.
  - The original ADE page is now marked deprecated in favour of a new web and desktop ADE.
- **mem0 platform.**
  - Memories are edited from a drawer, and deleted one at a time, in batches, or by filter (https://docs.mem0.ai/core-concepts/memory-operations/delete).
  - Its changelog records that the dashboard's **Graph Memory tab was removed in April 2026** (https://docs.mem0.ai/changelog/platform). That is a signal that a graph canvas is not automatically what memory users want.
- **Neo4j Browser ("Query") and Bloom ("Explore").** A query console whose results toggle between **graph and table**, beside a no-code explorer with natural-language search for non-developers (https://neo4j.com/docs/tools; https://neo4j.com/developer/tools-graph-visualization/).
- **Apache AGE Viewer.** A web viewer for PostgreSQL's AGE graph extension, built on Node, Apache-2.0, with an empty releases page (https://github.com/apache/age-viewer). It is the closest "graph inside PostgreSQL" precedent, and a thin one.
- **Qdrant Web UI.** Collections, snapshots, and a **console for REST calls** (https://qdrant.tech/documentation/web-ui/).

**What to take for MaluDB screens** (subject to the MaluDB sibling's model).
- **A memory-database browser.** Namespaces and scopes, documents with their source and chunks, and episodes over time.
- **Graph neighbourhood views as graph and table.** The table view is the 375 px and accessibility fallback.
- **Provenance from a fact to its supporting episodes and documents.** This is Zep's best feature.
- **An API console** in the Qdrant style, read-only by default.
- **A read-only "ask this memory" assistant** that shows its retrieval steps.
- **Forgetting shown before and verified after.**

---

## 3. Feature matrix

**Legend.**
- **Y** — built in.
- **P** — partial, paid only, or by plugin.
- **–** — absent.
- **?** — not verified in this survey.
- **†** — taken from general product knowledge and not re-checked at a primary source for this report.
- A number is the default page size or row cap.

Sources are those cited in section 2.

### 3a. General-purpose tools

| Capability | phpMyAdmin | Adminer | phpPgAdmin | pgAdmin 4 | Supabase Studio | pgweb | DBeaver | DataGrip | TablePlus | Postico 2 | Beekeeper |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Web application (not desktop) | Y | Y | Y | Y (server mode) | Y | Y | P (CloudBeaver) | – | – | – | – (Electron) |
| Multi-user accounts of its own | – | – | – | Y | P (one basic-auth user self-hosted) | – | – | – | – | – | – |
| Schema as a first-class level | – | Y | Y | Y | Y | ? | Y | Y | Y | Y | Y |
| PostgreSQL object coverage (domains, types, policies, publications, FTS…) | – | P | Y (to PG 13) | Y | P | – | Y† | Y† | P† | P | P† |
| Reverse-engineered DDL per object | P | P | ? | Y | P | P (view definitions) | Y† | Y† | ? | Y | ? |
| SQL preview before a structural change | Y | – | ? | Y | ? | – | ? | Y | Y | ? | ? |
| Lock or rewrite cost shown for DDL | – | – | – | – | – | – | – | – | – | – | – |
| Dependencies / dependents view | – | – | ? | Y | ? | – | ? | ? | ? | ? | ? |
| Data-grid editing | Y | Y | Y | Y | Y | – | Y | Y | Y | Y | Y |
| Edits staged, saved together | P (off by default) | P | – | Y | P (2026 preview) | – | Y | Y | Y | ? | Y |
| SQL preview of pending data edits | – | – | – | – | P (diff in preview) | – | Y | Y | Y | ? | Y |
| Edits refused without a key | – (warns) | ? | ? | Y | ? | – | P (virtual key) | ? | ? | ? | Y |
| Foreign key → referenced row | Y | P (plugin) | ? | ? | Y | – | Y | Y | Y | ? | Y |
| Referencing rows from a row | – | P (plugin) | ? | ? | ? | – | Y | Y | ? | ? | ? |
| Foreign-key picker when editing | Y (dropdown or popup) | P (plugin) | Y (autocomplete) | ? | Y | – | ? | ? | ? | Y | ? |
| Default page / row cap | 25 | 50 | 30 | batches; View All uncapped until 9.17 | SQL 100 (selects only) | 100 | 200 | 500 | 300 | ? | ? |
| Filter builder plus raw WHERE | Y | Y | P | Y | ? | P | Y | Y | Y | P | Y |
| Explicit transaction controls with indicator | – | – | – | Y | – | – | Y | Y | – | P | Y (paid) |
| Idle-transaction auto-rollback | – | – | – | – (prompt on close) | – | – | Y | ? | – | – | Y (warning at 9 min) |
| Destructive-SQL warning | P (regex) | – (buttons only) | ? | P (menu actions) | P (regex/heuristic) | P (buttons) | Y (Production type) | Y (no WHERE) | Y (safe mode) | – | ? |
| Dry run (simulate or rollback) | Y | – | – | – | – | – | – | – | – | – | – |
| Graphical or tabular EXPLAIN | – (text) | – (text) | – | Y (graph, table, stats) | P | P (text) | Y† | Y† | ? | – | ? |
| Query history | P (needs pmadb) | Y | ? | Y | P | Y | P (persists in paid editions) | Y | Y | ? | Y† |
| Saved queries | Y (bookmarks) | – | P (reports) | P (macros) | Y (snippets) | – | Y† | Y† | Y† | ? | Y† |
| ER / schema diagram | Y (Designer) | P (read-only) | – | Y (ERD tool) | Y | – | Y | Y† | – | – | P (paid) |
| Schema diff | – | P (dump-alter plugin) | – | Y | – | – | P† | Y† | – | – | – |
| Sessions with cancel / terminate | Y (MySQL) | P | Y | Y | ? | P (no kill) | Y† | P† | ? | – | ? |
| Locks view | – | – | Y | Y | ? | – | ? | ? | ? | – | ? |
| Roles and privileges UI | Y | P (MySQL; PG by plugin) | Y | Y (grant wizard) | Y | – | Y† | Y† | ? | – | ? |
| RLS policies (edit / test as role) | – | – | – | Y† | Y (editor, impersonation, tester) | – | ? | ? | ? | – | ? |
| Backup / restore | P | P | Y (pg_dump) | Y | Y (platform) | P (SQL dump) | Y† | Y† | Y† | – | P† |
| Import / export | Y | Y | Y | Y | Y† | P (export only) | Y | Y† | Y† | Y† | Y† |
| Maintenance (VACUUM, ANALYZE, REINDEX) | Y (MySQL) | Y (MySQL) | Y (+ autovacuum per table) | Y | – | P (analyze) | ? | ? | ? | – | ? |
| Deterministic advisors / lints | P (server advisor) | – | – | – | Y (splinter) | – | – | – | – | – | – |
| Index advice | – | – | – | P (AI Insights) | Y (index_advisor) | – | – | – | – | – | – |
| Environment colour / production mode | – | P (remote-color plugin) | – | P (server colour) | – | – | Y (connection types) | Y (colour) | Y (tags, safe mode) | – | P |
| Read-only mode (how enforced) | – | – | – | – | P (MCP read-only user) | P (GUC + regex) | P (client flag) | P (editor only) | – | P (startup query or role) | P |
| AI: natural language to SQL | – | P (plugins) | – | Y | Y | – | Y | Y | Y | – | Y (paid) |
| AI may execute | – | – | – | P (reads, read-only) | Y (reads auto, writes approved) | – | Y (per-class confirm) | Y (consent) | ? | – | Y (consent) |
| Licence | GPL-2.0† | Apache-2.0 / GPL-2.0† | GPL-2.0† | PostgreSQL | Apache-2.0 | MIT | Apache-2.0 (CE)† | commercial | commercial | commercial | GPL-3.0 (CE) |

### 3b. Specialist tools

**Modelling and documentation**

| Capability | pgModeler | ChartDB | Azimutt | DrawSQL | dbdiagram / DBML | dbdocs | SchemaSpy | pgAdmin ERD (ref.) |
|---|---|---|---|---|---|---|---|---|
| Source of truth | model file | pasted catalog JSON | imported schema + own notes | the diagram | DBML text | DBML | live catalog (batch) | live catalog |
| Focus on a subset / saved views | Y (layers) | P (areas) | Y (layouts start empty) | P (groups) | Y (DiagramView, paid) | – | – | Y (table + depth) |
| Find a join path | – | – | Y | – | – | – | – | – |
| Comments as documentation | P | – (empty by default) | P (notes outside the DB) | – | Y (notes) | Y | Y (Markdown) | P |
| Lint / anomalies | Y (validation) | – | Y (27 rules) | – | – | – | Y (anomalies) | – |
| Diff / changelog | P (diff, paid from 2.0) | P (cloud) | P (CLI diff) | P (history) | Y (versions) | Y (schema changelog) | – | – |
| Generates DDL | Y | Y | P | Y | Y | – | – | Y (Generate SQL) |
| AI | – | Y (OpenAI) | – | – | Y (diff to accept) | – | – | – |
| Licence | GPL-3.0 / paid binaries | AGPL-3.0 | MIT | closed | Apache-2.0 (DBML) | closed | LGPL-3.0 | PostgreSQL |

**Plan visualisers**

| Capability | PEV2 | explain.depesz.com | pgMustard | pgAdmin explain (ref.) |
|---|---|---|---|---|
| Graph view | Y | – | P (timing bars) | Y |
| Table with exclusive / inclusive time | Y (Grid) | Y | Y | Y |
| Row-estimate factor with colour thresholds | Y | Y (10 / 100 / 1000) | Y | Y |
| Buffers / I/O / WAL | Y | Y (buffers) | Y | Y |
| Ranked advice | P (badges) | – | Y (0–5 stars) | P (AI Insights) |
| Works without JavaScript | – | Y | – | – |
| Plan leaves your server | no (self-host) / yes (explain.dalibo.com) | yes | yes | no |
| Licence | PostgreSQL | Perl licence (Pg::Explain) | commercial | PostgreSQL |

**Monitoring**

| Capability | pgHero | pganalyze | PoWA | pgwatch | pg_activity |
|---|---|---|---|---|---|
| Health checks pass/fail | Y | Y | P | Y (Health Check, Recommendations) | – |
| Running / waiting / blocking views | P (live queries) | Y (root-cause blocker) | – | Y (Sessions, Lock Details) | Y (F1–F3) |
| Cancel / terminate | Y (Kill, `disable_kill`) | – (never) | – | – | Y (confirmed, colour-graded) |
| pg_stat_statements query stats | Y | Y | Y | Y | – |
| Index advice | Y (suggested, via Dexter/HypoPG) | Y (constraint model) | Y (qualstats + HypoPG) | P (reco_add_index) | – |
| Trends (needs collector) | Y (cron capture) | Y | Y (archivist) | Y (gatherer) | – |
| Explain sandbox | Y (rollback, one statement, timeout) | Y (auto_explain) | – | – | – |
| Least-privilege role | Y (SECURITY DEFINER wrappers, lock_timeout 1 s) | ? | ? | Y (pg_monitor) | – (superuser for full data) |
| Licence | MIT | commercial | PostgreSQL† | BSD-3-Clause | PostgreSQL |

**Schema change and review**

| Capability | Bytebase | Atlas | Liquibase | Flyway Desktop | squawk | strong_migrations |
|---|---|---|---|---|---|---|
| Web UI | Y | P (Cloud) | – (Hub shut down) | – (desktop) | P (WASM playground) | – |
| Change workflow with approval | Y (CEL rules, stages) | Y (`lint.review`) | P (policy checks) | P | – | – |
| PostgreSQL lock- and rewrite-aware rules | P (not version-aware) | Y (PG1xx / PG3xx) | P | P (regex / SQLFluff) | Y (78 rules, version-aware) | Y (with safe alternatives) |
| Rollback script | Y (data backup, reverse) | P | Y (RollbackRequired) | Y (undo, paid) | – | – |
| Drift detection | Y (anomaly centre) | Y (Pro) | Y (Secure) | Y (Enterprise) | – | – |
| SQL editor gated by the change path | Y | – | – | – | – | – |
| AI | Y (schema names only) | P (agents as seats) | P (preview) | – | – | – |
| Licence | MIT core + enterprise | Apache-2.0 core + Pro | FSL-1.1-ALv2 (5.x) | Apache-2.0 core + paid | Apache-2.0 | MIT |

**What the matrix says.**
- **No tool shows what a DDL statement costs.** None of the general-purpose tools shows the lock it takes or whether it rewrites the table. That knowledge exists only in the linters: Atlas, squawk, strong_migrations. Joining the two is the clearest gap in the field.
- **The other gaps** are the dry run, idle-transaction rollback, and graded AI exposure. Each is present in only one or two tools.
- **No web tool combines** multi-user accounts, full PostgreSQL coverage, staged edits with SQL preview, deterministic advisors, a gated change path and a guarded AI. Each exists somewhere; none exists together.

---

## 4. Ranked v1 screens

The ranking weighs three things. First, how often a DBA or developer would land on the screen. Second, how many surveyed tools treat it as core. Third, whether leaving it out would push users back to psql or a desktop client.

"Phone" says what the screen must do at 375 px under the estate's design system: **full** means usable for its purpose, **read** means readable and navigable with editing allowed to degrade, **–** means a link to a wider screen is enough.

| Rank | Screen | What it holds | Justified by | Phone |
|---|---|---|---|---|
| 1 | **Object browser** | Databases → schemas → object families. Paged, filterable lists. Search over names, comments and columns. Recent and favourite objects. An "advanced objects" toggle. | phpMyAdmin tree and verb tabs; phpPgAdmin hierarchy; pgAdmin explorer and its scale problem; Azimutt search | full |
| 2 | **Table: Structure** | Columns, constraints, indexes, triggers, policies, partitions, privileges, statistics (size, rows, bloat hint), comments. **DDL** with a commented DROP. **Dependencies/dependents.** | phpMyAdmin Structure; pgAdmin Properties, SQL and Dependencies tabs; DataGrip DDL view | read |
| 3 | **Table: Data (browse grid)** | Paged grid with a filter builder plus raw WHERE, sort, the generated SQL shown. Foreign-key links. **Staged edits** marked by colour, with a sticky "N pending — Review · Discard · Apply" bar. | phpMyAdmin Browse; Beekeeper, DBeaver, TablePlus, DataGrip, pgAdmin; Supabase queue (2026) | read |
| 4 | **Change review** | The one page every change ends on: graphical DDL, staged edits, grants, an agent's proposal. Shows the exact SQL, lint findings with **lock level / rewrite / scan** and the safe form, affected rows from a dry run, a rollback script where available, then Apply or Discard. When the policy says so, a request for approval instead. | pgAdmin SQL tab; DataGrip preview pane; TablePlus Code Review; phpMyAdmin Preview SQL and Simulate; Atlas, squawk, strong_migrations; Bytebase plan and review | full |
| 5 | **SQL workspace** | Editor with schema completion. Run statement, selection or script; Cancel. Results capped on the fetch side. Messages with the error position. Plan tab. History list. A dry-run toggle. Transaction state, if multi-request transactions exist (section 7, O1). | pgAdmin Query Tool; phpMyAdmin SQL tab; Supabase SQL editor; Beekeeper and DBeaver transaction UX | read |
| 6 | **Row page** | One record as a full-page form: NULL vs empty made explicit; foreign keys edited through the record picker; **referencing rows grouped by foreign key**; optimistic-concurrency conflict view. | DBeaver References panel; DataGrip Related Rows; Postico picker and sidebar; Supabase FK selector; estate record picker | full |
| 7 | **Object forms** | Create or alter a schema, table, column, constraint, index, view, materialised view, sequence, function or procedure, trigger, type, domain, enum, extension, policy. Each is a full page ending in Change review. | pgAdmin dialogs (de-modalised); Adminer forms; DataGrip Modify | read |
| 8 | **Memory browser (MaluDB)** | Memory databases, namespaces and scopes, documents with sources and chunks, episodes, a graph neighbourhood as table and graph, provenance from a fact to its episodes, a read-only API console. Content to be set by the MaluDB sibling. | Zep, Letta ADE, Neo4j Browser, Qdrant console; the product brief | read |
| 9 | **Activity** | Running / waiting / blocking, with the root blocker. Idle-in-transaction age. Locks. Cancel (yellow) and terminate (red) as separate confirmed actions. Auto-refresh. | pg_activity; pgAdmin Dashboard; pganalyze Connections; pgHero | full |
| 10 | **Plan view** | Server-rendered table: exclusive and inclusive time, rows factor coloured, buffers. Deterministic flags. Optional PEV2 graph. Plans kept in history. "Explain this plan" for the expert agent. | depesz; pgAdmin explain table; PEV2; pganalyze anti-patterns; pgMustard | full (table) |
| 11 | **Roles and privileges** | Role list. Role page: attributes, memberships, effective privileges. A privileges tab on every object. A grant wizard ending in Change review. | pgAdmin Grant Wizard and Security tabs; phpMyAdmin User accounts; phpPgAdmin | read |
| 12 | **History and saved queries** | The person's and agents' executed statements, with outcome, duration and rows. Searchable. Saved queries with parameters, private or shared. | pgAdmin History; DBeaver Query Manager; DataGrip 2026.2; phpMyAdmin bookmarks; Supabase snippets | full |
| 13 | **Health / advisors** | Deterministic checks with severity: missing primary key, unindexed foreign keys, duplicate and unused indexes, sequences near overflow, wraparound, bloat hint, RLS gaps, SECURITY DEFINER without `search_path`. Each fix is SQL that opens in Change review. | pgHero; splinter; pgwatch recommendations; Azimutt rules; SchemaSpy anomalies | full |
| 14 | **Change log and drift** | Every applied change: who, when, SQL, outcome, rollback. The live schema against the last recorded state, or against the owning application's migrations, with adopt/revert. | phpMyAdmin Tracking; Bytebase; Flyway; Atlas; dbdocs Schema Changelog; Supabase drift footgun | read |
| 15 | **Database overview** | Version, size by schema, extensions, non-default settings highlighted, maintenance actions (VACUUM, ANALYZE, REINDEX CONCURRENTLY, REFRESH MATERIALIZED VIEW) as jobs with lock notes. | pgweb settings; phpPgAdmin Admin and red values; pgAdmin Maintenance | read |
| 16 | **Export / import jobs** | Export of a table or result as CSV, JSON or SQL; COPY-based import with preview and column mapping. Background jobs with progress and an audit row. | phpMyAdmin Export/Import; pgAdmin Import/Export and Processes | read |
| 17 | **Schema diagram (focused)** | Start from a table, add N hops, detail levels, saved layouts, find a join path into the editor, SVG export. | Azimutt; dbdiagram views; pgAdmin ERD; Adminer schema | – |
| 18 | **RLS: policies and "run as role"** | Policies per table with the SQL shown; a SELECT-only "run as role" tester. | Supabase RLS editor, impersonation and tester | read |

**For v1 by evidence, but LATER by effort:**
- query statistics with trends (needs a collector);
- index advice through HypoPG;
- schema diff between two databases;
- data-dictionary export (HTML or Markdown) and DBML or Mermaid export;
- dump and restore;
- the PL/pgSQL debugger (needs a server library and a restart);
- ERD-driven design that generates DDL into Change review.

**Never,** on the evidence: an in-browser psql or shell, which pgAdmin disables by default in server mode.

---

## 5. Requirements

Each requirement carries a tag:
- **MUST** — v1.
- **SHOULD** — v1 if the slices allow, otherwise the first follow-up.
- **LATER** — a known want that is deferred.

Each one names the tools whose screens, documentation or failures justify it. They are field requirements: what the market shows a tool of this kind needs. The estate, internals and security reports will add, sharpen or overrule them.

### 5.1 Navigation and information architecture
- **R1 MUST** — Navigation follows PostgreSQL's hierarchy, with the schema as a first-class level: database → schema → object family → object. *phpPgAdmin, pgAdmin, Adminer; phpMyAdmin lacks it.*
- **R2 MUST** — The same verbs appear as tabs at each level, scoped to it: structure, data, SQL, search, import/export, privileges, operations. *phpMyAdmin's three-level tabs.*
- **R3 MUST** — Object lists come from set-based catalog queries, never one query per object. They are paged, and a filter box appears on large folders. A schema of 10,000 tables stays usable. *pgAdmin's tree problem; phpMyAdmin's filter at 30 items.*
- **R4 MUST** — Object search covers names, column names, types and comments, and opens the object. *pgAdmin Search Objects (names only); Azimutt.*
- **R5 SHOULD** — Recent and favourite objects per person. *phpMyAdmin.*
- **R6 SHOULD** — "Show system schemas" and "show advanced object families" toggles keep the tree usable. *phpPgAdmin `show_system`/`show_advanced`.*
- **R7 MUST** — Every screen is a plain URL: bookmarkable, safe on the back button, shareable with a colleague who has the same rights. *Adminer.*

### 5.2 Objects and DDL
- **R8 MUST** — A table page shows columns, constraints, indexes, triggers, RLS policies, partitions, privileges, size and statistics, and comments. *phpMyAdmin Structure; pgAdmin.*
- **R9 MUST** — Every object shows its reverse-engineered DDL, with a commented DROP, ready to copy into the editor. *pgAdmin SQL tab.*
- **R10 MUST** — Every object shows its dependencies and dependents, and the DROP screen lists them, including the full reach of CASCADE. *pgAdmin; pgModeler's CASCADE warning.*
- **R11 MUST** — Create and alter forms, each a full page with no modal, exist for: schema, table, column, constraint (PK, FK, unique, check, exclusion), index, view, materialised view, sequence, function and procedure, trigger, type, domain, enum, extension, policy. *pgAdmin dialogs; Adminer forms; the estate's no-modal rule.*
- **R12 MUST** — Every graphical change ends on Change review showing the exact SQL. The SQL can be copied or edited in the editor before Apply. *pgAdmin SQL tab; DataGrip preview pane; TablePlus Code Review; phpMyAdmin Preview SQL.*
- **R13 MUST** — Change review annotates each DDL statement with:
  - the lock it takes;
  - whether it rewrites or scans the table;
  - the table's size;
  - the safe alternative where one exists — CONCURRENTLY, NOT VALID then VALIDATE, a check constraint before SET NOT NULL.

  The rules know the server version. *Atlas PG1xx/PG3xx; squawk; strong_migrations. No general-purpose tool does this.*
- **R14 MUST** — DDL is applied with a short `lock_timeout` and a `statement_timeout`. When the lock cannot be taken, the screen says so, shows the blocking sessions, and offers a retry. *GoCardless; Xata; strong_migrations; pgHero's role (`lock_timeout` 1 s).*
- **R15 MUST** — `CREATE INDEX` defaults to CONCURRENTLY on a table that already holds data. Statements that cannot run in a transaction are run on their own and reported so. *Atlas PG101; squawk; Bytebase rule.*
- **R16 SHOULD** — A rename is a rename, never a drop and re-create. A diff or form that cannot tell asks. *pgModeler's warning that renames are dropped.*
- **R17 MUST** — Destructive operations on an object sit in one labelled danger zone: TRUNCATE, DROP, DROP CASCADE. CASCADE and FORCE are visibly distinct actions. *phpMyAdmin Operations; pgAdmin menus.*
- **R18 SHOULD** — Comments (`COMMENT ON`) are editable on every object and rendered as Markdown documentation. *SchemaSpy; Adminer Editor's labels; Azimutt's drift.*
- **R19 SHOULD** — Copy table (structure, data, or both), rename and move to another schema. *phpMyAdmin Operations.*
- **R20 LATER** — A central dictionary of reusable column definitions. *phpMyAdmin central columns.*

### 5.3 Data grid and row editing
- **R21 MUST** — The grid pages on the server, at 50–200 rows by default. There is no "fetch all" in the grid. A count taken from statistics is labelled as an estimate. *phpMyAdmin 25, Adminer 50, pgweb 100, DBeaver 200, TablePlus 300, DataGrip 500; pgAdmin's uncapped View All Rows until 9.17.*
- **R22 MUST** — Long text is truncated with a way to expand it. Binary and large values show their size, never the bytes. *phpMyAdmin `LimitChars`; Adminer text length.*
- **R23 MUST** — Filtering offers a builder (column, operator, value), a raw WHERE box, and "filter by this value" from a cell. The generated SQL is always shown. *DBeaver; TablePlus; pgweb; phpMyAdmin `ShowSQL`.*
- **R24 SHOULD** — Filter history and saved named filters. *DBeaver.*
- **R25 MUST** — Edits are staged in a durable change set held on the server. It survives reload, sorting, filtering, paging and session expiry. *Beekeeper's documented "sorting or filtering … will discard your staged changes".*
  - Rows are marked by colour: new, changed, deleted.
  - A sticky bar reads "N pending — Review SQL · Discard · Apply".
  - *DBeaver, TablePlus, DataGrip, Supabase queue.*
- **R26 MUST** — Apply runs the whole change set in one transaction. Each statement must touch exactly the rows expected, or everything is rolled back. *Supabase "single transaction"; pgAdmin's SAVEPOINT.*
- **R27 MUST** — Optimistic concurrency. A row changed by someone else since it was read is shown as a conflict, never silently overwritten. *xmin as a concurrency token (Npgsql); DataGrip's merge on conflict.*
- **R28 MUST** — Editing needs a primary key or a unique key with no NULLs. Without one the grid is read-only and says why. *pgAdmin; Beekeeper; phpMyAdmin's duplicate-row footgun.*
- **R29 MUST** — NULL, empty string and DEFAULT are distinct and visible, with explicit "set NULL" and "set DEFAULT". *DBeaver; pgAdmin's opaque convention.*
- **R30 MUST** — A value the person did not change is never rewritten. Numeric, jsonb and timestamp values round-trip exactly. *pgAdmin's 9.16 jsonb bug.*
- **R31 MUST** — A foreign-key cell links to the referenced row. The row page lists the rows that reference it, grouped by foreign key. *DBeaver References; DataGrip Related Rows; phpMyAdmin; Beekeeper.*
- **R32 MUST** — A foreign-key value is chosen through the searchable record picker, never a `<select>` of every row. *Postico; Supabase FK selector; phpMyAdmin `ForeignKeyMaxLimit`; estate record picker.*
- **R33 SHOULD** — The display column of a referenced row is chosen per table, for links and pickers. *phpMyAdmin display column; Adminer Editor.*
- **R34 SHOULD** — JSON, jsonb, arrays and long text are edited on a full page or in an inline editor that validates. *pgAdmin JSON editor; Beekeeper.*
- **R35 SHOULD** — Revert one cell, one row, or everything. *DataGrip Revert Selected.*
- **R36 MUST** — Bulk edit or delete of "all matching rows" happens only through generated SQL shown with the exact count. It is never a checkbox beside a page of results. *Adminer's "Whole result".*
- **R37 SHOULD** — An insert form with a function or DEFAULT per column, and "then: insert another / back to list". *phpMyAdmin Insert.*

### 5.4 SQL workspace
- **R38 MUST** — The editor has PostgreSQL highlighting, schema-aware completion, formatting, and runs the statement at the cursor, the selection, or the script. *pgAdmin; phpMyAdmin; Postico; CodeMirror lang-sql PostgreSQL dialect.*
- **R39 MUST** — A visible Cancel stops a running statement. Every run carries a `statement_timeout`. *pgAdmin Stop; pgweb `--query-timeout`; Crunchy guidance.*
- **R40 MUST** — Results are bounded on the fetch side (a row cap and a byte cap), not by rewriting the SQL, so CTEs, scripts and commented queries are bounded too. *Supabase's auto-limit skips them; Bytebase 100k rows / 100 MB; pgAdmin batches.*
- **R41 MUST** — A messages panel shows notices, errors with their position marked in the editor, rows affected and duration. *pgAdmin Messages.*
- **R42 MUST** — Every statement is classified on the server by a real PostgreSQL parser, before it runs:
  - read, DML, DDL, DCL, transaction control, utility;
  - by effect, so a writing CTE or EXPLAIN ANALYZE of a write counts as DML;
  - for every statement in a batch, comments included.

  The classification drives confirmations, permissions and history. *phpMyAdmin's regex and its TODO; Supabase's regex weaknesses; Bytebase classification by effect.*
- **R43 MUST** — Destructive and unscoped statements need a confirmation that names the objects and the estimated rows: DROP, TRUNCATE, DELETE or UPDATE without WHERE, ALTER … DROP COLUMN. Dropping a database or schema means typing its name. *DataGrip; Supabase; phpMyAdmin `Confirm`; Supabase type-to-delete.*
- **R44 MUST** — A dry run executes DML or DDL inside BEGIN … ROLLBACK and reports rows affected and objects changed. Statements that cannot run in a transaction are named, not run. *phpMyAdmin Rollback when finished and Simulate query; PostgreSQL's transactional DDL.*
- **R45 MUST** — If the tool offers transactions that span requests, their state is always visible. *pgAdmin indicator; CloudBeaver count; Beekeeper 10 min; DBeaver 600 s.*
  - Idle shows its age; aborted shows a Rollback button.
  - A warning comes before the idle timeout, and the transaction is rolled back after it.
  - Leaving the page warns.
- **R46 MUST** — Query history per person and database records text, time, duration, rows and outcome. It is searchable and kept in the tool's own database. *pgAdmin; DBeaver Query Manager; DataGrip; phpMyAdmin's pmadb lesson.*
- **R47 SHOULD** — Saved queries with named parameters, private or shared. A saved query never runs implicitly. *phpMyAdmin bookmarks and their auto-run footgun; Supabase snippets.*
- **R48 SHOULD** — Export a result without re-running it, or re-run it under the same caps. *Adminer 6.0; Bytebase.*
- **R49 LATER** — Snippets or macros. *pgAdmin macros; Supabase snippets.*
- **R50 LATER** — Chart a result. *pgAdmin Graph Visualiser; phpMyAdmin Display chart.*

### 5.5 Plans
- **R51 MUST** — EXPLAIN and EXPLAIN ANALYZE with BUFFERS, VERBOSE, SETTINGS, and SERIALIZE and MEMORY on 17. ANALYZE carries a warning that it executes the statement. ANALYZE of a write runs in a transaction that is rolled back, one statement only, with a timeout. *pgMustard; pgHero's explain sandbox.*
- **R52 MUST** — A server-rendered plan table that works without JavaScript and at 375 px. It shows exclusive and inclusive time and the rows-estimate factor, coloured at documented thresholds. *depesz; pgAdmin explain table.*
- **R53 SHOULD** — A graphical plan through PEV2 (PostgreSQL licence), vendored as committed static files and pinned to a version. *PEV2; its 1.22 HTML-injection fix; Boards' committed-bundle precedent.*
- **R54 SHOULD** — Deterministic plan flags: mis-estimate, disk sort, hash batches, lossy bitmap, slow scan, stale statistics, high heap fetches, never executed. They appear before any AI commentary. *PEV2 badges; pganalyze's eight anti-patterns; pgMustard tips.*
- **R55 MUST** — Plans and query text are never sent to an outside service. "Copy JSON" is the only export. *explain.dalibo.com stores plans; depesz; pgMustard.*
- **R56 SHOULD** — Plans are kept in history with their query and a comment. *PEV2 `plan-comment`; explain.dalibo.com's list.*

### 5.6 Activity and administration
- **R57 MUST** — An activity screen shows sessions as running, waiting and blocking, with the root blocker highlighted and idle-in-transaction age. Cancel and terminate are separate actions, colour-graded and confirmed. There is no unconfirmed "kill all". *pg_activity; pgAdmin Dashboard; pganalyze Connections; pgHero's Kill All.*
- **R58 MUST** — A locks view links each lock to its session and object. *pgAdmin State tab; phpPgAdmin Locks; pgwatch Lock Details.*
- **R59 SHOULD** — A database overview shows version, sizes by schema, extensions, and settings with the non-default ones highlighted. *pgweb settings; phpPgAdmin's red values; pgAdmin Configuration.*
- **R60 SHOULD** — VACUUM, ANALYZE, REINDEX CONCURRENTLY and REFRESH MATERIALIZED VIEW run as background jobs. VACUUM FULL and CLUSTER carry an ACCESS EXCLUSIVE warning. *pgAdmin Maintenance, which lacks the warning; phpPgAdmin Admin.*
- **R61 SHOULD** — Per-table autovacuum settings are shown and editable. *phpPgAdmin; pgAdmin Parameter tab.*
- **R62 LATER** — A prepared-transactions view. *pgAdmin.*

### 5.7 Roles, privileges and RLS
- **R63 MUST** — A roles list, and a role page showing attributes, memberships and effective privileges by object. *pgAdmin; phpMyAdmin User accounts; phpPgAdmin.*
- **R64 MUST** — A privileges tab on every object, and a grant wizard that ends in Change review. *pgAdmin Security tab and Grant Wizard.*
- **R65 MUST** — An RLS policy list and editor, with the SQL front and centre. *Supabase RLS editor; Supabase's "CREATE TABLE without RLS" warning.*
- **R66 SHOULD** — "Run as role" testing of RLS, SELECT only. *Supabase impersonation and RLS Tester ("mutations could trigger side effects").*
- **R67 MUST** — Hiding is never authorisation. What a person may do is enforced by the PostgreSQL role the tool uses on their behalf, not by hiding menus or objects. *phpMyAdmin user groups; phpPgAdmin `owned_only`; Adminer's database-hide disclaimer.*
- **R68 MUST** — Read-only access is a PostgreSQL role without write privileges, with `default_transaction_read_only` as a second layer. It is never only a UI flag, a GUC or a keyword regex. *DataGrip; Postico; pgweb; pgAdmin's 2026 CVEs; Supabase MCP's read-only user.*

### 5.8 Environment and production safety
- **R69 MUST** — Every connected database carries an environment label (production, staging, development, scratch). The label shows with its colour in the header, the grid and the editor. *DBeaver connection types; TablePlus tags; DataGrip colours.*
- **R70 MUST** — Production bundles stricter defaults: confirm every write, read-only on entry, a short idle timeout, warnings that cannot be switched off. *DBeaver Production; TablePlus safe mode; DataGrip's permanent "execute and suppress".*
- **R71 MUST** — The tool's queries are attributable, through `application_name` and a comment naming the person or agent, in `pg_stat_activity` and the logs. *Supabase `-- source: dashboard`; pgAdmin's access-log identity.*
- **R72 MUST** — Guards fail closed and have tests. A missing confirmation is a defect, not a pass. *Supabase MCP failing open without elicitation; Supabase PR #33801.*

### 5.9 Modelling and documentation
- **R73 SHOULD** — A schema diagram drawn from the live catalog with no separate model file, focused rather than whole. *Azimutt; dbdiagram views and detail levels; pgAdmin ERD; Adminer schema; pgModeler's drift.*
  - Start from a table and add N hops.
  - Detail levels.
  - Saved layouts.
  - SVG export.
- **R74 SHOULD** — Find a join path between two tables, with an ignore list for hub tables, and emit the JOIN into the editor. *Azimutt.*
- **R75 SHOULD** — A data-dictionary export (HTML or Markdown) built from comments. *pgModeler; SchemaSpy; dbdocs.*
- **R76 LATER** — DBML and Mermaid export, generated natively in PHP. *DBML (Apache-2.0); Mermaid.*
- **R77 LATER** — ERD-driven design that generates DDL into Change review and never applies it directly. *pgAdmin ERD Generate SQL; dbdiagram's AI diff.*

### 5.10 Monitoring and advice
- **R78 MUST** — A health page of deterministic checks, each with a severity and its fix as SQL that opens in Change review. There is never a run button. *pgHero; splinter; pgwatch recommendations; Azimutt rules; SchemaSpy anomalies.*
  - missing primary key;
  - unindexed foreign keys;
  - duplicate, invalid and unused indexes;
  - sequences and integer columns near overflow;
  - wraparound age;
  - RLS gaps;
  - SECURITY DEFINER without `search_path`;
  - idle-in-transaction sessions.
- **R79 SHOULD** — Query statistics from `pg_stat_statements` (total and mean time, calls, rows), each linking to explain. *pgHero; Supabase Query Performance; pganalyze; PoWA.*
- **R80 LATER** — Index advice that is deterministic and checked by the planner through HypoPG or `index_advisor`. It recommends and never creates. *PoWA; Supabase index_advisor; pganalyze; Dexter's `--create` opt-in.*
- **R81 LATER** — Trends from a collector, as snapshots of statistics over time. *pgHero capture jobs; pgwatch; PoWA archivist.*

### 5.11 Change management
- **R82 MUST** — Every applied DDL, DCL or bulk DML is recorded in the tool's change log: who (person or agent), when, database, the SQL, the outcome, the rollback script if any. *phpMyAdmin Tracking; Bytebase history; dbdocs changelog.*
- **R83 SHOULD** — Lint rules run on every change script, with a policy that decides which findings need approval. *Atlas `lint.review`; Bytebase CEL rules; squawk; Liquibase policy checks.*
- **R84 SHOULD** — Each change carries a rollback script where one can be generated, and says plainly when none can. *Liquibase RollbackRequired; Flyway undo; Bytebase.*
- **R85 SHOULD** — Drift: the live schema is compared with the last recorded state and, for an estate application's database, with that application's migrations. The result is a diff with adopt or revert, never fixed automatically. *Flyway; Atlas; Bytebase; Supabase's warning that edits made in the dashboard break `db push`.*
- **R86 MUST** — The SQL editor is not a side door. A write the person may not make directly is turned into a proposed change for review, not refused silently or run. *Bytebase run-queries redirect.*
- **R87 LATER** — A schema diff between two databases that generates a script and never applies it. *pgAdmin Schema Diff; pgModeler.*

### 5.12 Import, export and backup
- **R88 MUST** — Export a table or result (CSV, JSON, SQL INSERTs) as a background job, with caps and an audit row. *phpMyAdmin; pgweb; pgAdmin; Bytebase export re-runs under masking.*
- **R89 SHOULD** — CSV import through COPY with preview, column mapping and PostgreSQL 17's ON_ERROR, in one transaction, as a background job. *pgAdmin Import/Export; phpMyAdmin's partial-import footgun.*
- **R90 LATER** — Dump and restore of a schema or database as a job. Command-line arguments are never built from request data, and binary versions are checked. *pgAdmin Backup and its 9.18 injection fix; phpPgAdmin's `pg_dump` version coupling.*

### 5.13 AI
- **R91 MUST** — AI-generated SQL lands in the editor, or as a diff in Change review, for a person to accept. The AI never executes a write itself. *pgAdmin Insert/Replace; Supabase diff; dbdiagram diff; Cloud SQL Studio; Neon.*
- **R92 MUST** — What the AI sees is graded by an administrator: schema only by default, then logs, then query results and data, each an explicit step up. *Supabase opt-in levels; DBeaver consent and scope; Beekeeper's approved results; TablePlus and Bytebase schema only.*
- **R93 MUST** — The AI's own reads run as a PostgreSQL role with no write privileges, one statement per call through the extended protocol, with row and time caps. *pgAdmin CVE-2026-12045 and CVE-2026-17351; the reference MCP server; Postgres MCP Pro restricted mode; JetBrains.*
- **R94 MUST** — Agent queries and proposals appear in the same history and change log as people's, attributed to the agent. *DataGrip 2026.2; Bytebase agent identities.*
- **R95 SHOULD** — "Explain this query", "Fix this error" and "Explain this plan" sit on the error, plan and editor panels, on top of the deterministic flags. *DataGrip; pgAdmin AI Insights; Neon; pgMustard.*
- **R96 SHOULD** — On-demand AI reports (security, performance, schema design) as downloadable Markdown, grounded in the health checks. *pgAdmin AI Reports.*

### 5.14 MaluDB (field-level; the MaluDB sibling sets the model)
- **R97 MUST** — A memory-database browser: memory databases, namespaces, scopes and principals, documents with source and chunks, episodes over time. A graph neighbourhood shown as a table and as a graph. *Zep; Letta ADE; Neo4j Browser's graph/table toggle; Qdrant.*
- **R98 SHOULD** — Provenance from a fact or edge to the episodes and documents that support it. *Zep "Ask graph".*
- **R99 SHOULD** — A MaluDB API console, read-only by default, using the person's own token. *Qdrant console.*
- **R100 MUST** — Forgetting (deleting a document or memory) shows what will be removed before, and verifies the removal after. *MaluDB API README:277; mem0 delete by filter.*

### 5.15 Platform
- **R101 MUST** — The tool's own state lives in its own database, never in a managed database. That covers history, saved queries, layouts, change log, pending change sets and preferences. *phpMyAdmin's pmadb dependence.*
- **R102 MUST** — Long operations run as background jobs with progress, never inside a PHP request: export, import, dump, maintenance, `CREATE INDEX CONCURRENTLY`. *phpMyAdmin `ExecTimeLimit` and partial import; pgAdmin Processes.*
- **R103 MUST** — Every string that comes from a database is escaped: identifiers, values, comments, error messages, plan JSON. *pgAdmin 9.16 stored XSS; PEV2 1.22 HTML injection.*
- **R104 MUST** — No shell-like feature: no in-browser psql, nothing that can reach `COPY … TO PROGRAM`. *pgAdmin PSQL tool disabled in server mode; the escalation of pgAdmin CVE-2026-12045 to RCE.*
- **R105 MUST** — Detect capabilities from the catalog by feature, for PostgreSQL 17 as the stated target, never through one code path per version. *phpPgAdmin's per-version classes.*
- **R106 SHOULD** — Read paths work at 375 px: browse, structure, activity, plan table, history. Heavy editing may ask for a wider screen but must not break. *Estate design system; pgAdmin's cramped graph.*
- **R107 LATER** — A data-only, label-driven face for people who are not DBAs. *Adminer Editor.*

**Count:** 107 requirements — **64 MUST, 32 SHOULD, 11 LATER**.

---

## 6. How these tools fail users

Each footgun below is set out in four parts: what goes wrong, the evidence, what the better tools add, and the requirement that answers it.

### 6.1 Editing production by accident

- **What goes wrong.** A tab, connection or host that looks like development is production.
- **Evidence.**
  - GitLab's outage of 2017-01-31 began when a command meant for one database host ran on the primary. About 300 GB was removed. One remedy in the postmortem was to make prompts "more clearly differentiate between hosts and environments" (https://about.gitlab.com/blog/2017/02/10/postmortem-of-database-outage-of-january-31/).
  - In July 2025 Replit's agent erased a database during a code freeze (https://incidentdatabase.ai/reports/5593/).
- **What the better tools add.**
  - **DBeaver's Production connection type**: colour, confirm SQL execution and data changes, auto-commit off, idle transactions ended after 600 s (https://dbeaver.com/docs/dbeaver/Connection-Types/).
  - **TablePlus**: a tag chosen when the connection is created, plus five safe-mode levels (https://docs.tableplus.com/gui-tools/code-review-and-safemode/safe-mode).
  - **DataGrip**: colour on editor tabs, consoles and grids.
  - **pgAdmin**: server colours (https://www.pgadmin.org/docs/pgadmin4/latest/server_dialog.html).
  - **Adminer**: a red strip when the database is remote (plugin).
- **The weak point.** Every one of these is a client-side label. DataGrip and Postico both admit that client-side read-only leaks.
- **Answer:** R68–R70. An environment label drives behaviour, and read-only is a database role.

### 6.2 The unbounded SELECT

- **What goes wrong.** A `SELECT *` on a large table freezes the client, exhausts PHP memory, or loads the server.
- **Evidence.**
  - pgAdmin "out of memory for query result" (https://www.postgresql.org/message-id/CAM9w-_n%3DYETKvKGZMA-U8ym_x%2BUoNVj26rDbXBe0KouTSnG5yA%40mail.gmail.com).
  - pgAdmin's "View All Rows" was uncapped until 9.17 in 2026 (https://www.pgadmin.org/docs/pgadmin4/latest/release_notes_9_17.html).
  - DBeaver documents that "Fetch all rows" can hang or run out of memory.
  - Supabase's auto-limit skips CTEs, scripts and commented queries (https://raw.githubusercontent.com/supabase/supabase/master/apps/studio/data/sql/utils.ts).
  - PostgreSQL's `statement_timeout` defaults to 0, meaning disabled (https://www.postgresql.org/docs/17/runtime-config-client.html).
- **What the better tools add.**
  - **Low default caps**: phpMyAdmin 25, MySQL Workbench 200 rows plus a 30 s read timeout (https://dev.mysql.com/doc/workbench/en/wb-preferences-sql-editor.html).
  - **Byte and row caps**: Bytebase, 100k rows / 100 MB.
  - **A per-role timeout**: Crunchy Data recommends 30–60 s (https://www.crunchydata.com/blog/control-runaway-postgres-queries-with-statement-timeout).
  - **A visible Cancel.**
- **Answer:** R21, R39, R40.

### 6.3 DROP, TRUNCATE, and DELETE or UPDATE without WHERE

- **What goes wrong.** A destructive statement runs with no second look.
- **Evidence and existing guards.**
  - **DataGrip** warns on DELETE or UPDATE without WHERE, but not on DROP or TRUNCATE. "Execute and suppress" turns the warning off for good (https://www.jetbrains.com/help/datagrip/query-execution.html).
  - **MySQL's safe updates** refuse such statements (https://dev.mysql.com/doc/refman/8.4/en/mysql-tips.html).
  - **PostgreSQL's `pg-safeupdate`** extension raises an error on UPDATE or DELETE without WHERE, CTEs included. `WHERE 1=1` is the deliberate override (https://github.com/eradman/pg-safeupdate).
  - **phpMyAdmin's confirmation** is a regex that misses statements after the first one (section 2.1).
  - **Adminer** confirms buttons but never the SQL box (section 2.2).
  - **Supabase's warning** is a regex its own MCP port calls "not a security barrier", which a parser later replaced (https://github.com/supabase/mcp/pull/408; https://github.com/supabase/mcp/pull/426).
  - **Supabase deletes a project only after you type its name** (https://supabase.com/docs/guides/platform/delete-project.md).
- **What the better tools add.**
  - Parser-based classification.
  - Confirmations that name the objects and the rows.
  - Type-to-confirm for databases and schemas.
  - A dry run.
  - Backups and point-in-time recovery as the real backstop, as GitLab and Replit both learned.
- **Answer:** R42–R44, and `pg-safeupdate` on the tool's write role as an option for the internals sibling.

### 6.4 The innocent ALTER that takes the site down

- **What goes wrong.** Most `ALTER TABLE` forms take ACCESS EXCLUSIVE (https://www.postgresql.org/docs/17/sql-altertable.html).
  - Several also **rewrite** the table: a volatile default, a type change that is not binary-coercible, and generated or identity columns.
  - Others **scan** it: adding a CHECK, SET NOT NULL, or a foreign key without NOT VALID.
  - A plain `CREATE INDEX` blocks writes, while `CONCURRENTLY` cannot run inside a transaction and leaves an INVALID index if it fails (https://www.postgresql.org/docs/17/sql-createindex.html).
- **The worst part is the lock queue.** "If the operation has to wait to acquire its exclusive lock, all queries which arrive after it will queue up behind it" (https://gocardless.com/blog/zero-downtime-postgres-migrations-a-little-help/).
  - GoCardless had a roughly 15-second payments outage this way (https://gocardless.com/blog/zero-downtime-postgres-migrations-the-hard-parts/).
- **What the better tools add.**
  - **Short timeouts**: GoCardless sets `lock_timeout` 750 ms and `statement_timeout` 1500 ms; Xata always sets `lock_timeout` and retries with backoff (https://xata.io/blog/migrations-and-exclusive-locks); strong_migrations recommends 10 s for migrations.
  - **Lint rules** that name the lock (Atlas, squawk).
- **The gap.** No general-purpose tool in this survey tells the person, at the moment they press Apply, that their ALTER will rewrite a 40 GB table under ACCESS EXCLUSIVE.
- **Answer:** R13–R15. The precise lock behaviour is for the internals sibling.

### 6.5 Edits lost in the grid

- **What goes wrong.** Pending edits disappear without the person noticing.
- **Evidence.**
  - pgAdmin once lost an edit when the person tabbed away, and silently discarded unsaved edits on sort or filter (https://www.postgresql.org/message-id/48123633.6010206%40falter.at). It now has "Prompt to save unsaved data changes?" and "Confirm on close or refresh" (https://www.pgadmin.org/docs/pgadmin4/latest/preferences.html).
  - Beekeeper still documents that sorting or filtering discards staged changes (https://docs.beekeeperstudio.io/user_guide/editing-data/).
  - **Session expiry**: phpMyAdmin's login cookie lasts 1440 s by default, bounded by PHP's session lifetime (https://docs.phpmyadmin.net/en/latest/config.html).
  - **Concurrent overwrite**: a grid that updates `WHERE pk = …` lets the last writer win.
- **What the better tools add.**
  - A pending count with Review, Save and Discard (TablePlus, DBeaver, DataGrip).
  - Prompts before leaving.
  - Concurrency tokens such as `xmin`, where a stale value matches zero rows and so signals a conflict (https://www.npgsql.org/efcore/modeling/concurrency.html).
- **Answer:** R25–R27. A change set held on the server is the strongest version of this, because it survives the browser.

### 6.6 Confusing transaction state

- **What goes wrong.**
  - An aborted transaction refuses everything until it is rolled back. psql makes you "explicitly abandon any failed transaction"; `ON_ERROR_ROLLBACK` exists to soften this (https://www.postgresql.org/docs/17/app-psql.html).
  - Manual-commit mode is forgotten, and an idle-in-transaction session holds locks and stops vacuum.
  - In MySQL Workbench "all query tabs in the same connection share the same transaction" (https://dev.mysql.com/doc/workbench/en/wb-preferences-sql-editor.html).
  - DataGrip has two stages: submitted, then committed.
  - pgAdmin reduces the state to a small icon.
- **What the better tools add.**
  - **DBeaver**: smart commit and "end idle transactions".
  - **CloudBeaver**: a count on the transaction-log button.
  - **Beekeeper**: a connection reserved per tab, a warning at 9 minutes and rollback at 10.
  - **On the server**: `idle_in_transaction_session_timeout` and PostgreSQL 17's `transaction_timeout` (runtime-config-client.html).
- **The web-specific trap.** pgAdmin must run as a single Python process so that a session keeps its connection. A PHP tool under prefork cannot hold a transaction across requests without a dedicated service.
- **Answer:** R45, and section 7, O1.

### 6.7 Editing rows that have no identity

- **What goes wrong.** phpMyAdmin warns that grid edits on a result with no unique column "may result in undesired behavior", and goes ahead anyway (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/libraries/classes/Sql.php#L1370-L1400). An update keyed by all the column values can hit several identical rows.
- **What the better tools add.** pgAdmin and Beekeeper refuse to edit. DBeaver asks the person to declare a key.
- **Answer:** R28.

### 6.8 Values corrupted on the round trip

- **What goes wrong.**
  - pgAdmin's jsonb editor stripped trailing zeros and rewrote large integers on save (fixed in 9.16).
  - pgAdmin's convention that an empty cell means NULL and `''` means the empty string is easy to get wrong (https://www.pgadmin.org/docs/pgadmin4/latest/editgrid.html).
- **Answer:** R29, R30.

### 6.9 One click, every row

- **What goes wrong.**
  - Adminer's **"Whole result"** checkbox turns a page action into an edit or delete of every matching row. The count beside it may be an estimate, and the only prompt is a generic "Are you sure?" (https://github.com/vrana/adminer/blob/main/adminer/select.inc.php#L686-L704).
  - pgHero's **Kill All** has no confirmation step in its template.
- **Evidence.** The research found no documented incident of real harm from a grid's "apply to all", so this is plausible but unproven.
- **Answer:** R36, R57.

### 6.10 Guards made of regexes and wrappers

- **What goes wrong.** Guards built from pattern matching or transaction wrappers are bypassed.
  - phpMyAdmin's regex carries a TODO to use the parser.
  - Supabase's regex is "not a security barrier" and once failed open (https://github.com/supabase/supabase/pull/33801). Its MCP server ran destructive SQL with no prompt when the client could not ask (https://github.com/supabase/mcp/issues/457).
  - pgweb's `--readonly` is a GUC the session can change, plus a keyword list.
  - pgAdmin's AI read-only transaction was bypassed twice in 2026, through stacked statements and a lexer differential.
  - The reference MCP Postgres server fell to stacked statements (https://securitylabs.datadoghq.com/articles/mcp-vulnerability-case-study-SQL-injection-in-the-postgresql-mcp-server/).
- **What the better tools add.** The pattern across all of them is that **only a database role is a wall**. Parsers and confirmations are a UI courtesy, and they must fail closed.
- **Answer:** R42, R68, R72, R93. Depth belongs to the security sibling.

### 6.11 Hiding mistaken for security

- **What goes wrong.** People treat a hidden object or menu as protected.
- **Evidence.** All three PHP tools say plainly that it is not:
  - phpMyAdmin user groups "only limit what a user sees";
  - phpPgAdmin's `owned_only` "does not in any way prevent your users from seeing other database by other means";
  - Adminer's database-hide plugin is "not a security plugin".
- **Answer:** R67.

### 6.12 Warnings that train click-through

- **What goes wrong.**
  - DataGrip's "Execute and suppress" turns the WHERE-less warning off for good.
  - TablePlus's "password before every query" levels make the prompt routine.
  - Supabase's MCP regex has false positives on `;` inside literals (https://github.com/supabase/mcp/issues/457). Noise teaches people to ignore the warning.
- **What the better tools add.** Warn rarely and specifically (name the object and the rows), exempt reads, and never let production warnings be suppressed.
- **Answer:** R43, R70.

### 6.13 Hidden behaviour

- **What goes wrong.** In phpMyAdmin, a private bookmark named after a table runs automatically whenever that table is browsed (https://docs.phpmyadmin.net/en/latest/bookmarks.html). "Browse" then means something different for that person.
- **Answer:** R47.

### 6.14 Drift from GUI edits (the most estate-specific footgun)

- **What goes wrong.** Supabase warns that "making schema changes directly on your remote database via the SQL editor or Table Editor bypasses the migration history and causes db push to fail" (https://supabase.com/docs/guides/deployment/database-migrations).
- **Why it matters here.** Every estate application ships numbered migrations in `db/` and is installed and upgraded by the kernel's installer (`/var/www/CLAUDE.md:74`). A web tool that lets a person `ALTER` an installed application's tables creates exactly this drift. The next migration may then fail, or quietly undo the change.
- **What the better tools add.** Bytebase, Atlas and Flyway all detect drift and offer adopt or revert. Bytebase's SQL editor redirects writes into a reviewed plan.
- **Answer:** R85, R86, and section 7, O4.

### 6.15 Data leaving the server

- **What goes wrong.** Data and metadata leave the server through convenience features.
  - **Plan-sharing sites** store plans and query text: explain.dalibo.com says so, depesz is the same, and pgMustard stores plans only on request.
  - **AI integrations** send the schema to outside providers: Adminer's sql-gemini sends every CREATE statement to Google, and ChartDB calls OpenAI.
  - **dbdocs** projects are public by default.
  - **Exports** carry personal data. Bytebase masks exports, and PostgreSQL Anonymizer offers masking views and anonymised dumps (https://postgresql-anonymizer.readthedocs.io/en/stable/).
- **Answer:** R55, R88, R92. The estate's rule that models are reached only through the kernel applies here.

### 6.16 Work tied to a web request

- **What goes wrong.** phpMyAdmin's import is bounded by `ExecTimeLimit` (300 s). To cope, it has a "partial import" that resumes by skipping queries and "can break transactions" (https://github.com/phpmyadmin/phpmyadmin/blob/QA_5_2/templates/import.twig).
- **Answer:** R102.

### 6.17 Shells and injection surfaces

- **What goes wrong.**
  - pgAdmin disables its in-browser psql in server mode because it can run shell commands.
  - 9.18 fixed argument injection into pg_dump and pg_restore through a database name.
  - 9.16 fixed stored XSS through server error text and plan nodes.
  - PEV2 1.22 fixed HTML injection in a plan node.
  - pgHero hides raw PostgreSQL errors because "data can be extracted through the Postgres error message".
- **Answer:** R103, R104. CVE detail belongs to the security sibling.

### 6.18 Catalogs too big for the tree

- **What goes wrong.** pgAdmin's tree slowed badly on 10,000 tables, and an older version enumerated objects one query at a time (section 2.4).
- **Answer:** R3.

### Guardrail ladder (weakest to strongest), as the field uses it

1. A label or colour (pgAdmin server colour).
2. A confirmation dialog (phpMyAdmin, Adminer buttons).
3. A specific confirmation naming objects and rows; type-to-confirm (DataGrip, Supabase).
4. A preview of the exact SQL (pgAdmin, TablePlus, DataGrip, DBeaver).
5. A dry run in a rolled-back transaction (phpMyAdmin Simulate and Rollback; pgHero explain sandbox).
6. Lint with lock and rewrite awareness, and the safe alternative (Atlas, squawk, strong_migrations).
7. A policy that routes risky changes to an approver (Bytebase, Atlas `lint.review`).
8. A PostgreSQL role that cannot do the dangerous thing, plus server timeouts (pgHero's role, pgwatch `pg_monitor`, Supabase MCP read-only user).
9. Backups and point-in-time recovery, tested by restoring (GitLab, Replit).

The better tools stack several rungs. No tool in this survey has all of them. Rungs 6 and 7 are absent from every general-purpose tool.

---

## 7. Options and open questions for the owner

These are the choices the field exposes. Each gives the options, the trade-offs, and a recommendation where the evidence supports one. Where a sibling report has to answer first, it is named.

**O1 — Transactions across HTTP requests.**
- **(a) Stateless.**
  - One request is one transaction. Grid and structure changes are staged in the tool's own database and applied atomically.
  - A dry run is BEGIN … ROLLBACK inside one request.
  - Each SQL-editor submission is its own transaction: all its statements commit together or not at all, as in Postico.
- **(b) A connection-holding service.**
  - A small long-lived process keeps one connection per open transaction per tab, like Beekeeper.
  - It warns at 9 minutes and rolls back at 10, and the transaction pill is always visible.
- **(c) Both.** (a) by default, (b) as an explicit "Open transaction" for permitted roles on non-production databases.
- **Trade-offs.**
  - (a) fits PHP prefork, leaves no idle-in-transaction sessions, and holds no connections.
  - (a) cannot do the interactive BEGIN … inspect … COMMIT that pgAdmin, DBeaver, DataGrip and Beekeeper users expect.
  - (b) needs a new service and a connection budget, which the estate already found tight (prefork 150 against `max_connections` 100, `/var/www/CLAUDE.md:39`), and it brings the risks of section 6.6 back.
- **Recommendation: (a) for v1.** The internals sibling should judge whether (b) is affordable later. Supabase's 2026 queued edits show (a) is enough for data editing.

**O2 — Which PostgreSQL role the tool acts as.**
- **The options.**
  - (a) A login role per person, mapped from the kernel's identity.
  - (b) A small set of tool roles (reader, editor, DDL, admin), chosen per request from the person's application role via SET ROLE.
  - (c) One powerful connection with checks in the application.
- **What the field shows.** Hiding is not authorisation (6.11) and only roles are walls (6.10), which rules out (c). Supabase Studio's "run as postgres" is the anti-pattern.
- **Recommendation: (b) as the likely shape.** The internals and security siblings decide.

**O3 — Which databases the tool reaches.**
- **The options.**
  - (a) Only databases a super-admin registers on this cluster: the kernel's, the applications', MaluDB memory databases, scratch databases.
  - (b) Any server reachable by connection string.
- **Trade-offs.** Adminer's open login form was its long-running SSRF surface (section 2.2).
- **Recommendation: (a).** Registration carries the environment label of R69.

**O4 — Installed applications' databases and their migrations.**
- **The options.**
  - (a) Edit them directly and detect drift afterwards.
  - (b) The tool writes a numbered migration for the owning application's repository, as Bytebase, Atlas and Flyway do.
  - (c) Production application databases are read-only in the tool except through (b), while scratch and development databases are directly editable.
- **Trade-offs.** (a) is phpMyAdmin's model and creates the drift of 6.14. (b) and (c) fit the estate's numbered-migration discipline but need a route from the tool into a repository.
- **Recommendation: (c), with (b) as the write path.** This is the owner's call, because it changes what "maintain database objects graphically" means for installed applications.

**O5 — The lint and rule engine.**
- **The options.**
  - (a) squawk as a dependency: Apache-2.0, 78 rules, version-aware, a JSON reporter.
  - (b) Our own rules, named on Atlas's codes, over a PostgreSQL parser.
  - (c) A small rule set of our own whose names match squawk's, so squawk can be adopted later.
- **Recommendation: evaluate (a) first.** The internals sibling should check packaging without Node and the parser choice behind R42.

**O6 — The diagram renderer.**
- **The options.**
  - (a) Graphviz on the server rendering SVG: no JavaScript, works as an image on a phone.
  - (b) A vendored layout library (elkjs or viz-js).
  - (c) An interactive canvas island, as in Boards.
- **Recommendation: (a) for v1 focused diagrams.** (c) only if diagram-driven design (R77) is wanted.

**O7 — The plan viewer.**
- **The options.** (a) A server-rendered table only. (b) The table plus a PEV2 island (Vue 3 and PEV2 UMD bundles, Bootstrap 5.3 compatible).
- **Recommendation: (b), table first.** Pin PEV2 and track its releases.

**O8 — The SQL editor.**
- **The options.**
  - (a) A plain textarea.
  - (b) CodeMirror 6 with `@codemirror/lang-sql`: MIT, a PostgreSQL dialect, schema completion (https://github.com/codemirror/lang-sql), as a committed bundle.
  - (c) Monaco, which ChartDB and Adminer's plugin use but which is heavy.
- **Recommendation: (b).** Open point: the GitHub repository of lang-sql is archived and "moved to another host", so where it is maintained must be confirmed before vendoring.

**O9 — What the expert agent sees and runs.**
- **The options** follow Supabase's levels: schema only / plus logs / plus results and data.
- **Recommendation.**
  - Schema only by default.
  - The agent's reads run under the no-write role with caps (R93).
  - Its writes always become a proposal in Change review (R91).
  - The kernel's approval hook decides any agent action that pauses (`/var/www/CLAUDE.md:184`).

**O10 — Who approves a risky change by a person.**
- **The options.**
  - (a) The kernel's approvals, which only super-admins decide.
  - (b) A reviewer role inside this application.
  - (c) A policy by environment and risk, as Bytebase's CEL rules and Atlas's `lint.review` do.
- **Open:** the estate settled agent approvals in the kernel, but not people's changes inside an application.

**O11 — Break glass.**
- **The options.** (a) None. (b) A super-admin-only admin mode, limited in time, requiring a reason and logged in full, unlike Bytebase's Admin Mode, which is guarded only by a warning.
- **Recommendation: (b), if any.**

**O12 — Monitoring history.**
- **The options.** (a) Live views only in v1. (b) A collector that snapshots `pg_stat_statements` and table statistics.
- **Recommendation: (a) now, (b) LATER (R81).** Trends need a timer and storage.

**O13 — Phone scope.** The field has no phone-first database tool. Section 4's "Phone" column is a proposal for the owner to confirm, given the estate's 375 px rule.

**Open questions, with who answers.**
1. Can a PHP request run a dry run and an apply against the same snapshot, and what of statements that cannot run in a transaction? *Internals sibling.*
2. Which parser classifies statements on the server, given the lexer-differential lesson of pgAdmin CVE-2026-17351? *Security and internals siblings.*
3. How are kernel identities mapped to PostgreSQL roles, and is `pg-safeupdate` acceptable on the write role? *Internals and security siblings.*
4. Which MaluDB objects get screens, what does "forget" verify, and does the API console exist at all? *MaluDB sibling.*
5. How do the application's own roles (Viewer, Developer, DBA, admin?) map to the actions above, and which actions pause for agents? *Estate sibling, then the owner.*
6. Is O4 (c) acceptable to the owner, and if so, how does the tool hand a migration to an application's repository? *Owner.*
7. Does the owner want ERD-driven design (R77) in v1, or is a read-only focused diagram enough? *Owner.*
8. Where is `@codemirror/lang-sql` maintained now? *Whoever vendors the editor.*
