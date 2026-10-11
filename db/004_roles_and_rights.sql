-- 004: Developer's roles and the rights they give (kernel db/145; roles-and-rights.md; the design §3, D9).
--
-- Published to the kernel by app_roles on the records MCP (os.app-roles/1). The kernel grants a SET of roles; the claims and the feed
-- carry them back into members.roles. What a role lets its holder do is the application's to enforce: dx_has_right(right) answers
-- from the catalogue and the mirror.
--
-- FOUR ROLES, AND NO `user` ROLE (D9): Viewer (`viewer`, read), Engineer (`engineer`, write), DBA (`dba`, write), Developer admin
-- (`admin`, admin, is_admin). The installer's --grant-standing-departments gives a department the role keyed member/user/write, which
-- matches nothing here, so nobody is admitted by default (maludb-os.json also says grant_standing_departments: false — K14's guard). A
-- grant the kernel sends WITHOUT roles is NO ROLE AT ALL (fail closed): capability alone admits nobody, whatever it says. A super-admin
-- of the kernel always holds `admin` (the kernel gives every super-admin the is_admin role everywhere; dx_member_roles adds it here).
--
-- WHO MAY HOLD A RIGHT AT ALL (`held_by`, MaluMail's appended column): `anyone` a role gives it to; `people` — a person's decision or a
-- person's reach, never an agent's whatever role it holds (rows, workbenches, exports, windows, writes, session control, maintenance,
-- classifications, memory content); `super_admins` — refused to anyone who is not an active human super-admin of the kernel, whatever
-- roles they hold (access levels, the registry, approving windows, memory reveals, settings, the audit, freeze). Agents hold the
-- `engineer` role (design §5) and keep only its `anyone` rights. The schema's later functions (db/006+) and the door refuse the same
-- decisions again, at the act — this is the first wall, not the only one.
--
-- RIGHTS ARE APPLICATION-WIDE CAPABILITIES. WHICH DATABASE a caller may read rows of, and at what level, is NOT a right: it is the
-- target's class (its ceiling) and the caller's level on it (target_access, db/006+), compiled by dx_door_policy() — design §3.
--
-- THE ESTATE'S DATA MODEL (design §6.11): the shape is Consultant Tracking db/004 = DocCloud db/004 = Sales CRM db/004 = the Data Lake
-- db/004 = Boards db/004 = MaluMail db/004 (ml_ -> dx_), with dx_rights carrying MaluMail's appended `held_by`; the roles and rights are
-- this application's; dx_member_roles(member) is Inventory db/004's convenience; dx_member_has_right(member, right) the Data Lake's.
BEGIN;

CREATE TABLE dx_rights (
    right_key   text PRIMARY KEY CHECK (right_key ~ '^[a-z][a-z0-9_.]{0,59}$'),
    description text NOT NULL,
    sort_order  integer NOT NULL DEFAULT 0,
    -- appended (MaluMail db/004; design §3, D9): who may hold the right at all, whatever roles they hold
    held_by     text NOT NULL DEFAULT 'anyone' CHECK (held_by IN ('anyone', 'people', 'super_admins'))
);
CREATE TABLE dx_roles (
    role_key    text PRIMARY KEY CHECK (role_key ~ '^[a-z][a-z0-9_]{0,39}$'),
    name        text NOT NULL,
    description text NOT NULL,
    capability  text NOT NULL CHECK (capability IN ('read', 'write', 'admin')),
    is_admin    boolean NOT NULL DEFAULT false,
    sort_order  integer NOT NULL DEFAULT 0,
    CHECK (NOT is_admin OR capability = 'admin')
);
CREATE UNIQUE INDEX dx_roles_one_admin ON dx_roles (is_admin) WHERE is_admin;
CREATE TABLE dx_role_rights (
    role_key  text NOT NULL REFERENCES dx_roles(role_key) ON DELETE CASCADE,
    right_key text NOT NULL REFERENCES dx_rights(right_key) ON DELETE CASCADE,
    PRIMARY KEY (role_key, right_key)
);

INSERT INTO dx_rights (right_key, description, sort_order, held_by) VALUES
 -- Viewer (design §3)
 ('catalog.read',            'Browse every registered database''s objects: the tree, every object''s page, its DDL, dependencies, privileges, statistics, diagrams and compare', 1, 'anyone'),
 ('plans.explain',           'Explain a query without running it (EXPLAIN without ANALYZE)', 2, 'anyone'),
 ('activity.read',           'See what the server is doing: sessions, blockers, locks, query texts normalized, top statements', 3, 'anyone'),
 ('health.read',             'Read the health findings, bloat estimates, index advice, vacuum and wraparound state, drift and the backup posture', 4, 'anyone'),
 ('memory.read',             'Read the memory databases'' state: the estate, tenant health, aggregates, graph statistics, models, skills and facades — never content', 5, 'anyone'),
 -- Engineer
 ('data.read',               'Read rows at the level granted on each database (masked or rows), in the grid and the SQL editor; EXPLAIN ANALYZE of a read (people only)', 6, 'people'),
 ('queries.save',            'Save queries (an agent''s are private) and share their own', 7, 'anyone'),
 ('workbench.use',           'Create workbenches (empty or a schema-only clone) and read them (people only)', 8, 'people'),
 ('workbench.apply',         'Change their own workbench live — DDL, DML, a CSV import — through the editor or Change review (people only)', 9, 'people'),
 ('changes.prepare',         'Prepare changes: forms, change sets, Change review, lint and rehearsals on a throwaway clone', 10, 'anyone'),
 ('migrations.draft',        'Draft migrations for an application''s repository, and export a workbench as a migration', 11, 'anyone'),
 ('exports.make',            'Export a table or a result at their level as CSV, JSON or SQL INSERTs (people only)', 12, 'people'),
 -- DBA
 ('data.unmask',             'May be granted the `rows` level on a database (personal columns readable; secret columns never) (people only)', 13, 'people'),
 ('window.request',          'Ask for a read window (rows on a private-by-design database) or a write window (row changes on an installed application''s database) (people only)', 14, 'people'),
 ('data.write',              'Apply change sets of row edits inside a write window (people only)', 15, 'people'),
 ('sessions.cancel',         'Cancel a session''s running statement on an application, development or workbench database (people only)', 16, 'people'),
 ('sessions.terminate',      'Terminate a session on an application, development or workbench database (people only)', 17, 'people'),
 ('maintenance.run',         'Run maintenance jobs: VACUUM, ANALYZE, REINDEX CONCURRENTLY, REFRESH MATERIALIZED VIEW CONCURRENTLY (people only)', 18, 'people'),
 ('classifications.confirm', 'Confirm or clear a column''s classification (a pattern-matched secret only a super-admin clears) (people only)', 19, 'people'),
 ('memory.content',          'Open the memory section''s content: subject pages, walks, paths, document, chat and note metadata, every view logged (people only)', 20, 'people'),
 -- Developer admin — a super-admin's
 ('access.manage',           'Grant and revoke the masked and rows levels per person or role and database', 21, 'super_admins'),
 ('registry.manage',         'Classify databases, mark them private by design, colour and hide them', 22, 'super_admins'),
 ('window.approve',          'Approve or refuse another person''s window', 23, 'super_admins'),
 ('memory.reveal',           'Reveal an episode''s payload or a document''s text in the memory section, with a reason', 24, 'super_admins'),
 ('settings.manage',         'Run Developer: limits, caps, retention, expiry, personal tokens', 25, 'super_admins'),
 ('audit.read',              'Read every run, statement, window, unmask and reveal by anyone', 26, 'super_admins'),
 ('freeze',                  'Freeze the tool: end every window, refuse the write and workbench tiers, stop every agent tool, close the door''s connections', 27, 'super_admins');

INSERT INTO dx_roles (role_key, name, description, capability, is_admin, sort_order) VALUES
 ('viewer',   'Viewer',          'Reads every registered database''s structure — objects, DDL, dependencies, plans without running them, activity, health and the memory databases'' state. No rows.', 'read', false, 1),
 ('engineer', 'Engineer',        'Builds on the estate''s databases: rows at the level granted per database, the SQL editor, saved queries, workbenches designed live, Change review, rehearsals, migration drafts and exports.', 'write', false, 2),
 ('dba',      'DBA',             'Runs the databases: the rows level where granted, write windows on installed applications'' databases, applying row changes, session control, maintenance, classifications and the memory section''s content.', 'write', false, 3),
 ('admin',    'Developer admin', 'Administers Developer: the registry, access levels, window approvals, memory reveals, settings, the audit and the freeze. Works only for a super-admin of the OS.', 'admin', true, 4);

INSERT INTO dx_role_rights (role_key, right_key)
SELECT 'viewer', r FROM unnest(ARRAY['catalog.read','plans.explain','activity.read','health.read','memory.read']) r
UNION ALL
SELECT 'engineer', r FROM unnest(ARRAY['catalog.read','plans.explain','activity.read','health.read','memory.read',
    'data.read','queries.save','workbench.use','workbench.apply','changes.prepare','migrations.draft','exports.make']) r
UNION ALL
SELECT 'dba', r FROM unnest(ARRAY['catalog.read','plans.explain','activity.read','health.read','memory.read',
    'data.read','queries.save','workbench.use','workbench.apply','changes.prepare','migrations.draft','exports.make',
    'data.unmask','window.request','data.write','sessions.cancel','sessions.terminate','maintenance.run','classifications.confirm','memory.content']) r
UNION ALL
SELECT 'admin', right_key FROM dx_rights;

-- The roles a member holds, resolved: the kernel's list (only roles Developer offers); a super-admin always holds admin. A member the
-- kernel has sent NO roles for holds none — capability alone admits nobody (D9: fail closed). Empty for nobody.
CREATE OR REPLACE FUNCTION dx_member_roles(p_member_id bigint) RETURNS text[]
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r text[];
BEGIN
    SELECT CASE
             WHEN m.member_kind = 'human' AND m.business_role = 'super_admin'
                  THEN (SELECT array_agg(DISTINCT x) FROM unnest(m.roles || ARRAY['admin']) x WHERE x IN (SELECT role_key FROM dx_roles))
             ELSE (SELECT COALESCE(array_agg(DISTINCT x), '{}') FROM unnest(m.roles) x WHERE x IN (SELECT role_key FROM dx_roles))
           END
      INTO r
      FROM members m
     WHERE m.id = p_member_id AND m.status = 'active' AND m.capability IS NOT NULL;
    RETURN COALESCE(r, '{}');
END$$;

-- A right a given member's roles give (the member must be active and admitted); a `people` right never to an agent, a `super_admins`
-- right only to an active human super-admin of the kernel (D9). One query.
CREATE OR REPLACE FUNCTION dx_member_has_right(p_member_id bigint, p_right text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM dx_role_rights rr
          JOIN dx_rights h ON h.right_key = rr.right_key
          JOIN members m ON m.id = p_member_id AND m.status = 'active'
         WHERE rr.right_key = p_right AND rr.role_key = ANY (dx_member_roles(p_member_id))
           AND (h.held_by = 'anyone'
                OR (h.held_by = 'people' AND m.member_kind = 'human')
                OR (h.held_by = 'super_admins' AND m.member_kind = 'human' AND m.business_role = 'super_admin')));
END$$;

-- The rule: a right the acting member's roles give.
CREATE OR REPLACE FUNCTION dx_has_right(p_right text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN dx_member_has_right(app_current_member_id(), p_right);
END$$;

-- Why the acting member lacks a right, in a sentence for a person — NULL when they hold it. Screens say this instead of a bare 403.
CREATE OR REPLACE FUNCTION dx_right_refusal(p_right text) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE who text; holds_role boolean;
BEGIN
    IF dx_has_right(p_right) THEN
        RETURN NULL;
    END IF;
    SELECT h.held_by INTO who FROM dx_rights h WHERE h.right_key = p_right;
    IF who IS NULL THEN
        RETURN 'That is not something Developer does.';
    END IF;
    IF cardinality(dx_member_roles(app_current_member_id())) = 0 THEN
        RETURN 'Your access to Developer gives no role yet. A super-admin gives you Viewer, Engineer or DBA.';
    END IF;
    holds_role := EXISTS (SELECT 1 FROM dx_role_rights rr WHERE rr.right_key = p_right
                            AND rr.role_key = ANY (dx_member_roles(app_current_member_id())));
    IF app_member_kind() = 'agent' AND who = 'super_admins' THEN
        RETURN 'Administering Developer is for people: an agent never does it.';
    END IF;
    IF app_member_kind() = 'agent' AND who = 'people' THEN
        RETURN 'That is a person''s to do: an agent reads no rows and changes no database.';
    END IF;
    IF who = 'super_admins' AND holds_role THEN
        RETURN 'Developer''s administration is for the OS''s super-admins. You hold the Developer admin role, but you are not a super-admin.';
    END IF;
    RETURN CASE WHEN who = 'super_admins' THEN 'Only a Developer admin — a super-admin of the OS — can do that.'
                ELSE 'Your Developer role does not let you do that.' END;
END$$;

-- Runs Developer: an active human super-admin of the kernel (who always holds Developer admin here). The one test the admin screens use.
CREATE OR REPLACE FUNCTION dx_is_developer_admin() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN app_is_super_admin();
END$$;

-- Someone who belongs here: admitted with a role (an agent granted one too). A grant without roles is not.
CREATE OR REPLACE FUNCTION dx_is_member_here() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN app_is_active_member() AND cardinality(dx_member_roles(app_current_member_id())) > 0;
END$$;

-- What app_roles answers, in one read (the catalogue; the kernel reads it as itself). `held_by` is published in each right's text.
CREATE OR REPLACE VIEW mcp_app_roles AS
SELECT r.role_key, r.name, r.description, r.capability, r.is_admin, r.sort_order,
       COALESCE((SELECT array_agg(rr.right_key ORDER BY h.sort_order) FROM dx_role_rights rr
                   JOIN dx_rights h ON h.right_key = rr.right_key WHERE rr.role_key = r.role_key), '{}') AS rights
FROM dx_roles r;

GRANT SELECT ON dx_rights, dx_roles, dx_role_rights, mcp_app_roles TO developer_rw, developer_records_ro;
GRANT EXECUTE ON FUNCTION dx_member_roles(bigint), dx_member_has_right(bigint, text), dx_has_right(text), dx_right_refusal(text),
    dx_is_developer_admin(), dx_is_member_here()
    TO developer_rw, developer_records_ro, developer_activity_ro;

COMMIT;
