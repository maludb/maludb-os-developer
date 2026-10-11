-- 009: THE AUDIT OF EVERY STATEMENT, SAVED QUERIES AND KEPT PLANS (design §6.1 step 7, §6.4, §6.7, §6.10; D14).
--
-- query_runs is ONE ROW PER REQUEST through the door (refusals and timeouts included), OPENED as the request starts (dx_door_run_open)
-- and CLOSED on every way out (dx_door_run_close); door_statements is its PER-STATEMENT child — an intent row (status running) written
-- before a statement runs, completed after (dx_door_statement_log). The door's NAMED catalog, statistics and activity queries are
-- counted per caller per day in door_usage (dx_door_usage_bump), not rowed — except the memory section's content queries (source
-- memory), which are runs. The SQL text is kept sql_text_days then nulled, the rows audit_keep_days. AN ERROR REACHES THESE TABLES
-- MASKED (quoted fragments and key values → •••; the door masks it) — the person who ran it saw it whole, once. The activity log never
-- holds SQL or a value. The door writes all of this as developer_meta through these SECURITY DEFINER functions (deploy/own-database.sql
-- grants their EXECUTE); it reads no application table here.
--
-- THE ESTATE'S DATA MODEL (design §6.11):
--   * `query_runs` — the Data Lake db/011 VERBATIM (one row per request), APPENDING target_database_id, datname, request_kind, tier,
--     level, window_id, change_set_id, rehearsal_id; `source` widened with grid, form, editor, worker, rehearsal, memory, and `status`
--     widened with 'running' (a request opened and not yet closed) — two enumerations widened, the shared-schema rule's allowed change.
--     The lake's columns (datasets, dataset_ids, metric_id, columns_read, masked_columns, row_filters, consumer_app, key_label, as_of)
--     stay, unused.
--   * `saved_queries` — the Data Lake db/011 VERBATIM (verified, the badge dropping by itself when the SQL changes), APPENDING
--     target_database_id; an agent's are private (the trigger below).
--   * `door_statements`, `door_usage`, `explain_plans` — NEW.
BEGIN;

CREATE TABLE query_runs (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    caller_member_id bigint NOT NULL,                                       -- no FK: the audit outlives a member
    on_behalf_of     bigint,                                                -- the person an agent acted for (K38)
    agent_run_id     bigint,
    request_id       text,
    source           text NOT NULL CHECK (source IN ('screen', 'preview', 'mcp', 'agent', 'api', 'k7', 'export', 'transform',
                                                     'grid', 'form', 'editor', 'worker', 'rehearsal', 'memory')),   -- widened (design §6.10)
    consumer_app     text,
    key_label        text,
    saved_query_id   bigint,
    metric_id        bigint,
    sql_sha256       text NOT NULL CHECK (sql_sha256 ~ '^[0-9a-f]{64}$'),
    sql              text,                                                  -- nulled after sql_text_days
    as_of            text,
    datasets         text[] NOT NULL DEFAULT '{}',
    dataset_ids      bigint[] NOT NULL DEFAULT '{}',
    columns_read     jsonb NOT NULL DEFAULT '{}'::jsonb,
    masked_columns   jsonb NOT NULL DEFAULT '{}'::jsonb,
    row_filters      jsonb NOT NULL DEFAULT '{}'::jsonb,
    rows_returned    bigint NOT NULL DEFAULT 0 CHECK (rows_returned >= 0),
    truncated        boolean NOT NULL DEFAULT false,
    bytes_returned   bigint NOT NULL DEFAULT 0 CHECK (bytes_returned >= 0),
    ms               integer NOT NULL DEFAULT 0 CHECK (ms >= 0),
    status           text NOT NULL CHECK (status IN ('ok', 'refused', 'timeout', 'error', 'cancelled', 'running')),       -- 'running' widened
    refusal_rule     text,
    error            text CHECK (error IS NULL OR length(error) <= 500),    -- masked
    worker           text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    -- appended (design §6.10)
    target_database_id bigint,                                              -- no FK: the audit outlives a registration
    datname          text,
    request_kind     text CHECK (request_kind IN ('run', 'explain', 'apply', 'named', 'cancel', 'clone', 'rehearse', 'snapshot', 'export', 'maintain', 'memory')),
    tier             text CHECK (tier IN ('meta', 'read_masked', 'read', 'write', 'workbench', 'ops', 'memory', 'rolemaker')),
    level            text CHECK (level IN ('none', 'structure', 'masked', 'rows')),
    window_id        bigint,
    change_set_id    bigint,
    rehearsal_id     bigint,
    finished_at      timestamptz
);
CREATE INDEX query_runs_caller_idx ON query_runs (caller_member_id, created_at DESC);
CREATE INDEX query_runs_behalf_idx ON query_runs (on_behalf_of, created_at DESC) WHERE on_behalf_of IS NOT NULL;
CREATE INDEX query_runs_time_idx ON query_runs (created_at);
CREATE INDEX query_runs_status_idx ON query_runs (status, created_at DESC) WHERE status <> 'ok';
CREATE INDEX query_runs_agent_run_idx ON query_runs (agent_run_id) WHERE agent_run_id IS NOT NULL;
CREATE INDEX query_runs_target_idx ON query_runs (target_database_id, created_at DESC) WHERE target_database_id IS NOT NULL;
CREATE INDEX query_runs_change_set_idx ON query_runs (change_set_id) WHERE change_set_id IS NOT NULL;

