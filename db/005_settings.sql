-- 005: the application's SETTINGS (one row) and the KEY rules that read them (design §6.1, §6.5–§6.7, §6.10; D5, D8, D11, D14).
--
-- THE ESTATE'S DATA MODEL (design §6.11): dx_settings is the siblings' one-row `app_settings` skeleton (Help Desk db/005: id smallint = 1,
-- updated_at) with the kit's generic columns (business name, time zone, the key rates) and THIS application's columns: the door's limits
-- (D8), the windows (D5, design §3 wall 4), the change-set caps and undo (D5), workbenches (design §6.5), retention (D14), exports (D15),
-- the DBA Advisor's hour, personal tokens (D16 — off) and THE FREEZE (design §3 wall 8). The key functions are Knowledge db/011's = Sales
-- CRM db/005's = the Data Lake db/005's = Boards db/005's = MaluMail db/005's (dx_resolve_key, dx_rate_ok, dx_key_calls_today,
-- dx_key_rotate, dx_prune_key_usage) — here because they read the settings.
--
-- WHO CHANGES THEM: a Developer admin (settings.manage — a super-admin, D9) on the admin screen; the freeze by `freeze`; never an agent.
-- FIXED RULES ARE NOT SETTINGS: no host or connection string anywhere, secret columns never shown, the kernel's database structure only,
-- live DDL only on workbenches (design §3).
BEGIN;

