-- Phase 0 proof of the schema (docs/developer-design.md §10). Everything happens inside one transaction that is ROLLED BACK: fixtures
-- written as postgres, acting members set through app.member_id exactly as PHP and the door set it, grants read as the read roles.
-- Fixtures are synthetic (example.invalid). Run as postgres on a SCRATCH database — never the installed one — after loading every
-- migration in order (tests/phase0/schema.sh, or tests/phase0/run.sh after tests/setup_dev.sh):
--   sudo -n -u postgres psql -v ON_ERROR_STOP=1 -d dx_proof -f db/proof/phase0_proof.sql; echo "exit $?"
-- Prints one line per check (ok / FAIL) and the count; exits non-zero when any check failed.
\set QUIET on
\o /dev/null
BEGIN;
CREATE TEMP TABLE proof (n serial, ok boolean, label text);
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
CREATE OR REPLACE FUNCTION pg_temp.as_member(p bigint) RETURNS void LANGUAGE sql AS $$ SELECT set_config('app.member_id', COALESCE(p::text, ''), true) $$;
CREATE OR REPLACE FUNCTION pg_temp.pol(c bigint, o bigint, d text) RETURNS jsonb LANGUAGE sql AS $$ SELECT dx_door_policy(c, o, d) $$;
CREATE OR REPLACE FUNCTION pg_temp.tid(d text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT id FROM target_databases WHERE datname = d $$;
CREATE TEMP TABLE keep (k text PRIMARY KEY, v bigint);
CREATE OR REPLACE FUNCTION pg_temp.put(k text, v bigint) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO keep VALUES (k, v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v RETURNING v $$;
CREATE OR REPLACE FUNCTION pg_temp.get(k text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT v FROM keep WHERE keep.k = $1 $$;

-- ================================================================ fixtures: every actor of §2
INSERT INTO members (id, member_kind, display_name, email, business_role, is_external, status, capability, roles) VALUES
 (1,  'human', 'SMOKE Owner',   'owner@example.invalid',  'super_admin', false, 'active', 'admin', '{admin}'),
 (2,  'human', 'SMOKE Second',  'second@example.invalid', 'super_admin', false, 'active', 'admin', '{admin}'),     -- a second super-admin
 (26, 'human', 'SMOKE Priya',   'priya@example.invalid',  'user',        false, 'active', 'write', '{engineer}'),
 (27, 'human', 'SMOKE Marco',   'marco@example.invalid',  'user',        false, 'active', 'admin', '{admin,dba}'),  -- admin role, NOT super
 (28, 'human', 'SMOKE Bea',     'bea@example.invalid',    'user',        false, 'active', 'write', '{}'),           -- no roles: nothing
 (29, 'human', 'SMOKE Ann',     'ann@example.invalid',    'user',        true,  'active', 'read',  '{viewer}'),     -- an external Viewer
 (30, 'human', 'SMOKE Dana',    'dana@example.invalid',   'user',        false, 'active', 'write', '{dba}'),
 (40, 'agent', 'SMOKE Expert',  NULL,                     'user',        false, 'active', 'write', '{engineer}'),
 (41, 'agent', 'SMOKE Watcher', NULL,                     'user',        false, 'active', NULL,    '{}'),
 (42, 'agent', 'SMOKE Advisor', NULL,                     'user',        false, 'active', 'write', '{engineer}'),
 (43, 'agent', 'SMOKE Ada',     NULL,                     'user',        false, 'active', 'admin', '{admin}');

-- ================================================================ the registry: proposals and constraints (§6.2)
SELECT pg_temp.check((SELECT class FROM dx_propose_class('dxw_7', false, '{gl}')) = 'workbench', 'precedence 1: the tool''s workbench name');
SELECT pg_temp.check((SELECT class FROM dx_propose_class('dx_template', false, '{gl}')) = 'system', '…the tool''s template is system');
SELECT pg_temp.check((SELECT class FROM dx_propose_class('postgres', false, '{gl}')) = 'system' AND (SELECT class FROM dx_propose_class('maludb', true, '{gl}')) = 'system',
                     'precedence 2: postgres and the maludb bootstrap are system (before the extension rule)');
SELECT pg_temp.check((SELECT class FROM dx_propose_class('certstudy', true, '{gl}')) = 'kernel', 'precedence 3: the kernel''s database by name');
SELECT pg_temp.check((SELECT class FROM dx_propose_class(current_database(), false, '{gl}')) = 'own', '…and the tool''s own');
SELECT pg_temp.check((SELECT class || ':' || application_key FROM dx_propose_class('subello_gl', false, '{gl,hr}')) = 'application:gl',
                     'precedence 4: subello_<key> for an installed application');
SELECT pg_temp.check((SELECT class FROM dx_propose_class('subello_cidery', true, '{gl}')) = 'memory', 'precedence 5: a database holding maludb_core (not an installed key)');
SELECT pg_temp.check((SELECT class || ':' || application_key FROM dx_propose_class('gl_dev2', false, '{gl}')) = 'development:gl', 'precedence 6: a development name');
SELECT pg_temp.check((SELECT class FROM dx_propose_class('cidery_dev', true, '{gl}')) = 'memory', '…after the extension rule');
SELECT pg_temp.check((SELECT class FROM dx_propose_class('somebody_else', false, '{gl}')) = 'unclassified', 'no rule matched: unclassified, an admin decides');

INSERT INTO target_databases (datname, class, application_key, private_by_design, grants_state, confirmed_by, confirmed_at) VALUES
 ('subello_gl',       'application', 'gl',       false, 'in_place', 1, now()),
 ('subello_malumail', 'application', 'malumail', true,  'in_place', 1, now()),
 ('certstudy',        'kernel',      NULL,       false, 'not_needed', 1, now()),
 ('certstudy_memory', 'memory',      NULL,       false, 'not_needed', 1, now()),
 ('hr_dev',           'development', 'hr',       false, 'pending', 1, now()),
 ('postgres',         'system',      NULL,       false, 'not_needed', 1, now()),
 ('stray_db',         'unclassified', NULL,      false, 'pending', NULL, NULL);
INSERT INTO target_databases (datname, class, grants_state, confirmed_by, confirmed_at) VALUES (current_database(), 'own', 'not_needed', 1, now());
SELECT pg_temp.refused($$INSERT INTO target_databases (datname, class) VALUES ('Bad-Name', 'unclassified')$$, 'check constraint', 'wall 1: a name outside ^[a-z0-9_]+$ is never registered');
SELECT pg_temp.refused($$INSERT INTO target_databases (datname, class) VALUES ('scratchy', 'workbench')$$, 'check constraint', 'a workbench is always named dxw_<n>');
SELECT pg_temp.refused($$INSERT INTO target_databases (datname, class) VALUES ('dxw_99', 'application')$$, 'check constraint', '…and the tool''s names are never another class');
SELECT pg_temp.refused($$INSERT INTO target_databases (datname, class, application_key, private_by_design) VALUES ('x_memory', 'memory', NULL, true)$$, 'check constraint', 'private by design only for an application');
SELECT pg_temp.refused($$INSERT INTO target_databases (datname, class) VALUES ('subello_x', 'application')$$, 'check constraint', 'an application names its key');

-- a workbench of Priya's (the door's lifecycle made the role and the database; this is its record)
INSERT INTO target_databases (datname, class, grants_state) VALUES ('dxw_1', 'workbench', 'not_needed');
INSERT INTO workbenches (target_database_id, datname, role_name, owner_member_id, title, kind, source_target_id, cloned_at, status, quota_bytes, expires_at)
VALUES (pg_temp.tid('dxw_1'), 'dxw_1', 'dxw_1', 26, 'GL index work', 'clone', pg_temp.tid('subello_gl'), now(), 'ready', 2147483648, now() + interval '14 days');
SELECT pg_temp.refused($$INSERT INTO workbenches (datname, role_name, owner_member_id, title, kind, quota_bytes, expires_at) VALUES ('dxw_2', 'dxw_2', 40, 'x', 'empty', 1, now() + interval '1 day')$$,
                       'agents have none', 'an agent never owns a workbench (design §5)');
SELECT pg_temp.refused($$INSERT INTO workbenches (datname, role_name, owner_member_id, title, kind, quota_bytes, expires_at) VALUES ('dxw_3', 'dxw_4', 26, 'x', 'empty', 1, now() + interval '1 day')$$,
                       'check constraint', 'a workbench''s role is its database''s name');
UPDATE dx_settings SET workbenches_per_person = 1;
SELECT pg_temp.refused($$INSERT INTO workbenches (datname, role_name, owner_member_id, title, kind, quota_bytes, expires_at) VALUES ('dxw_5', 'dxw_5', 26, 'x', 'empty', 1, now() + interval '1 day')$$,
                       'the most a person may keep', 'the per-person count holds');
UPDATE dx_settings SET workbenches_per_person = 5;

-- ================================================================ access levels (§3)
SELECT pg_temp.refused($$INSERT INTO target_access (target_database_id, principal_kind, member_id, level) VALUES (pg_temp.tid('subello_gl'), 'member', 40, 'masked')$$,
                       'agents read no rows', 'an agent is never given a level (wall 6)');
SELECT pg_temp.refused($$INSERT INTO target_access (target_database_id, principal_kind, member_id, level) VALUES (pg_temp.tid('subello_gl'), 'member', 26, 'rows')$$,
                       'data.unmask', 'the rows level only for a holder of data.unmask (an Engineer may not)');
SELECT pg_temp.refused($$INSERT INTO target_access (target_database_id, principal_kind, role_key, level) VALUES (pg_temp.tid('subello_gl'), 'role', 'engineer', 'rows')$$,
                       'data.unmask', '…nor a role that does not give it');
SELECT pg_temp.refused($$INSERT INTO target_access (target_database_id, principal_kind, member_id, level) VALUES (pg_temp.tid('certstudy'), 'member', 30, 'masked')$$,
                       'installed application', 'no level on the kernel''s database (structure only)');
INSERT INTO target_access (target_database_id, principal_kind, member_id, level, granted_by) VALUES
 (pg_temp.tid('subello_gl'), 'member', 26, 'masked', 1),
 (pg_temp.tid('subello_malumail'), 'member', 30, 'masked', 1),
 (pg_temp.tid('subello_gl'), 'member', 29, 'masked', 1),
 (pg_temp.tid('hr_dev'), 'member', 26, 'masked', 1);
INSERT INTO target_access (target_database_id, principal_kind, role_key, level, granted_by) VALUES (pg_temp.tid('subello_gl'), 'role', 'dba', 'rows', 1);
SELECT pg_temp.refused($$INSERT INTO target_access (target_database_id, principal_kind, member_id, level) VALUES (pg_temp.tid('subello_gl'), 'member', 26, 'masked')$$,
                       'duplicate key', 'one live level per principal and database');
SELECT pg_temp.check(dx_person_level(26, pg_temp.tid('subello_gl')) = 'masked', 'Priya (Engineer) reads the GL masked');
SELECT pg_temp.check(dx_person_level(30, pg_temp.tid('subello_gl')) = 'rows', 'Dana (DBA) reads it at rows — through her role''s grant');
SELECT pg_temp.check(dx_person_level(29, pg_temp.tid('subello_gl')) = 'structure', 'Ann holds a masked grant but no data.read (a Viewer): structure');
SELECT pg_temp.check(dx_person_level(28, pg_temp.tid('subello_gl')) = 'structure', 'Bea (no roles): structure');
SELECT pg_temp.check(dx_person_level(26, pg_temp.tid('certstudy')) = 'structure' AND dx_person_level(30, pg_temp.tid('certstudy_memory')) = 'structure',
                     'the kernel''s and the memory databases are structure for everyone');
UPDATE target_access SET revoked_at = now(), revoked_by = 1 WHERE member_id = 26 AND target_database_id = pg_temp.tid('subello_gl');
SELECT pg_temp.check(dx_person_level(26, pg_temp.tid('subello_gl')) = 'structure', 'a revoked level is gone');
INSERT INTO target_access (target_database_id, principal_kind, member_id, level, granted_by) VALUES (pg_temp.tid('subello_gl'), 'member', 26, 'masked', 1);

-- ================================================================ dx_door_policy (the one place §3 is compiled)
SELECT pg_temp.check((pg_temp.pol(999, NULL, 'subello_gl') ->> 'ok')::boolean = false AND pg_temp.pol(999, NULL, 'subello_gl') -> 'refusal' ->> 'rule' = 'member',
                     'an unknown member is refused (rule member)');
SELECT pg_temp.check((pg_temp.pol(41, NULL, 'subello_gl') ->> 'ok')::boolean = false, 'an agent not admitted is refused');
SELECT pg_temp.check((pg_temp.pol(28, NULL, 'subello_gl') ->> 'ok')::boolean = false, 'a member sent no roles is refused (fail closed)');
SELECT pg_temp.check(pg_temp.pol(26, NULL, 'stray_db') -> 'refusal' ->> 'rule' = 'unregistered' AND pg_temp.pol(26, NULL, 'postgres') -> 'refusal' ->> 'rule' = 'unregistered'
                     AND pg_temp.pol(26, NULL, 'no_such_db') -> 'refusal' ->> 'rule' = 'unregistered',
                     'wall 1: unclassified, system and unknown databases are never reached');
CREATE TEMP TABLE p_gl26 AS SELECT pg_temp.pol(26, NULL, 'subello_gl') AS j;
SELECT pg_temp.check((SELECT j ->> 'level' = 'masked' AND (j -> 'tiers') ? 'read_masked' AND NOT (j -> 'tiers') ? 'read' AND NOT (j -> 'tiers') ? 'write'
                             AND j -> 'ceiling' ->> 'dml' = 'never' AND j -> 'ceiling' ->> 'ddl' = 'draft' FROM p_gl26),
                     'Priya on the GL: masked, the masked tier only, no data changes, schema changes as a draft');
SELECT pg_temp.check((SELECT (j -> 'rights') ? 'migrations.draft' AND NOT (j -> 'rights') ? 'data.write' AND j -> 'target' ->> 'class' = 'application'
                             AND (j -> 'limits' ->> 'statement_timeout_ms')::int = 30000 AND (j -> 'limits' ->> 'show_rows')::int = 1000 FROM p_gl26),
                     '…her rights as held, the screen''s limits (30 s, 1,000 rows)');
CREATE TEMP TABLE p_gl30 AS SELECT pg_temp.pol(30, NULL, 'subello_gl') AS j;
SELECT pg_temp.check((SELECT j ->> 'level' = 'rows' AND (j -> 'tiers') ? 'read' AND j -> 'ceiling' ->> 'dml' = 'never' AND NOT (j -> 'tiers') ? 'write'
                             AND (j -> 'tiers') ? 'ops' FROM p_gl30),
                     'Dana (DBA) on the GL: rows and the ops tier; no writes without a window');
SELECT pg_temp.check((SELECT j ->> 'level' = 'structure' AND j -> 'tiers' = '["meta"]'::jsonb AND (j -> 'ceiling' ->> 'rows')::boolean = false
                        FROM (SELECT pg_temp.pol(30, NULL, 'certstudy') AS j) x),
                     'the kernel''s database: structure only, the meta tier alone (D2, (a))');
SELECT pg_temp.check((SELECT j ->> 'level' = 'structure' AND (j -> 'tiers') ? 'memory' AND NOT (j -> 'tiers') ? 'read' FROM (SELECT pg_temp.pol(30, NULL, 'certstudy_memory') AS j) x),
                     'a memory database: structure, the memory section''s tier, never a read tier');
SELECT pg_temp.check((SELECT j ->> 'level' = 'structure' AND j -> 'tiers' = '["meta"]'::jsonb FROM (SELECT pg_temp.pol(26, NULL, 'hr_dev') AS j) x),
                     'a development database whose grants are pending: structure, whatever the level');
SELECT pg_temp.check(pg_temp.pol(26, NULL, current_database()) -> 'refusal' ->> 'rule' = 'own' AND (pg_temp.pol(1, NULL, current_database()) ->> 'ok')::boolean,
                     'the tool''s own database is its admins''');
CREATE TEMP TABLE p_wb AS SELECT pg_temp.pol(26, NULL, 'dxw_1') AS j;
SELECT pg_temp.check((SELECT j ->> 'level' = 'rows' AND j -> 'ceiling' ->> 'dml' = 'live' AND j -> 'ceiling' ->> 'ddl' = 'live' AND (j -> 'tiers') ? 'workbench'
                             AND j -> 'workbench' ->> 'role' = 'dxw_1' AND (j -> 'limits' ->> 'statement_timeout_ms')::int = 300000 FROM p_wb),
                     'Priya''s workbench: live DDL and DML as its own role, 300 s');
SELECT pg_temp.check(pg_temp.pol(30, NULL, 'dxw_1') -> 'refusal' ->> 'rule' = 'workbench', 'another person''s workbench is refused');
CREATE TEMP TABLE p_ex AS SELECT pg_temp.pol(40, NULL, 'subello_gl') AS j;
SELECT pg_temp.check((SELECT j ->> 'level' = 'structure' AND (j -> 'caller' ->> 'is_agent')::boolean AND NOT (j -> 'tiers') ? 'read' AND NOT (j -> 'tiers') ? 'write'
                             AND (j -> 'rights') ? 'catalog.read' AND (j -> 'rights') ? 'changes.prepare' AND NOT (j -> 'rights') ? 'data.read'
                             AND NOT (j -> 'rights') ? 'workbench.apply' AND NOT (j -> 'rights') ? 'exports.make' FROM p_ex),
                     'the Expert (an agent, Engineer): structure only, no row tier, its people rights absent (wall 6)');
SELECT pg_temp.check(pg_temp.pol(40, 28, 'subello_gl') -> 'refusal' ->> 'rule' = 'on_behalf_of', 'in a chat turn for someone with no role here: refused (K38)');
SELECT pg_temp.check((SELECT NOT (j -> 'rights') ? 'changes.prepare' AND (j -> 'rights') ? 'catalog.read' AND j -> 'on_behalf_of' ->> 'member_id' = '29'
                        FROM (SELECT pg_temp.pol(40, 29, 'subello_gl') AS j) x),
                     '…for a Viewer: its rights intersected with the Viewer''s');
SELECT pg_temp.check((SELECT NOT (j -> 'rights') ? 'freeze' AND NOT (j -> 'rights') ? 'access.manage' AND NOT (j -> 'rights') ? 'data.write'
                        FROM (SELECT pg_temp.pol(43, NULL, 'subello_gl') AS j) x),
                     'Ada (an agent given admin) holds no super-admin and no people right');

-- ================================================================ windows (§3 wall 4)
SELECT pg_temp.as_member(26);
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('subello_gl'), 'write', 30, 'fix two rows', now())$$, 'role does not let', 'an Engineer may not ask for a window');
SELECT pg_temp.as_member(30);
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('subello_gl'), 'write', 30, 'fix two rows', now() - interval '20 minutes')$$, 'from the launcher', 'the step-up: a stale sign-on is refused');
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('certstudy'), 'write', 30, 'fix two rows', now())$$, 'installed application', 'no window on the kernel''s database');
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('subello_gl'), 'write', 600, 'fix two rows', now())$$, 'minutes', 'at most window_max_minutes');
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('subello_gl'), 'read', 30, 'look', now())$$, 'private-by-design', 'a read window only on a private-by-design database');
SELECT pg_temp.put('w1', dx_window_request(pg_temp.tid('subello_gl'), 'write', 30, 'fix two rows in invoices', now()));
SELECT pg_temp.check((SELECT status = 'requested' AND NOT self_approved FROM access_windows WHERE id = pg_temp.get('w1')), 'a DBA''s window waits for a super-admin');
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('subello_gl'), 'write', 30, 'again', now())$$, 'duplicate key', 'one live window per person, database and mode');
SELECT pg_temp.refused($$SELECT dx_window_decide(pg_temp.get('w1'), true)$$, 'super-admin', 'nobody decides their own (and a DBA decides none)');
SELECT pg_temp.as_member(27);
SELECT pg_temp.refused($$SELECT dx_window_decide(pg_temp.get('w1'), true)$$, 'super-admin', 'Marco, holding the admin role but no super-admin, decides nothing');
SELECT pg_temp.as_member(1);
SELECT dx_window_decide(pg_temp.get('w1'), true, 'go ahead');
SELECT pg_temp.check((SELECT status = 'open' AND decided_by = 1 AND expires_at BETWEEN now() + interval '29 minutes' AND now() + interval '31 minutes' FROM access_windows WHERE id = pg_temp.get('w1')),
                     'a super-admin approves: open for its minutes');