CREATE TABLE door_statements (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    query_run_id     bigint NOT NULL REFERENCES query_runs(id) ON DELETE CASCADE,
    statement_index  integer NOT NULL CHECK (statement_index >= 0),
    class            text NOT NULL CHECK (class IN ('read', 'dml', 'ddl', 'tx', 'utility', 'dcl', 'refused')),
    tier             text CHECK (tier IN ('meta', 'read_masked', 'read', 'write', 'workbench', 'ops', 'memory', 'rolemaker')),
    fingerprint      text,                                                  -- libpg_query's normalized fingerprint
    status           text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'error', 'refused', 'timeout', 'cancelled')),
    sqlstate         text CHECK (sqlstate IS NULL OR sqlstate ~ '^[0-9A-Z]{5}$'),
    rows_affected    bigint CHECK (rows_affected IS NULL OR rows_affected >= 0),
    ms               integer CHECK (ms IS NULL OR ms >= 0),
    backend_pid      integer,
    error_masked     text CHECK (error_masked IS NULL OR length(error_masked) <= 500),
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    UNIQUE (query_run_id, statement_index)
);
CREATE INDEX door_statements_running_idx ON door_statements (started_at) WHERE status = 'running';

CREATE TABLE door_usage (
    day         date NOT NULL DEFAULT current_date,
    member_id   bigint NOT NULL,                                            -- no FK: counts outlive a member
    kind        text NOT NULL CHECK (kind ~ '^(named|memory):[a-z0-9_]{1,60}$'),
    calls       integer NOT NULL DEFAULT 0 CHECK (calls >= 0),
    PRIMARY KEY (day, member_id, kind)
);

