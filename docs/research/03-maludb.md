> Research report for `docs/developer-design.md` §0, written 2026-10-11 by a research agent of the planning session.

# 03 — The MaluDB memory system, as a thing the developer tool browses and administers

Scope: what a MaluDB section of `maludb-os-developer` would show and do. PostgreSQL internals, the product
survey, the estate's conventions and AI-agent safety belong to the sibling reports and are touched only where
MaluDB forces the point. Everything here was read on this host on 2026-10-11 without writing anything: the
extension at `/home/maludb/maludb-core` (main at 0.106.0), the API at `/home/maludb/maludb-python-api-server`
(0.4.1), the `maludb` CLI binary, the kernel at `/var/www`, Knowledge, DocCloud, the cidery and ProcessCore under
`/srv/apps`. All live queries ran as the kernel's own roles, read-only, and returned only catalog facts and
aggregate counts. No episode, document or chat content was read.

---

## 0. Key findings

1. **Three layers, one source of truth.** The extension `maludb_core` (C + PL/pgSQL, version **0.106.0** in all
   nine databases that hold it) is the engine and the store. It never calls a model. The **MaluDB API** (FastAPI,
   0.4.1, port 8000, 180 route handlers in 27 router files) is the only "model worker". It chunks text, calls the
   extraction and embedding models, and writes back through the extension's functions. The **`maludb` CLI**
   (a compiled binary) is an API client that can also serve MCP over stdio. It holds no database connection of its own.
2. **A "memory database" is an ordinary PostgreSQL database with `CREATE EXTENSION maludb_core`.** It holds one or more
   tenant schemas. Each tenant is a schema and a login role of the same name, enabled with
   `maludb_core.enable_memory_schema(schema)`, which writes 78 views and 98 functions (the "facades") into the schema.
   The role gets access through `maludb_core.grant_memory_access(role, 'read'|'write'|'admin')`. Rows live in the
   shared `maludb_core.malu$*` tables (161 tables) and are told apart by an `owner_schema` column under row-level security.
3. **The estate uses three placement patterns, and the integration contract allows only one.** (A) dedicated memory
   databases: the kernel's `certstudy_memory`, `subello_knowledge_memory` and `subello_doccloud_memory`. (B) a co-located
   `memory` schema inside the application's own database: the cidery and ProcessCore. (C) the contract's rule, "never
   create a second memory database" (`~/maludb-os-integration/skills/os-integration/SKILL.md:93`). Knowledge and DocCloud
   broke rule C on purpose, by recorded decisions. Whether the developer tool may hold a memory database of its own is
   an open question.
4. **The "database model" is the extension's DM-1 feature (0.104.0), not `maludb_modeld`.** `maludb_modeld` is the
   unrelated, unbuilt LLM gateway. DM-1, `maludb_datamodel_refresh(namespace, schemas[])`, reads `pg_catalog` into the
   tenant's knowledge graph: tables, views and matviews with their columns and primary key, routines, triggers, and the
   edges `fk_references`, `depends_on`, `triggers_on` and `belongs_to`, plus `reads`/`writes` edges found by a rough
   text scan of routine source. It sees only its own database, and in that database only the tenant schema,
   `maludb_core` and `public`. The CLI's `db impact`, `db join-path` and `db related` walk that graph through the API.
   As shipped it cannot model another application's database, and it pollutes the tenant's agent memory (see §4).
5. **Most facades are writable, and a generic grid would corrupt memory.** 67 of the 78 facade views are
   auto-updatable, including `maludb_embedding_dirty`, `maludb_semantic_edge`, `maludb_object_embedding`,
   `maludb_episode` and `maludb_llm_request`. A phpMyAdmin-style editor would offer INSERT, UPDATE and DELETE on all of
   them and would bypass supersession, provenance and the API's model pipeline.
6. **A tenant-isolation question, withheld.** The survey raised a question about how strongly memory databases and
   tenants on this host are separated from one another. *Withheld from the public copy (2026-10-11): an estate security finding, reported privately to the owner; it will be published once fixed.* For the tool: tenant roles are not a wall the
   tool's own permission model may rely on (§7.2).
7. **The kernel's tenant memory holds the whole estate's activity.** It has 61,918 `activity` episodes from 12
   applications plus the kernel, all `sensitivity = internal`, all `scope = default`. The kernel's bridge sends every
   activity row's `before` and `after` images (`/var/www/mcp/activity_ingest.py:28-54`), so payloads can hold personal
   and financial data. Principal scoping, new in 0.106.0, is not used by anyone yet.
8. **No maintenance runs on this host.** Only `maludb-api.service` is active. The embedding, memory-reindex and
   skill-reindex timers ship in the API's `deploy/` folder but are not installed. In `certstudy_memory`, 57,801 entity
   cards wait to be embedded (oldest 2026-09-20), and all 474 documents have never been reindexed. Each episode also
   mints a subject (61,941 `activity` subjects) and a realtime event row (`malu$event`, 61,951 rows, no subscribers).
9. **Model configuration lives in two places.** Per-namespace configuration is in PostgreSQL
   (`maludb_memory_model_config`, provider and alias, sealed secret). Per-API-user provider keys and task→model choices
   are in the API's SQLite auth store. A console that reads only SQL cannot show which model would be used.

---

## 1. Architecture

### 1.1 The layers