CREATE TEMP TABLE p_w30 AS SELECT pg_temp.pol(30, NULL, 'subello_gl') AS j;
SELECT pg_temp.check((SELECT j -> 'ceiling' ->> 'dml' = 'window' AND (j -> 'tiers') ? 'write' AND (j -> 'window' -> 'write' ->> 'id')::bigint = pg_temp.get('w1') FROM p_w30),
                     'inside the window: the write tier, the window named');
SELECT pg_temp.put('w_self', dx_window_request(pg_temp.tid('subello_gl'), 'write', 15, 'owner check', now()));
SELECT pg_temp.check((SELECT status = 'open' AND self_approved FROM access_windows WHERE id = pg_temp.get('w_self')), 'a super-admin''s own window opens at once (self-approved)');
SELECT pg_temp.put('notified', dx_notify_self_approved_window(pg_temp.get('w_self')));
SELECT pg_temp.check(pg_temp.get('notified') = 1 AND EXISTS (SELECT 1 FROM notifications WHERE member_id = 2 AND kind = 'window_opened_by_super_admin')
                     AND NOT EXISTS (SELECT 1 FROM notifications WHERE member_id = 1 AND kind = 'window_opened_by_super_admin'),
                     '…and every other super-admin is told at once (not the one who opened it)');
