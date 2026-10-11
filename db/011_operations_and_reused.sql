-- 011: OPERATIONS (maintenance jobs, backup marks, diagram layouts) and the REUSED tables (exports, notifications, dispatches, the
-- worker's record) — design §6.7, §6.11.
--
-- THE ESTATE'S DATA MODEL:
--   * `maintenance_jobs` — NEW. The Data Lake's `maintenance_runs` was compared (design §6.11) and is a different concept (lake files
--     merged, snapshots expired), so it is not reused; this is a job the worker runs through the door (VACUUM, ANALYZE, REINDEX
--     CONCURRENTLY, REFRESH MATERIALIZED VIEW CONCURRENTLY) on one object of one target.
--   * `backup_marks`, `diagram_layouts` — NEW.
--   * `exports` — Spaces db/016 (+ db/023's `params`), kept without its references to Spaces' pages, spaces and channels (plain nullable
--     columns, the CRM's precedent), `kind` and `format` widened with Developer's (table, result; sql), APPENDING target_database_id,
--     query_run_id, row_count — the tool's export file, made by the worker through the door at the maker's level.
--   * `notifications`, `notification_prefs`, `notification_outbox` — Spaces db/012 (member-only) as GL db/014 and MaluMail db/007 carry
--     them, Spaces' appended references kept as plain nullable columns, the kinds ours, APPENDING target_database_id.
--   * `agent_dispatches` — Spaces db/012 with its `kind`, the kind list widened with Developer's (`blocked_session`), APPENDING
--     target_database_id.
--   * `worker_passes` — Spaces db/016 verbatim.
BEGIN;

-- ------------------------------------------------------------------------------------------------- maintenance jobs
CREATE TABLE maintenance_jobs (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    operation          text NOT NULL CHECK (operation IN ('vacuum', 'vacuum_analyze', 'analyze', 'reindex_concurrently', 'refresh_concurrently')),
    obj_type           text NOT NULL,
    obj_names          text[] NOT NULL,
    lock_note          text NOT NULL,                                          -- the lock it takes, said before it starts
    requested_by       bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    status             text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'ok', 'failed', 'cancelled')),
    progress           jsonb NOT NULL DEFAULT '{}'::jsonb,                     -- from pg_stat_progress_* while it runs
    query_run_id       bigint REFERENCES query_runs(id) ON DELETE SET NULL,
    error_masked       text CHECK (error_masked IS NULL OR length(error_masked) <= 500),
    requested_at       timestamptz NOT NULL DEFAULT now(),
    started_at         timestamptz,
    finished_at        timestamptz
);
CREATE INDEX maintenance_jobs_queue_idx ON maintenance_jobs (requested_at) WHERE status = 'queued';
CREATE INDEX maintenance_jobs_target_idx ON maintenance_jobs (target_database_id, requested_at DESC);

-- A job is a person's (maintenance.run, people only) on an installed application's database — never VACUUM FULL or CLUSTER (D15).
CREATE OR REPLACE FUNCTION dx_maintenance_jobs_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT dx_member_has_right(NEW.requested_by, 'maintenance.run') THEN
        RAISE EXCEPTION 'Maintenance is a person''s (maintenance.run): an agent never runs it' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF (SELECT class FROM target_databases WHERE id = NEW.target_database_id) <> 'application' THEN
        RAISE EXCEPTION 'Maintenance jobs run on an installed application''s database' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER maintenance_jobs_before BEFORE INSERT ON maintenance_jobs FOR EACH ROW EXECUTE FUNCTION dx_maintenance_jobs_before();