-- ------------------------------------------------------------------------------------------------- the door's audit functions
-- Open a request's row (refusals included). {request_id, caller, on_behalf_of, agent_run_id, source, datname, kind, sql_sha256, sql}
CREATE OR REPLACE FUNCTION dx_door_run_open(p jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid bigint; tid bigint; sqltext text := p ->> 'sql';
BEGIN
    SELECT t.id INTO tid FROM target_databases t WHERE t.datname = p ->> 'datname';
    INSERT INTO query_runs (caller_member_id, on_behalf_of, agent_run_id, request_id, source, sql_sha256, sql, status, target_database_id, datname, request_kind,
                            saved_query_id, change_set_id, rehearsal_id)
    VALUES ((p ->> 'caller')::bigint, (p ->> 'on_behalf_of')::bigint, (p ->> 'agent_run_id')::bigint, p ->> 'request_id',
            COALESCE(p ->> 'source', 'screen'),
            COALESCE(p ->> 'sql_sha256', encode(sha256(convert_to(COALESCE(sqltext, ''), 'UTF8')), 'hex')),
            sqltext, 'running', tid, p ->> 'datname', p ->> 'kind',
            (p ->> 'saved_query_id')::bigint, (p ->> 'change_set_id')::bigint, (p ->> 'rehearsal_id')::bigint)
    RETURNING id INTO rid;
    RETURN rid;
END$$;

-- Close a request. {status, refusal_rule, tier, level, rows_returned, truncated, ms, error (masked), bytes_returned, window_id}
CREATE OR REPLACE FUNCTION dx_door_run_close(p_run bigint, p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE query_runs
       SET status = COALESCE(p ->> 'status', 'error'), refusal_rule = p ->> 'refusal_rule', tier = p ->> 'tier', level = p ->> 'level',
           rows_returned = COALESCE((p ->> 'rows_returned')::bigint, 0), truncated = COALESCE((p ->> 'truncated')::boolean, false),
           bytes_returned = COALESCE((p ->> 'bytes_returned')::bigint, 0), ms = COALESCE((p ->> 'ms')::integer, 0),
           error = left(p ->> 'error', 500), window_id = COALESCE((p ->> 'window_id')::bigint, window_id), finished_at = now()
     WHERE id = p_run AND status = 'running';
    IF NOT FOUND THEN RAISE EXCEPTION 'No open run %', p_run USING ERRCODE = 'no_data_found'; END IF;
END$$;

-- A statement's intent (no "id": INSERT, status running) or its result (with "id": UPDATE). Returns the row's id.
--   insert {run_id, statement_index, class, tier, fingerprint, status:"running"}
--   update {id, status, sqlstate, rows_affected, ms, backend_pid, error_masked}
CREATE OR REPLACE FUNCTION dx_door_statement_log(p jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid bigint;
BEGIN
    IF p ? 'id' THEN
        UPDATE door_statements
           SET status = COALESCE(p ->> 'status', 'error'), sqlstate = p ->> 'sqlstate', rows_affected = (p ->> 'rows_affected')::bigint,
               ms = (p ->> 'ms')::integer, backend_pid = (p ->> 'backend_pid')::integer, error_masked = left(p ->> 'error_masked', 500), finished_at = now()
         WHERE id = (p ->> 'id')::bigint AND status = 'running'
        RETURNING id INTO rid;
        IF rid IS NULL THEN RAISE EXCEPTION 'No running statement %', p ->> 'id' USING ERRCODE = 'no_data_found'; END IF;
        RETURN rid;
    END IF;
    INSERT INTO door_statements (query_run_id, statement_index, class, tier, fingerprint, status, backend_pid)
    VALUES ((p ->> 'run_id')::bigint, (p ->> 'statement_index')::integer, p ->> 'class', p ->> 'tier', p ->> 'fingerprint',
            COALESCE(p ->> 'status', 'running'), (p ->> 'backend_pid')::integer)
    RETURNING id INTO rid;
    RETURN rid;
END$$;

-- A named query counted, not rowed ('named:<name>' | 'memory:<name>').
CREATE OR REPLACE FUNCTION dx_door_usage_bump(p_caller bigint, p_kind text) RETURNS void
    LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    INSERT INTO door_usage (day, member_id, kind, calls) VALUES (current_date, p_caller, p_kind, 1)
    ON CONFLICT (day, member_id, kind) DO UPDATE SET calls = door_usage.calls + 1;
$$;

-- The windows of D14: the SQL text after sql_text_days, the rows after audit_keep_days; a run left 'running' by a crashed door for an
-- hour is closed as 'error' (the worker's retention pass).
CREATE OR REPLACE FUNCTION dx_query_runs_prune() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s dx_settings%ROWTYPE; a integer; b integer; c integer; d integer;
BEGIN
    SELECT * INTO s FROM dx_settings WHERE id = 1;
    UPDATE query_runs SET status = 'error', error = 'the door stopped before closing the run', finished_at = now()
     WHERE status = 'running' AND created_at < now() - interval '1 hour';
    GET DIAGNOSTICS a = ROW_COUNT;
    UPDATE door_statements SET status = 'error', error_masked = 'the door stopped before the statement finished', finished_at = now()
     WHERE status = 'running' AND started_at < now() - interval '1 hour';
    UPDATE query_runs SET sql = NULL WHERE sql IS NOT NULL AND created_at < now() - make_interval(days => s.sql_text_days);
    GET DIAGNOSTICS b = ROW_COUNT;
    DELETE FROM query_runs WHERE created_at < now() - make_interval(days => s.audit_keep_days);
    GET DIAGNOSTICS c = ROW_COUNT;
    DELETE FROM door_usage WHERE day < current_date - s.audit_keep_days;
    GET DIAGNOSTICS d = ROW_COUNT;
    RETURN a + b + c + d;
END$$;

-- ------------------------------------------------------------------------------------------------- saved queries (Data Lake db/011)
CREATE TABLE saved_queries (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_member_id      bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    title                text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description          text,
    question             text,
    sql                  text NOT NULL CHECK (length(sql) BETWEEN 1 AND 20000),
    sql_sha256           text NOT NULL DEFAULT '',
    parameters           jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(parameters) = 'array'),
    dataset_ids          bigint[] NOT NULL DEFAULT '{}',
    shared               boolean NOT NULL DEFAULT false,
    verified_by          bigint REFERENCES members(id) ON DELETE SET NULL,
    verified_at          timestamptz,
    verified_sql_sha256  text,
    unverified_reason    text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    deleted_at           timestamptz,
    -- appended (design §6.4): the database a saved query was written for (NULL = any)
    target_database_id   bigint REFERENCES target_databases(id) ON DELETE SET NULL,
    CHECK ((verified_at IS NULL) = (verified_sql_sha256 IS NULL))
);
CREATE INDEX saved_queries_owner_idx ON saved_queries (owner_member_id) WHERE deleted_at IS NULL;
CREATE INDEX saved_queries_verified_idx ON saved_queries (verified_at) WHERE verified_at IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX saved_queries_title_trgm_idx ON saved_queries USING gin (title gin_trgm_ops);
CREATE TRIGGER saved_queries_touch BEFORE UPDATE ON saved_queries FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE OR REPLACE FUNCTION dx_saved_queries_before() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    NEW.sql_sha256 := encode(sha256(convert_to(NEW.sql, 'UTF8')), 'hex');
    IF NEW.verified_at IS NOT NULL AND NEW.verified_sql_sha256 IS DISTINCT FROM NEW.sql_sha256 THEN
        NEW.verified_at := NULL; NEW.verified_by := NULL; NEW.verified_sql_sha256 := NULL;
        NEW.unverified_reason := 'the SQL changed after it was verified';
    END IF;
    -- an agent's saved queries are private (design §5: a shared query is a channel to other people)
    IF NEW.shared AND EXISTS (SELECT 1 FROM members m WHERE m.id = NEW.owner_member_id AND m.member_kind = 'agent') THEN
        RAISE EXCEPTION 'An agent''s saved queries are private' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER saved_queries_before BEFORE INSERT OR UPDATE ON saved_queries FOR EACH ROW EXECUTE FUNCTION dx_saved_queries_before();
CREATE OR REPLACE FUNCTION dx_saved_query_verify(p_id bigint, p_verify boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q saved_queries%ROWTYPE;
BEGIN
    IF NOT dx_has_right('queries.verify') THEN
        RAISE EXCEPTION '%', COALESCE(dx_right_refusal('queries.verify'), 'Verifying a query is a DBA''s') USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT * INTO q FROM saved_queries WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No such saved query' USING ERRCODE = 'no_data_found'; END IF;
    IF p_verify THEN
        UPDATE saved_queries SET verified_by = app_current_member_id(), verified_at = now(), verified_sql_sha256 = q.sql_sha256, unverified_reason = NULL WHERE id = p_id;
    ELSE
        UPDATE saved_queries SET verified_by = NULL, verified_at = NULL, verified_sql_sha256 = NULL, unverified_reason = 'unverified by a person' WHERE id = p_id;
    END IF;
END$$;

-- ------------------------------------------------------------------------------------------------- kept plans
CREATE TABLE explain_plans (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id          bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_database_id bigint REFERENCES target_databases(id) ON DELETE SET NULL,
    query_run_id       bigint REFERENCES query_runs(id) ON DELETE SET NULL,
    sql                text NOT NULL CHECK (length(sql) BETWEEN 1 AND 20000),
    options            text[] NOT NULL DEFAULT '{}',                       -- ANALYZE, BUFFERS, VERBOSE, SETTINGS, SERIALIZE, MEMORY, GENERIC_PLAN
    executed           boolean NOT NULL DEFAULT false,                     -- ANALYZE ran it (a write on a workbench: rolled back)
    plan               jsonb NOT NULL,                                     -- FORMAT JSON
    flags              jsonb NOT NULL DEFAULT '[]'::jsonb,                 -- the deterministic flags found
    comment            text CHECK (comment IS NULL OR length(comment) <= 2000),
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX explain_plans_member_idx ON explain_plans (member_id, created_at DESC);

GRANT SELECT ON query_runs, door_statements, door_usage TO developer_rw;
GRANT SELECT, INSERT, UPDATE ON saved_queries, explain_plans TO developer_rw;
REVOKE ALL ON FUNCTION dx_door_run_open(jsonb), dx_door_run_close(bigint, jsonb), dx_door_statement_log(jsonb), dx_door_usage_bump(bigint, text),
    dx_query_runs_prune(), dx_saved_query_verify(bigint, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dx_query_runs_prune(), dx_saved_query_verify(bigint, boolean) TO developer_rw;

COMMIT;