-- a read window on the private database
SELECT pg_temp.as_member(30);
SELECT pg_temp.check(pg_temp.pol(30, NULL, 'subello_malumail') ->> 'level' = 'structure', 'a private-by-design database: structure until a read window opens, whatever the level');
SELECT pg_temp.put('w_read', dx_window_request(pg_temp.tid('subello_malumail'), 'read', 20, 'a customer''s complaint', now()));
SELECT pg_temp.as_member(2);
SELECT dx_window_decide(pg_temp.get('w_read'), true);
SELECT pg_temp.check(pg_temp.pol(30, NULL, 'subello_malumail') ->> 'level' = 'masked', '…inside it, the person''s level (masked)');
SELECT pg_temp.as_member(30);
SELECT dx_window_end(pg_temp.get('w_read'));
SELECT pg_temp.check((SELECT status = 'ended' AND ended_by_kind = 'member' FROM access_windows WHERE id = pg_temp.get('w_read'))
                     AND pg_temp.pol(30, NULL, 'subello_malumail') ->> 'level' = 'structure', 'its holder ends it, and the level falls back');
UPDATE access_windows SET expires_at = now() - interval '1 second', starts_at = now() - interval '1 hour' WHERE id = pg_temp.get('w_self');
SELECT pg_temp.put('expired', dx_windows_expire());
SELECT pg_temp.check(pg_temp.get('expired') = 1 AND (SELECT status FROM access_windows WHERE id = pg_temp.get('w_self')) = 'expired', 'the worker expires an open window past its time');