-- ------------------------------------------------------------------------------------------------- backup marks (the gate of D5)
CREATE TABLE backup_marks (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    datname      text NOT NULL CHECK (datname ~ '^[a-z0-9_]{1,63}$'),
    kind         text NOT NULL CHECK (kind IN ('dump', 'base_backup', 'snapshot', 'other')),
    taken_at     timestamptz NOT NULL DEFAULT now(),
    recorded_by  text NOT NULL DEFAULT 'bin/backup_mark.php',
    note         text CHECK (note IS NULL OR length(note) <= 500)
);
CREATE INDEX backup_marks_db_idx ON backup_marks (datname, taken_at DESC);

-- The newest backup of a database, or NULL — the cap-crossing apply's gate (design §6.6, §6.7).
CREATE OR REPLACE FUNCTION dx_last_backup(p_datname text) RETURNS timestamptz
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT max(taken_at) FROM backup_marks WHERE datname = p_datname;
$$;

-- ------------------------------------------------------------------------------------------------- diagram layouts
CREATE TABLE diagram_layouts (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id          bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    title              text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    root_type          text NOT NULL,
    root_names         text[] NOT NULL,
    hops               smallint NOT NULL DEFAULT 1 CHECK (hops BETWEEN 0 AND 5),
    detail             text NOT NULL DEFAULT 'keys' CHECK (detail IN ('names', 'keys', 'columns')),
    tables             jsonb NOT NULL DEFAULT '[]'::jsonb,                      -- the tables kept in it (at most 60)
    shared             boolean NOT NULL DEFAULT false,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (jsonb_array_length(tables) <= 60)
);
CREATE INDEX diagram_layouts_member_idx ON diagram_layouts (member_id, updated_at DESC);
CREATE TRIGGER diagram_layouts_touch BEFORE UPDATE ON diagram_layouts FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ------------------------------------------------------------------------------------------------- exports (Spaces db/016 + db/023)
CREATE TABLE exports (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          text NOT NULL CHECK (kind IN ('page', 'space', 'channel', 'database', 'all', 'table', 'result')),   -- widened: table, result
    format        text NOT NULL CHECK (format IN ('md', 'html', 'csv', 'json', 'zip', 'sql')),                       -- widened: sql
    page_id       uuid,                                                -- Spaces' references kept as plain columns (unused here)
    space_id      bigint,
    channel_id    bigint,
    include_subpages boolean NOT NULL DEFAULT true,
    status        text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
    storage_path  text,
    byte_size     bigint,
    item_count    integer NOT NULL DEFAULT 0,
    log           text,
    created_by    bigint REFERENCES members(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    expires_at    timestamptz NOT NULL DEFAULT now() + interval '7 days',
    downloaded_at timestamptz,
    -- appended by Spaces (db/023)
    params        jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- appended (design §6.7)
    target_database_id bigint REFERENCES target_databases(id) ON DELETE SET NULL,
    query_run_id  bigint REFERENCES query_runs(id) ON DELETE SET NULL,
    row_count     bigint
);
CREATE INDEX exports_owner_idx ON exports (created_by, created_at DESC);
CREATE INDEX exports_expiry_idx ON exports (expires_at) WHERE storage_path IS NOT NULL;

-- An export is a person's (exports.make, people only — an agent's would carry rows out, design §5).
CREATE OR REPLACE FUNCTION dx_exports_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.created_by IS NULL OR NOT dx_member_has_right(NEW.created_by, 'exports.make') THEN
        RAISE EXCEPTION 'Exports are a person''s (exports.make): an agent never exports' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.expires_at := now() + make_interval(hours => (SELECT export_keep_hours FROM dx_settings WHERE id = 1));
    RETURN NEW;
END$$;
CREATE TRIGGER exports_before BEFORE INSERT ON exports FOR EACH ROW EXECUTE FUNCTION dx_exports_before();

