-- 010: WORKBENCHES, CHANGE SETS, REHEARSALS, MIGRATION DRAFTS AND BEFORE-IMAGES (design §6.5, §6.6; D4, D5).
--
-- A workbench is a database dxw_<n> and its own login role dxw_<n>, made by the door's composed lifecycle (developer_rolemaker) — its
-- row here is the tool's record; its target_databases row (class workbench) is what the door reaches. People own workbenches; agents
-- have none in v1 (design §5). A change set is an ordered list of statements for one target with its origin, author and state; THE
-- TRIGGER BELOW IS ITS SECOND WALL (the door and the screens the first): a change set is APPLIED only to a workbench by its owner holding
-- workbench.apply, or to an installed application's database as row edits (origin grid, every item DML) by a person holding data.write
-- inside their own open write window — never by an agent, never anywhere else; it becomes a MIGRATION DRAFT only for an installed
-- application's database, and only once rehearsed. Before-images (row_images) keep every row an applied change set touched, keyed by
-- identity, for undo while no later change touched it (checked by xmin, by the door), undo_days.
--
-- THE ESTATE'S DATA MODEL (design §6.11): every table here is NEW CANONICAL — no change set, workbench or migration draft exists anywhere
-- in the estate.
BEGIN;

CREATE TABLE workbenches (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint UNIQUE REFERENCES target_databases(id) ON DELETE SET NULL,   -- its registry row (class workbench), once created
    datname            text NOT NULL UNIQUE CHECK (datname ~ '^dxw_[0-9]+$'),
    role_name          text NOT NULL UNIQUE CHECK (role_name ~ '^dxw_[0-9]+$'),
    owner_member_id    bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    title              text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    kind               text NOT NULL CHECK (kind IN ('empty', 'clone')),
    source_target_id   bigint REFERENCES target_databases(id) ON DELETE SET NULL,          -- what it was cloned from
    cloned_at          timestamptz,
    status             text NOT NULL DEFAULT 'creating' CHECK (status IN ('creating', 'ready', 'failed', 'dropped')),
    error              text CHECK (error IS NULL OR length(error) <= 2000),
    quota_bytes        bigint NOT NULL CHECK (quota_bytes > 0),
    size_bytes         bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
    size_checked_at    timestamptz,
    suspended_at       timestamptz,                                                        -- over quota: CONNECT suspended until it shrinks
    expires_at         timestamptz NOT NULL,
    warned_at          timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    dropped_at         timestamptz,
    dropped_by_kind    text CHECK (dropped_by_kind IN ('owner', 'expiry', 'admin', 'failed')),
    CHECK (role_name = datname),
    CHECK (kind = 'empty' OR source_target_id IS NOT NULL OR cloned_at IS NOT NULL),           -- a clone names its source (or when)
    CHECK ((status = 'dropped') = (dropped_at IS NOT NULL))
);
CREATE INDEX workbenches_owner_idx ON workbenches (owner_member_id) WHERE dropped_at IS NULL;
CREATE INDEX workbenches_expiry_idx ON workbenches (expires_at) WHERE dropped_at IS NULL;

-- A workbench is a person's (agents have none in v1), within the per-person count.
CREATE OR REPLACE FUNCTION dx_workbenches_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE kind text; n integer; cap integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT m.member_kind INTO kind FROM members m WHERE m.id = NEW.owner_member_id;
        IF kind IS DISTINCT FROM 'human' THEN
            RAISE EXCEPTION 'A workbench is a person''s: agents have none (design §5)' USING ERRCODE = 'check_violation';
        END IF;
        SELECT count(*) INTO n FROM workbenches w WHERE w.owner_member_id = NEW.owner_member_id AND w.dropped_at IS NULL;
        SELECT workbenches_per_person INTO cap FROM dx_settings WHERE id = 1;
        IF n >= cap THEN
            RAISE EXCEPTION 'You already have % workbenches (the most a person may keep)', cap USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER workbenches_before BEFORE INSERT ON workbenches FOR EACH ROW EXECUTE FUNCTION dx_workbenches_before();