-- ================================================================ change sets (§6.5, §6.6) — the second wall
SELECT pg_temp.as_member(26);
INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('subello_gl'), 'form', 26, 'an index on invoices') RETURNING pg_temp.put('cs_ddl', id);
INSERT INTO change_set_items (change_set_id, position, statement, class) VALUES (pg_temp.get('cs_ddl'), 1, 'CREATE INDEX CONCURRENTLY invoices_customer_idx ON invoices (customer_id)', 'ddl');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 26 WHERE id = pg_temp.get('cs_ddl')$$, 'goes from draft', 'draft → applied is not a transition');
UPDATE change_sets SET state = 'reviewed', reviewed_at = now() WHERE id = pg_temp.get('cs_ddl');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 26 WHERE id = pg_temp.get('cs_ddl')$$, 'migration draft', 'DDL on an installed application is never applied (D4)');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'drafted_as_migration' WHERE id = pg_temp.get('cs_ddl')$$, 'goes from reviewed', 'a migration draft only once rehearsed');
UPDATE change_sets SET state = 'rehearsed', rehearsed_at = now() WHERE id = pg_temp.get('cs_ddl');
UPDATE change_sets SET state = 'drafted_as_migration' WHERE id = pg_temp.get('cs_ddl');
SELECT pg_temp.check((SELECT state FROM change_sets WHERE id = pg_temp.get('cs_ddl')) = 'drafted_as_migration', '…rehearsed, it becomes a draft');
INSERT INTO migration_drafts (change_set_id, target_database_id, application_key, file_number, slug, body, sql_sha256, created_by)
VALUES (pg_temp.get('cs_ddl'), pg_temp.tid('subello_gl'), 'gl', 21, 'invoices_customer_idx', '-- header\nCREATE INDEX …', repeat('a', 64), 26) RETURNING pg_temp.put('md', id);
SELECT pg_temp.check((SELECT file_name FROM migration_drafts WHERE id = pg_temp.get('md')) = '021_invoices_customer_idx.sql', 'the draft''s file name is the application''s next number');
UPDATE migration_drafts SET file_number = NULL WHERE id = pg_temp.get('md');
SELECT pg_temp.check((SELECT file_name FROM migration_drafts WHERE id = pg_temp.get('md')) = 'NNN_invoices_customer_idx.sql', '…NNN while the number is unknown');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'discarded' WHERE id = pg_temp.get('cs_ddl')$$, 'goes from drafted_as_migration', 'a drafted change set is final');
-- a workbench change set: live, by its owner
INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('dxw_1'), 'form', 26, 'the same index, live') RETURNING pg_temp.put('cs_wb', id);
INSERT INTO change_set_items (change_set_id, position, statement, class) VALUES (pg_temp.get('cs_wb'), 1, 'CREATE INDEX invoices_customer_idx ON invoices (customer_id)', 'ddl');
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_wb');
SELECT pg_temp.as_member(30);
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30 WHERE id = pg_temp.get('cs_wb')$$, 'its owner', 'another person never applies to my workbench');
SELECT pg_temp.as_member(26);
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30 WHERE id = pg_temp.get('cs_wb')$$, 'person acting', 'applied_by is the person acting');
UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 26 WHERE id = pg_temp.get('cs_wb');
SELECT pg_temp.check((SELECT state FROM change_sets WHERE id = pg_temp.get('cs_wb')) = 'applied', 'the owner applies to their workbench, live');
-- row edits on the GL: only from the grid, in the person's own open write window, by a holder of data.write
SELECT pg_temp.as_member(30);
INSERT INTO change_sets (target_database_id, origin, author_member_id, title, row_count) VALUES (pg_temp.tid('subello_gl'), 'grid', 30, 'two invoice dates', 2) RETURNING pg_temp.put('cs_grid', id);
INSERT INTO change_set_items (change_set_id, position, statement, class) VALUES (pg_temp.get('cs_grid'), 1, 'UPDATE invoices SET due_on = $1 WHERE id = $2 AND xmin = $3', 'dml');
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_grid');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30 WHERE id = pg_temp.get('cs_grid')$$, 'write window', 'row changes need the window named');
UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30, window_id = pg_temp.get('w1') WHERE id = pg_temp.get('cs_grid');
SELECT pg_temp.check((SELECT state = 'applied' AND window_id = pg_temp.get('w1') FROM change_sets WHERE id = pg_temp.get('cs_grid')), 'inside her open write window, Dana applies the grid''s edits');
INSERT INTO change_sets (target_database_id, origin, author_member_id, title, row_count) VALUES (pg_temp.tid('subello_gl'), 'grid', 30, 'many rows', 5000) RETURNING pg_temp.put('cs_big', id);
INSERT INTO change_set_items (change_set_id, position, statement, class) VALUES (pg_temp.get('cs_big'), 1, 'UPDATE …', 'dml');
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_big');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30, window_id = pg_temp.get('w1') WHERE id = pg_temp.get('cs_big')$$, 'typed back', 'above the confirm cap the count is typed back');
UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30, window_id = pg_temp.get('w1'), typed_count = 5000 WHERE id = pg_temp.get('cs_big');
SELECT pg_temp.check((SELECT state FROM change_sets WHERE id = pg_temp.get('cs_big')) = 'applied', '…typed exactly, it applies');
INSERT INTO change_sets (target_database_id, origin, author_member_id, title, row_count) VALUES (pg_temp.tid('subello_gl'), 'grid', 30, 'too many', 20000) RETURNING pg_temp.put('cs_huge', id);
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_huge');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30, window_id = pg_temp.get('w1'), typed_count = 20000 WHERE id = pg_temp.get('cs_huge')$$, 'migration', 'over change_set_max_rows: refused (a migration)');
INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('subello_gl'), 'grid', 30, 'a sneaky DDL') RETURNING pg_temp.put('cs_mix', id);
INSERT INTO change_set_items (change_set_id, position, statement, class) VALUES (pg_temp.get('cs_mix'), 1, 'ALTER TABLE invoices DROP COLUMN memo', 'ddl');
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_mix');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 30, window_id = pg_temp.get('w1') WHERE id = pg_temp.get('cs_mix')$$, 'only row edits', '…and only row edits — a DDL item in a grid change set is refused');
-- agents
SELECT pg_temp.refused($$INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('subello_gl'), 'form', 40, 'x')$$, 'proposal', 'an agent''s change set is a proposal');
INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('subello_gl'), 'agent_proposal', 40, 'an index for an unindexed FK') RETURNING pg_temp.put('cs_ag', id);
SELECT pg_temp.check((SELECT author_is_agent FROM change_sets WHERE id = pg_temp.get('cs_ag')), '…marked as an agent''s');
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_ag');
SELECT pg_temp.as_member(40);
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 40 WHERE id = pg_temp.get('cs_ag')$$, 'agent never', 'an agent never applies (design §5)');
-- the kernel's database takes nothing
SELECT pg_temp.as_member(1);
INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('certstudy'), 'editor', 1, 'k') RETURNING pg_temp.put('cs_k', id);
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_k');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 1 WHERE id = pg_temp.get('cs_k')$$, 'Nothing is applied', 'nothing is applied to the kernel''s database, by anyone');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'drafted_as_migration' WHERE id = pg_temp.get('cs_k')$$, 'goes from reviewed', '…nor drafted from it unrehearsed');