CREATE TABLE dx_settings (
    id                          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    business_name               text,
    timezone                    text NOT NULL DEFAULT 'UTC',
    -- the door's limits (D8, design §6.1)
    screen_timeout_seconds      smallint NOT NULL DEFAULT 30  CHECK (screen_timeout_seconds BETWEEN 5 AND 60),       -- a screen's statement; the read tier's role ceiling is 60 s
    workbench_timeout_seconds   smallint NOT NULL DEFAULT 300 CHECK (workbench_timeout_seconds BETWEEN 30 AND 600),  -- a workbench script or a rehearsal
    show_rows                   integer  NOT NULL DEFAULT 1000 CHECK (show_rows BETWEEN 50 AND 10000),               -- rows shown, then the truncation said
    show_bytes_mb               smallint NOT NULL DEFAULT 8   CHECK (show_bytes_mb BETWEEN 1 AND 64),
    cell_chars                  integer  NOT NULL DEFAULT 2000 CHECK (cell_chars BETWEEN 100 AND 100000),            -- a cell cut, its full length shown
    door_pool_max               smallint NOT NULL DEFAULT 8   CHECK (door_pool_max BETWEEN 2 AND 40),                -- connections the door holds in all (the tool's share is 18: door 8, FPM 6, MCP 2, grants 1, worker 1)
    runs_per_person             smallint NOT NULL DEFAULT 2   CHECK (runs_per_person BETWEEN 1 AND 10),              -- concurrent runs a person
    grid_page_rows              smallint NOT NULL DEFAULT 50  CHECK (grid_page_rows BETWEEN 10 AND 200),
    -- windows (D5; design §3 wall 4)
    window_default_minutes      smallint NOT NULL DEFAULT 60  CHECK (window_default_minutes BETWEEN 5 AND 240),
    window_max_minutes          smallint NOT NULL DEFAULT 240 CHECK (window_max_minutes BETWEEN 15 AND 480),
    step_up_minutes             smallint NOT NULL DEFAULT 10  CHECK (step_up_minutes BETWEEN 1 AND 60),              -- a window needs a hand-off this recent
    idle_timeout_minutes        smallint NOT NULL DEFAULT 30  CHECK (idle_timeout_minutes BETWEEN 5 AND 480),        -- the session's idle timeout
    -- change sets (D5; design §6.6)
    change_set_confirm_rows     integer  NOT NULL DEFAULT 1000  CHECK (change_set_confirm_rows BETWEEN 1 AND 100000),  -- up to this: confirm the count
    change_set_max_rows         integer  NOT NULL DEFAULT 10000 CHECK (change_set_max_rows BETWEEN 1 AND 1000000),     -- above this: refused (a migration)
    backup_max_age_hours        smallint NOT NULL DEFAULT 24  CHECK (backup_max_age_hours BETWEEN 1 AND 720),         -- a cap-crossing apply needs a backup this recent
    undo_days                   smallint NOT NULL DEFAULT 30  CHECK (undo_days BETWEEN 1 AND 365),                    -- before-images kept
    -- workbenches (design §6.5)
    workbench_quota_gb          smallint NOT NULL DEFAULT 2   CHECK (workbench_quota_gb BETWEEN 1 AND 100),
    workbench_expiry_days       smallint NOT NULL DEFAULT 14  CHECK (workbench_expiry_days BETWEEN 1 AND 365),
    workbenches_per_person      smallint NOT NULL DEFAULT 5   CHECK (workbenches_per_person BETWEEN 0 AND 50),
    -- retention (D14; design §6.10)
    sql_text_days               smallint NOT NULL DEFAULT 90  CHECK (sql_text_days BETWEEN 1 AND 3650),              -- query_runs.sql nulled after
    audit_keep_days             smallint NOT NULL DEFAULT 730 CHECK (audit_keep_days BETWEEN 30 AND 3650),           -- query_runs / door_statements rows kept
    snapshot_ddl_days           smallint NOT NULL DEFAULT 90  CHECK (snapshot_ddl_days BETWEEN 7 AND 3650),          -- snapshot_objects' DDL text kept
    -- exports (D15; design §6.7)
    export_max_rows             integer  NOT NULL DEFAULT 1000000 CHECK (export_max_rows BETWEEN 1000 AND 100000000),
    export_max_mb               integer  NOT NULL DEFAULT 1024 CHECK (export_max_mb BETWEEN 1 AND 102400),
    export_keep_hours           smallint NOT NULL DEFAULT 24  CHECK (export_keep_hours BETWEEN 1 AND 720),
    -- the DBA Advisor's weekday note (design §5; the duty's schedule is the kernel's, this is the hour its inputs are cut at)
    advisor_note_at             time NOT NULL DEFAULT '07:20',
    -- personal MCP tokens (D16): off in version 1
    personal_tokens_enabled     boolean NOT NULL DEFAULT false,
    -- THE FREEZE (design §3 wall 8): every window ends, the write and workbench tiers are refused, every agent tool answers "frozen"
    frozen                      boolean NOT NULL DEFAULT false,
    frozen_by                   bigint REFERENCES members(id) ON DELETE SET NULL,
    frozen_at                   timestamptz,
    frozen_reason               text CHECK (frozen_reason IS NULL OR length(frozen_reason) BETWEEN 3 AND 1000),
    -- keys (the kit's; db/003)
    key_rate_per_minute         integer NOT NULL DEFAULT 60 CHECK (key_rate_per_minute BETWEEN 1 AND 100000),
    key_rate_per_day            integer NOT NULL DEFAULT 5000 CHECK (key_rate_per_day BETWEEN 1 AND 10000000),
    key_rotation_overlap_hours  smallint NOT NULL DEFAULT 24 CHECK (key_rotation_overlap_hours BETWEEN 0 AND 168),
    storage_dir                 text,                                                                          -- NULL = DX_STORAGE_DIR from the environment (export files)
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    CHECK (window_default_minutes <= window_max_minutes),
    CHECK (change_set_confirm_rows <= change_set_max_rows),
    CHECK (NOT frozen OR (frozen_at IS NOT NULL AND frozen_reason IS NOT NULL))
);
INSERT INTO dx_settings (id) VALUES (1) ON CONFLICT DO NOTHING;
CREATE TRIGGER dx_settings_touch BEFORE UPDATE ON dx_settings FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- One setting by name, for the rules that read them (never for a column that is not a number / not text).
CREATE OR REPLACE FUNCTION dx_setting_int(p_name text) RETURNS bigint
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint;
BEGIN
    EXECUTE format('SELECT %I::bigint FROM dx_settings WHERE id = 1', p_name) INTO v;
    RETURN v;
END$$;
CREATE OR REPLACE FUNCTION dx_setting_text(p_name text) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v text;
BEGIN
    EXECUTE format('SELECT %I::text FROM dx_settings WHERE id = 1', p_name) INTO v;
    RETURN v;
END$$;
CREATE OR REPLACE FUNCTION dx_setting_bool(p_name text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v boolean;
BEGIN
    EXECUTE format('SELECT %I::boolean FROM dx_settings WHERE id = 1', p_name) INTO v;
    RETURN v;
END$$;

-- ---------------------------------------------------------------------------------------------
-- KEYS (db/003): a key's defaults, its resolution, the rate rule, rotation and pruning — Knowledge db/011 minus the base
-- (Sales CRM's and the Data Lake's copies, without the Data Lake's per-key SQL switch).
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dx_access_tokens_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.scope = 'api' THEN
        NEW.rate_per_minute := COALESCE(NEW.rate_per_minute, dx_setting_int('key_rate_per_minute')::integer);
        NEW.rate_per_day := COALESCE(NEW.rate_per_day, dx_setting_int('key_rate_per_day')::integer);
        IF NEW.rotated_from IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mcp_access_tokens o WHERE o.id = NEW.rotated_from AND o.member_id = NEW.member_id AND o.scope = 'api') THEN
            RAISE EXCEPTION 'A key is rotated from a key of the same person' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER mcp_access_tokens_before BEFORE INSERT OR UPDATE ON mcp_access_tokens FOR EACH ROW EXECUTE FUNCTION dx_access_tokens_before();

-- Resolve a key by its hash: the token, its person, its label and its limits, with last_used_at touched. Nothing for a
-- revoked, expired or mcp-scope token, or one whose person is no longer admitted (a revoked grant shuts this door too).
CREATE OR REPLACE FUNCTION dx_resolve_key(p_hash text)
    RETURNS TABLE (token_id bigint, member_id bigint, label text, rate_per_minute integer, rate_per_day integer)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE mcp_access_tokens t SET last_used_at = now()
      FROM members m
     WHERE t.token_hash = p_hash AND t.scope = 'api' AND t.revoked_at IS NULL AND (t.expires_at IS NULL OR t.expires_at > now())
       AND m.id = t.member_id AND m.status = 'active' AND m.capability IS NOT NULL;
    RETURN QUERY
        SELECT t.id, t.member_id, t.label, t.rate_per_minute, t.rate_per_day
          FROM mcp_access_tokens t JOIN members m ON m.id = t.member_id
         WHERE t.token_hash = p_hash AND t.scope = 'api' AND t.revoked_at IS NULL AND (t.expires_at IS NULL OR t.expires_at > now())
           AND m.status = 'active' AND m.capability IS NOT NULL;
END$$;

-- Count one call. ok = the call may proceed; when not, limit_hit says which bucket and retry_after how many seconds until it
-- opens. The minute bucket is charged first; a call the minute refuses is not charged to the day (so a burst never eats the
-- day); a call the day refuses stays counted in the minute (it was made). `refused` is kept per bucket for the keys screen.
CREATE OR REPLACE FUNCTION dx_rate_ok(p_token_id bigint, p_at timestamptz DEFAULT now())
    RETURNS TABLE (ok boolean, limit_hit text, retry_after integer, minute_calls integer, day_calls integer)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t mcp_access_tokens%ROWTYPE; m_start timestamptz; d_start timestamptz; m_calls integer; d_calls integer;
BEGIN
    SELECT * INTO t FROM mcp_access_tokens WHERE id = p_token_id AND scope = 'api' FOR UPDATE;   -- serialises the two upserts per key
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'no_key'::text, 0, 0, 0; RETURN;
    END IF;
    IF t.revoked_at IS NOT NULL OR (t.expires_at IS NOT NULL AND t.expires_at <= p_at) THEN
        RETURN QUERY SELECT false, 'revoked'::text, 0, 0, 0; RETURN;
    END IF;
    m_start := date_trunc('minute', p_at);
    d_start := date_trunc('day', p_at);
    INSERT INTO key_usage (token_id, bucket_kind, bucket_start, calls) VALUES (p_token_id, 'minute', m_start, 1)
    ON CONFLICT (token_id, bucket_kind, bucket_start) DO UPDATE SET calls = key_usage.calls + 1
    RETURNING calls INTO m_calls;
    IF m_calls > t.rate_per_minute THEN
        UPDATE key_usage SET calls = calls - 1, refused = refused + 1 WHERE token_id = p_token_id AND bucket_kind = 'minute' AND bucket_start = m_start;
        SELECT COALESCE(calls, 0) INTO d_calls FROM key_usage WHERE token_id = p_token_id AND bucket_kind = 'day' AND bucket_start = d_start;
        RETURN QUERY SELECT false, 'minute'::text, GREATEST(1, ceil(extract(epoch FROM (m_start + interval '1 minute' - p_at)))::integer), m_calls - 1, COALESCE(d_calls, 0);
        RETURN;
    END IF;
    INSERT INTO key_usage (token_id, bucket_kind, bucket_start, calls) VALUES (p_token_id, 'day', d_start, 1)
    ON CONFLICT (token_id, bucket_kind, bucket_start) DO UPDATE SET calls = key_usage.calls + 1
    RETURNING calls INTO d_calls;
    IF d_calls > t.rate_per_day THEN
        UPDATE key_usage SET calls = calls - 1, refused = refused + 1 WHERE token_id = p_token_id AND bucket_kind = 'day' AND bucket_start = d_start;
        RETURN QUERY SELECT false, 'day'::text, GREATEST(1, ceil(extract(epoch FROM (d_start + interval '1 day' - p_at)))::integer), m_calls, d_calls - 1;
        RETURN;
    END IF;
    RETURN QUERY SELECT true, NULL::text, 0, m_calls, d_calls;
END$$;

-- Today's count for a key (the keys screen, find_keys).
CREATE OR REPLACE FUNCTION dx_key_calls_today(p_token_id bigint) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE((SELECT calls FROM key_usage WHERE token_id = p_token_id AND bucket_kind = 'day' AND bucket_start = date_trunc('day', now())), 0);
$$;

-- Rotate: a new key for the same person, label and limits; the old one expires after the overlap (24 h) and points nowhere —
-- the new one says `rotated_from`. Returns the new row's id; the raw key is the caller's (PHP mints the 48 hex, hashes them, and
-- passes the hash in).
CREATE OR REPLACE FUNCTION dx_key_rotate(p_old_token_id bigint, p_new_hash text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o mcp_access_tokens%ROWTYPE; nid bigint; overlap integer;
BEGIN
    SELECT * INTO o FROM mcp_access_tokens WHERE id = p_old_token_id AND scope = 'api' FOR UPDATE;
    IF NOT FOUND OR o.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'Only a live key is rotated' USING ERRCODE = 'check_violation'; END IF;
    overlap := dx_setting_int('key_rotation_overlap_hours')::integer;
    INSERT INTO mcp_access_tokens (member_id, label, token_hash, scope, rate_per_minute, rate_per_day, rotated_from)
    VALUES (o.member_id, o.label, p_new_hash, 'api', o.rate_per_minute, o.rate_per_day, o.id)
    RETURNING id INTO nid;
    UPDATE mcp_access_tokens SET expires_at = LEAST(COALESCE(expires_at, 'infinity'::timestamptz), now() + make_interval(hours => overlap)) WHERE id = o.id;
    RETURN nid;
END$$;

-- The worker prunes buckets once a minute: minute buckets older than a day, day buckets older than 35 days.
CREATE OR REPLACE FUNCTION dx_prune_key_usage() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
    DELETE FROM key_usage WHERE (bucket_kind = 'minute' AND bucket_start < now() - interval '1 day') OR (bucket_kind = 'day' AND bucket_start < now() - interval '35 days');
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

GRANT SELECT, UPDATE ON dx_settings TO developer_rw;
GRANT EXECUTE ON FUNCTION dx_setting_int(text), dx_setting_text(text), dx_setting_bool(text), dx_key_calls_today(bigint) TO developer_rw, developer_records_ro, developer_activity_ro;
REVOKE ALL ON FUNCTION dx_resolve_key(text), dx_rate_ok(bigint, timestamptz), dx_key_rotate(bigint, text), dx_prune_key_usage() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dx_resolve_key(text), dx_rate_ok(bigint, timestamptz), dx_key_rotate(bigint, text), dx_prune_key_usage() TO developer_rw;

COMMIT;
