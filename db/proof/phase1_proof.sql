-- Phase 1 proof of the reads (db/012): every mcp_* view read AS THE READ ROLE THAT SERVES IT, with app.member_id (and, for a chat turn,
-- app.on_behalf_of) set exactly as the MCP servers set them. One transaction, rolled back; synthetic fixtures (example.invalid). Run after
-- db/proof/phase0_proof.sql by tests/phase0/schema.sh on a SCRATCH database.
\set QUIET on
\o /dev/null
BEGIN;
CREATE TEMP TABLE proof (n serial, ok boolean, label text);
GRANT ALL ON proof TO PUBLIC; GRANT ALL ON SEQUENCE proof_n_seq TO PUBLIC;
CREATE OR REPLACE FUNCTION pg_temp.check(b boolean, l text) RETURNS void LANGUAGE sql AS $$ INSERT INTO proof (ok, label) VALUES (COALESCE(b, false), l) $$;
CREATE OR REPLACE FUNCTION pg_temp.refused(p_sql text, p_like text, l text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO proof (ok, label) VALUES (false, l || ' (was NOT refused)');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO proof (ok, label) VALUES (SQLERRM ILIKE '%' || p_like || '%', l || CASE WHEN SQLERRM ILIKE '%' || p_like || '%' THEN '' ELSE ' (said: ' || SQLERRM || ')' END);
    END;
END$$;
-- act as a read role for member p (on behalf of o): what the MCP servers do per call
CREATE OR REPLACE FUNCTION pg_temp.as_reader(r text, p bigint, o bigint DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('app.member_id', COALESCE(p::text, ''), true);
    PERFORM set_config('app.on_behalf_of', COALESCE(o::text, ''), true);
    EXECUTE format('SET LOCAL ROLE %I', r);
END$$;
CREATE OR REPLACE FUNCTION pg_temp.n(q text) RETURNS bigint LANGUAGE plpgsql AS $$ DECLARE c bigint; BEGIN EXECUTE 'SELECT count(*) FROM (' || q || ') x' INTO c; RETURN c; END$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO PUBLIC;

-- ================================================================ fixtures (as postgres)
INSERT INTO members (id, member_kind, display_name, email, business_role, is_external, status, capability, roles) VALUES
 (1,  'human', 'SMOKE Owner',  'owner@example.invalid', 'super_admin', false, 'active', 'admin', '{admin}'),
 (26, 'human', 'SMOKE Priya',  'priya@example.invalid', 'user', false, 'active', 'write', '{engineer}'),
 (28, 'human', 'SMOKE Bea',    'bea@example.invalid',   'user', false, 'active', 'write', '{}'),
 (29, 'human', 'SMOKE Ann',    'ann@example.invalid',   'user', true,  'active', 'read',  '{viewer}'),
 (30, 'human', 'SMOKE Dana',   'dana@example.invalid',  'user', false, 'active', 'write', '{dba}'),
 (40, 'agent', 'SMOKE Expert', NULL, 'user', false, 'active', 'write', '{engineer}'),
 (41, 'agent', 'SMOKE Watcher', NULL, 'user', false, 'active', NULL, '{}'),
 (42, 'agent', 'SMOKE Advisor', NULL, 'user', false, 'active', 'write', '{engineer}');
INSERT INTO target_databases (datname, class, application_key, grants_state) VALUES
 ('subello_gl', 'application', 'gl', 'in_place'), ('certstudy', 'kernel', NULL, 'not_needed'), ('certstudy_memory', 'memory', NULL, 'not_needed'),
 ('hr_dev', 'development', 'hr', 'pending'), ('postgres', 'system', NULL, 'not_needed'), ('stray_db', 'unclassified', NULL, 'pending'),
 ('dxw_1', 'workbench', NULL, 'not_needed'), ('dxw_2', 'workbench', NULL, 'not_needed');
INSERT INTO target_databases (datname, class, grants_state) VALUES (current_database(), 'own', 'not_needed');
INSERT INTO workbenches (target_database_id, datname, role_name, owner_member_id, title, kind, quota_bytes, expires_at, status)
SELECT id, datname, datname, CASE datname WHEN 'dxw_1' THEN 26 ELSE 30 END, 'bench ' || datname, 'empty', 1073741824, now() + interval '1 day', 'ready'
  FROM target_databases WHERE class = 'workbench';
INSERT INTO catalog_index (target_database_id, obj_type, obj_names, family, schema_name, name, search_text)
SELECT id, 'table', ARRAY['public', 'invoices'], 'tables', 'public', 'invoices', 'invoices customer_id' FROM target_databases WHERE datname IN ('subello_gl', 'certstudy', 'certstudy_memory', 'dxw_2', 'stray_db');
INSERT INTO target_access (target_database_id, principal_kind, member_id, level, granted_by) SELECT id, 'member', 26, 'masked', 1 FROM target_databases WHERE datname = 'subello_gl';
INSERT INTO saved_queries (owner_member_id, title, sql, shared) VALUES (26, 'mine private', 'SELECT 1', false), (26, 'mine shared', 'SELECT 2', true), (30, 'Dana private', 'SELECT 3', false);
INSERT INTO change_sets (target_database_id, origin, author_member_id, title)
SELECT id, 'agent_proposal', 40, 'an index for the FK' FROM target_databases WHERE datname = 'subello_gl';
INSERT INTO change_sets (target_database_id, origin, author_member_id, title)
SELECT id, 'form', 30, 'on Dana''s bench' FROM target_databases WHERE datname = 'dxw_2';
INSERT INTO access_windows (member_id, target_database_id, mode, reason, minutes, status, handoff_at)
SELECT 30, id, 'write', 'two rows', 30, 'requested', now() FROM target_databases WHERE datname = 'subello_gl';
INSERT INTO activity_log (actor_member_id, source, action, entity_type, entity_id, target_database_id)
SELECT 1, 'web', a, 'target', id, id FROM target_databases, unnest(ARRAY['registry.confirm', 'access.grant', 'change_set.apply']) a WHERE datname = 'subello_gl';
INSERT INTO activity_log (actor_member_id, source, action, entity_type, entity_id, target_database_id)
SELECT 30, 'web', 'change_set.apply', 'change_set', 9, id FROM target_databases WHERE datname = 'dxw_2';
INSERT INTO dba_notes (author_member_id, title, body) VALUES (42, 'Monday note', 'Two unindexed foreign keys on subello_gl.');

-- ================================================================ the dba_notes trigger
SELECT pg_temp.check((SELECT author_is_agent FROM dba_notes WHERE author_member_id = 42), 'a note by the Advisor is marked an agent''s');
SELECT pg_temp.refused($$INSERT INTO dba_notes (author_member_id, title, body) VALUES (41, 'x', 'y')$$, 'role does not let', 'an agent not admitted posts no note');
SELECT pg_temp.refused($$INSERT INTO dba_notes (author_member_id, title, body) VALUES (28, 'x', 'y')$$, 'role does not let', 'nor a person sent no roles');
SELECT pg_temp.refused($$INSERT INTO dba_notes (author_member_id, title, body, change_set_ids) VALUES (42, 'x', 'y', '{999999}')$$, 'does not exist', 'a note names only change sets that exist');

-- ================================================================ the visible targets, as developer_records_ro
SELECT pg_temp.as_reader('developer_records_ro', 26);
SELECT pg_temp.check((SELECT array_agg(datname ORDER BY datname) FROM mcp_visible_targets) = ARRAY['certstudy', 'certstudy_memory', 'dxw_1', 'hr_dev', 'subello_gl'],
                     'Priya sees the application, the kernel (structure), the development database, the memory database (memory.read) and her own workbench');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM mcp_visible_targets WHERE datname IN ('postgres', 'stray_db', 'dxw_2') OR class = 'own'),
                     '…never system, unclassified, another person''s workbench or the tool''s own database');