-- ------------------------------------------------------------------------------------------------- change sets
CREATE TABLE change_sets (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    origin             text NOT NULL CHECK (origin IN ('form', 'grid', 'editor', 'health_fix', 'agent_proposal', 'workbench_export', 'compare', 'import')),
    author_member_id   bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    author_is_agent    boolean NOT NULL DEFAULT false,                         -- set by the trigger from the mirror — marked wherever it appears
    title              text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    state              text NOT NULL DEFAULT 'draft'
                       CHECK (state IN ('draft', 'reviewed', 'rehearsed', 'applied', 'drafted_as_migration', 'discarded', 'failed')),
    row_count          integer CHECK (row_count IS NULL OR row_count >= 0),     -- rows the change set's edits touch (grid, import)
    typed_count        integer,                                                 -- the count the person typed back above the confirm cap
    lint_summary       jsonb NOT NULL DEFAULT '{}'::jsonb,                      -- {errors, warnings, overrides: [{rule, reason, member_id}]}
    reviewed_at        timestamptz,
    rehearsed_at       timestamptz,
    applied_at         timestamptz,
    applied_by         bigint REFERENCES members(id) ON DELETE SET NULL,
    window_id          bigint REFERENCES access_windows(id) ON DELETE SET NULL,
    discarded_at       timestamptz,
    failed_at          timestamptz,
    failure            text CHECK (failure IS NULL OR length(failure) <= 2000),
    undo_state         text NOT NULL DEFAULT 'none' CHECK (undo_state IN ('none', 'available', 'used', 'expired', 'blocked')),
    undo_of            bigint REFERENCES change_sets(id) ON DELETE SET NULL,      -- this change set undoes that one
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CHECK ((state = 'applied') = (applied_at IS NOT NULL)),
    CHECK (state <> 'applied' OR applied_by IS NOT NULL)
);
CREATE INDEX change_sets_target_idx ON change_sets (target_database_id, created_at DESC);
CREATE INDEX change_sets_author_idx ON change_sets (author_member_id, created_at DESC);
CREATE INDEX change_sets_open_idx ON change_sets (state) WHERE state IN ('draft', 'reviewed', 'rehearsed');
CREATE TRIGGER change_sets_touch BEFORE UPDATE ON change_sets FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE change_set_items (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_set_id      bigint NOT NULL REFERENCES change_sets(id) ON DELETE CASCADE,
    position           integer NOT NULL CHECK (position >= 1),
    statement          text NOT NULL CHECK (length(statement) BETWEEN 1 AND 100000),
    class              text NOT NULL CHECK (class IN ('read', 'dml', 'ddl', 'tx', 'utility', 'dcl')),
    annotations        jsonb NOT NULL DEFAULT '[]'::jsonb,                     -- per relation: {relation, lock, rewrite, scan, in_tx, size_bytes, rows}
    lock_source        text NOT NULL DEFAULT 'rule_table' CHECK (lock_source IN ('rule_table', 'measured', 'unknown')),
    lint               jsonb NOT NULL DEFAULT '[]'::jsonb,                     -- squawk's findings for this statement
    literals           jsonb NOT NULL DEFAULT '[]'::jsonb,                     -- every string literal and comment text (listed on review)
    rehearsal          jsonb,                                                  -- what the rehearsal measured for it
    status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ok', 'failed', 'skipped')),
    sqlstate           text CHECK (sqlstate IS NULL OR sqlstate ~ '^[0-9A-Z]{5}$'),
    error_masked       text CHECK (error_masked IS NULL OR length(error_masked) <= 500),
    rows_affected      bigint,
    ms                 integer,
    UNIQUE (change_set_id, position)
);