-- ------------------------------------------------------------------------------------------------- notifications
CREATE TABLE notifications (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id    bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('window_requested', 'window_decided', 'window_opened_by_super_admin', 'window_ending', 'window_ended',
                                               'workbench_expiring', 'workbench_dropped', 'workbench_suspended', 'proposal', 'draft_applied',
                                               'blocked_session', 'wraparound', 'export_ready', 'grants_pending', 'frozen', 'advisor_note', 'digest')),
    record_type  text,
    record_id    bigint,
    title        text NOT NULL,
    body         text,
    read_at      timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    -- appended by Spaces (db/012), kept without its references to Spaces' channels and messages
    record_uuid  uuid,
    channel_id   bigint,
    message_id   bigint,
    actor_member_id bigint REFERENCES members(id) ON DELETE SET NULL,
    -- appended (design §6.7)
    target_database_id bigint REFERENCES target_databases(id) ON DELETE SET NULL
);
CREATE INDEX notifications_member_idx ON notifications (member_id, created_at DESC);
CREATE INDEX notifications_unread_idx ON notifications (member_id) WHERE read_at IS NULL;

CREATE TABLE notification_prefs (
    member_id      bigint PRIMARY KEY REFERENCES members(id) ON DELETE CASCADE,
    email_enabled  boolean NOT NULL DEFAULT true,
    text_enabled   boolean NOT NULL DEFAULT false,                -- K6: the kernel keeps the opt-out; this is the person's choice here
    kinds          text[] NOT NULL DEFAULT '{window_requested,window_decided,window_opened_by_super_admin,window_ending,workbench_expiring,blocked_session,wraparound,frozen}',
    text_kinds     text[] NOT NULL DEFAULT '{blocked_session,window_requested}',
    updated_at     timestamptz NOT NULL DEFAULT now(),
    -- appended by Spaces (db/012)
    digest         boolean NOT NULL DEFAULT false,
    away_minutes   integer CHECK (away_minutes IS NULL OR away_minutes BETWEEN 1 AND 1440)
);