SELECT pg_temp.check((SELECT my_level FROM mcp_target_databases WHERE datname = 'subello_gl') = 'masked', '…and her level on each (masked on the GL)');
SELECT pg_temp.check((SELECT array_agg(datname ORDER BY datname) FROM mcp_catalog_index) = ARRAY['certstudy', 'subello_gl'],
                     'catalog search: the visible targets'' objects, never a memory database''s, another''s workbench''s or an unclassified one''s');
SELECT pg_temp.check((SELECT address FROM mcp_catalog_index LIMIT 1) = 'table:public.invoices', 'an object''s address is <type>:<identity>');
SELECT pg_temp.as_reader('developer_records_ro', 1);
SELECT pg_temp.check(EXISTS (SELECT 1 FROM mcp_visible_targets WHERE class = 'own'), 'an admin sees the tool''s own database');
SELECT pg_temp.as_reader('developer_records_ro', 28);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_visible_targets') = 0 AND pg_temp.n('SELECT * FROM mcp_catalog_index') = 0, 'a member sent no roles sees nothing');
SELECT pg_temp.as_reader('developer_records_ro', 41);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_visible_targets') = 0, 'an agent not admitted sees nothing');

-- K38: an agent in a person's chat turn
SELECT pg_temp.as_reader('developer_records_ro', 40);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_visible_targets') = 4 AND NOT EXISTS (SELECT 1 FROM mcp_visible_targets WHERE class = 'workbench'),
                     'the Expert on a duty: the classes'' structure, and no workbench (agents own none)');