-- ================================================================ the freeze (§3 wall 8)
SELECT pg_temp.as_member(27);
SELECT pg_temp.refused($$SELECT dx_freeze(true, 'drill')$$, 'super-admin', 'Marco (admin role, no super-admin) cannot freeze');
SELECT pg_temp.as_member(1);
SELECT dx_freeze(true, 'a drill');
SELECT pg_temp.check((SELECT frozen AND frozen_reason = 'a drill' FROM dx_settings), 'a super-admin freezes, with a reason');
SELECT pg_temp.check((SELECT status = 'ended' AND ended_by_kind = 'freeze' FROM access_windows WHERE id = pg_temp.get('w1')), '…every open window ends');
SELECT pg_temp.check(pg_temp.pol(40, NULL, 'subello_gl') -> 'refusal' ->> 'rule' = 'frozen', '…every agent tool answers frozen');
SELECT pg_temp.check((SELECT j -> 'ceiling' ->> 'dml' = 'never' AND NOT (j -> 'tiers') ? 'workbench' FROM (SELECT pg_temp.pol(26, NULL, 'dxw_1') AS j) x),
                     '…and the workbench tier is refused');
SELECT pg_temp.as_member(26);
INSERT INTO change_sets (target_database_id, origin, author_member_id, title) VALUES (pg_temp.tid('dxw_1'), 'editor', 26, 'while frozen') RETURNING pg_temp.put('cs_fz', id);
UPDATE change_sets SET state = 'reviewed' WHERE id = pg_temp.get('cs_fz');
SELECT pg_temp.refused($$UPDATE change_sets SET state = 'applied', applied_at = now(), applied_by = 26 WHERE id = pg_temp.get('cs_fz')$$, 'frozen', '…and nothing is applied while frozen');
SELECT pg_temp.as_member(30);
SELECT pg_temp.refused($$SELECT dx_window_request(pg_temp.tid('subello_gl'), 'write', 30, 'during', now())$$, 'frozen', '…and no window opens');
SELECT pg_temp.as_member(1);
SELECT dx_freeze(false);
SELECT pg_temp.check((SELECT NOT frozen AND frozen_reason IS NULL FROM dx_settings), 'the freeze lifts');