| Layer | What it is | Where | On this host |
|---|---|---|---|
| **Extension** `maludb_core` | PostgreSQL 17 extension in C and PL/pgSQL. Schemas `maludb_core` (storage `malu$*`, 559 functions, 114 of them `SECURITY DEFINER`) and `mc2db`. Requires `vector`, `btree_gist`, `pg_trgm`, `pgcrypto`. "Core never calls a model" (`sql/extension/maludb_core--0.106.0.sql:50250-50262`). | `/home/maludb/maludb-core`. Control file `maludb_core.control` (default_version 0.106.0). Install script `sql/extension/maludb_core--0.106.0.sql` (57,463 lines), upgrade chain `maludb_core--X--Y.sql`. | 0.106.0 installed in 9 databases. Host files declare 0.106.0 (`/usr/share/postgresql/17/extension/maludb_core.control`). |
| **MaluDB API** | FastAPI with psycopg 3, raw SQL per route. Bearer token → SQLite auth store → that tenant's PostgreSQL login → one connection per request (`app/auth.py:63-114`). Calls the models for extraction, embedding and answers. Also serves `/mcp` (9 tools) and a PostgREST-compatible `/rest/v1/{table}` over a tenant's own base tables (`docs/rest-user-tables.md:1-15`). | `/home/maludb/maludb-python-api-server` (`pyproject.toml:3` version 0.4.1). | `maludb-api.service` active since 2026-10-10. Not bound to loopback only; whether the port is reachable from outside depends on the firewall (security sibling to confirm). |
| **`maludb` CLI** | A compiled binary (`~/.local/bin/maludb`). Subcommands: `set-api`, `token mint`, `profile`, `subjects`, `hints`, `get`, `graph`, `db`, `note`, `doc`, `skill`, `llm`, `chat`, `smoke`, `sync`, `mcp`. Every data command is an API call (the binary's strings show `/v1/datamodel/*`, `/v1/graph/*`, `/v1/memory/*`, `/v1/skills*`, `/v1/tokens`). `profile`, `subjects` and `hints` are local CLI settings. `sync push/pull` stores them as a note titled `malu-cli-settings` in the tenant. | Config `~/.config/malu/config.toml`: profile `myapp` → the local API. The token is kept in the keyring. | No token is configured in this session (`graph_stats` answered "No token found for key myapp"), so its tools were not run live. |
| Optional services, unused here | `maludb_mc2dbd` (MCP listener :5329, Prometheus `/metrics`), `maludb_modeld` (LLM gateway, a contract only: `docs/maludb-modeld-contract.md:1-12`), `maludb-restd`, `maludb-realtimed`, `maludb-pageindexd`, `mcp-broker`. | `README.md:19` | None running. The tables they use exist and are empty. |

### 1.2 Memory database, bootstrap database, tenant schema and role

- `scripts/maludb-bootstrap` creates a database named `maludb` and installs the extension there
  (`README.md:77-95`). The kernel's rule: **"The `maludb` database is only the extension's bootstrap — never a tenant"**
  (`/var/www/CLAUDE.md:261`). On this host the `maludb` database nevertheless holds a tenant schema `app` (login role
  `app`, member of `maludb_user`, 36 MB). That matches the README's quickstart example (`README.md:140-220`) and the
  CLI profile named `myapp`. Flag it as a stray tenant.
- **Tenant recipe** (`README.md:149-233`; the kernel's own at `/var/www/docs/install.md:116-133`; Knowledge at
  `/srv/apps/knowledge/deploy/ROOT_STEPS.sh:45-80`; DocCloud at `/srv/apps/doccloud/deploy/ROOT_STEPS.sh:68-103`):
  `createdb <tenant>_<app>_memory`, then `CREATE EXTENSION maludb_core CASCADE`, then a login role and a schema of one
  name, then `SELECT maludb_core.enable_memory_schema('<schema>')`, then
  `SELECT maludb_core.grant_memory_access('<role>','write')`. Knowledge's engine proof found that
  `GRANT maludb_secret_consumer TO <role>` is also needed; without it every model-calling route answers
  `409 model_not_configured` (`knowledge/deploy/ROOT_STEPS.sh:71-72`). The README leaves this out.
- `enable_memory_schema` writes the facades into the schema and records each one in `malu$enabled_schema_object`
  with an `object_purpose` sentence, and the version in `malu$enabled_schema`. **It must be re-run in every tenant
  after every extension upgrade.** A migration cannot replace objects the tenant owns (`README.md:235-266`;
  `docs/principal-scoping.md:106-115`: 165 → 194 objects at 0.106.0).
- `grant_memory_access(role, level)` (`maludb_core--0.106.0.sql:33876-33924`) is a `SECURITY DEFINER` wrapper that
  grants `maludb_read` (read), `maludb_user` (write) or `maludb_admin` (admin). These are **cluster-wide** PostgreSQL
  roles. Their grants on each database's `maludb_core` objects and tenant schemas are per database.
- The pattern-B variant (the cidery and ProcessCore) enables a schema called `memory` inside the application's own
  database as the application's role (`/srv/apps/cidery/deploy/os-provision.sh:28`). Its activity MCP then reads
  `memory.maludb_*` in SQL (`/srv/apps/cidery/services/activity_mcp/server.py:163`).

### 1.3 Roles

| Role (cluster-wide) | Meaning (`docs/admin-guide.md:7-31`) | Observed |
|---|---|---|
| `maludb_read` → `maludb_memory_reader` | Read the facade views and the read-only search wrappers | `cidery_activity_ro`, `processcore_activity_ro` |
| `maludb_user` → `maludb_memory_executor` + `maludb_read` | Normal tenant read and write | `certstudy_mem`, `knowledge_mem`, `doccloud_mem`, `cidery_app`, `processcore_app`, `ma_scratch`, `app` |
| `maludb_admin` → `maludb_memory_admin` | Trusted admin delegation | No login member |
| `maludb_memory_admin`, `maludb_memory_auditor` | Full CRUD, or read-only, across governed tables. **Both have BYPASSRLS** (not inherited: it takes effect after `SET ROLE`). | No login member |
| `maludb_llm_*`, `maludb_mc2dbd`, `maludb_modeld` | Model and listener tier. `maludb_mc2dbd` and `maludb_modeld` are LOGIN roles with BYPASSRLS. | Present, unused |
| `maludb` | NOLOGIN **superuser**, no members | The CLI-side peer login fails by design (`README.md:125-131`) |
| `maludb_memory_dba` | Listed in `docs/admin-guide.md:17` | **Does not exist on this host** |

### 1.4 Tenant isolation and principal scoping

- The tenant wall is a PERMISSIVE policy `tenant_owner` on 132 RLS tables
  (`docs/security-review.md:44-55`; confirmed in `pg_policies`). A second PERMISSIVE policy, `grant_visibility`, ORs
  in rows shared through `malu$object_grant`.
- **Principal scoping (0.106.0)** adds RESTRICTIVE `principal_scope` policies on documents, episodes, chat and pools,
  and the same predicate inside `maludb_memory`, `maludb_source_package` and the `SECURITY DEFINER` search workers. A
  principal is a row in `maludb_principal` (`principal_ref` such as `agent:44`, `home_scope`, `max_sensitivity`). It is
  granted scopes in `maludb_principal_scope` (read or write). It is bound per session by the settings
  `maludb_core.principal_ref`, `principal_scopes` (narrow only) and `principal_readonly`. **No principal set means
  unrestricted.** Sensitivity is ranked `public < internal < restricted < prohibited`
  (`docs/principal-scoping.md:9-54`). The API maps the headers `X-MaluDB-Principal`, `X-MaluDB-Scopes` and
  `X-MaluDB-Readonly` onto these settings (`app/principal.py:1-25`).
- The extension says this "is not a defence against the tenant's own login", and vocabulary (subjects, verbs,
  statements) is shared across scopes (`docs/principal-scoping.md:96-104`). **The kernel does not use principals.** Its
  Memory MCP server holds the one tenant token and picks namespaces itself
  (`/var/www/mcp/memory_server.py:1-13`, `maludb_client.py:1-8`). `maludb_principal` is empty in `certstudy_memory`.
- **Finding 6.** *Withheld from the public copy (2026-10-11): an estate security finding, reported privately to the owner; it will be published once fixed.*

### 1.5 Tokens: two unrelated systems

1. **API tokens** `malu_…`, the ones the estate uses. `POST /v1/tokens` takes `{pg_dbname, pg_user, pg_password}`, tests
   the login, and stores `sha256(token)` with the sealed password in the API's SQLite store (`app/routers/tokens.py:59-123`;
   sealed at rest since 0.3.1). `GET /v1/tokens` and `DELETE /v1/tokens/{id}` also need the PostgreSQL credentials, and
   GET takes them in a JSON body (`tokens.py:131-175`). A token carries a free-text `role` (default `executor`) that **no
   route enforces**. It reaches exactly what the PostgreSQL role reaches. It has an optional expiry and no
   last-used time.
2. **In-extension tokens** `malu$auth_token`, with JWT signing keys and a pepper. These are V3 AUTH for `maludb-restd`
   and `mc2dbd`. Their functions are `auth_token_create`, `auth_token_verify` and `auth_token_revoke`. There are 0 rows
   here.

A console must say which kind it means. The estate's tokens live in `config/.env` files (`MALUDB_API_TOKEN`,
`MALUDB_KB_API_TOKEN`, `MALUDB_DC_API_TOKEN`), and the role passwords behind them live in root-only files
(`knowledge/deploy/ROOT_STEPS.sh:51-61`).

### 1.6 "Namespace" means three different things

| Sense | Example | Where it matters |
|---|---|---|
| Memory namespace or scope (the vector compartment) | `agent:44`, `dept:3`, `org`, `kb:7`, `dc` | `/v1/memory/*`, `maludb_memory_search`, principal scopes |
| Graph-import namespace: a **canonical-name prefix** `<ns>/` | `datamodel/…`, a graphify repo name | `maludb_graph_import`, `maludb_datamodel_refresh`, `GET /v1/graph/query?namespace=`. DocCloud found that `namespace=dc` matched nothing there (`/srv/apps/doccloud/tests/phase0/engine/FINDINGS.md`). |
| CLI profile namespace | `default` | Local CLI settings |