CREATE TABLE notification_outbox (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel        text NOT NULL CHECK (channel IN ('email', 'text')),
    member_id      bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    to_email       citext,
    kind           text NOT NULL,
    record_type    text,
    record_id      bigint,
    dedupe_key     text,
    subject        text,
    body           text NOT NULL,
    body_html      text,
    status         text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sent', 'skipped', 'failed')),
    attempts       integer NOT NULL DEFAULT 0,
    detail         text,
    provider_ref   text,
    send_after     timestamptz NOT NULL DEFAULT now(),
    sent_at        timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX notification_outbox_dedupe ON notification_outbox (dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX notification_outbox_due_idx ON notification_outbox (send_after) WHERE status = 'queued';

-- One notice to a person: the bell, and a mail when their preferences ask for it (the worker's notify_outbox pass sends it through
-- MaluMail's REST send — app/mail.php). Says nothing of any row's content; an agent is never notified here.
CREATE OR REPLACE FUNCTION dx_notify(p_member bigint, p_kind text, p_title text, p_body text, p_target bigint DEFAULT NULL,
                                     p_record_type text DEFAULT NULL, p_record_id bigint DEFAULT NULL, p_actor bigint DEFAULT NULL,
                                     p_force_email boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE nid bigint; m members%ROWTYPE; pr notification_prefs%ROWTYPE;
BEGIN
    SELECT * INTO m FROM members WHERE id = p_member;
    IF NOT FOUND OR m.status <> 'active' OR m.member_kind <> 'human' THEN RETURN NULL; END IF;
    INSERT INTO notifications (member_id, kind, title, body, target_database_id, record_type, record_id, actor_member_id)
    VALUES (p_member, p_kind, p_title, p_body, p_target, p_record_type, p_record_id, p_actor) RETURNING id INTO nid;
    SELECT * INTO pr FROM notification_prefs WHERE member_id = p_member;
    IF m.email IS NOT NULL AND (p_force_email OR (COALESCE(pr.email_enabled, true)
         AND p_kind = ANY (COALESCE(pr.kinds, '{window_requested,window_decided,window_opened_by_super_admin,window_ending,workbench_expiring,blocked_session,wraparound,frozen}'::text[])))) THEN
        INSERT INTO notification_outbox (channel, member_id, to_email, kind, record_type, record_id, dedupe_key, subject, body)
        VALUES ('email', p_member, m.email, p_kind, p_record_type, p_record_id, 'n' || nid, p_title, COALESCE(p_body, p_title));
    END IF;
    RETURN nid;
END$$;

-- A super-admin's own window (self-approved, design §3 wall 4): every OTHER active super-admin is told at once. Returns how many.
CREATE OR REPLACE FUNCTION dx_notify_self_approved_window(p_window bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE w access_windows%ROWTYPE; n integer := 0; r record; who text; db text;
BEGIN
    SELECT * INTO w FROM access_windows WHERE id = p_window AND self_approved;
    IF NOT FOUND THEN RETURN 0; END IF;
    SELECT display_name INTO who FROM members WHERE id = w.member_id;
    SELECT datname INTO db FROM target_databases WHERE id = w.target_database_id;
    FOR r IN SELECT m.id FROM members m WHERE m.member_kind = 'human' AND m.business_role = 'super_admin' AND m.status = 'active' AND m.id <> w.member_id LOOP
        PERFORM dx_notify(r.id, 'window_opened_by_super_admin', who || ' opened a ' || w.mode || ' window on ' || db,
                          'For ' || w.minutes || ' minutes. Reason: ' || left(w.reason, 300), w.target_database_id, 'access_window', w.id, w.member_id, true);
        n := n + 1;
    END LOOP;
    RETURN n;
END$$;

-- ------------------------------------------------------------------------------------------------- dispatches (Spaces db/012)
CREATE TABLE agent_dispatches (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    record_type      text,
    record_id        bigint,
    agent_member_id  bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    kind             text NOT NULL CHECK (kind IN ('mention', 'dm', 'duty_proposal', 'ask', 'blocked_session')),   -- widened: blocked_session
    via              text NOT NULL CHECK (via IN ('chat', 'wake', 'duty')),
    acting_member_id bigint REFERENCES members(id) ON DELETE SET NULL,
    run_id           bigint,
    request_id       text,
    status           text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'answered', 'refused', 'failed', 'awaiting_approval', 'queued', 'skipped')),
    reply_excerpt    text,
    detail           text,
    attempts         integer NOT NULL DEFAULT 1,
    created_at       timestamptz NOT NULL DEFAULT now(),
    answered_at      timestamptz,
    -- appended by Spaces (db/012), kept without its references
    record_uuid      uuid,
    channel_id       bigint,
    conversation_id  text,
    reply_message_id bigint,
    pending_message_id bigint,
    next_attempt_at  timestamptz NOT NULL DEFAULT now(),
    -- appended (design §5)
    target_database_id bigint REFERENCES target_databases(id) ON DELETE SET NULL
);
CREATE INDEX agent_dispatches_due_idx ON agent_dispatches (next_attempt_at) WHERE status = 'queued';

-- ------------------------------------------------------------------------------------------------- the worker's record (Spaces db/016)
CREATE TABLE worker_passes (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    steps         jsonb NOT NULL DEFAULT '{}'::jsonb,
    error         text
);

GRANT SELECT, INSERT, UPDATE ON maintenance_jobs, backup_marks, diagram_layouts, exports, notifications, notification_prefs, notification_outbox,
    agent_dispatches, worker_passes TO developer_rw;
GRANT DELETE ON diagram_layouts TO developer_rw;
GRANT EXECUTE ON FUNCTION dx_last_backup(text) TO developer_rw, developer_records_ro;
REVOKE ALL ON FUNCTION dx_notify(bigint, text, text, text, bigint, text, bigint, bigint, boolean), dx_notify_self_approved_window(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dx_notify(bigint, text, text, text, bigint, text, bigint, bigint, boolean), dx_notify_self_approved_window(bigint) TO developer_rw;

COMMIT;
