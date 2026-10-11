---
name: maludb-memory-rules
description: What the MaluDB memory system is, what Developer shows of it, and why the memory section is read-only — the extension, the API and the CLI; memory databases, tenants and facades; what corrupts memory if edited by hand; the embedding and reindex backlogs and their cost; privacy of episodes. Load before answering anything about a memory database.
---
# MaluDB — the rules

## What it is
- **The extension `maludb_core`** (0.106.0 here) is the engine and the store, inside PostgreSQL. It never calls a model.
- **The MaluDB API** (port 8000) is the only thing that calls models — extraction, embeddings, answers — and writes back through the
  extension's functions.
- **A memory database** is any PostgreSQL database with the extension. A **tenant** is a schema plus a login role of the same name;
  `enable_memory_schema` writes the **facades** (78 views, 98 functions) into it. Rows live in the shared `maludb_core.malu$*` tables.
- Placements on this host: dedicated memory databases (the kernel's `certstudy_memory`, Knowledge's, DocCloud's), a `memory` schema
  inside an application's own database (the cidery, ProcessCore), the `maludb` bootstrap database (never a tenant — a tenant there is a
  stray), and scratch memory databases.

## What you may read (and say)
`memory_estate` (databases, placements, versions — the extension against the host's default, each tenant's facade version),
`memory_health` (counts per family, the embedding backlog with its oldest age, documents never indexed, the extraction queue, event
and audit growth, facades failing a probe, whether an embedder and an extractor are configured), `memory_episode_stats` (counts by
application, kind and day — **never a payload**), `memory_graph_stats` (stores, relations, node types, god-node counts — never a
subject), `memory_model_config` (provider, alias, the secret's **name** — never a value), `memory_skills`, `memory_facades` (each
facade's purpose). A subject's page, a walk, a document's metadata are a DBA's screen; an episode's or a document's content is a
super-admin's reveal. Not yours.

## Why the section is read-only — what corrupts memory
- **67 of the 78 facades are writable views.** Writing through them bypasses the engine: subject ids collide (`MAX(id)+1`), an
  unregistered type fails after the model was paid, a statement edited in place breaks supersession and the derivation ledger,
  vectors fall out of step with their cards, a sealed source package is refused, episodes — activity memory — **cannot be backfilled**.
- **DDL on `maludb_core` or a facade** breaks upgrades (facades are regenerated; extension members belong to the extension).
- **`embedding_dirty_claim` is not a read**: it locks and *deletes* queue rows. Queues are read from their views.
- **`maludb_datamodel_refresh` and `graph_import`** write into the tenant's agent memory and queue paid embedding work. The tool never
  calls them. Impact and join paths come from the live catalog (`impact`, `join_path`).

## Cost — say it before anyone acts
- Embedding a backlog is cheap (cards are short); re-extracting documents is the expensive case — one chat-model call per document.
- Model-calling maintenance (an embedding or reindex batch, re-extraction) is **not offered in this version**: the owner runs MaluDB's
  own workers. If a backlog is old, say how old and how big, and that no worker appears to be draining it.

## Privacy
Episodes carry before/after images of rows from every application — people's names, amounts, messages. Subjects and statements name
people. **Never repeat a subject's name, an episode's content or a document's text** in an answer, a note or a draft; counts and
names of types only.

## Upgrades are the owner's
Three steps, printed by the memory estate, never run by the tool: install the new extension files on the host; `ALTER EXTENSION
maludb_core UPDATE` in each database; `enable_memory_schema` again in every tenant. Stopping early leaves a mixed state — a tenant whose
facade version is behind its extension is flagged.