-- THE SECOND WALL on a change set's state (design §6.5, §6.6): the transitions, and who may apply what where. The acting member is
-- app.member_id (PHP sets it; the door applies on its behalf and sets the state through developer_rw).
CREATE OR REPLACE FUNCTION dx_change_sets_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t target_databases%ROWTYPE; who members%ROWTYPE; wb workbenches%ROWTYPE; w access_windows%ROWTYPE; non_dml integer; ok_from text[];
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.author_is_agent := EXISTS (SELECT 1 FROM members m WHERE m.id = NEW.author_member_id AND m.member_kind = 'agent');
        IF NEW.state NOT IN ('draft', 'reviewed') THEN
            RAISE EXCEPTION 'A change set starts as a draft' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.author_is_agent AND NEW.origin NOT IN ('agent_proposal', 'health_fix') THEN
            RAISE EXCEPTION 'An agent''s change set is a proposal' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.state = OLD.state THEN RETURN NEW; END IF;
    ok_from := CASE NEW.state
                 WHEN 'reviewed' THEN ARRAY['draft']
                 WHEN 'rehearsed' THEN ARRAY['draft', 'reviewed', 'rehearsed']
                 WHEN 'applied' THEN ARRAY['reviewed', 'rehearsed']
                 WHEN 'drafted_as_migration' THEN ARRAY['rehearsed']
                 WHEN 'discarded' THEN ARRAY['draft', 'reviewed', 'rehearsed', 'failed']
                 WHEN 'failed' THEN ARRAY['reviewed', 'rehearsed']
                 ELSE '{}'::text[] END;
    IF NOT (OLD.state = ANY (ok_from)) THEN
        RAISE EXCEPTION 'A change set goes from % to %? No.', OLD.state, NEW.state USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO t FROM target_databases WHERE id = NEW.target_database_id;
    IF NEW.state = 'applied' THEN
        SELECT * INTO who FROM members WHERE id = NEW.applied_by;
        IF who.member_kind IS DISTINCT FROM 'human' OR who.status <> 'active' THEN
            RAISE EXCEPTION 'Only a person applies a change set: an agent never does (design §5)' USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF NEW.applied_by IS DISTINCT FROM app_current_member_id() THEN
            RAISE EXCEPTION 'A change set is applied by the person acting' USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF (SELECT frozen FROM dx_settings WHERE id = 1) THEN
            RAISE EXCEPTION 'Developer is frozen: nothing is applied' USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF t.class = 'workbench' THEN
            SELECT * INTO wb FROM workbenches WHERE target_database_id = t.id AND dropped_at IS NULL;
            IF wb.owner_member_id IS DISTINCT FROM NEW.applied_by OR NOT dx_member_has_right(NEW.applied_by, 'workbench.apply') THEN
                RAISE EXCEPTION 'A workbench''s changes are applied by its owner holding workbench.apply' USING ERRCODE = 'insufficient_privilege';
            END IF;
        ELSIF t.class = 'application' THEN
            SELECT count(*) INTO non_dml FROM change_set_items i WHERE i.change_set_id = NEW.id AND i.class <> 'dml';
            IF NEW.origin NOT IN ('grid') OR non_dml > 0 THEN
                RAISE EXCEPTION 'An installed application''s database takes only row edits from the grid; anything else is a migration draft (D4)'
                    USING ERRCODE = 'check_violation';
            END IF;
            IF NOT dx_member_has_right(NEW.applied_by, 'data.write') THEN
                RAISE EXCEPTION 'Applying row changes is a holder of data.write''s (a DBA)' USING ERRCODE = 'insufficient_privilege';
            END IF;
            SELECT * INTO w FROM access_windows WHERE id = NEW.window_id;
            IF w.id IS NULL OR w.member_id <> NEW.applied_by OR w.target_database_id <> t.id OR w.mode <> 'write' OR w.status <> 'open' OR w.expires_at <= now() THEN
                RAISE EXCEPTION 'Row changes are applied inside your own open write window on this database' USING ERRCODE = 'insufficient_privilege';
            END IF;
            IF NEW.row_count IS NOT NULL AND NEW.row_count > (SELECT change_set_max_rows FROM dx_settings WHERE id = 1) THEN
                RAISE EXCEPTION 'More rows than a change set may touch: that is a migration (D5)' USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.row_count IS NOT NULL AND NEW.row_count > (SELECT change_set_confirm_rows FROM dx_settings WHERE id = 1)
               AND NEW.typed_count IS DISTINCT FROM NEW.row_count THEN
                RAISE EXCEPTION 'Above the confirm cap the count is typed back exactly' USING ERRCODE = 'check_violation';
            END IF;
        ELSE
            RAISE EXCEPTION 'Nothing is applied to a % database through Developer', t.class USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF NEW.state = 'drafted_as_migration' AND t.class <> 'application' THEN
        RAISE EXCEPTION 'A migration draft is for an installed application''s database' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER change_sets_before BEFORE INSERT OR UPDATE ON change_sets FOR EACH ROW EXECUTE FUNCTION dx_change_sets_before();

