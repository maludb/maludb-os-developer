# maludb-os-developer

**Developer** is an application of the MaluDB Business OS: a web tool for database development and
administration for PostgreSQL 17 and the MaluDB memory system. It does for PostgreSQL what phpMyAdmin
does for MySQL: admins, software engineers and DBAs maintain database objects graphically through the
web. It is built on the `maludb-os-htmx-php-guidelines` (Apache, PHP 8.3, HTMX, Bootstrap 5.3,
PostgreSQL 17 + MaluDB, MCP servers, an expert agent), and the OS kernel (`maludb-os-core`) signs its
users in, following the `maludb-os-integration` contract.

## State

**Phase 0 complete (2026-10-11)** — the kit, the schema (db/001–011) and *the door* are built and proven (`tests/phase0/`,
`tests/door/`, `tests/integration/`). **Phase 1 written (2026-10-11)** — the [MCP tool surface](docs/developer-mcp-tool-surface.md), the
[action manifest](docs/developer-action-manifest.md), the schema completed (db/012–013), three build specs and eleven slice specs in
[`docs/build-specs/`](docs/build-specs/), the [consistency record](docs/phase1-consistency.md) — awaiting the owner's approval. Five research reports are in [`docs/research/`](docs/research/):

| Report | What it covers |
|---|---|
| [01-field.md](docs/research/01-field.md) | phpMyAdmin, Adminer, pgAdmin 4, Supabase Studio, the desktop grids, the modellers, the plan visualisers, the monitoring dashboards and the schema-review products, screen by screen. 107 requirements (R1–R107) and how these tools fail their users. |
| [02-postgres.md](docs/research/02-postgres.md) | Building a graphical PostgreSQL 17 object manager: rebuilding DDL from the catalogs, lock levels and table rewrites, schema diff, running arbitrary SQL from a web request, row editing, monitoring, a browser SQL editor and ER diagrams, and this server's inventory. 48 technical requirements (T1–T48). |
| [03-maludb.md](docs/research/03-maludb.md) | The MaluDB memory system as something to browse and administer: the extension, the API and the CLI, the object model, admin operations, the database-model feature, risks. 34 requirements (MR1–MR34) and proposed upstream items. |
| [04-estate.md](docs/research/04-estate.md) | The guidelines' rules that bind a database tool, the integration contract, the estate's databases and how their migrations run, the kernel's governance, free numbers. 30 requirements (E1–E30) and proposed kernel items. |
| [05-safety.md](docs/research/05-safety.md) | Credential models, the vulnerability history of web database tools, change control alongside numbered migrations, AI agents with database access, the threat model. 36 requirements (S1–S36) and the owner's decisions. |

**Design written (2026-10-11):** [`docs/developer-design.md`](docs/developer-design.md) — §0–§16, decisions D1–D16 and four open
questions, approved by the owner as recommended (§15). In short: one sandboxed service (*the door*) is the only path to any database and the only holder of
the tool's database credentials; every database has a class whose ceiling the door enforces; installed applications' schemas change
only through migration files drafted, rehearsed and linted here and applied by the existing route, while *workbenches* the tool
creates are designed live; rows are deny-by-default per person and masks are database privileges, not a display filter; row edits on production happen only in
a time-boxed write window; the MaluDB memory databases are shown in a curated, read-only section; the tool's AI agents explain,
propose and draft, and in version 1 read no rows and write no database.

Some estate security findings from the research were reported privately to the owner and are left out of
these public copies until they are fixed. Each one is marked where it was removed.