SELECT pg_temp.as_reader('developer_records_ro', 40, 28);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_visible_targets') = 0, 'the Expert in the turn of a person with no role here sees nothing (K38)');
SELECT pg_temp.as_reader('developer_records_ro', 40, 26);
SELECT pg_temp.check(EXISTS (SELECT 1 FROM mcp_visible_targets WHERE datname = 'dxw_1')
                     AND (SELECT my_level FROM mcp_target_databases WHERE datname = 'subello_gl') = 'masked',
                     '…in Priya''s turn: what Priya may see, her workbench''s structure included, at her level');
SELECT pg_temp.as_reader('developer_records_ro', 40, 29);
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM mcp_visible_targets WHERE class = 'workbench') AND EXISTS (SELECT 1 FROM mcp_visible_targets WHERE datname = 'subello_gl'),
                     '…in a Viewer''s turn: the Viewer''s targets');

-- ================================================================ admin-only, people-only and own views
SELECT pg_temp.as_reader('developer_records_ro', 26);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_registry_changes') = 0 AND pg_temp.n('SELECT * FROM mcp_access_levels') = 0,
                     'an Engineer reads neither the registry''s changes nor the access levels');
SELECT pg_temp.as_reader('developer_records_ro', 1);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_registry_changes') = 1 AND pg_temp.n('SELECT * FROM mcp_access_levels') = 1, '…a super-admin reads both');
SELECT pg_temp.as_reader('developer_records_ro', 40);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_access_windows') = 0, 'an agent reads no window');
SELECT pg_temp.as_reader('developer_records_ro', 30);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_access_windows') = 1, 'a DBA reads her own window');
SELECT pg_temp.as_reader('developer_records_ro', 26);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_access_windows') = 0, '…an Engineer (no window.request) reads none');
SELECT pg_temp.as_reader('developer_records_ro', 1);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_access_windows') = 1, '…a super-admin reads every one');
SELECT pg_temp.as_reader('developer_records_ro', 30);
SELECT pg_temp.check((SELECT array_agg(title ORDER BY title) FROM mcp_saved_queries) = ARRAY['Dana private', 'mine shared'], 'saved queries: my own and the shared, never another''s private one');
SELECT pg_temp.check((SELECT array_agg(title ORDER BY title) FROM mcp_change_sets) = ARRAY['an index for the FK', 'on Dana''s bench'],
                     'change sets: on visible targets, and my own on my workbench');
SELECT pg_temp.as_reader('developer_records_ro', 26);
SELECT pg_temp.check((SELECT array_agg(title) FROM mcp_change_sets) = ARRAY['an index for the FK'], '…never one on another person''s workbench');
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_workbenches') = 2, 'every workbench''s title and source is listed (its contents are its owner''s)');
SELECT pg_temp.check((SELECT array_agg(kind ORDER BY kind) FROM mcp_agent_proposals) = ARRAY['change_set', 'note'], 'the agents'' proposals: the Expert''s change set and the Advisor''s note');
SELECT pg_temp.refused($$SELECT * FROM change_sets$$, 'permission denied', 'the records role reads no base table');
SELECT pg_temp.refused($$SELECT * FROM row_images$$, 'permission denied', '…not the before-images');
SELECT pg_temp.refused($$INSERT INTO dba_notes (author_member_id, title, body) VALUES (42, 'x', 'y')$$, 'permission denied', '…and writes nothing');

-- ================================================================ the activity server's wall, as developer_activity_ro
SELECT pg_temp.as_reader('developer_activity_ro', 26);
SELECT pg_temp.check((SELECT array_agg(action ORDER BY action) FROM mcp_activity_log) = ARRAY['change_set.apply', 'registry.confirm'],
                     'activity: an Engineer sees the GL''s change and its registry entry — not the level granted, not another''s workbench');
SELECT pg_temp.as_reader('developer_activity_ro', 1);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_activity_log WHERE action = ''access.grant''') = 1, '…an auditor (a super-admin) sees the levels'' rows');
SELECT pg_temp.as_reader('developer_activity_ro', 30);
SELECT pg_temp.check(pg_temp.n('SELECT * FROM mcp_activity_log WHERE datname = ''dxw_2''') = 1, '…the owner sees her workbench''s rows');
SELECT pg_temp.refused($$SELECT * FROM mcp_change_sets$$, 'permission denied', 'the activity role reads only the activity view');

RESET ROLE;
\o
SELECT CASE WHEN ok THEN 'ok   ' ELSE 'FAIL ' END || label FROM proof ORDER BY n;
SELECT ' ' || count(*) FILTER (WHERE ok) || ' ok, ' || count(*) FILTER (WHERE NOT ok) || ' failed' FROM proof;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM proof WHERE NOT ok) THEN RAISE EXCEPTION 'the Phase 1 reads proof failed'; END IF; END $$;
ROLLBACK;
