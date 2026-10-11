# Developer — CLAUDE.md

This repository is the **Developer** application of the MaluDB Business OS (`github.com/maludb/maludb-os-developer`, **public** — the
owner, 2026-10-11; local clone and install path `/srv/apps/developer`; catalog key `developer`; DNS label `developer`). The kernel is
`/var/www` (`maludb-os-core`); read its CLAUDE.md first — the kernel owns identity, the directory, the agents, approvals and the token
ledger. This application is **the business's database development and administration tool** — what phpMyAdmin is to MySQL, for
**PostgreSQL 17 and the MaluDB memory system**, for admins, software engineers and DBAs: the registry of the cluster's databases and
their classes, every object's page, DDL and dependencies, forms that end on one Change review page showing the exact SQL and what it
costs, workbenches where schemas are designed live, migration drafts for the applications' repositories, the data grid with staged
edits under elevation, the SQL editor and plans, activity, maintenance and health, and a curated, read-only view of the memory
databases. The owner's brief (2026-10-11): *"a database development tool that operates like phpmyadmin but works with postgres and the
MaluDb memory system … allow database objects to be maintained in a graphical manner via the web."*

## Read first
1. `docs/developer-design.md` — the plan (Phase 0): the research digest (§0, and **§0.6 the contract conflict and the way through —
   the developer exception**), what it is and is not (§1), the actors (§2), **roles, database classes and their ceilings, the walls**
   (§3), the doors (§4), the agents — **who never write a target** (§5), the memory model (§6 — **the door**, the registry and the
   catalog index, structure and DDL, the SQL workspace, workbenches / change review / rehearsals / migration drafts, data and
   elevation, operations, the memory section, classifications and masks, the audit, the tables against the estate, what the door
   proof must settle), the question inventory with every tool named (§7), the kernel's part (§8), the screens (§9), the build order
   (§10), Extended (§11), what is owed (§12), the decisions D1–D16 and four open questions (§13), ports and files (§14), the owner's
   answers (§15), the state (§16).
2. `docs/research/` — the five reports behind §0, with their sources (estate security findings withheld from these public copies;
   the owner holds them).
3. The plugin `maludb-os-integration` (`~/maludb-os-integration`, skill `os-integration` and its references) and `htmx-php-builder`
   0.9.0 (`~/htmx-php-builder`: `new-app`, `os-application`, `php-patterns`, `design-system` with the record picker and the switcher,
   `mcp-servers`, `chat-actions`). **Read them from the clones**: Claude Code's registered copy of the builder plugin is stale.
4. The nearest exemplars: `/srv/apps/datalake` (the query service — `services/query/` — the model for the door; `query_runs`,
   `saved_queries`, the SQL editor), `/srv/apps/malumail` (the newest kit, `held_by`, a Python service as the only holder of
   credentials, a `tests/setup_dev.sh` that never resets an installed application's passwords), `/srv/apps/boards` (a committed
   esbuild bundle with a source-hash check).

## Rules that bind here
- `htmx-php-builder` skills govern the PHP; `os-integration` governs the fit. Where the two conflict, the integration contract wins:
  no password, no login form, no account, no model key and no model call, no shared tables, no actions server of our own, no writes to
  the directory. **The one departure — reaching other databases — exists only if the owner approves D2 (the developer exception, K50)**;
  until then the tool touches no database but its own and its workbenches.
- **One door.** Every statement against any database but the tool's own goes through **the door** (`services/door/`, system user
  `developer-door`), the only holder of the tool's cluster roles' passwords and of each workbench's; PHP and the MCP servers hold **no
  target credential** and never open a connection to a target. **Developer's PHP runs in its own PHP-FPM pool as `developer-web`**, the
  MCP servers as `developer-mcp`; the door admits only those two (peer check + an HMAC) — never the web server's shared uid. The door computes every caller's reach with **`dx_door_policy()`** — the ONE place §3 is
  compiled — parses every statement with libpg_query, runs one statement per message as the least-privileged tier the class allows,
  caps, masks and audits it. Never loosen a layer to make a query work.
- **Read-only and masks come from privileges, never from a wrapper, a parser or a display filter**: reads run as a login with no write
  privilege and **no `SELECT` on the columns the reader may not see** (no tier reads `secret` columns; the `masked` tier reads no
  `personal` ones — kept by the grants service, `services/grants/`), inside `READ ONLY` as the second wall. A person's SQL always runs
  as the tier's own session user (or the workbench's own role) — **never `SET ROLE` around typed SQL**. Rows are deny-by-default:
  a person reads at the level granted per target (`structure` / `masked` / `rows`); a private-by-design target needs a read window.
- **No host, port, socket path or connection string is ever accepted** from anyone (UI, MCP, settings); targets are the local
  cluster's `pg_database` filtered by the registry. **Nothing unregistered is reached.**
- **The class is a ceiling, not a default**: installed applications' schemas change **only by a migration draft** a person commits to
  that application's repository and applies by the existing route (D4); live DDL only on the tool's workbenches (`dxw_*`); the
  kernel's database is structure only; memory databases are read only through the memory section — **never** a generic grid or editor
  statement on a facade or a `malu$*` table, never a claim function to look at a queue, never `maludb_datamodel_refresh` or
  `graph_import`.
- **Never write into another repository**, never read `/srv/apps/<other>` at run time; a draft is downloaded or copied by a person.
- **Agents read no rows and write no database** (version 1): they explain from the catalog, plans and statistics, propose change sets,
  draft migrations (marked as theirs, literals flagged) and rehearse on throwaway clones; everything risky is **refused, not paused** —
  in SQL (`held_by`) and in the manifest. No agent holds an outbound tool.