-- ------------------------------------------------------------------------------------------------- rehearsals
CREATE TABLE rehearsals (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_set_id      bigint NOT NULL REFERENCES change_sets(id) ON DELETE CASCADE,
    clone_datname      text NOT NULL CHECK (clone_datname ~ '^dxr_[0-9]+$'),
    source_target_id   bigint REFERENCES target_databases(id) ON DELETE SET NULL,
    requested_by       bigint REFERENCES members(id) ON DELETE SET NULL,
    status             text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'failed')),
    results            jsonb NOT NULL DEFAULT '[]'::jsonb,                     -- per statement: {position, locks: [...], rewrote, ms, error, lock_source}
    error              text CHECK (error IS NULL OR length(error) <= 2000),
    started_at         timestamptz NOT NULL DEFAULT now(),
    finished_at        timestamptz,
    clone_dropped_at   timestamptz
);
CREATE INDEX rehearsals_change_set_idx ON rehearsals (change_set_id, started_at DESC);

-- ------------------------------------------------------------------------------------------------- migration drafts
CREATE TABLE migration_drafts (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_set_id      bigint NOT NULL UNIQUE REFERENCES change_sets(id) ON DELETE CASCADE,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    application_key    text NOT NULL CHECK (application_key ~ '^[a-z][a-z0-9_]{1,31}$'),
    file_number        integer CHECK (file_number IS NULL OR file_number BETWEEN 1 AND 9999),   -- the application's next; typed when unknown
    slug               text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9_]{0,59}$'),
    file_name          text GENERATED ALWAYS AS (CASE WHEN file_number IS NULL THEN 'NNN_' || slug || '.sql'
                                                      ELSE lpad(file_number::text, 3, '0') || '_' || slug || '.sql' END) STORED,
    body               text NOT NULL CHECK (length(body) BETWEEN 1 AND 500000),              -- the header comment + the statements + a verify query
    sql_sha256         text NOT NULL CHECK (sql_sha256 ~ '^[0-9a-f]{64}$'),
    agent_authored     boolean NOT NULL DEFAULT false,                                     -- marked in its header and everywhere it appears
    literal_flags      jsonb NOT NULL DEFAULT '[]'::jsonb,                                 -- literals and comments over 40 characters, flagged
    state              text NOT NULL DEFAULT 'drafted' CHECK (state IN ('drafted', 'downloaded', 'observed_applied', 'abandoned')),
    downloaded_at      timestamptz,
    observed_at        timestamptz,
    observed_snapshot_id bigint REFERENCES catalog_snapshots(id) ON DELETE SET NULL,
    created_by         bigint REFERENCES members(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK ((state = 'observed_applied') = (observed_at IS NOT NULL))
);
CREATE INDEX migration_drafts_app_idx ON migration_drafts (application_key, created_at DESC);
CREATE INDEX migration_drafts_pending_idx ON migration_drafts (target_database_id) WHERE state IN ('drafted', 'downloaded');

-- ------------------------------------------------------------------------------------------------- before-images (undo)
CREATE TABLE row_images (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_set_id      bigint NOT NULL REFERENCES change_sets(id) ON DELETE CASCADE,
    item_id            bigint REFERENCES change_set_items(id) ON DELETE CASCADE,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    schema_name        text NOT NULL,
    relation_name      text NOT NULL,
    operation          text NOT NULL CHECK (operation IN ('insert', 'update', 'delete')),
    identity           jsonb NOT NULL,                                                     -- the row's identity (primary or NOT NULL unique key)
    xmin_before        text,
    xmin_after         text,
    before             jsonb,                                                              -- the readable columns as they were (never a secret column)
    after              jsonb,
    created_at         timestamptz NOT NULL DEFAULT now(),
    undone_at          timestamptz,
    undo_change_set_id bigint REFERENCES change_sets(id) ON DELETE SET NULL,
    CHECK (operation = 'insert' OR before IS NOT NULL)
);
CREATE INDEX row_images_change_set_idx ON row_images (change_set_id);
CREATE INDEX row_images_time_idx ON row_images (created_at);

-- The worker's undo window: before-images past undo_days dropped and their change sets' undo expired.
CREATE OR REPLACE FUNCTION dx_row_images_prune() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer; d integer;
BEGIN
    SELECT undo_days INTO d FROM dx_settings WHERE id = 1;
    UPDATE change_sets SET undo_state = 'expired' WHERE undo_state = 'available' AND applied_at < now() - make_interval(days => d);
    DELETE FROM row_images WHERE created_at < now() - make_interval(days => d);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

GRANT SELECT, INSERT, UPDATE ON workbenches, change_sets, change_set_items, rehearsals, migration_drafts, row_images TO developer_rw;
REVOKE ALL ON FUNCTION dx_row_images_prune() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dx_row_images_prune() TO developer_rw;

COMMIT;
