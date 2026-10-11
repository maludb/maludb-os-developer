# Build spec: the memory section (slice 9)

What exists at the end: **the MaluDB memory databases, curated and read-only** (design §6.8, MR1–MR34). For every Viewer and agent
(`memory.read`) — **state, never content**: the memory estate (every database holding `maludb_core`, its placement, size, the extension's
version against the host's default, each tenant schema with its facade version, flags, and the owner's steps printed, never executed);
a tenant's health (counts, **the embedding backlog with its oldest age**, never-indexed documents, the extraction queue, failing facades,
configured models, "no worker has drained this queue in N days"); episode aggregates; graph statistics; models, skills and the facade
reference; the isolation audit. For DBAs (`memory.content`, people only) — **content, every view logged**: the graph explorer (subject
search, a subject's page, neighbours, a bounded walk, a path) and document, chat and note metadata. For super-admins (`memory.reveal`) —
an episode's payload or a document's text, with a reason, logged without the content. **Never**: a grid or editor statement on a facade or
a `malu$*` table, DDL on `maludb_core`, a claim function, `maludb_datamodel_refresh` or `graph_import`, secret material of any kind.

Schema (db/006, 009, 012, never modified, plus this slice's migration): `target_databases` (`class = 'memory'`, `has_maludb`,
`memory_schemas` — slice 1's discovery fills them), `query_runs` (source `memory`, content and reveal rows), `door_usage`
(`memory:<name>`), `mcp_target_databases` (db/012). Door: kind `memory` and the memory library (`the-door.md` §5), the named query
`extensions` (the host's default version), `isolation` (as meta).

## Divergences from the design
1. **One PHP module talks to MaluDB** — `app/developer/memory.php` (DocCloud's `graph.php` shape), always through `door_memory()`; an
   unreachable door or a refusing engine renders *"Memory unavailable — the tool could not read this memory database just now"* in the
   panel, never an error page (MR3). The MaluDB API is not called by this slice: Store B's per-user model store is Extended (D13), so the
   model configuration shown is Store A (the PostgreSQL store per namespace) and the screen says so.
2. **A co-located memory schema** (the cidery's, ProcessCore's — a `memory` schema inside an `application` database) is read through the same
   door kind with the schema named; this slice's migration `db/0NN_memory_section.sql` appends `memory_schemas` and `has_maludb` to
   `dx_door_policy()`'s `target` object (a `CREATE OR REPLACE` with the JSON's keys appended, nothing else changed) — reported as a schema
   change. The door checks the named schema is one of `target.memory_schemas`.
3. **The memory estate is assembled by PHP and by the records server from one call per memory target** (the door's `estate` on each visible
   `memory` target and each co-located schema, and `extensions` once on the tool's own database for the host's default versions) — never one
   query across databases. A target that fails is listed with *unavailable*.
4. **Episode payloads and document texts appear only on the reveal page** (`memory_reveal`'s answer, rendered once, `Cache-Control:
   no-store`); every other page shows ids, kinds, sizes and times.

## Who may do what
| Action / screen | Right | Rule |
|---|---|---|
| `memory-estate`, `memory-tenant`, `memory-episodes`, `memory-graph-stats`, `memory-config`, `memory-isolation` | `memory.read` | anyone, agents included (through the records tools); state queries only |
| `memory-graph`, `memory-documents` | `memory.content` | **people only** (`require_human()`); each page view rowed in `query_runs` (source `memory`, the query's name and the subject or document id, never the content) and logged `memory.view` |
| `memory_reveal` | `memory.reveal` | a super-admin; a reason; logged `memory.reveal` with the target, schema, kind and id — **never the content** |
| any write to a memory database | — | **none exists**: no action, no door kind, no named query writes; the grid (slice 5) refuses a facade or a `malu$*` relation with the reason and a link here (MR6) |

## Screens
| Screen id | Canonical URL | Purpose |
|---|---|---|
| `memory-estate` | `/memory` | the memory databases as **cards** (name, placement — dedicated · co-located in an application · the bootstrap · development · scratch —, size, extension version against the host's default with a "behind" chip, tenants with their facade versions); flags as a list (facades behind the extension: "the upgrade's third step has not been run on certstudy_mem"; a tenant inside the `maludb` bootstrap; scratch memory databases); **the owner's steps** printed in a `<pre>` per flag (`ALTER EXTENSION maludb_core UPDATE`, the facade upgrade, `enable_memory_schema`, `grant_memory_access`, token minting, secret re-creation after a restore) with "The owner runs these as postgres — the tool never does" |
| `memory-tenant` | `/memory/{datname}/{schema}` | one tenant's health: counts per family, **the embedding backlog** (count, oldest age — amber over a day, red over a week —, by kind), documents never or long ago indexed, the extraction queue, `malu$event` and audit growth, table sizes, facades failing their probe, embedder and extractor configured or not, the stale-queue sentence; tabs to the pages below |
| `memory-episodes` | `/memory/{datname}/{schema}/episodes?since=&group=` | episode counts grouped by kind, application, day, sensitivity or scope (a table and a bar per row) — never a payload |
| `memory-graph-stats` | `/memory/{datname}/{schema}/graph-stats` | stores, relations, node types with counts, god-node count, communities, import namespaces — never a subject's name |
| `memory-config` | `/memory/{datname}/{schema}/config` | models per namespace (provider, alias, prompt template, **the secret's name**, never a value), skills (name, version, enabled, review state), the facade reference rendered from `object_purpose` (writable ones marked "writable view — read here, never edited") |
| `memory-isolation` | `/memory/isolation` | database `CONNECT` grants of every memory database, members of the `maludb_*` groups, `BYPASSRLS` logins, FORCE RLS state per tenant table — each line a fact, with the hardening item it belongs to when it is one |
| `memory-graph` | `/memory/{datname}/{schema}/graph?q=&subject=&walk=&to=` | the graph explorer (a DBA's): subject search by name, alias and type (≤ 100); a subject's page — verbs, attributes, statements with provenance and valid time, relationships —, neighbours (≤ 200), a walk (depth ≤ 3, ≤ 200 nodes) and a path to another subject (depth ≤ 3) **as tables**; each "namespace" field labelled with which of MaluDB's three senses it means; every view logged |
| `memory-documents` | `/memory/{datname}/{schema}/documents?q=&kind=` | document, chat and note metadata (source type, namespace, size, indexed when) — **Reveal** on a row for a super-admin opens the reveal form (`memory_reveal`: a reason, ✔) and renders the text once |

## Files (exactly these)
- `html/memory/{index,tenant,episodes,graph-stats,config,isolation,graph,documents,reveal}.php`
- `app/developer/memory.php` (the one module: `memory_estate()`, `memory_tenant()`, `memory_query()`), `app/features/memory/{present,reveal}.php`
- `app/views/memory/{estate,tenant,episodes,graph-stats,config,isolation,graph,documents,reveal}.php` + `app/views/memory/partials/{estate-card,
  flag,owner-steps,backlog,unavailable,subject,walk-table}.php`
- `services/door/memory_queries.py` — the library of `the-door.md` §5 (the Phase 0 names `tenant_counts`, `embedding_backlog`,
  `extension_version` folded into `tenant_health` and `estate`), `tests/door/test_memory_secrets.py` extended to every new query
- `db/0NN_memory_section.sql` — `dx_door_policy()` with `target.memory_schemas` and `target.has_maludb` appended; nothing else
- `tests/phase3/slice9/{run.sh,lib.php,state.php,content.php,reveal.php,refusals.php,json.php,browser.mjs}`

## Query functions (signatures fixed)
- `memory_estate(): array{databases, flags, owner_steps, host_default}` — per visible memory target and co-located schema
  `door_memory($datname, 'estate', ['schema' => …])`, plus `door_named(own, 'extensions')`; failures per target as `unavailable`
- `memory_tenant(string $datname, string $schema): array` — `tenant_health`
- `memory_query(string $datname, string $schema, string $name, array $params = []): array` — any library query by name; content names
  (`graph_search`, `subject`, `neighbours`, `walk`, `path`, `documents`) require `memory.content` and are refused for an agent
- `memory_reveal(string $datname, string $schema, string $kind, string $id, string $reason): array` — `reveal_episode` / `reveal_document`;
  the answer is passed straight to the view and not kept
- `memory_owner_steps(array $flags): array` — fixed text per flag (the steps are the MaluDB documentation's, with the database and schema
  names quoted for psql)

## MCP tools this slice makes real
`memory_estate`, `memory_health`, `memory_episode_stats`, `memory_graph_stats`, `memory_model_config`, `memory_skills`, `memory_facades` —
state only, through the door as the agent on behalf of the person; no records tool reads content, reveals or writes.

## Manifest rows claimed
Screens (8): `memory-estate`, `memory-tenant`, `memory-episodes`, `memory-graph-stats`, `memory-config`, `memory-isolation`, `memory-graph`, `memory-documents`
Actions (1): `memory_reveal`

## Activity log events
`memory.view` `{target, schema, page, subject_id?}` (a content page; screen views of state pages are the kit's ordinary screen views);
`memory.reveal` `{target, schema, kind, id, reason}` — never the content.

## Status vocabulary
A memory target's placement: `dedicated`, `co-located`, `bootstrap`, `development`, `scratch`. A tenant's state: *healthy* · *behind*
(a backlog over a day or a facade behind) · *stale* (a queue no worker drained in 7 days) · *unavailable*.

## Out of scope for this slice
Curated writes — forget, skill review, an embedding or reindex batch with a cost estimate (MR21, MR22 — Extended, D13); the "see as this
principal" probe and the API's Store B (Extended); installing or upgrading MaluDB (the owner's, printed only — MR23); the graph drawn as a
picture (the tables here; Extended).

## Proof (`tests/phase3/slice9/run.sh`: scratch `dx_dev9`; php -S on 9401, fake kernel 9402, fakes 9403; user-level Apache on 9407; the scratch door; a scratch memory database `dx_t9_memory` with `maludb_core` installed by the proof and a tenant schema seeded through the extension's own functions (episodes, a document, subjects and edges, a model config with a `secret_ref`), and a scratch application database `dx_t9_app` with a co-located `memory` schema; a scratch `BYPASSRLS` login standing in for `maludb_memory_auditor` as in Phase 0; Playwright)
- The estate lists both (dedicated and co-located) with versions; a facade-behind fixture raises its flag and prints the owner's step; a
  stopped door renders *memory unavailable* per target.
- Tenant health shows the seeded backlog and its oldest age; episode aggregates by each grouping; graph statistics; the model config shows
  the secret's **name** and no value (the page grepped for the seeded secret's value: absent).
- A Viewer opens every state page and is refused `memory-graph` and `memory-documents`; a DBA opens them, each view rowed in `query_runs`
  (source `memory`) and logged; an agent's records tools answer state and have no content tool; an agent token on the content pages is
  refused (`require_human()`).
- A super-admin reveals an episode with a reason: the payload shows once; `activity_log` and `query_runs` hold the reason and the id, not the
  payload (grepped); a DBA's reveal is refused.
- `tests/door/test_memory_secrets.py` passes over the whole library; a planted query naming `value_encrypted` makes it fail (then removed).
- The editor (slice 3) refuses SQL on `dx_t9_memory` ("use the memory section"); the grid (slice 5) refuses a facade with a link here.
- 375 and 1280 screenshots of `memory-estate`, `memory-tenant`, `memory-graph`; no horizontal scroll.

## Requirements claimed
MUSTs (21): R97, R103, MR1, MR2, MR3, MR4, MR5, MR6, MR7, MR8, MR9, MR10, MR11, MR12, MR13, MR14, MR15, MR23, MR28, MR30, S25

## Decisions taken here
1. **MR4 is met by named rights**, not super-admin only: state is `memory.read` (Viewers and agents), content `memory.content` (DBAs,
   people), payloads `memory.reveal` (super-admins) — the design's §6.8 split.
2. **MR15's Store B** (the API's per-user model store) is not read in version 1; the config page says "Per-user models (the API's store) are
   not shown in this version".
3. **Walks and paths are tables**, not a drawn graph — they work at 375 and without JavaScript (R97's "as a graph" is Extended).

## Open questions
None.
