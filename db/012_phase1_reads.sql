-- Developer db/012 — the Phase 1 reads (2026-10-11): the mcp_* views the records and activity servers read (docs/developer-mcp-tool-surface.md),
-- the Advisor's notes (dba_notes, design §5's "notification", the action dba_note_post) and the address helper.
--
-- The rules every view keeps (the kernel's db/160 lesson, the scale rule of design §3):
--   * WITH (security_barrier = true); owned by postgres, so the read roles hold no grant on any base table (Phase 0's check stays true);
--   * a check that depends only on the caller is a scalar subquery — it runs once per statement, never once per row;
--   * visibility of a target is ONE set (mcp_visible_targets — a few hundred rows at most), joined, never a function per row of a big table;
--   * K38: in a person's chat turn the server sets app.on_behalf_of to the person, and every right is the agent's AND the person's
--     (dx_caller_may) — the same intersection dx_door_policy() makes for target reads.
-- Nothing here returns a row of a target database: the views read the tool's own tables only.

-- ------------------------------------------------------------------ helpers
CREATE OR REPLACE FUNCTION dx_on_behalf_of() RETURNS bigint
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.on_behalf_of', true), '')::bigint $$;

-- The caller holds the right — and, in a person's chat turn, so does the person (K38). PL/pgSQL, one query each; call it in a scalar subquery.
CREATE OR REPLACE FUNCTION dx_caller_may(p_right text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE obo bigint := dx_on_behalf_of();
BEGIN
    IF NOT dx_has_right(p_right) THEN RETURN false; END IF;
    RETURN obo IS NULL OR dx_member_has_right(obo, p_right);
END$$;

-- An object's address as the tool writes it: <type>:<identity> (design §6.3; the action manifest's conventions).
CREATE OR REPLACE FUNCTION dx_address(p_type text, p_names text[], p_args text[]) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(p_type, ' ', '_') || ':' || array_to_string(p_names, '.')
           || CASE WHEN p_args IS NULL OR cardinality(p_args) = 0 THEN
                   CASE WHEN p_type IN ('function', 'procedure', 'aggregate') THEN '()' ELSE '' END
              ELSE '(' || array_to_string(p_args, ',') || ')' END
$$;

-- ------------------------------------------------------------------ the Advisor's notes (new canonical — no notes table of this meaning in the estate)
CREATE TABLE IF NOT EXISTS dba_notes (
    id              bigserial PRIMARY KEY,
    author_member_id bigint NOT NULL REFERENCES members(id) ON DELETE RESTRICT,
    author_is_agent boolean NOT NULL DEFAULT false,
    agent_run_id    bigint,
    title           text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
    body            text NOT NULL CHECK (length(body) BETWEEN 1 AND 20000),
    change_set_ids  bigint[] NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dba_notes_created_idx ON dba_notes (created_at DESC);

CREATE OR REPLACE FUNCTION dx_dba_notes_before() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.author_is_agent := COALESCE((SELECT m.member_kind = 'agent' FROM members m WHERE m.id = NEW.author_member_id), false);
    IF NOT dx_member_has_right(NEW.author_member_id, 'health.read') THEN
        RAISE EXCEPTION 'Your role does not let you post a DBA note.' USING ERRCODE = '42501';
    END IF;
    IF NOT NEW.change_set_ids <@ ARRAY(SELECT id FROM change_sets WHERE id = ANY (NEW.change_set_ids)) THEN
        RAISE EXCEPTION 'A note names a change set that does not exist.' USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END$$;
DROP TRIGGER IF EXISTS dba_notes_before ON dba_notes;
CREATE TRIGGER dba_notes_before BEFORE INSERT ON dba_notes FOR EACH ROW EXECUTE FUNCTION dx_dba_notes_before();
GRANT SELECT, INSERT ON dba_notes TO developer_rw;
GRANT USAGE ON SEQUENCE dba_notes_id_seq TO developer_rw;

-- ------------------------------------------------------------------ the visible targets (design §3: the class shows the structure)
CREATE OR REPLACE VIEW mcp_visible_targets WITH (security_barrier = true) AS
SELECT t.id, t.datname, t.class
  FROM target_databases t
 WHERE t.gone_at IS NULL
   AND (SELECT dx_caller_may('catalog.read'))
   AND (   t.class IN ('application', 'development', 'kernel')
        OR (t.class = 'memory' AND (SELECT dx_caller_may('memory.read')))
        OR (t.class = 'own' AND (SELECT dx_is_developer_admin()) AND (SELECT dx_on_behalf_of()) IS NULL)
        OR (t.class = 'workbench' AND EXISTS (SELECT 1 FROM workbenches w
                                               WHERE w.target_database_id = t.id AND w.dropped_at IS NULL
                                                 AND w.owner_member_id = COALESCE((SELECT dx_on_behalf_of()), (SELECT dx_current_member_id())))));

CREATE OR REPLACE VIEW mcp_target_databases WITH (security_barrier = true) AS
SELECT t.id AS target_id, t.datname, COALESCE(t.label, t.datname) AS label, t.class, t.application_key, t.private_by_design, t.colour,
       t.grants_state, t.size_bytes, t.pg_version, t.extensions, t.has_maludb, t.memory_schemas, t.first_seen_at, t.last_seen_at, t.hidden,
       dx_person_level(COALESCE((SELECT dx_on_behalf_of()), (SELECT dx_current_member_id())), t.id) AS my_level
  FROM target_databases t
  JOIN mcp_visible_targets v ON v.id = t.id;

CREATE OR REPLACE VIEW mcp_catalog_index WITH (security_barrier = true) AS
SELECT c.id, v.datname, c.target_database_id AS target_id, dx_address(c.obj_type, c.obj_names, c.obj_args) AS address, c.obj_type, c.family,
       c.schema_name, c.name, c.owner_name, c.comment, c.extension_name, c.is_system, c.columns, c.search_text, c.indexed_at
  FROM catalog_index c
  JOIN mcp_visible_targets v ON v.id = c.target_database_id
 WHERE v.class <> 'memory';                 -- the memory databases are read through the memory section only

CREATE OR REPLACE VIEW mcp_registry_changes WITH (security_barrier = true) AS
SELECT a.id, a.occurred_at AS at, t.datname, a.action AS change, a.before, a.after, m.display_name AS by_name, a.source
  FROM activity_log a
  LEFT JOIN target_databases t ON t.id = a.target_database_id
  LEFT JOIN members m ON m.id = a.actor_member_id
 WHERE (SELECT dx_caller_may('registry.manage'))
   AND a.action IN ('registry.confirm', 'registry.update', 'registry.discover', 'registry.appeared', 'registry.gone', 'grants.change');

CREATE OR REPLACE VIEW mcp_access_levels WITH (security_barrier = true) AS
SELECT ta.id AS access_id, t.datname, ta.principal_kind, ta.member_id, m.display_name AS member_name, ta.role_key, ta.level, ta.reason,
       g.display_name AS granted_by_name, ta.granted_at
  FROM target_access ta
  JOIN target_databases t ON t.id = ta.target_database_id
  LEFT JOIN members m ON m.id = ta.member_id
  LEFT JOIN members g ON g.id = ta.granted_by
 WHERE ta.revoked_at IS NULL
   AND (SELECT dx_caller_may('access.manage'));

CREATE OR REPLACE VIEW mcp_column_classes WITH (security_barrier = true) AS
SELECT cc.id, v.datname, cc.schema_name, cc.relation_name, cc.column_name, cc.class, cc.kind, cc.pattern_match, cc.proposed_by,
       m.display_name AS confirmed_by_name, cc.confirmed_at, cc.cleared_by_super_admin
  FROM column_classes cc
  JOIN mcp_visible_targets v ON v.id = cc.target_database_id
  LEFT JOIN members m ON m.id = cc.confirmed_by;

CREATE OR REPLACE VIEW mcp_schema_changes WITH (security_barrier = true) AS
SELECT s.id AS snapshot_id, v.datname, s.taken_at AS at, dx_address(o.obj_type, o.obj_names, o.obj_args) AS address, o.obj_type, o.change,
       o.ddl_sha256, o.explained_by, o.explained_ref
  FROM snapshot_objects o
  JOIN catalog_snapshots s ON s.id = o.snapshot_id
  JOIN mcp_visible_targets v ON v.id = s.target_database_id
 WHERE o.change IS NOT NULL AND o.change <> 'same';

-- ------------------------------------------------------------------ changes
CREATE OR REPLACE VIEW mcp_change_sets WITH (security_barrier = true) AS
SELECT cs.id AS change_set_id, cs.title, t.datname, t.class AS target_class, cs.origin, cs.state, cs.author_member_id, m.display_name AS author_name,
       cs.author_is_agent, cs.row_count, cs.lint_summary, cs.reviewed_at, cs.rehearsed_at, cs.applied_at, ab.display_name AS applied_by_name,
       cs.window_id, cs.discarded_at, cs.failed_at, cs.undo_state, cs.undo_of, cs.created_at, cs.updated_at
  FROM change_sets cs
  JOIN target_databases t ON t.id = cs.target_database_id
  LEFT JOIN members m ON m.id = cs.author_member_id
  LEFT JOIN members ab ON ab.id = cs.applied_by
 WHERE cs.target_database_id IN (SELECT id FROM mcp_visible_targets)
    OR cs.author_member_id = (SELECT dx_current_member_id());

-- An applied grid change set's statements are composed with bound values ($n): no value is in an item, and the before-images
-- (row_images) are never exposed to a read role.
CREATE OR REPLACE VIEW mcp_change_set_items WITH (security_barrier = true) AS
SELECT i.id AS item_id, i.change_set_id, i.position, i.statement, i.class, i.annotations, i.lock_source, i.lint, i.literals, i.rehearsal,
       i.status, i.sqlstate, i.error_masked, i.rows_affected, i.ms
  FROM change_set_items i
 WHERE i.change_set_id IN (SELECT change_set_id FROM mcp_change_sets);

CREATE OR REPLACE VIEW mcp_rehearsals WITH (security_barrier = true) AS
SELECT r.id AS rehearsal_id, r.change_set_id, r.status, r.results, r.error, r.started_at, r.finished_at, m.display_name AS requested_by_name
  FROM rehearsals r
  LEFT JOIN members m ON m.id = r.requested_by
 WHERE r.change_set_id IN (SELECT change_set_id FROM mcp_change_sets);

CREATE OR REPLACE VIEW mcp_migration_drafts WITH (security_barrier = true) AS
SELECT d.id AS draft_id, d.file_name, d.application_key, t.datname, d.change_set_id, d.state, d.agent_authored AS author_is_agent,
       m.display_name AS author_name, d.body, d.literal_flags, d.created_at, d.downloaded_at, d.observed_at AS observed_applied_at
  FROM migration_drafts d
  JOIN target_databases t ON t.id = d.target_database_id
  LEFT JOIN members m ON m.id = d.created_by
 WHERE (SELECT dx_caller_may('catalog.read'))
   AND (d.target_database_id IN (SELECT id FROM mcp_visible_targets) OR d.created_by = (SELECT dx_current_member_id()));

-- Titles and sources of every workbench (an agent sees that a workbench exists, never its contents — its structure is a target the
-- owner alone reaches through mcp_visible_targets).
CREATE OR REPLACE VIEW mcp_workbenches WITH (security_barrier = true) AS
SELECT w.id AS workbench_id, w.title, w.datname, w.kind, w.owner_member_id, m.display_name AS owner_name, s.datname AS source_datname, w.cloned_at,
       w.status, w.size_bytes, w.quota_bytes, w.suspended_at, w.expires_at, w.created_at
  FROM workbenches w
  LEFT JOIN members m ON m.id = w.owner_member_id
  LEFT JOIN target_databases s ON s.id = w.source_target_id
 WHERE w.dropped_at IS NULL
   AND (SELECT dx_caller_may('catalog.read'));

-- ------------------------------------------------------------------ queries, plans, operations
CREATE OR REPLACE VIEW mcp_saved_queries WITH (security_barrier = true) AS
SELECT q.id AS saved_query_id, q.title, q.description, q.sql, q.parameters, t.datname, q.shared, q.owner_member_id, m.display_name AS owner_name,
       q.verified_at IS NOT NULL AS verified, v.display_name AS verified_by_name, q.verified_at, q.unverified_reason, q.updated_at
  FROM saved_queries q
  LEFT JOIN target_databases t ON t.id = q.target_database_id
  LEFT JOIN members m ON m.id = q.owner_member_id
  LEFT JOIN members v ON v.id = q.verified_by
 WHERE q.deleted_at IS NULL
   AND (SELECT dx_caller_may('catalog.read'))
   AND (q.owner_member_id = (SELECT dx_current_member_id()) OR q.shared);

CREATE OR REPLACE VIEW mcp_explain_plans WITH (security_barrier = true) AS
SELECT p.id AS plan_id, t.datname, p.member_id, m.display_name AS created_by_name, p.options, p.executed AS analyzed, p.plan, p.flags, p.comment,
       p.created_at
  FROM explain_plans p
  JOIN target_databases t ON t.id = p.target_database_id
  LEFT JOIN members m ON m.id = p.member_id
 WHERE (SELECT dx_caller_may('plans.explain'))
   AND p.member_id = COALESCE((SELECT dx_on_behalf_of()), (SELECT dx_current_member_id()));

CREATE OR REPLACE VIEW mcp_maintenance_jobs WITH (security_barrier = true) AS
SELECT j.id AS job_id, v.datname, j.operation, dx_address(j.obj_type, j.obj_names, NULL) AS address, j.lock_note, j.status, j.progress,
       m.display_name AS requested_by_name, j.requested_at, j.started_at, j.finished_at, j.error_masked
  FROM maintenance_jobs j
  JOIN mcp_visible_targets v ON v.id = j.target_database_id
  LEFT JOIN members m ON m.id = j.requested_by
 WHERE (SELECT dx_caller_may('health.read'));

CREATE OR REPLACE VIEW mcp_backup_marks WITH (security_barrier = true) AS
SELECT b.datname, b.kind, b.taken_at, b.note
  FROM backup_marks b
 WHERE (SELECT dx_caller_may('health.read'))
   AND b.datname IN (SELECT datname FROM mcp_visible_targets);

-- Windows are a person's business: the holder's own, or every one for a super-admin (window.approve). An agent holds neither right.
CREATE OR REPLACE VIEW mcp_access_windows WITH (security_barrier = true) AS
SELECT w.id AS window_id, t.datname, w.mode, w.member_id, m.display_name AS member_name, w.reason, w.minutes, w.status, w.requested_at,
       w.starts_at, w.expires_at, w.ended_at, w.ended_by_kind, d.display_name AS decided_by_name, w.self_approved,
       (SELECT count(*) FROM change_sets cs WHERE cs.window_id = w.id AND cs.state = 'applied') AS change_sets_applied
  FROM access_windows w
  JOIN target_databases t ON t.id = w.target_database_id
  LEFT JOIN members m ON m.id = w.member_id
  LEFT JOIN members d ON d.id = w.decided_by
 WHERE (SELECT dx_caller_may('window.approve'))
    OR (w.member_id = (SELECT dx_current_member_id()) AND (SELECT dx_caller_may('window.request')));

CREATE OR REPLACE VIEW mcp_dba_notes WITH (security_barrier = true) AS
SELECT n.id AS note_id, n.title, n.body, n.change_set_ids, n.author_member_id, m.display_name AS author_name, n.author_is_agent, n.created_at
  FROM dba_notes n
  LEFT JOIN members m ON m.id = n.author_member_id
 WHERE (SELECT dx_caller_may('health.read'));

CREATE OR REPLACE VIEW mcp_agent_proposals WITH (security_barrier = true) AS
SELECT 'change_set'::text AS kind, cs.change_set_id AS id, cs.title, cs.datname, cs.author_member_id AS agent_member_id, cs.author_name AS agent_name,
       cs.state, cs.applied_by_name AS decided_by_name, COALESCE(cs.applied_at, cs.discarded_at, cs.failed_at) AS decided_at, cs.created_at
  FROM mcp_change_sets cs WHERE cs.author_is_agent
UNION ALL
SELECT 'draft', d.draft_id, d.file_name, d.datname, NULL, d.author_name, d.state, NULL, d.observed_applied_at, d.created_at
  FROM mcp_migration_drafts d WHERE d.author_is_agent
UNION ALL
SELECT 'note', n.note_id, n.title, NULL, n.author_member_id, n.author_name, 'posted', NULL, NULL, n.created_at
  FROM mcp_dba_notes n WHERE n.author_is_agent;

-- ------------------------------------------------------------------ the activity server's wall
-- A row is visible to a holder of catalog.read when it names no target or a visible one; the sensitive families (levels, windows,
-- reveals, raw session texts, the freeze, the audit) only to an auditor (audit.read) or to the person who acted.
CREATE OR REPLACE VIEW mcp_activity_log WITH (security_barrier = true) AS
SELECT a.id, a.occurred_at, a.actor_member_id, m.display_name AS actor_name, m.member_kind AS actor_kind, a.source, a.action, a.screen,
       a.entity_type, a.entity_id, t.datname, a.target_database_id, a.agent_run_id,
       -- before/after carry ids, classes, counts and rules only (design §6.10); they are passed through as the handlers wrote them
       a.before, a.after
  FROM activity_log a
  LEFT JOIN members m ON m.id = a.actor_member_id
  LEFT JOIN target_databases t ON t.id = a.target_database_id
 WHERE (SELECT dx_caller_may('catalog.read'))
   AND (a.target_database_id IS NULL OR a.target_database_id IN (SELECT id FROM mcp_visible_targets))
   AND (   NOT (a.action LIKE ANY (ARRAY['access.%', 'window.%', 'memory.reveal', 'memory.view', 'session.text_open', 'freeze.%', 'audit.%', 'settings.%']))
        OR a.actor_member_id = (SELECT dx_current_member_id())
        OR (SELECT dx_caller_may('audit.read')));

-- ------------------------------------------------------------------ grants (views only; no base table)
GRANT EXECUTE ON FUNCTION dx_on_behalf_of(), dx_caller_may(text), dx_address(text, text[], text[]) TO developer_rw, developer_records_ro, developer_activity_ro;
GRANT SELECT ON mcp_visible_targets, mcp_target_databases, mcp_catalog_index, mcp_registry_changes, mcp_access_levels, mcp_column_classes,
                mcp_schema_changes, mcp_change_sets, mcp_change_set_items, mcp_rehearsals, mcp_migration_drafts, mcp_workbenches,
                mcp_saved_queries, mcp_explain_plans, mcp_maintenance_jobs, mcp_backup_marks, mcp_access_windows, mcp_dba_notes,
                mcp_agent_proposals
   TO developer_records_ro, developer_rw;
GRANT SELECT ON mcp_activity_log, mcp_visible_targets TO developer_activity_ro;
GRANT SELECT ON mcp_activity_log TO developer_rw;
