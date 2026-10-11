-- Developer db/013 — the Phase 1 fixes (2026-10-11): what the slice specs found the Phase 0 schema lacked, gathered here so Phase 1 approves
-- ONE complete schema (design §10's gate). Additive; nothing renamed or dropped.
--   * change_set_items.payload — a staged grid edit's values (data-windows.md); never exposed by mcp_change_set_items, which names its columns;
--   * snapshot_objects: a person may explain a change (drift_explain, health-compare.md) — explained_by widened with 'person' and three columns;
--   * target_databases.side_effect_tables — tables whose triggers write elsewhere, refused by the grid up front (FINDINGS 8, data-windows.md);
--   * explain_plans: developer_rw may delete a plan (plan_delete, plans.md);
--   * dx_door_policy(): target.has_maludb and target.memory_schemas, so the door reaches a co-located memory schema (memory-section.md);
--   * dx_door_job_update(): the door reports a maintenance job's status and progress from its own thread (activity-maintenance.md);
--   * dx_settings.blocked_alert_minutes — the blocked-session notice's threshold (design §5's ten minutes; agents-admin.md, activity-maintenance.md).

ALTER TABLE change_set_items ADD COLUMN IF NOT EXISTS payload jsonb;          -- {key, values{column: text|null}, before_xmin}; NULL for typed or generated statements

ALTER TABLE snapshot_objects DROP CONSTRAINT IF EXISTS snapshot_objects_explained_by_check;
ALTER TABLE snapshot_objects ADD CONSTRAINT snapshot_objects_explained_by_check
    CHECK (explained_by IN ('change_set', 'migration_draft', 'grants', 'person', 'none'));
ALTER TABLE snapshot_objects ADD COLUMN IF NOT EXISTS explained_note text CHECK (explained_note IS NULL OR length(explained_note) <= 500),
                             ADD COLUMN IF NOT EXISTS explained_member_id bigint REFERENCES members(id) ON DELETE SET NULL,
                             ADD COLUMN IF NOT EXISTS explained_at timestamptz;

ALTER TABLE target_databases ADD COLUMN IF NOT EXISTS side_effect_tables text[] NOT NULL DEFAULT '{}';

GRANT DELETE ON explain_plans TO developer_rw;

ALTER TABLE dx_settings ADD COLUMN IF NOT EXISTS blocked_alert_minutes smallint NOT NULL DEFAULT 10 CHECK (blocked_alert_minutes BETWEEN 1 AND 240);