-- ================================================================ classifications and the grants plan (§6.9, §6.1)
SELECT pg_temp.check((SELECT class FROM dx_classify_column('password_hash', 'text')) = 'secret' AND (SELECT class FROM dx_classify_column('api_key', 'text')) = 'secret'
                     AND (SELECT class FROM dx_classify_column('token_hash', 'text')) = 'secret' AND (SELECT class FROM dx_classify_column('ciphertext', 'bytea')) = 'secret',
                     'the classifier: secret names');
SELECT pg_temp.check((SELECT kind FROM dx_classify_column('email', 'citext')) = 'email' AND (SELECT kind FROM dx_classify_column('mobile_phone', 'text')) = 'phone'
                     AND (SELECT kind FROM dx_classify_column('last_name', 'text')) = 'name' AND (SELECT kind FROM dx_classify_column('ip_address', 'inet')) = 'ip_address'
                     AND (SELECT kind FROM dx_classify_column('salary', 'numeric')) = 'compensation' AND (SELECT kind FROM dx_classify_column('diagnosis', 'text')) = 'health',
                     '…personal kinds');
SELECT pg_temp.check((SELECT kind FROM dx_classify_column('body', 'text')) = 'free_text' AND (SELECT kind FROM dx_classify_column('after', 'jsonb')) = 'free_text'
                     AND (SELECT kind FROM dx_classify_column('notes', 'text')) = 'free_text',
                     '…free text: bodies, notes, the activity log''s row images');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM dx_classify_column('total_cents', 'bigint')) AND NOT EXISTS (SELECT 1 FROM dx_classify_column('status', 'text')),
                     '…and nothing for an ordinary column');