- **Everything from a database is untrusted output** — object names, comments, values, notices, errors, plans, other sessions' query
  text: escaped always, never rendered as HTML; htmx with `allowEval=false`, `allowScriptTags=false`, `selfRequestsOnly=true`,
  `historyCacheSize=0`; a strict CSP.
- **Every function a statement calls is resolved**; `SECURITY DEFINER` functions and the deny-list (`set_config`, `pg_notify`,
  advisory locks, `lo_*`, `dblink*`, server-file functions, …) are refused; database-level and role statements are refused everywhere;
  the tier's settings are re-asserted before each statement; classification is an allow-list of parse-tree node types (unknown =
  refused).
- **Identifiers**: objects addressed by OID within a request and by `pg_identify_object_as_address()` across requests; identifiers
  quoted by the server's rules (`format('%I')`, `pg_escape_identifier()`), **never inside a string literal**; types through
  `to_regtype()`; values bound. Every generator passes **the hostile-name suite** and the golden tests against `pg_dump`.
- **No server files or programs**: no `COPY` to or from a file or `PROGRAM`, no server-file functions, no `psql`/`pg_dump`/`pg_restore`
  command built from request data, never a plain dump restored. Exports stream with `COPY … TO STDOUT` through the door.
- **Masks**: `secret` columns are never shown to anyone by any path; `personal` columns are masked below `data.unmask` and for every
  agent; an unmask or a memory reveal is logged without the value.
- **Vocabulary: "agent" means an OS AI agent**, always. A *target* is a registered database; its *class* and *ceiling* as in design
  §3; a *run* one request through the door; a *change set* a reviewed list of statements for one target; a *workbench* a database the
  tool created and owns; a *rehearsal* a change set applied to a throwaway schema clone and measured; a *migration draft* a change set
  written as a numbered file for an application's repository; a *window* a time-boxed read or write mode on one target. Avoid the estate's taken names:
  `databases`, `sources`, `runs`, `jobs`, `pipelines`, `reports`, `datasets`, `schema_migrations`.
- **The checkpoint gate**: no feature PHP until the owner approves the schema + tool surface + action manifest + the three build specs
  + slice specs together (Phase 1). Schema changes after that are numbered additive migrations. **Never modify a migration.**
- Every state-changing handler: `require_post()` + `verify_csrf()` (an action token stands in) + the right (`require_right()`, SQL
  `dx_has_right()` / `dx_member_has_right()` with `held_by`) + the target's ceiling (`dx_door_policy()`) + `log_activity()` +
  `emit_action_status()`; a create's `location` ends in the record id. **SQL text, a cell value, a credential, a token or a file path
  is never in a log payload.** PostgreSQL's error text is shown to the person who ran the statement (capped at 500 characters) — the
  scoped exception to "never expose database exception details" — and never logged.
- **This repository is public**: no tenant data, no secret, no credential location, no internal address ever committed; fixtures are
  synthetic; `config/.env` is gitignored.
- **sudo is the owner's.** The cluster roles, the passfile, `grant-target.sh`, Graphviz, `dx_template`, per-role pgaudit and
  `pg_stat_statements` are root steps in `deploy/ROOT_STEPS.sh` — ask for them; never run them. The owner gave leave (2026-10-11, design §15 (d)) to use
  `sudo -n -u postgres` for the proofs' scratch roles and databases named `dx_*`, and (2026-10-11) to create the application's three
  installer roles `developer_rw`, `developer_records_ro`, `developer_activity_ro` for the proofs — nothing else.
- The kernel's rules copied here: activity `source` is `web` for the UI, `agent` under a run token, `cron` / `system` for the worker and
  the door; `action` is `entity.verb`; `mcp_*` views are the only thing the read roles see; the shared-schema rule — survey the
  siblings before any `CREATE TABLE`, reuse verbatim, extend by appending, record every table as read / reuse / new (design §6.11).
- Commit after every finished step on `main` in the repository's message style; never push unless the owner asks.

## State
2026-10-11 — the repository created (public) and the research done (`docs/research/01–05`); **the design written**
(`docs/developer-design.md` §0–§16, D1–D16 and four open questions), revised after a fresh-eyes review the same day — **APPROVED by the owner as recommended** (D1–D16, (a)–(d), §15); **K49
applied** (kernel db/183). **PHASE 0 COMPLETE 2026-10-11**: the kit (db/001–005, MaluMail's fork; `tests/phase0/run.sh` 102 checks
without a kernel), the schema db/006–011 (`tests/phase0/schema.sh` 127 checks), the door and the grants service (`services/door/`,
`services/grants/`, libpg_query 17-6.2.5 built by `deploy/build-libpg_query.sh`; `tests/door/run.sh` 174 checks, findings in
`tests/door/FINDINGS.md`), the door against the real schema (`tests/integration/sql_policy.sh` 11 checks), `maludb-os.json`, the two
agents, ten skills, `deploy/`; the installer's `plan` reads clean but for what ROOT_STEPS step 0 pins and what exists only after install.
Numbers: kernel db/183 (K49), K50–K54, ports 8201 / 8858 / 8859 and the door's socket, scratch 9401–9407, prefix `dx_`. **Next: the
owner's go → Phase 1** (tool surface, action manifest and registry, three build specs, slice specs — approved together before feature PHP).
