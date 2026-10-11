-- 007: THE CATALOG INDEX AND SNAPSHOTS (design §6.2, §6.7). Both are written by the worker from the door's named catalog queries (the door
-- reads a target's pg_catalog as developer_meta; nothing here ever connects to a target).
--
-- catalog_index is a CACHE for search across databases (R4): every object of a registered target by its address
-- (pg_identify_object_as_address: type, names, args), with its family, schema, name, owner, comment, extension and — for relations — its
-- columns, trigram-searched. An object's page always reads the live catalog. catalog_snapshots / snapshot_objects keep, nightly, each
-- object's normalized-DDL hash (the text kept snapshot_ddl_days): an object's DDL history, "what changed since …", drift, and the
-- applied-draft check (design §6.5).
--
-- THE ESTATE'S DATA MODEL (design §6.11): NEW CANONICAL — no catalog of database objects exists anywhere in the estate (the Data Lake's
-- `datasets` / `schema_versions` describe lake datasets, a different concept).
BEGIN;

CREATE TABLE catalog_index (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    obj_type           text NOT NULL,                        -- pg_identify_object_as_address(): type ('table', 'view', 'function', 'index', …)
    obj_names          text[] NOT NULL,                      --   object_names
    obj_args           text[] NOT NULL DEFAULT '{}',          --   object_args (a routine's argument types)
    family             text NOT NULL,                        -- the browser's family: table, view, matview, sequence, function, procedure, …
    schema_name        text,
    name               text NOT NULL,
    owner_name         text,
    comment            text,                                 -- cut to 2,000 characters
    extension_name     text,                                 -- an extension member (read-only, design §6.3)
    is_system          boolean NOT NULL DEFAULT false,       -- pg_catalog, information_schema, pg_toast*
    columns            jsonb NOT NULL DEFAULT '[]'::jsonb,   -- relations: [{name, type}] — never a value
    search_text        text NOT NULL DEFAULT '',             -- name, schema, comment and column names, lower-cased, for trigram search
    indexed_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (target_database_id, obj_type, obj_names, obj_args)
);
CREATE INDEX catalog_index_search_idx ON catalog_index USING gin (search_text gin_trgm_ops);
CREATE INDEX catalog_index_name_idx ON catalog_index USING gin (name gin_trgm_ops);
CREATE INDEX catalog_index_family_idx ON catalog_index (target_database_id, family, schema_name);

-- One pass of the index for a target: what the worker last did (how many, how long, an error).
CREATE TABLE catalog_index_passes (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    started_at         timestamptz NOT NULL DEFAULT now(),
    finished_at        timestamptz,
    objects            integer NOT NULL DEFAULT 0,
    columns            integer NOT NULL DEFAULT 0,
    proposals          integer NOT NULL DEFAULT 0,           -- classifier proposals made in this pass (db/008)
    error              text CHECK (error IS NULL OR length(error) <= 2000)
);
CREATE INDEX catalog_index_passes_target_idx ON catalog_index_passes (target_database_id, started_at DESC);

CREATE TABLE catalog_snapshots (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    taken_at           timestamptz NOT NULL DEFAULT now(),
    status             text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'failed')),
    object_count       integer NOT NULL DEFAULT 0,
    changed_count      integer NOT NULL DEFAULT 0,          -- against the previous snapshot
    unexplained_count  integer NOT NULL DEFAULT 0,          -- changes no change set, draft or grants pass explains (drift)
    error              text CHECK (error IS NULL OR length(error) <= 2000)
);
CREATE INDEX catalog_snapshots_target_idx ON catalog_snapshots (target_database_id, taken_at DESC);

CREATE TABLE snapshot_objects (
    snapshot_id        bigint NOT NULL REFERENCES catalog_snapshots(id) ON DELETE CASCADE,
    obj_type           text NOT NULL,
    obj_names          text[] NOT NULL,
    obj_args           text[] NOT NULL DEFAULT '{}',
    ddl_sha256         text NOT NULL CHECK (ddl_sha256 ~ '^[0-9a-f]{64}$'),
    ddl                text,                                 -- nulled after snapshot_ddl_days
    change             text CHECK (change IN ('added', 'changed', 'removed', 'same')),
    explained_by       text CHECK (explained_by IN ('change_set', 'migration_draft', 'grants', 'none')),
    explained_ref      bigint,                               -- the change set or draft that explains it
    PRIMARY KEY (snapshot_id, obj_type, obj_names, obj_args)
);

-- An object's DDL history across snapshots, newest first (the object page's History tab; object_history).
CREATE OR REPLACE FUNCTION dx_object_history(p_target bigint, p_type text, p_names text[], p_args text[] DEFAULT '{}', p_limit integer DEFAULT 50)
    RETURNS TABLE (taken_at timestamptz, ddl_sha256 text, change text, explained_by text, explained_ref bigint, has_text boolean)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT s.taken_at, o.ddl_sha256, o.change, o.explained_by, o.explained_ref, o.ddl IS NOT NULL
      FROM snapshot_objects o JOIN catalog_snapshots s ON s.id = o.snapshot_id
     WHERE s.target_database_id = p_target AND s.status = 'ok' AND o.obj_type = p_type AND o.obj_names = p_names AND o.obj_args = p_args
     ORDER BY s.taken_at DESC LIMIT LEAST(GREATEST(p_limit, 1), 500);
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON catalog_index, catalog_index_passes, catalog_snapshots, snapshot_objects TO developer_rw;
GRANT EXECUTE ON FUNCTION dx_object_history(bigint, text, text[], text[], integer) TO developer_rw, developer_records_ro;

COMMIT;