SELECT pg_temp.check(dx_classify_propose(pg_temp.tid('subello_gl'), 'public', 'members', 'password_hash', 'text')
                     AND dx_classify_propose(pg_temp.tid('subello_gl'), 'public', 'customers', 'email', 'citext')
                     AND NOT dx_classify_propose(pg_temp.tid('subello_gl'), 'public', 'customers', 'email', 'citext')
                     AND NOT dx_classify_propose(pg_temp.tid('subello_gl'), 'public', 'invoices', 'total_cents', 'bigint'),
                     'a proposal is made once, refreshed only when it changes, never for an ordinary column');
SELECT pg_temp.as_member(26);
SELECT pg_temp.refused($$SELECT dx_classify_confirm(pg_temp.tid('subello_gl'), 'public', 'customers', 'email', 'none')$$, 'role does not let', 'an Engineer confirms no classification');
SELECT pg_temp.as_member(30);
SELECT dx_classify_confirm(pg_temp.tid('subello_gl'), 'public', 'customers', 'email', 'personal', 'email');
SELECT pg_temp.check((SELECT confirmed_by = 30 AND proposed_by = 'person' FROM column_classes WHERE column_name = 'email'), 'a DBA confirms a proposal');
SELECT pg_temp.check(NOT dx_classify_propose(pg_temp.tid('subello_gl'), 'public', 'customers', 'email', 'citext'), '…and the classifier never overwrites a person''s call');
SELECT pg_temp.refused($$SELECT dx_classify_confirm(pg_temp.tid('subello_gl'), 'public', 'members', 'password_hash', 'none')$$, 'super-admin', 'a DBA never clears a secret-pattern column');
SELECT pg_temp.as_member(1);
SELECT dx_classify_confirm(pg_temp.tid('subello_gl'), 'public', 'members', 'password_hash', 'none');
SELECT pg_temp.check((SELECT cleared_by_super_admin FROM column_classes WHERE column_name = 'password_hash'), '…a super-admin does, and it is marked so');
SELECT pg_temp.check((SELECT count(*) FROM mcp_grant_plan WHERE datname = 'subello_gl' AND table_name IS NOT NULL) = 2
                     AND (SELECT count(*) FROM mcp_grant_plan WHERE datname = 'subello_gl' AND table_name IS NULL) = 1
                     AND (SELECT cleared_secret FROM mcp_grant_plan WHERE column_name = 'password_hash'),
                     'the grants plan: the GL''s classified columns plus one row for the target, the cleared one marked');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM mcp_grant_plan WHERE datname IN ('hr_dev', 'certstudy', 'certstudy_memory', 'dxw_1')),
                     '…never a target whose grants are pending, the kernel''s, a memory database or a workbench');
SELECT pg_temp.check(dx_grants_pass_log('subello_gl', '{"changes": 3, "detail": {"read": ["customers.email"]}}') > 0, 'the grants service records its pass');

-- ================================================================ the door's audit (§6.10)
SELECT pg_temp.put('run', dx_door_run_open(jsonb_build_object('request_id', 'r1', 'caller', 26, 'source', 'editor', 'datname', 'subello_gl', 'kind', 'run',
                                                              'sql', 'SELECT id FROM invoices')));
SELECT pg_temp.check((SELECT status = 'running' AND target_database_id = pg_temp.tid('subello_gl') AND sql_sha256 ~ '^[0-9a-f]{64}$' FROM query_runs WHERE id = pg_temp.get('run')),
                     'a request''s row opens running, its target and the SQL''s hash kept');
SELECT pg_temp.put('st', dx_door_statement_log(jsonb_build_object('run_id', pg_temp.get('run'), 'statement_index', 0, 'class', 'read', 'tier', 'read_masked',
                                                                  'fingerprint', 'abc', 'status', 'running')));
SELECT pg_temp.check((SELECT status FROM door_statements WHERE id = pg_temp.get('st')) = 'running', 'a statement''s intent is written before it runs');
SELECT pg_temp.put('st2', dx_door_statement_log(jsonb_build_object('id', pg_temp.get('st'), 'status', 'ok', 'rows_affected', 12, 'ms', 4)));
SELECT pg_temp.check(pg_temp.get('st2') = pg_temp.get('st') AND (SELECT status = 'ok' AND rows_affected = 12 FROM door_statements WHERE id = pg_temp.get('st')), '…and its result after');
SELECT dx_door_run_close(pg_temp.get('run'), '{"status": "ok", "tier": "read_masked", "level": "masked", "rows_returned": 12, "ms": 9}');
SELECT pg_temp.check((SELECT status = 'ok' AND level = 'masked' AND finished_at IS NOT NULL FROM query_runs WHERE id = pg_temp.get('run')), 'the request closes with its outcome');
SELECT pg_temp.refused($$SELECT dx_door_run_close(pg_temp.get('run'), '{"status": "ok"}')$$, 'No open run', 'a run closes once');
SELECT dx_door_usage_bump(26, 'named:table_describe'); SELECT dx_door_usage_bump(26, 'named:table_describe');
SELECT pg_temp.check((SELECT calls FROM door_usage WHERE member_id = 26 AND kind = 'named:table_describe') = 2, 'named queries are counted, not rowed');
SELECT pg_temp.refused($$SELECT dx_door_usage_bump(26, 'select * from x')$$, 'check constraint', '…under a name only');
SELECT pg_temp.refused($$INSERT INTO query_runs (caller_member_id, source, sql_sha256, status) VALUES (1, 'bogus', repeat('a', 64), 'ok')$$, 'check constraint', 'query_runs refuses a source outside the widened list');
SELECT pg_temp.put('run2', dx_door_run_open(jsonb_build_object('caller', 26, 'source', 'grid', 'datname', 'subello_gl', 'kind', 'run', 'sql', 'x')));
UPDATE query_runs SET created_at = now() - interval '2 hours' WHERE id = pg_temp.get('run2');
SELECT dx_query_runs_prune();
SELECT pg_temp.check((SELECT status FROM query_runs WHERE id = pg_temp.get('run2')) = 'error', 'a run a crashed door left open is closed as an error');
SELECT pg_temp.check((SELECT count(*) FROM information_schema.role_table_grants WHERE grantee IN ('developer_records_ro', 'developer_activity_ro')
                        AND table_name IN ('query_runs', 'door_statements', 'target_access', 'access_windows', 'column_classes', 'row_images', 'change_sets')) = 0,
                     'the read roles hold no grant on the audit, the levels, the windows, the classes, the images or the change sets');