-- The door reports a job (as developer_meta, like the other dx_door_* functions): {status, progress, error_masked}; started and finished stamped here.
CREATE OR REPLACE FUNCTION dx_door_job_update(p_job bigint, p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE maintenance_jobs
       SET status = COALESCE(p ->> 'status', status),
           progress = COALESCE(p -> 'progress', progress),
           error_masked = COALESCE(p ->> 'error_masked', error_masked),
           started_at = CASE WHEN p ->> 'status' = 'running' AND started_at IS NULL THEN now() ELSE started_at END,
           finished_at = CASE WHEN p ->> 'status' IN ('ok', 'failed', 'cancelled') THEN now() ELSE finished_at END
     WHERE id = p_job AND status IN ('queued', 'running');
    IF NOT FOUND THEN RAISE EXCEPTION 'No queued or running job %.', p_job USING ERRCODE = 'P0002'; END IF;
END$$;
REVOKE ALL ON FUNCTION dx_door_job_update(bigint, jsonb) FROM PUBLIC;

-- dx_door_policy(), as db/006 wrote it, with target.has_maludb and target.memory_schemas appended.
CREATE OR REPLACE FUNCTION dx_door_policy(p_caller bigint, p_on_behalf_of bigint, p_datname text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE m members%ROWTYPE; t target_databases%ROWTYPE; s dx_settings%ROWTYPE; wb record; roles text[]; is_agent boolean; is_super boolean;
        lvl text := 'structure'; rw access_windows%ROWTYPE; ww access_windows%ROWTYPE; tiers text[] := '{}'; dml text := 'never';
        ddl text := 'never'; timeout_ms integer; obo jsonb := NULL; rights text[]; wb_left integer; wbj jsonb := NULL; wb_suspended boolean := false;
BEGIN
    SELECT * INTO s FROM dx_settings WHERE id = 1;
    SELECT * INTO m FROM members WHERE id = p_caller;
    IF NOT FOUND OR NOT dx_door_member_active(p_caller) THEN
        RETURN dx_door_refusal('member', 'Unknown or not admitted here.', s.frozen);
    END IF;
    roles := dx_member_roles(p_caller);
    is_agent := m.member_kind = 'agent';
    is_super := (m.member_kind = 'human' AND m.business_role = 'super_admin');
    IF is_agent AND s.frozen THEN
        RETURN dx_door_refusal('frozen', 'Developer is frozen: every agent tool is off.', true);
    END IF;
    IF NOT dx_member_has_right(p_caller, 'catalog.read') THEN
        RETURN dx_door_refusal('right', 'Your Developer role does not let you browse databases.', s.frozen);
    END IF;
    SELECT * INTO t FROM target_databases WHERE datname = p_datname AND gone_at IS NULL;
    IF NOT FOUND OR t.class IN ('unclassified', 'system') THEN
        RETURN dx_door_refusal('unregistered', 'That database is not registered with Developer.', s.frozen);   -- wall 1
    END IF;
    IF t.class = 'own' AND NOT is_super THEN
        RETURN dx_door_refusal('own', 'Developer''s own database is its admins''.', s.frozen);
    END IF;
    IF t.class = 'workbench' THEN
        SELECT w.id, w.owner_member_id, w.role_name, w.suspended_at IS NOT NULL AS suspended INTO wb
          FROM workbenches w WHERE w.target_database_id = t.id AND w.dropped_at IS NULL;
        IF wb.id IS NULL OR (wb.owner_member_id IS DISTINCT FROM p_caller AND NOT is_super) THEN
            RETURN dx_door_refusal('workbench', 'That workbench is someone else''s.', s.frozen);
        END IF;
        wbj := jsonb_build_object('id', wb.id, 'owner_member_id', wb.owner_member_id, 'role', wb.role_name, 'suspended', wb.suspended);
        wb_suspended := wb.suspended;
    END IF;
    -- an agent in a person's chat turn: only on targets the person may see (K38) — the person must belong here and browse
    IF is_agent AND p_on_behalf_of IS NOT NULL THEN
        IF NOT dx_door_member_active(p_on_behalf_of) OR NOT dx_member_has_right(p_on_behalf_of, 'catalog.read') THEN
            RETURN dx_door_refusal('on_behalf_of', 'The person this agent acts for may not browse databases here.', s.frozen);
        END IF;
        obo := jsonb_build_object('member_id', p_on_behalf_of, 'active', true, 'level', dx_person_level(p_on_behalf_of, t.id));
    END IF;
    -- the rights held (an agent's people and super_admins rights are absent by held_by; in a chat turn, intersected with the person's)
    SELECT COALESCE(array_agg(h.right_key ORDER BY h.sort_order), '{}') INTO rights
      FROM dx_rights h
     WHERE dx_member_has_right(p_caller, h.right_key)
       AND (NOT is_agent OR p_on_behalf_of IS NULL OR dx_member_has_right(p_on_behalf_of, h.right_key));
    -- the level: an agent never reads rows (wall 6); a person's from target_access; the kernel's and memory databases structure only
    IF NOT is_agent THEN
        IF t.class = 'workbench' THEN
            lvl := CASE WHEN 'workbench.use' = ANY (rights) THEN 'rows' ELSE 'structure' END;
        ELSIF t.class = 'own' THEN
            lvl := 'rows';
        ELSE
            lvl := dx_person_level(p_caller, t.id);
            IF t.class = 'development' AND t.grants_state NOT IN ('in_place', 'partial') THEN lvl := 'structure'; END IF;
        END IF;
        SELECT * INTO rw FROM access_windows WHERE id = dx_open_window(p_caller, t.id, 'read');
        IF lvl IN ('masked', 'rows') AND t.private_by_design AND rw.id IS NULL THEN lvl := 'structure'; END IF;   -- a read window first
        SELECT * INTO ww FROM access_windows WHERE id = dx_open_window(p_caller, t.id, 'write');
    END IF;
    -- data and schema changes, by class (D4, D5)
    IF NOT is_agent AND NOT s.frozen THEN
        IF t.class = 'application' AND ww.id IS NOT NULL AND 'data.write' = ANY (rights) THEN dml := 'window';
        ELSIF t.class = 'workbench' AND 'workbench.apply' = ANY (rights) AND NOT wb_suspended THEN dml := 'live'; ddl := 'live';
        END IF;
    END IF;
    IF t.class = 'application' AND 'migrations.draft' = ANY (rights) THEN ddl := 'draft'; END IF;
    -- the tiers the door may use for this caller on this target (design §6.1)
    tiers := ARRAY['meta'];
    IF t.class IN ('application', 'development') AND t.grants_state IN ('in_place', 'partial') THEN
        tiers := array_append(tiers, 'read_masked');                                                      -- EXPLAIN without execution, masked reads
        IF lvl = 'rows' THEN tiers := array_append(tiers, 'read'); END IF;
        IF dml = 'window' THEN tiers := array_append(tiers, 'write'); END IF;
    END IF;
    IF t.class = 'workbench' AND NOT s.frozen AND lvl = 'rows' THEN tiers := array_append(tiers, 'workbench'); END IF;
    IF t.class IN ('application', 'development', 'workbench') AND NOT is_agent
       AND ('maintenance.run' = ANY (rights) OR 'sessions.cancel' = ANY (rights) OR 'sessions.terminate' = ANY (rights)) THEN
        tiers := array_append(tiers, 'ops');
    END IF;
    IF t.class = 'memory' THEN tiers := array_append(tiers, 'memory'); END IF;
    timeout_ms := CASE WHEN t.class = 'workbench' THEN s.workbench_timeout_seconds ELSE s.screen_timeout_seconds END * 1000;
    SELECT GREATEST(s.workbenches_per_person - count(*), 0) INTO wb_left FROM workbenches w WHERE w.owner_member_id = p_caller AND w.dropped_at IS NULL;
    RETURN jsonb_build_object(
        'ok', true, 'refusal', NULL, 'frozen', s.frozen,
        'caller', jsonb_build_object('member_id', p_caller, 'is_agent', is_agent, 'active', true, 'is_super_admin', is_super, 'roles', to_jsonb(roles)),
        'on_behalf_of', obo,
        'target', jsonb_build_object('id', t.id, 'datname', t.datname, 'class', t.class, 'application_key', t.application_key,
                                     'private_by_design', t.private_by_design, 'grants_state', t.grants_state,
                                     'has_maludb', t.has_maludb, 'memory_schemas', to_jsonb(t.memory_schemas)),
        'rights', to_jsonb(rights),
        'level', CASE WHEN is_agent THEN 'structure' ELSE lvl END,
        'window', jsonb_build_object(
            'read',  CASE WHEN rw.id IS NOT NULL THEN jsonb_build_object('id', rw.id, 'expires_at', rw.expires_at) END,
            'write', CASE WHEN ww.id IS NOT NULL THEN jsonb_build_object('id', ww.id, 'expires_at', ww.expires_at) END),
        'workbench', wbj,
        'limits', jsonb_build_object('statement_timeout_ms', timeout_ms, 'lock_timeout_ms', CASE WHEN t.class = 'workbench' THEN 10000 ELSE 5000 END,
                                     'idle_in_tx_ms', 60000, 'transaction_timeout_ms', CASE WHEN t.class = 'workbench' THEN 600000 ELSE 120000 END,
                                     'show_rows', s.show_rows, 'show_bytes', s.show_bytes_mb::bigint * 1048576, 'cell_chars', s.cell_chars,
                                     'concurrent_runs', s.runs_per_person, 'change_set_confirm_rows', s.change_set_confirm_rows,
                                     'change_set_max_rows', s.change_set_max_rows, 'workbenches_left', wb_left),
        'ceiling', jsonb_build_object('structure', true, 'rows', t.class IN ('application', 'development', 'workbench', 'own'), 'dml', dml, 'ddl', ddl),
        'tiers', to_jsonb(tiers));
END$$;