The UI must label which sense a field means. Upstream already owes M3, which covers graph routes that are tenant-wide
and take name-prefix namespaces.

---

## 2. The object model a console would show

"Facade" means the schema-local object that `enable_memory_schema` creates. **Read** says whether a direct SQL SELECT
through the facade is safe. **Write** says the only safe path. In the live catalog, 67 of the 78 facade views are
auto-updatable; that is a fact about PostgreSQL, not a licence to write. Row counts are `certstudy_memory`, 2026-10-11.

| Family | Facade objects | Base tables (`maludb_core`) | Rows | Read | Write path | Notes |
|---|---|---|---|---|---|---|
| **Episodes** (what happened) | `maludb_episode`, `maludb_episode_with_attributes`, `maludb_episode_type`; `maludb_register_episode()`, `maludb_episode_get()` | `malu$episode_object` (103 MB), `malu$episode_replay`, `malu$current_episode` | 61,889 | Safe. Payload is personal data (§7.2). | API `POST/PATCH/DELETE /v1/episodes`, or `maludb_register_episode()` | Each episode mints a subject (type `activity`) and a `malu$event` row, and marks the subject's embedding card dirty (`maludb_core--0.106.0.sql:46717-46740`). Bitemporal (`occurred_at`/`occurred_until`). |
| **Documents, chunks, sources** | `maludb_document`(+`_with_attributes`), `maludb_document_type`, `maludb_document_tag`, `maludb_document_suggested_tag`, `maludb_document_svpor_hint`, `maludb_source_package`, `maludb_raw_ingest`, `maludb_unapplied_ingest`; `maludb_upload_document()`, `maludb_document_get()`, `maludb_forget_document()`, `maludb_forget_chunk()`, `maludb_set_scope()` | `malu$document`, `malu$source_package` (sealed by trigger `source_package_seal_lock_tg`), `malu$verbatim_archive`, `malu$vector_chunk`/`_compartment`/`_tombstone` (owner-only, tenant has no SELECT), `malu$ingest_extraction` | 474 docs, 595 sources | Metadata safe. Content is sensitive. | API `/v1/documents`, `/v1/memory/documents` (model), `/v1/memory/remember` (embedding only), or the facade functions. **Forget only through `maludb_forget_*`**, which takes chunks, edges and source together and refuses a source under legal hold (`docs/principal-scoping.md:67-77`). | Chat sessions are stored as documents with `source_type llm-chat` (319 here), skills as `agent_skill` (95), notes as `note` (60). `source_type` is a controlled vocabulary (FK to `malu$source_type`). |
| **Chat** | `maludb_chat_session`, `maludb_chat_message`; `maludb_chat_start/append_message/finalize/get/messages()` | `malu$chat_session`, `malu$chat_message`, `malu$chat_index_tree` | 319 / 5,411 | Content sensitive | API `/v1/chat/*` | The kernel's `session_search` reads these |
| **Knowledge graph (SVPOR)** | `maludb_subject`(+`_with_attributes`), `maludb_subject_type`, `maludb_verb`, `maludb_verb_type`, `maludb_subject_verb`, `maludb_svpor_statement`, `maludb_svpor_attribute`, `maludb_attribute_template`, `maludb_subject_relationship`, `maludb_svpor_relationship`, `maludb_related_subject`; `maludb_svpor_statement_create/close/delete/set_provenance()`, `maludb_svpor_attribute_*()`, `maludb_subject_relationship_*()`, `maludb_subject_verb_*()`, `maludb_register_subject_type()`, `maludb_link_*()`, `maludb_create_reference_view()` | `malu$svpor_subject` (33 MB), `malu$svpor_verb`, `malu$svpor_statement`, `malu$svpor_attribute`, `malu$svpor_predicate`, `malu$svpor_subject_relationship_edge`, `malu$svpor_subject_type`/`_verb_type` (**global catalogs, no RLS**) | 62,008 subjects, 7 verbs, 120 statements | Safe | API `/v1/subjects`, `/v1/verbs`, `/v1/statements`, `/v1/attributes`, or the facade functions. **Never insert subjects through the view:** ids come from `MAX(id)+1` (API `CLAUDE.md:120`; upstream M7), and a type must already be registered (an unknown `subject_type` fails, after the model has been paid, in the API pipeline). | Statements carry provenance `provided → suggested → accepted/rejected` and valid-time windows. A correction closes a window and never overwrites (`README.md:56-58`). |
| **Claims, facts, memories** (the Stage-2 pipeline) | `maludb_claim`, `maludb_fact`, `maludb_memory`, `maludb_memory_detail`, `maludb_person`, `maludb_stakeholder`, `maludb_project` | `malu$claim`, `malu$fact`, `malu$fact_claim`, `malu$memory`, `malu$memory_detail_object`, `malu$derivation_ledger`, `malu$supersession_edge`, `malu$maut_*`, `malu$current_*` views | 0 / 0 / 3 | Safe | `correct_fact()`, `consolidate_memories()`, `apply_lifecycle_state()`, `legal_hold_*()`; API `/v1/memory/{consolidate,lifecycle,staleness,score,reinforcement,retention-candidates}` | **Doctrine:** "every derived object has a `malu$derivation_ledger` entry", and corrections never overwrite (`README.md:52-70`). The 3 memories are the kernel's principal-profile entries (`memory_kind core_memory`, append-only with tombstones: `app/routers/principals.py:1-19`). API notes are also `maludb_memory` rows (`notes.py:1-12`). |
| **Projects** | `maludb_project`; `maludb_project_archive/unarchive()` | Subjects of type `project` | 0 | Safe | API `/v1/projects` (subject and verb links) | Known API defect: deleting a project leaves its subject links, and a reused id inherits them (`knowledge/docs/knowledge-design.md:535`) |
| **Unified graph and analytics** | `maludb_edge` (union view), `maludb_community`, `maludb_community_membership`; `maludb_graph_neighbors/walk/path/degree/surprises()`, `maludb_graph_import()`, `maludb_community_replace()`, `maludb_datamodel_refresh/describe()` | `malu$edge_unified` view, `malu$relationship_edge`, `malu$community`, `malu$community_membership` | 40,508 edges (40,388 `semantic_edge`, 120 `svpor_statement`), 0 communities | Safe. Bound the walk depth. | Communities are only *written*, by import or replace, and never computed (upstream M6). Import is capped at 50k nodes and 200k links (`maludb_core--0.106.0.sql:51715-51722`). | `GET /v1/graph/{neighbors,walk,path,stats,query,god-nodes,surprises}`, `/v1/communities` |
| **Embeddings and semantic layer** | `maludb_object_embedding`, `maludb_semantic_edge`, `maludb_embedding_dirty`; `maludb_embedding_card()`, `maludb_embedding_dirty_claim/complete()`, `maludb_embedding_complete()`, `maludb_embedding_requeue_all()`, `maludb_embedding_backfill()`, `maludb_semantic_search/neighbors()`, `maludb_semantic_edges_refresh(_all)()`, `maludb_vector_search()`, `maludb_memory_search()` | `malu$object_embedding` (37 MB), `malu$semantic_edge`, `malu$embedding_dirty` (15 MB), `malu$embedding_space`, `malu$model_registry`, `malu$index_migration`, `malu$ann_index`/`_delta`, `malu$vector_index_status` | 4,363 vectors (`entity-v1`, `text-embedding-3-small`); **57,801 dirty** | Safe (the queue *view*) | **Internal: never by hand.** Only through the worker contract claim → embed → complete (the API's `POST /v1/memory/embeddings/run`). | **`embedding_dirty_claim()` is not a read.** It takes row locks and *deletes* unchanged or vanished rows in-claim (`maludb_core--0.106.0.sql:47040-47099`). A console must read the view instead. With no embedder configured, the API's fallback writes sha256 "vectors" that are not semantic (`app/helpers/llm.py:11-12,51-56`). |
| **Extraction** | `maludb_memory_model_config()`, `maludb_memory_set_model_config()`, `maludb_memory_request_extraction()`, `maludb_memory_harvest_extractions()`, `maludb_memory_ingest_edge()`, `maludb_memory_ingest_extraction()`, `maludb_memory_reindex_claim()` (read-only, granted to the auditor), `maludb_memory_reindex_apply()` | `malu$memory_extraction`, `malu$memory_extraction_config`, `malu$document.last_indexed(_model)` | 0 / 0. 474 documents never indexed. | Safe | API `/v1/memory/ingest`, `/documents`, `/reindex/run` | Reindex replaces a document's statements anchored on that document, re-ingests, and stamps the watermark (`maludb_core--0.106.0.sql:50250-50300`) |
| **Skills** | `maludb_skill`, `maludb_skill_file`, `maludb_skill_keyword/subject/verb`, `maludb_skill_access`, `maludb_skill_principal_access`, `maludb_skill_load_event`, `maludb_skill_embedding`, `maludb_skill_state/transition/execution`; `maludb_skill_register/get/search/fork/review/grant_principal/revoke_principal/record_load/reindex_claim/reindex_apply()` | `malu$skill_package` and its siblings; the public schema `maludb_public` | 95 skills, 122 files, 2,057 keywords | Safe (skill text is instructions: show it as text) | API `/v1/skills*` (ingest and reindex call `skill_extract`), `maludb_skill_review()`. An author cannot review their own proposal. | A skill resolves only when `enabled` **and** `review_state = approved` (`docs/principal-scoping.md:79-87`) |
| **Pools and presence** | `maludb_memory_pool*`, `maludb_pool_*`, `maludb_pool_presence`; `maludb_pool_search()`, `maludb_presence_*()`, `maludb_pool_add/remove_named_member()` | `malu$active_memory_pool*`, `malu$pool_presence*` | 0 | `maludb_pool_subject_verb` **fails for the tenant role**: "permission denied for table malu$vector_compartment" | API `/v1/pools*` | A facade defect, proposed upstream |
| **Principals and scopes** | `maludb_principal`, `maludb_principal_scope`; `maludb_principal_upsert/grant_scope/revoke_scope/whoami()` | `malu$principal`, `malu$principal_scope` | 0 | Safe | API `/v1/principals*`, `/v1/scope`. Refused inside any session bound to a principal. | |
| **LLM and MCP catalog (in-DB)** | `maludb_llm_model/provider/request/response`, `maludb_model_provider`, `maludb_model_alias`, `maludb_prompt`, `maludb_prompt_render`, `maludb_mcp_*`; `maludb_register_model_provider/alias()` | `malu$model_provider/alias/request/response` (the tenant has no SELECT on the raw tables), `malu$prompt_*`, `malu$mc2db_*` | 0 | Safe through facades. `secret_ref` is a *reference*, never a value (`docs/maludb-modeld-contract.md:100-107`). | Functions only | Unused here. The API is the model worker. |
| **Secrets** | (none) | `malu$secret`, `malu$secret_version` (`value_encrypted bytea`), `malu$secret_use`, `malu$secret_master_key` (tenant has no SELECT) | 0 here | **Never display** `value_encrypted` | `secret_set()`, `secret_revoke()`, `secret_get_metadata()`; API `POST /v1/memory/config` | The per-database master key and pepper are deliberately left out of `pg_dump`. After a restore, secrets and tokens must be re-created (`CHANGELOG.md:207-221`). |
| **Workflows** | `maludb_workflow_trace/step/candidate` | `malu$workflow_*` | 0 | Safe | Candidates never auto-promote (`README.md:68-70`) | |
| **Governance and audit** | (none) | `malu$audit_event`, `malu$legal_hold`, `malu$lifecycle_policy`, `malu$reinforcement_event`, `malu$retrieval_decision_audit`, `malu$object_grant` | 0 | Safe (the auditor reads all) | `legal_hold_apply/release()`, `apply_lifecycle_state()`, `retention_candidates()` | Legal hold blocks terminal transitions and forgetting (`docs/admin-guide.md:83-110`) |
| **Platform (V3)** | (none) | `malu$queue/_job/_lease`, `malu$schedule/_run`, `malu$event/_subscription/_delivery`, `malu$log_drain*`, `malu$backup_manifest/_verification`, `malu$preview_env*`, `malu$rest_endpoint/_invocation`, `malu$storage_adapter`, `malu$source_object*`, `malu$page_index_tree`, `malu$local_memory_node`, `malu$node_*` | 0, except **`malu$event` 61,951 (31 MB), no subscriptions** | Safe | Service-owned | Monotonic growth with no consumer |
| **Facade registry** | (none) | `malu$enabled_schema` (version per tenant, **no RLS**: a tenant sees the other schema names in its database), `malu$enabled_schema_object` (`object_purpose` for all 176 objects) | 1 tenant | Safe | `enable_memory_schema()` only | Built-in documentation a console can render |

**Reading the extension's own documentation.** `DATABASE_STRUCTURE.md` says it was "generated 2026-05-25 from
`maludb_core--0.76.1.sql`" (`DATABASE_STRUCTURE.md:3-4`). It lists 144 tables and 56 facade views; the live database
has 161 and 78. `maludb_core_release()` still answers "R1.0 Stage 1 substrate", and the API's MCP `SERVER_VERSION` is
"0.4.0" against package 0.4.1 (`app/routers/mcp.py:52`). **A console must introspect the live catalog and must not
trust the documents.**

---

## 3. Administrative operations and how each is invoked

| Operation | Invoked by | Who on this estate | Model cost | Side effects / notes |
|---|---|---|---|---|
| Create a memory database and tenant | `createdb` → `CREATE EXTENSION maludb_core CASCADE` → role and schema → `enable_memory_schema()` → `grant_memory_access()` (+ `maludb_secret_consumer`) | root/postgres (ROOT_STEPS); the owner's | none | §1.2 |
| Mint, list or revoke an API token | `POST/GET/DELETE /v1/tokens` with the tenant's PostgreSQL credentials | root step (ROOT_STEPS 4) | none | The token is shown once; nobody holds the password afterwards except root-only files |
| Grant access | `grant_memory_access(role, level)`; principals through `maludb_principal_upsert/grant_scope` or `/v1/principals` | postgres; tenant | none | Cluster-wide groups (§1.3) |
| Upgrade | (1) per host `make install`; (2) per database `ALTER EXTENSION maludb_core UPDATE`; (3) per tenant `enable_memory_schema()`. Or `scripts/maludb-upgrade -v VER -d DB -s SCH|--all-schemas` | root; the owner's | none | "Stopping early leaves the system in a mixed state" (`README.md:237-238`). Building from an old checkout silently downgrades `default_version` (`README.md:242-244`). |
| Check versions | `SELECT extversion FROM pg_extension`; `maludb_core.maludb_core_version()`; `pg_available_extensions.default_version`; `malu$enabled_schema.enabled_version`; `scripts/maludb-validate` | any reader | none | API `/health` answers only `{"status":"ok"}` (`app/main.py:197-200`). No version route exists. |
| Re-embed (queue drain) | `POST /v1/memory/embeddings/run?limit=&kinds=` per tenant token, or the worker contract | timer `maludb-embedding-worker.timer` every 15 min: **not installed** | embedding call per card | Refreshes `semantic_edge` neighbours. Skipped when no embedder is configured. |
| Re-embed under a new model | `propose_index_migration()` → `advance_index_migration(id, 'shadow_building'|'dual_serve',w|'cutover'|'cleanup'|'done')`; `route_query('embedding')` | postgres or admin | full re-embed | Blue-green, no downtime (`docs/admin-guide.md:189-210`) |
| Requeue all cards | `maludb_embedding_requeue_all(kind)`, `maludb_embedding_backfill()` | tenant | queues work, which then costs | Mass dirtying |
| Reindex documents and notes (re-extract) | `POST /v1/memory/reindex/run?limit=&max_age=&source_type=` (`app/routers/memory.py:967-1040`); SQL `maludb_memory_reindex_claim` (read-only) → `maludb_memory_reindex_apply` | timer every 6 h: **not installed** | **one extraction call per document** | Replaces each document's statement footprint |
| Reindex skills | `POST /v1/skills/reindex/run` | timer every 30 min: not installed | `skill_extract` per skill | |
| Rebuild ANN indexes | `ann_build()`, `ann_rebuild()`, `ann_status()`, `vector_index_status()` | admin | none | Weekly `REINDEX` of the bitemporal GiST indexes under heavy supersession (`docs/admin-guide.md:152-160`) |
| Monitor queues | SELECT `maludb_embedding_dirty`, `malu$memory_extraction`, `malu$queue_job`, `malu$schedule`, `malu$document.last_indexed` | reader | none | Prometheus `/metrics` exists only on `mc2dbd`, which is not running (`docs/monitoring.md:8-27`) |
| Retention and lifecycle | `retention_candidates()`, `apply_lifecycle_state()`, `legal_hold_apply/release()`, `consolidate_memories()`, `propagate_staleness()`; API `/v1/memory/{lifecycle,consolidate,staleness,retention-candidates}` | admin | none | Legal hold gates terminal states |
| Forget | `maludb_forget_document()`, `maludb_forget_chunk()`, `DELETE /v1/documents/{id}`, `DELETE /v1/memory/chunks/{id}`, `DELETE /v1/episodes/{id}` | tenant | none | Irreversible. Subjects stay (vocabulary is tenant-wide). |
| Model configuration | Store A: `POST/PUT /v1/memory/config` (secret + provider + alias + bind per namespace). Store B: `PUT /v1/llm/providers/{p}`, `PUT /v1/llm/models/{task}` (tasks `extract`, `skill_extract`, `embed`, `query_parse`, `answer`: `app/llm_catalog.py:36`) | tenant token | none | Two stores with cross-fallback (`app/routers/memory.py:47-60`) |
| Data-model graph | `maludb_datamodel_refresh(ns, schemas[])` or `POST /v1/datamodel/refresh`; `maludb_datamodel_describe(rel)` or `GET /v1/datamodel/describe` (`app/routers/graph.py:926-990`) | tenant | none directly; **dirties embedding cards** | §4 |
| Backup and restore | `pg_dump -Fc` carries MaluDB data since 0.105.0. Restore as superuser with `PGOPTIONS='-c session_replication_role=replica'`, then re-create secrets and tokens. | the owner | none | `CHANGELOG.md:207-221` |
| Force RLS | `scripts/maludb-force-rls --status|--apply|--revert` | postgres | none | Opt-in. Breaks cross-tenant maintenance. |
| Audit | `malu$audit_event`; pgaudit (the estate turned `pgaudit.log` to `none` on 2026-10-10 after the disk filled) | auditor, postgres | none | |

---

## 4. The "database model": DM-1, the CLI's `db` tools, and how a DB tool could use them

**Name.** `maludb_modeld` is the model *gateway* contract (`docs/maludb-modeld-contract.md`). The feature the task
asks about is **DM-1, the relational data-model graph** (0.104.0; `maludb_core--0.106.0.sql:51640-51668`; `README.md:16`).

**What `_datamodel_refresh_for_schema` does** (`maludb_core--0.106.0.sql:51858-52017`, `SECURITY DEFINER`):

1. It refuses any schema except the tenant's own, `maludb_core` and `public` (`:51876`). `pg_catalog` belongs to one
   database, so **it can only ever see the memory database it runs in.**
2. Nodes: one `db_schema_ns` per schema. `db_table`, `db_view` and `db_matview` nodes (id `schema.relation`) carry the
   attributes `columns` (cut to 2,000 characters) and `primary_key`. `db_routine` (overloads collapse) and
   `db_trigger` nodes follow.
3. Edges, all marked EXTRACTED (confidence 1.0): `belongs_to`, `fk_references` (relation → relation, no column
   pairs), `depends_on` (view → relation from `pg_rewrite`/`pg_depend`) and `triggers_on`. `reads` and `writes` are
   INFERRED (0.7) from a `strpos` over `prosrc` for table names of at least 6 characters (`:51989-52010`). That gives
   false positives on substrings and comments, and it misses short names (`users`, `items`) and all SQL that lives in
   application code.
4. It feeds `_graph_import_for_schema`. Nodes become subjects with canonical names `<ns>/<id>`, links become SVO
   statements, node types are registered in the **global** `malu$svpor_subject_type`, and there is one community per
   schema (`:51674-51853`). Communities are replaced. **I found no code that deletes subjects or edges for objects that
   disappeared**, so a dropped table very likely survives a refresh as a stale node.
5. Every created subject and statement fires the embedding-dirty triggers. A refresh therefore enqueues paid
   embedding work and mixes schema nodes into the tenant's semantic search, recall proposals and god-nodes.

`maludb_datamodel_describe(relation)` is a live description: columns, primary key, and foreign keys out and in, with
columns (`:52027-52094`).

**The CLI** (`maludb db --help`): `schema` → `/v1/datamodel/describe`; `refresh` → `/v1/datamodel/refresh`;
`related`, `join-path` (default `--max-depth 6`) and `impact` (default 3) walk the `datamodel` namespace through
`/v1/graph/neighbors|walk|path` with the relation filter `fk_references,reads,writes,depends_on,triggers_on`. The
binary's strings contain that list; the source is not on this host. Its MCP mode exposes `db_schema`, `db_related`,
`db_join_path`, `db_impact`, `db_model_refresh` (writes), `graph_walk`, `shortest_path`, `god_nodes`,
`get_communities`, `query_graph`, `graph_stats`, `graph_surprises`, `graph_import` (writes) and `sync_*` (settings
blob; push writes a note).

**DM-3, code ↔ schema.** graphify's `--sql-usage` (`~/graphify/graphify/sql_usage.py:1-11`) regex-mines
`INSERT/UPDATE/DELETE/FROM/JOIN` in `.php`/`.py`/`.sql`/… files. It emits file → `datamodel/<schema>.<table>` links,
imported with `options.resolve_external`, so "which PHP files touch `invoices`" becomes a graph question (INFERRED).

### Options for the developer tool

| Option | How | For | Against |
|---|---|---|---|
| **A. Live catalog only** | The tool computes impact (recursive over `pg_depend`, `pg_constraint`, `pg_trigger`, `pg_policy`, sequences, defaults), join paths (BFS over FK column pairs) and related objects directly in each target database | Exact, always current, any database, column-level join conditions, no MaluDB write, no cost | No code ↔ schema layer; PL/pgSQL bodies are not in `pg_depend` (the same blind spot DM-1 papers over with text scanning; the PostgreSQL sibling covers `plpgsql_check`) |
| **B. DM-1 in place** | Call `maludb_datamodel_refresh` in a memory database | Already built; the CLI and agents speak it | Sees only its own memory database, never `subello_gl` and the rest; pollutes and costs in the tenant's agent memory; stale nodes; relation-level paths |
| **C. External introspection → `maludb_graph_import`** | The tool builds DM-1's node-link JSON for *any* database and imports it under a namespace such as `dm.subello_gl` (allowed by `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`, `:51703`) into a memory store of the tool's own; graphify DM-3 links stitched in | Cross-database; the same graph tools for agents; code links; snapshot history | Needs a memory database (contract rule, open question); embedding pollution unless upstream lets a namespace opt out; still no deletes |
| **D. Hybrid (recommended)** | A is authoritative for every screen ("what breaks if I drop this column"). C is an optional, labelled "code and schema map" layer with a snapshot time and a refresh button, kept out of the tenant's agent memory. | Exact answers plus code reach | Two mechanisms to maintain |

**Recommendation: D.** Answer impact and join paths from the live catalog, which is exact. Treat the MaluDB graph as a
derived, possibly stale map whose INFERRED edges are shown as such. Never call `maludb_datamodel_refresh` or
`graph_import` against the kernel's `certstudy_memory`.

---

## 5. What exists on this host (names only)

| Database | Tenant schema(s) | Pattern | Size | Extension |
|---|---|---|---|---|
| `maludb` | `app` (stray quickstart tenant) | bootstrap | 36 MB | 0.106.0 |
| `certstudy_memory` | `certstudy_mem` (facades 0.106.0) | A, the kernel's tenant memory | 299 MB | 0.106.0 |
| `subello_knowledge_memory` | `knowledge_mem` | A, Knowledge (namespaces `kb:<id>`) | 25 MB | 0.106.0 |
| `subello_doccloud_memory` | `doccloud_mem` | A, DocCloud (namespace `dc`) | 26 MB | 0.106.0 |
| `subello_cidery` | `memory` (beside `app`) | B | n/a | 0.106.0 |
| `subello_processcore` | `memory` (beside `app`) | B | n/a | 0.106.0 |
| `cidery_dev`, `processcore_dev` | `memory` | B, development | n/a | 0.106.0 |
| `maludb_ma_scratch` | `ma_scratch` | scratch (upstream M-item work) | 26 MB | 0.106.0 |

- Host extension files: 0.106.0. The extension repository is at commit `71cf34d` (0.106.0, principal scoping). API
  0.4.1 (M12 merged). Worktrees `~/maludb-core-mb`, `~/maludb-api-m1|m12|ma|mb` belong to other sessions.
- Services: only `maludb-api.service`. No MaluDB timers. No `mc2dbd`.
- `certstudy_memory` in brief:
  - episodes by application: kernel 24,663, helpdesk 9,034, gl 7,775, consultant_tracking 7,769, spaces 6,512,
    doccloud 1,703, projects 1,409, knowledge 914, hr 879, txtschedules 707, processcore 210, inventory 207, cidery 183;
  - subjects: 61,941 `activity` + 89 skill + 30 concept;
  - edges: 40,388 semantic + 120 SVO;
  - embedding backlog 57,801 (subjects 57,691 since 2026-09-20, statements 110);
  - 0 principals, 0 communities;
  - largest tables `malu$episode_object` 103 MB, `malu$object_embedding` 37 MB, `malu$svpor_subject` 33 MB,
    `malu$event` 31 MB.
- The memory roles of Knowledge and DocCloud have passwords only in root-only files. I did not read their memories.

---

## 6. What the MaluDB section should offer

### 6.1 Screens, ranked

1. **Memory estate.** Every database with `maludb_core`, its pattern, size, extension version against the host's
   default, and its tenant schemas with facade versions. Flags: facades behind the extension, a tenant in `maludb`,
   scratch databases.
2. **Tenant health.** Counts per family; embedding backlog (count, oldest, by kind); documents never or stale indexed;
   extraction queue; `malu$event` and audit growth; table sizes; facades that fail a `LIMIT 0` probe; whether
   embedder and extractor are configured; "no worker has drained this queue in N days".
3. **Graph explorer.** Subject search by name, alias and type; a subject page (verbs, attributes, statements,
   relationships, documents); neighbours, walk, path; god-nodes; stats by store and relation; communities and
   import namespaces. Depth and node caps on everything.
4. **Data model (shared with the PostgreSQL side of the tool).** Impact, join path and related, from the live catalog;
   optionally the MaluDB "code and schema map" (§4 D).
5. **Episodes.** A timeline filtered by kind, application, day, sensitivity and scope, with the payload hidden. Revealing
   one payload takes a right and is logged.
6. **Documents, chat and notes.** Metadata lists; content behind the same reveal rule; *Forget* as a confirmed,
   logged action.
7. **Skills.** Versions, `enabled`, `review_state`, files, load events; review as an action.
8. **Principals and scopes.** List and grants; "what would this principal see": `maludb_principal_whoami()` under
   `SET LOCAL` in a read-only transaction.
9. **Model configuration (read-only).** Store A per namespace (alias, model, prompt template name, `secret_ref` name);
   Store B through the API (`key_set` per provider, task choices); the effective model per task.
10. **Maintenance.** Run one embedding or reindex batch with a cost estimate and super-admin confirmation; retention
    candidates; legal holds; the upgrade plan (read-only; execution is the owner's).
11. **Isolation audit (read-only).** CONNECT ACLs, members of the `maludb_*` groups, BYPASSRLS login roles, FORCE RLS
    status, tenant schemas per database.
12. **Facade reference.** `malu$enabled_schema_object.object_purpose` rendered as documentation.

### 6.2 What agents should be able to ask (MCP, read-only)

| Tool | Answers |
|---|---|
| `memory_estate` | Memory databases, patterns, versions, mismatches |
| `memory_health(db, schema)` | Counts, backlogs, staleness, broken facades |
| `memory_object_counts(db, schema)` | Per family |
| `memory_graph_stats` / `memory_god_nodes` / `memory_communities` | Graph shape |
| `memory_subject_find(q, type)` / `memory_subject_detail(id)` | Vocabulary |
| `memory_graph_path(a, b, max_depth)` / `memory_graph_walk(...)` | Connections (bounded) |
| `memory_episode_stats(application, kind, period)` | **Aggregates only**, never payloads |
| `memory_document_list(source_type, namespace)` | Metadata only |
| `memory_skill_list` / `memory_principal_list` | Governance |
| `memory_model_config(namespace)` | Names of models, never keys |
| `db_impact` / `db_join_path` / `db_related` / `db_schema` | From the live catalog (§4 A) |

Writes stay manifest actions paused for a person: refresh the code map, run a batch, forget, review a skill.

---

## 7. Risks

### 7.1 What corrupts memory when edited by hand

- **DML through the auto-updatable facades or on `malu$*`:**
  - inserting subjects or verbs (`MAX(id)+1` collisions, unregistered types);
  - editing a statement or fact in place (breaks supersession and the derivation ledger);
  - deleting a subject directly (statements, attributes and episodes reference it; the purge trigger drops its vectors
    and semantic edges);
  - editing `maludb_embedding_dirty`, `maludb_object_embedding` or `maludb_semantic_edge` (vectors that disagree with
    their cards, a queue generation mismatch);
  - editing `maludb_source_package` (seal lock trigger) or episodes (activity memory cannot be backfilled);
  - writing the audit-like facades (`maludb_llm_request`, `maludb_mcp_invocation`).
- **DDL** on facade objects (they are regenerated, and `_memory_schema_assert_object_slot` refuses foreign objects) or
  on `maludb_core` (extension members: upgrades break, `pg_dump` registration drifts).
- **Calling claim functions to "look"**: `embedding_dirty_claim` deletes and locks rows (§2).
- **Restoring without `session_replication_role=replica`**: triggers re-queue rows and the COPY fails on duplicates
  (`CHANGELOG.md:213-221`).
- **Registering node types**: subject types are global to the database.

### 7.2 Privacy

- Episodes carry `before`/`after` row images from twelve applications, including HR and GL, all marked `internal` and
  scoped `default`. Chat messages (5,411) and notes are verbatim text. The kernel's design treats the MaluDB token as
  reading everything (`/var/www/mcp/maludb_client.py:1-8`). A developer console with an auditor-level read path would
  hold the same power over **every** memory database.
- There is no erasure-by-person function: forget works per document or chunk, and episodes are deleted one at a time
  by id.
- A reveal screen must not leak into logs. pgaudit is off today but can be re-enabled. Activity logging of a reveal
  must record that it happened, never the content. That logged reveal itself becomes an episode in tenant memory.
- Finding 6 (withheld) means tenant roles are weaker walls than they look. The developer tool
  must not rely on them for its own permission model.

### 7.3 Cost

- Model-calling routes:
  - `/v1/memory/documents`: one extraction per chunk, plus embeddings;
  - `/v1/memory/ingest` and `/v1/memory/reindex/run`: one extraction per document;
  - `/v1/skills/ingest` and `/v1/skills/reindex/run`;
  - `/v1/memory/answer`: one or two completions plus an embedding;
  - `/v1/memory/search`, `/recall` and `/remember`: embeddings;
  - `/v1/memory/embeddings/run`: one embedding per card;
  - `/v1/memory/notes`: an optional `query_parse` call.
- Sizing today:
  - The 57,801-card backlog is cheap to embed. At an assumed 40–150 tokens a card that is roughly 2–9 M tokens, a few
    tenths of a dollar at small-embedding list prices (verify). It grows by about 2,500 a day, because every activity
    episode adds a subject card, and refreshing semantic neighbours costs database CPU.
  - Re-extracting the 474 never-indexed documents is the expensive case: one chat-model call each. The price depends
    on the model, and the extraction can fail *after* payment on an unregistered subject type.
- The kernel's ledger proxy meters application credentials (K24), but the API reports usage only on `answer` (M2). A
  console must estimate before it acts.

---

## 8. Requirements

**Discovery and access**

- **MR1 MUST** — Discover memory databases from the catalog (`pg_extension` in each database) and classify each:
  dedicated (pattern A), co-located `memory` schema (pattern B), bootstrap `maludb`, scratch or development. Flag any
  tenant in the bootstrap database.
- **MR2 MUST** — Read MaluDB through one dedicated read path of the tool's own (§10 Q2). Every session is
  `default_transaction_read_only = on` with a `statement_timeout`. Never borrow an application's memory-role password or
  API token, and never read the API's auth store.
- **MR3 MUST** — One module of the tool talks to MaluDB, like DocCloud's `app/doccloud/graph.php`. An unreachable or
  refusing engine degrades to "memory unavailable" and never to an exception page.
- **MR4 MUST** — The MaluDB section is super-admin only (or a named right of the tool). Agents reach it only through
  §6.2's read tools.
- **MR5 MUST** — Never display, export or hand to an agent any secret material: `malu$secret_version.value_encrypted`,
  token hashes, JWT keys, the master key, the pepper, provider keys. Show names, kinds, `secret_ref` strings and dates
  only.

**Read-only by default**

- **MR6 MUST** — The generic table and grid editor treats every facade object and every `maludb_core.malu$*` and `mc2db`
  table as read-only, although 67 facade views are auto-updatable. It refuses with the reason and names the curated
  action instead.
- **MR7 MUST** — Refuse DDL on `maludb_core`, `mc2db` and on facade objects inside a memory-enabled schema; point to
  `enable_memory_schema`.
- **MR8 MUST** — Never call a claim function (`*_claim`) or any function that writes in order to display something.
  Queues are read from their views (`maludb_embedding_dirty`); staleness comes from `last_indexed` or the read-only
  `maludb_memory_reindex_claim`.
- **MR9 MUST** — Every MaluDB read is bounded (LIMIT and paging, depth and node caps on walks, a row cap on lists) and
  avoids per-row function calls over large views.

**Screens**

- **MR10 MUST** — Memory estate screen (§6.1 #1): versions per database and per tenant schema against the host's
  `pg_available_extensions.default_version`, with mismatches flagged and the three upgrade steps shown read-only.
- **MR11 MUST** — Tenant health screen (§6.1 #2), including the embedding backlog with its oldest age, never-indexed
  documents, `malu$event` growth, table sizes, and facades that fail a `LIMIT 0` probe.
- **MR12 MUST** — Graph explorer (§6.1 #3) over `maludb_edge` and the graph facade functions, labelling which of the
  three "namespace" senses a field uses.
- **MR13 MUST** — Episodes: lists and aggregates by kind, application, day, sensitivity and scope, payload hidden. Revealing
  one episode's payload requires the right, asks for a reason, and is activity-logged without the content.
- **MR14 MUST** — Documents, chat sessions and notes: metadata lists. Content behind the MR13 reveal rule.
- **MR15 MUST** — Model configuration (read-only): Store A per namespace from SQL and Store B through the API, with the
  effective model per task, never key values.
- **MR16 SHOULD** — Skills screen (versions, enabled, review state, files, load events) and principals-and-scopes
  screen with a "see as principal" probe (`SET LOCAL maludb_core.principal_ref` in a read-only transaction).
- **MR17 SHOULD** — The facade reference rendered from `malu$enabled_schema_object.object_purpose`.
- **MR18 SHOULD** — Isolation audit screen (read-only): CONNECT ACLs on memory databases, members of the `maludb_*`
  groups, BYPASSRLS login roles, FORCE RLS status, schemas per database.
- **MR19 SHOULD** — Retention and governance view: `retention_candidates()`, legal holds, lifecycle policies, the
  growth of `malu$event`, `malu$audit_event` and `malu$episode_replay`.
- **MR20 LATER** — A read-only SQL console limited to one tenant's facades and `maludb_core`'s public views, SELECT
  only, row cap, timeout.

**Actions (all curated, logged, `hx-confirm`, paused when an agent asks)**

- **MR21 MUST** — Every action that can call a model (embedding batch, reindex batch, documents ingest, skills
  ingest or reindex, answer) shows an estimate first (items × assumed tokens × the configured model) and needs a
  super-admin's confirmation. The tool never schedules such work itself.
- **MR22 MUST** — Destructive memory actions (`maludb_forget_document`, `maludb_forget_chunk`, episode delete,
  `maludb_set_scope`, legal-hold release, lifecycle transitions) run only through the extension's functions or the
  API's routes, honour legal holds, and report what was removed.
- **MR23 MUST** — Installation, upgrade, `enable_memory_schema`, `grant_memory_access`, token minting and the
  re-creation of secrets after a restore are shown as the owner's steps, printed and never executed by the web tool.
- **MR24 SHOULD** — Skill review (`maludb_skill_review`) as an action, refusing self-review as the engine does.
- **MR25 LATER** — A blue-green re-embedding wizard over `propose_index_migration`/`advance_index_migration`.
- **MR26 LATER** — Token list and revoke for a memory database (needs that tenant's login at the moment of action, never
  stored).

**Data model**

- **MR27 MUST** — Impact, join path (with FK column pairs) and related objects are computed from the live catalog of
  the target database (§4 A). MaluDB is not required for them.
- **MR28 MUST** — The tool never runs `maludb_datamodel_refresh` or `maludb_graph_import` against the kernel's tenant
  memory or any application's memory.
- **MR29 SHOULD** — An optional "code and schema map" (§4 C): DM-1-shaped node-link JSON built by the tool for any
  database, plus graphify DM-3 links, imported under `dm.<database>` into a store decided in §10 Q1. Shown with its
  snapshot time and INFERRED edges marked, refreshed on request.

**Agents**

- **MR30 MUST** — The MCP tools of §6.2: read-only, `readOnlyHint`, aggregates for episodes, metadata for documents,
  bounded walks, no payloads and no secrets.
- **MR31 SHOULD** — The expert's skills explain MaluDB's write rules (§7.1) so the agent proposes curated actions
  rather than SQL against facades.

**Operations knowledge**

- **MR32 SHOULD** — The backup screen states MaluDB's `pg_dump` caveats (secrets and tokens unrecoverable after restore;
  restore with `session_replication_role=replica`).
- **MR33 SHOULD** — Show, per tenant, whether embedding, reindex and skill-reindex sweeps are running, derived from data
  (the oldest dirty age, `last_indexed` watermarks) because systemd timers are not visible to PHP.
- **MR34 SHOULD** — Warn before any reveal or bulk read when `pgaudit.log` would record statement text.

---

## 9. Proposed upstream items (MaluDB; unnumbered)

Already owed and **not** repeated here: M2 (usage on model responses), M3 (graph and recall namespace semantics,
project filter), M5 (documents dry run), M6 (community detection), M7 (subject ids from a sequence, aliases), M10
(`document_ids[]` pre-filter), M11 (async ingest).

- **A status surface.** A read-only SQL function and API route answering engine version, facade version per schema,
  queue sizes and oldest ages, reindex watermarks and configured models. `/health` should carry versions. Correct
  `maludb_core_release()` and the MCP `SERVER_VERSION`.
- **Tenant isolation (finding 6).** *Withheld from the public copy (2026-10-11): an estate security finding, reported privately to the owner; it will be published once fixed.*

- **DM-1 completeness.**
  - Delete nodes and edges of objects that vanished (true replace per namespace).
  - Column pairs on `fk_references`.
  - Exact routine dependencies where `pg_depend` has them (SQL-standard bodies), the text scan only as a fallback, and
    no 6-character floor.
  - A documented entry point for a catalog snapshot of *another* database (or bless `graph_import` with DM-1's node
    types).
- **Embedding opt-out per namespace or subject type.** Data-model nodes and the 61,941 `activity` subjects should not
  queue entity cards unless asked.
- **Side-effect-free queue inspection.** Document that `embedding_dirty_claim` writes, and give
  `/v1/memory/embeddings/run` and `/reindex/run` a `dry_run` that returns what would be claimed with a token estimate.
- **Facade defect.** `maludb_pool_subject_verb` is unreadable by the tenant role (permission denied on
  `malu$vector_compartment`).
- **Erasure and subject access by person.** List and forget the episodes, chat and documents of a principal or payload
  key, with a proof like `maludb_forget_document`'s.
- **`malu$event` retention** when a tenant has no subscriptions, or an opt-out from realtime events.
- **Tokens with teeth.** Enforce the token's role (a read-only token), let a token bind its principal (the "delegated
  token" `app/principal.py` mentions), record last use, and stop putting credentials in a GET body.
- **One effective-model read** across the PostgreSQL namespace configuration and the SQLite per-user choices.
- **Documentation drift.**
  - Regenerate `DATABASE_STRUCTURE.md` for 0.106.0.
  - `maludb_memory_dba` is documented but absent.
  - The README omits `maludb_secret_consumer`.
  - The README's verification expects 0.104.0.

---

## 10. Open questions for the owner

1. **A memory database for the developer tool?** The contract says one memory per tenant; Knowledge and DocCloud made
   dedicated ones by decision; the cidery and ProcessCore co-locate. Does the tool get `<tenant>_developer_memory` for
   its code-and-schema map, write into the tenant memory, or keep no MaluDB store at all (§4 A only)?
2. **The read path into other memory databases.**
   - (a) A login role of the tool's own, a member of `maludb_memory_auditor`, which can `SET ROLE` to BYPASSRLS and
     read all governed tables, ciphertext included, in every memory database.
   - (b) A member of `maludb_read`: facades only, and only one tenant at a time through `search_path`, which itself
     relies on the §1.4 weakness.
   - (c) Per-tenant API tokens, which means holding every application's token.

   Recommendation: (a) with presenters that never select secret columns, used only server-side, read-only
   transactions. The decision is the owner's.
3. **Who may reveal an episode or document payload**, and must the reveal carry a reason?
4. **Should the tool run model-calling maintenance at all**, or only show the backlog and hand the run to the owner?
   Is the 57,801-card backlog intended (no worker installed)?
5. **The isolation finding (withheld).** It is outside the tool's scope, but should the developer design carry a
   kernel or estate item for it?
6. **Curated writes.** Beyond forget and skill review, may a super-admin ever correct memory (rename a subject, close a
   statement) from the tool, or is MaluDB strictly read-only in it?
7. **Strays.** Should the estate view list the `maludb` database's `app` tenant and the scratch and development memory
   databases, or hide them?
8. **Data model.** Is the live catalog alone (§4 A) enough for v1, with the MaluDB code-and-schema map LATER?

---

## Sources

Local:
- `/home/maludb/maludb-core`: `README.md:16,52-70,77-266`, `maludb_core.control`, `DATABASE_STRUCTURE.md:3-35,4072-4158`,
  `docs/admin-guide.md:7-221`, `docs/principal-scoping.md:1-115`, `docs/security-review.md:44-55,147-154`,
  `docs/monitoring.md:8-27`, `docs/maludb-modeld-contract.md:1-107`, `docs/maludb-mc2dbd-contract.md:1-40`,
  `docs/user-manual.md:380-576`, `CHANGELOG.md:200-221`, `scripts/maludb-upgrade`, `scripts/maludb-validate`,
  `scripts/maludb-force-rls`, `sql/extension/maludb_core--0.106.0.sql:33876-33939,46560-46740,47040-47099,50250-50300,51640-52140`.
- `/home/maludb/maludb-python-api-server`: `CLAUDE.md:120`, `pyproject.toml:3`, `app/main.py:197-200`,
  `app/auth.py:63-114`, `app/principal.py:1-25`, `app/llm_catalog.py:36`, `app/helpers/llm.py:11-12,51-56`,
  `app/routers/tokens.py:59-175`, `app/routers/memory.py:1-16,47-60,967-1100`, `app/routers/graph.py:248-300,926-990`,
  `app/routers/llm_config.py:1-16`, `app/routers/mcp.py:20-25,52`, `app/routers/principals.py:1-19`,
  `app/routers/notes.py:1-12`, `app/routers/memory_maintenance.py:1-10`, `app/routers/scoping.py:97-120`,
  `docs/rest-user-tables.md:1-15`, `deploy/*.timer`.
- `~/.local/bin/maludb` (`--help`, `db|graph|sync|mcp --help`, `strings`); `~/.config/malu/config.toml` (keys only);
  `~/graphify/graphify/sql_usage.py:1-11`.
- `/var/www/CLAUDE.md:257-268`; `/var/www/docs/install.md:116-133`; `/var/www/mcp/activity_ingest.py:28-54`;
  `/var/www/mcp/memory_server.py:1-13`; `/var/www/mcp/maludb_client.py:1-8`.
- `/srv/apps/knowledge/deploy/ROOT_STEPS.sh:45-137`; `/srv/apps/knowledge/docs/knowledge-design.md:70-73,520-535`;
  `/srv/apps/doccloud/deploy/ROOT_STEPS.sh:68-148`; `/srv/apps/doccloud/app/doccloud/graph.php:1-50`;
  `/srv/apps/doccloud/tests/phase0/engine/FINDINGS.md`; `/srv/apps/cidery/deploy/os-provision.sh:28`;
  `/srv/apps/cidery/services/activity_mcp/server.py:163`.
- `~/maludb-os-integration/skills/os-integration/SKILL.md:93-94`; `.../references/memory.md:5-13,140-160`;
  `~/htmx-php-builder/skills/mcp-servers/SKILL.md:9-30`.
- Live, read-only, as the kernel's roles: `pg_database`, `pg_extension`, `pg_namespace`, `pg_roles`, `pg_auth_members`,
  `pg_policies`, `information_schema.views`, `malu$enabled_schema(_object)`; aggregate counts in `certstudy_memory`;
  `systemctl list-units 'maludb*'`; `ss -tln`.

Web: none needed. Every fact above is local and versioned (extension 0.106.0, API 0.4.1).