-- ================================================================ saved queries, exports, maintenance, backups, notices
SELECT pg_temp.refused($$INSERT INTO saved_queries (owner_member_id, title, sql, shared) VALUES (40, 'x', 'SELECT 1', true)$$, 'private', 'an agent''s saved queries are private');
INSERT INTO saved_queries (owner_member_id, title, sql, shared, target_database_id) VALUES (26, 'open invoices', 'SELECT id FROM invoices WHERE paid_at IS NULL', true, pg_temp.tid('subello_gl'))
RETURNING pg_temp.put('sq', id);
SELECT pg_temp.as_member(26);
SELECT pg_temp.refused($$SELECT dx_saved_query_verify(pg_temp.get('sq'), true)$$, 'role does not let', 'an Engineer verifies no query');
SELECT pg_temp.as_member(30);
SELECT dx_saved_query_verify(pg_temp.get('sq'), true);
SELECT pg_temp.check((SELECT verified_by = 30 FROM saved_queries WHERE id = pg_temp.get('sq')), 'a DBA verifies');
UPDATE saved_queries SET sql = sql || ' LIMIT 10' WHERE id = pg_temp.get('sq');
SELECT pg_temp.check((SELECT verified_at IS NULL AND unverified_reason LIKE '%changed%' FROM saved_queries WHERE id = pg_temp.get('sq')), '…and the badge drops by itself when the SQL changes');
SELECT pg_temp.refused($$INSERT INTO exports (kind, format, created_by) VALUES ('result', 'csv', 40)$$, 'never exports', 'an agent never exports');
INSERT INTO exports (kind, format, created_by, target_database_id) VALUES ('result', 'csv', 26, pg_temp.tid('subello_gl')) RETURNING pg_temp.put('ex', id);
SELECT pg_temp.check((SELECT expires_at BETWEEN now() + interval '23 hours' AND now() + interval '25 hours' FROM exports WHERE id = pg_temp.get('ex')), 'a person''s export, kept export_keep_hours');
SELECT pg_temp.refused($$INSERT INTO maintenance_jobs (target_database_id, operation, obj_type, obj_names, lock_note, requested_by) VALUES (pg_temp.tid('subello_gl'), 'analyze', 'table', '{public,invoices}', 'SHARE UPDATE EXCLUSIVE', 26)$$,
                       'maintenance.run', 'an Engineer runs no maintenance');
SELECT pg_temp.refused($$INSERT INTO maintenance_jobs (target_database_id, operation, obj_type, obj_names, lock_note, requested_by) VALUES (pg_temp.tid('certstudy'), 'analyze', 'table', '{public,x}', 'x', 30)$$,
                       'installed application', 'maintenance never on the kernel''s database');
SELECT pg_temp.refused($$INSERT INTO maintenance_jobs (target_database_id, operation, obj_type, obj_names, lock_note, requested_by) VALUES (pg_temp.tid('subello_gl'), 'vacuum_full', 'table', '{public,invoices}', 'x', 30)$$,
                       'check constraint', 'never VACUUM FULL (D15)');
INSERT INTO maintenance_jobs (target_database_id, operation, obj_type, obj_names, lock_note, requested_by) VALUES (pg_temp.tid('subello_gl'), 'analyze', 'table', '{public,invoices}', 'SHARE UPDATE EXCLUSIVE', 30);
SELECT pg_temp.check(EXISTS (SELECT 1 FROM maintenance_jobs WHERE requested_by = 30 AND status = 'queued'), 'a DBA queues an ANALYZE on an installed application');
INSERT INTO backup_marks (datname, kind, taken_at) VALUES ('subello_gl', 'dump', now() - interval '3 hours');
SELECT pg_temp.check(dx_last_backup('subello_gl') > now() - interval '24 hours' AND dx_last_backup('subello_hr') IS NULL, 'the last backup of a database, for the gate');
SELECT pg_temp.check(dx_notify(40, 'proposal', 'x', 'y') IS NULL AND dx_notify(30, 'blocked_session', 'A session blocks three', NULL) IS NOT NULL, 'notices are people''s: an agent is never notified here');

\o
SELECT CASE WHEN ok THEN 'ok   ' ELSE 'FAIL ' END || label FROM proof ORDER BY n;
SELECT ' ' || count(*) FILTER (WHERE ok) || ' ok, ' || count(*) FILTER (WHERE NOT ok) || ' failed' FROM proof;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM proof WHERE NOT ok) THEN RAISE EXCEPTION 'the schema proof failed'; END IF; END $$;
ROLLBACK;
