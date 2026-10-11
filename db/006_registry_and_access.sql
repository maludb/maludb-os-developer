-- 006: THE REGISTRY, ACCESS LEVELS, WINDOWS, FAVOURITES AND RECENTS — and THE ONE PLACE §3 IS COMPILED: dx_door_policy() (design §3,
-- §6.1, §6.2; D2, D3, D5).
--
-- target_databases is every database of the local cluster the tool knows of: discovered by the worker from pg_database through the door
-- (slice 1), a class PROPOSED by a fixed precedence (design §6.2) and CONFIRMED by an admin (registry.manage). Nothing unregistered is
-- reached (wall 1). target_access gives a person — or every holder of a role — the `masked` or `rows` level on one target (rows are
-- deny-by-default; `structure` is implicit). access_windows are the time-boxed read and write modes of design §3 wall 4. The door asks
-- dx_door_policy(caller, on_behalf_of, datname) before every request and enforces what it answers; the target's own privileges (the
-- tiers' column grants, design §6.1) enforce it again.
--
-- THE ESTATE'S DATA MODEL (design §6.11): every table here is NEW CANONICAL — no database registry exists anywhere in the estate
-- (`databases` is Spaces' Notion databases, hence target_databases; `grants` is the Data Lake's, hence target_access).
BEGIN;

-- The kernel's database by name (the class `kernel`, structure only — D2, (a)); the tool's own is current_database().
ALTER TABLE dx_settings ADD COLUMN kernel_datname text NOT NULL DEFAULT 'certstudy' CHECK (kernel_datname ~ '^[a-z0-9_]{1,63}$');

CREATE TABLE target_databases (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    datname            text NOT NULL UNIQUE CHECK (datname ~ '^[a-z0-9_]{1,63}$'),        -- wall 1: never a name outside this
    class              text NOT NULL DEFAULT 'unclassified'
                       CHECK (class IN ('application', 'workbench', 'development', 'memory', 'kernel', 'own', 'system', 'unclassified')),
    proposed_class     text CHECK (proposed_class IN ('application', 'workbench', 'development', 'memory', 'kernel', 'own', 'system', 'unclassified')),
    proposal_reason    text,                                                             -- the precedence rule that proposed it, in words
    application_key    text CHECK (application_key IS NULL OR application_key ~ '^[a-z][a-z0-9_]{1,31}$'),
    private_by_design  boolean NOT NULL DEFAULT false,                                   -- rows only inside a read window (design §3)
    label              text CHECK (label IS NULL OR length(label) BETWEEN 1 AND 120),
    colour             text CHECK (colour IS NULL OR colour ~ '^#[0-9a-f]{6}$'),
    hidden             boolean NOT NULL DEFAULT false,
    grants_state       text NOT NULL DEFAULT 'pending' CHECK (grants_state IN ('pending', 'in_place', 'partial', 'revoked', 'not_needed')),
    grants_checked_at  timestamptz,
    grants_detail      jsonb NOT NULL DEFAULT '{}'::jsonb,                               -- per tier / per table, as the worker read it
    has_maludb         boolean NOT NULL DEFAULT false,                                   -- maludb_core installed (discovery's one probe)
    memory_schemas     text[] NOT NULL DEFAULT '{}',                                     -- memory-enabled schemas (a co-located `memory` counts as memory)
    size_bytes         bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
    pg_version         text,
    extensions         jsonb NOT NULL DEFAULT '[]'::jsonb,                               -- [{name, version, default_version}]
    first_seen_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at       timestamptz NOT NULL DEFAULT now(),
    gone_at            timestamptz,                                                      -- dropped from the cluster: marked, never deleted
    confirmed_by       bigint REFERENCES members(id) ON DELETE SET NULL,
    confirmed_at       timestamptz,
    notes              text CHECK (notes IS NULL OR length(notes) <= 4000),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (class <> 'application' OR application_key IS NOT NULL),
    CHECK (class <> 'workbench' OR datname ~ '^dxw_[0-9]+$'),
    CHECK (datname !~ '^dx(w|r)_' OR class IN ('workbench', 'unclassified')),             -- the tool's own names are never a target of another class
    CHECK (NOT private_by_design OR class = 'application'),
    CHECK ((confirmed_by IS NULL) OR (confirmed_at IS NOT NULL))
);
CREATE INDEX target_databases_class_idx ON target_databases (class) WHERE gone_at IS NULL;
CREATE INDEX target_databases_app_idx ON target_databases (application_key) WHERE application_key IS NOT NULL;
CREATE TRIGGER target_databases_touch BEFORE UPDATE ON target_databases FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- The fixed precedence of design §6.2: the tool's own database → the tool's own names → system → the kernel's → subello_<key> with a kernel application of that key
-- → a database holding maludb_core → development name patterns → unclassified. p_app_keys are the kernel's application keys (the
-- switcher's feed, K31, read as the admin); p_has_maludb is discovery's one pg_extension probe. Returns (class, application_key, reason).
CREATE OR REPLACE FUNCTION dx_propose_class(p_datname text, p_has_maludb boolean, p_app_keys text[], p_tenant text DEFAULT 'subello')
    RETURNS TABLE (class text, application_key text, reason text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE k text; kern text;
BEGIN
    SELECT s.kernel_datname INTO kern FROM dx_settings s WHERE s.id = 1;
    IF p_datname = current_database() THEN RETURN QUERY SELECT 'own'::text, NULL::text, 'this tool''s own database'; RETURN; END IF;
    IF p_datname ~ '^dxw_[0-9]+$' THEN RETURN QUERY SELECT 'workbench'::text, NULL::text, 'a workbench of this tool (dxw_)'; RETURN; END IF;
    IF p_datname ~ '^dx(r_[0-9]+|_template)$' OR p_datname ~ '^dx_' THEN RETURN QUERY SELECT 'system'::text, NULL::text, 'the tool''s own scratch name'; RETURN; END IF;
    IF p_datname IN ('postgres', 'template0', 'template1', 'maludb') THEN RETURN QUERY SELECT 'system'::text, NULL::text, 'a system database'; RETURN; END IF;
    IF p_datname = kern THEN RETURN QUERY SELECT 'kernel'::text, NULL::text, 'the kernel''s database (structure only)'; RETURN; END IF;
    IF p_datname LIKE p_tenant || '\_%' THEN
        k := substr(p_datname, length(p_tenant) + 2);
        IF k = ANY (COALESCE(p_app_keys, '{}')) THEN
            RETURN QUERY SELECT 'application'::text, k, 'named ' || p_tenant || '_<key> for the installed application ' || k; RETURN;
        END IF;
    END IF;
    IF p_has_maludb THEN RETURN QUERY SELECT 'memory'::text, NULL::text, 'holds maludb_core'; RETURN; END IF;
    IF p_datname ~ '(^|_)(dev|proof|spike|scratch)[0-9]*($|_)' THEN
        RETURN QUERY SELECT 'development'::text, NULLIF(split_part(p_datname, '_', 1), ''), 'a development or proof name'; RETURN;
    END IF;
    RETURN QUERY SELECT 'unclassified'::text, NULL::text, 'no rule matched — an admin decides';
END$$;

-- ------------------------------------------------------------------------------------------------- access levels
CREATE TABLE target_access (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    principal_kind     text NOT NULL CHECK (principal_kind IN ('member', 'role')),
    member_id          bigint REFERENCES members(id) ON DELETE CASCADE,
    role_key           text REFERENCES dx_roles(role_key) ON DELETE CASCADE,
    level              text NOT NULL CHECK (level IN ('masked', 'rows')),
    reason             text CHECK (reason IS NULL OR length(reason) <= 1000),
    granted_by         bigint REFERENCES members(id) ON DELETE SET NULL,
    granted_at         timestamptz NOT NULL DEFAULT now(),
    revoked_by         bigint REFERENCES members(id) ON DELETE SET NULL,
    revoked_at         timestamptz,
    CHECK ((principal_kind = 'member') = (member_id IS NOT NULL)),
    CHECK ((principal_kind = 'role') = (role_key IS NOT NULL))
);
CREATE UNIQUE INDEX target_access_one_live ON target_access (target_database_id, principal_kind, COALESCE(member_id, 0), COALESCE(role_key, ''))
    WHERE revoked_at IS NULL;
CREATE INDEX target_access_member_idx ON target_access (member_id) WHERE revoked_at IS NULL;

-- A level is given only where rows exist to read (application and development targets), never to an agent, and `rows` only to a holder
-- of data.unmask (a person, or a role that gives it). The admin's screen is the first wall; this is the second.
CREATE OR REPLACE FUNCTION dx_target_access_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE cls text; kind text;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
        RETURN NEW;                                                                         -- a revocation is always allowed
    END IF;
    SELECT t.class INTO cls FROM target_databases t WHERE t.id = NEW.target_database_id;
    IF cls NOT IN ('application', 'development') THEN
        RAISE EXCEPTION 'A level is given only on an installed application''s or a development database (this one is %)', cls USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.principal_kind = 'member' THEN
        SELECT m.member_kind INTO kind FROM members m WHERE m.id = NEW.member_id;
        IF kind IS DISTINCT FROM 'human' THEN
            RAISE EXCEPTION 'An agent is never given a level: agents read no rows (design §3 wall 6)' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.level = 'rows' AND NOT dx_member_has_right(NEW.member_id, 'data.unmask') THEN
            RAISE EXCEPTION 'The rows level is for a holder of data.unmask (a DBA)' USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.level = 'rows' AND NOT EXISTS (SELECT 1 FROM dx_role_rights rr WHERE rr.role_key = NEW.role_key AND rr.right_key = 'data.unmask') THEN
        RAISE EXCEPTION 'The rows level is given only to a role that gives data.unmask' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER target_access_before BEFORE INSERT OR UPDATE ON target_access FOR EACH ROW EXECUTE FUNCTION dx_target_access_before();

-- ------------------------------------------------------------------------------------------------- windows (design §3 wall 4; D5)
CREATE TABLE access_windows (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id          bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    mode               text NOT NULL CHECK (mode IN ('read', 'write')),
    reason             text NOT NULL CHECK (length(reason) BETWEEN 3 AND 1000),
    minutes            smallint NOT NULL CHECK (minutes BETWEEN 5 AND 480),
    status             text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'open', 'refused', 'ended', 'expired', 'withdrawn')),
    handoff_at         timestamptz NOT NULL,                                -- the hand-off that satisfied the step-up
    requested_at       timestamptz NOT NULL DEFAULT now(),
    decided_by         bigint REFERENCES members(id) ON DELETE SET NULL,
    decided_at         timestamptz,
    decision_reason    text CHECK (decision_reason IS NULL OR length(decision_reason) <= 1000),
    self_approved      boolean NOT NULL DEFAULT false,                      -- a super-admin's own (every other super-admin notified)
    starts_at          timestamptz,
    expires_at         timestamptz,
    ended_at           timestamptz,
    ended_by_kind      text CHECK (ended_by_kind IN ('member', 'expiry', 'freeze', 'admin')),
    ended_by           bigint REFERENCES members(id) ON DELETE SET NULL,
    CHECK (status <> 'open' OR (starts_at IS NOT NULL AND expires_at IS NOT NULL AND decided_at IS NOT NULL)),
    CHECK (status NOT IN ('ended', 'expired') OR ended_at IS NOT NULL),
    CHECK (expires_at IS NULL OR expires_at > starts_at)
);
CREATE UNIQUE INDEX access_windows_one_live ON access_windows (member_id, target_database_id, mode) WHERE status IN ('requested', 'open');
CREATE INDEX access_windows_open_idx ON access_windows (expires_at) WHERE status = 'open';
CREATE INDEX access_windows_requested_idx ON access_windows (requested_at) WHERE status = 'requested';

-- Ask for a window as the acting member. Refused unless: a person with window.request; not frozen; a write window on an application
-- target (and the person holds data.write), a read window on a private-by-design application target (and the person holds data.read
-- and a level there); minutes within the settings; the hand-off within step_up_minutes. A super-admin's own opens at once
-- (self_approved — the screen notifies the others); anyone else's waits for a super-admin. Returns the window's id.
CREATE OR REPLACE FUNCTION dx_window_request(p_target bigint, p_mode text, p_minutes integer, p_reason text, p_handoff_at timestamptz)
    RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me bigint := app_current_member_id(); t target_databases%ROWTYPE; s dx_settings%ROWTYPE; wid bigint; selfok boolean;
BEGIN
    SELECT * INTO s FROM dx_settings WHERE id = 1;
    IF s.frozen THEN RAISE EXCEPTION 'Developer is frozen: no window opens until a super-admin lifts the freeze' USING ERRCODE = 'insufficient_privilege'; END IF;
    IF NOT dx_has_right('window.request') THEN
        RAISE EXCEPTION '%', COALESCE(dx_right_refusal('window.request'), 'You may not ask for a window') USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT * INTO t FROM target_databases WHERE id = p_target AND gone_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'No such database' USING ERRCODE = 'no_data_found'; END IF;
    IF t.class <> 'application' THEN
        RAISE EXCEPTION 'Windows open only on an installed application''s database' USING ERRCODE = 'check_violation';
    END IF;
    IF p_mode = 'write' AND NOT dx_has_right('data.write') THEN
        RAISE EXCEPTION 'A write window is for a holder of data.write (a DBA)' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_mode = 'read' AND (NOT t.private_by_design OR NOT dx_has_right('data.read') OR dx_person_level(me, t.id) = 'structure') THEN
        RAISE EXCEPTION 'A read window is for a private-by-design database where you hold a level' USING ERRCODE = 'check_violation';
    END IF;
    IF p_minutes IS NULL OR p_minutes < 5 OR p_minutes > s.window_max_minutes THEN
        RAISE EXCEPTION 'A window lasts 5 to % minutes', s.window_max_minutes USING ERRCODE = 'check_violation';
    END IF;
    IF p_handoff_at IS NULL OR p_handoff_at < now() - make_interval(mins => s.step_up_minutes) OR p_handoff_at > now() + interval '1 minute' THEN
        RAISE EXCEPTION 'Open Developer again from the launcher first (a window needs a sign-on within % minutes)', s.step_up_minutes
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    selfok := app_is_super_admin();
    INSERT INTO access_windows (member_id, target_database_id, mode, reason, minutes, handoff_at, status, decided_by, decided_at, self_approved,
                                starts_at, expires_at)
    VALUES (me, t.id, p_mode, p_reason, p_minutes, p_handoff_at,
            CASE WHEN selfok THEN 'open' ELSE 'requested' END,
            CASE WHEN selfok THEN me END, CASE WHEN selfok THEN now() END, selfok,
            CASE WHEN selfok THEN now() END, CASE WHEN selfok THEN now() + make_interval(mins => p_minutes) END)
    RETURNING id INTO wid;
    RETURN wid;
END$$;

-- Approve or refuse another person's window (window.approve — a super-admin's). A person never decides their own.
CREATE OR REPLACE FUNCTION dx_window_decide(p_window bigint, p_approve boolean, p_reason text DEFAULT NULL) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE w access_windows%ROWTYPE;
BEGIN
    IF NOT dx_has_right('window.approve') THEN
        RAISE EXCEPTION '%', COALESCE(dx_right_refusal('window.approve'), 'You may not decide windows') USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT * INTO w FROM access_windows WHERE id = p_window FOR UPDATE;
    IF NOT FOUND OR w.status <> 'requested' THEN RAISE EXCEPTION 'That window is not awaiting a decision' USING ERRCODE = 'check_violation'; END IF;
    IF w.member_id = app_current_member_id() THEN RAISE EXCEPTION 'Nobody decides their own window' USING ERRCODE = 'check_violation'; END IF;
    IF (SELECT frozen FROM dx_settings WHERE id = 1) AND p_approve THEN
        RAISE EXCEPTION 'Developer is frozen: no window opens' USING ERRCODE = 'insufficient_privilege';
    END IF;
    UPDATE access_windows SET status = CASE WHEN p_approve THEN 'open' ELSE 'refused' END, decided_by = app_current_member_id(), decided_at = now(),
           decision_reason = p_reason,
           starts_at = CASE WHEN p_approve THEN now() END,
           expires_at = CASE WHEN p_approve THEN now() + make_interval(mins => w.minutes) END
     WHERE id = p_window;
END$$;

-- End a window: its holder at any time, a super-admin any window. Withdraw a request the same way.
CREATE OR REPLACE FUNCTION dx_window_end(p_window bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE w access_windows%ROWTYPE; me bigint := app_current_member_id();
BEGIN
    SELECT * INTO w FROM access_windows WHERE id = p_window FOR UPDATE;
    IF NOT FOUND OR w.status NOT IN ('requested', 'open') THEN RAISE EXCEPTION 'That window is not open' USING ERRCODE = 'check_violation'; END IF;
    IF w.member_id <> me AND NOT app_is_super_admin() THEN RAISE EXCEPTION 'Only its holder or a super-admin ends a window' USING ERRCODE = 'insufficient_privilege'; END IF;
    UPDATE access_windows SET status = CASE WHEN w.status = 'requested' THEN 'withdrawn' ELSE 'ended' END, ended_at = now(),
           ended_by_kind = CASE WHEN w.member_id = me THEN 'member' ELSE 'admin' END, ended_by = me
     WHERE id = p_window;
END$$;

-- The worker's pass: open windows past expires_at end (ended_by_kind expiry). Returns how many.
CREATE OR REPLACE FUNCTION dx_windows_expire(p_now timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
    UPDATE access_windows SET status = 'expired', ended_at = p_now, ended_by_kind = 'expiry' WHERE status = 'open' AND expires_at <= p_now;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

-- THE FREEZE (design §3 wall 8): set or lift by a super-admin (`freeze`), with a reason; freezing ends every open window and refuses every
-- pending one. The door reads `frozen` through dx_door_policy() and closes its own connections.
CREATE OR REPLACE FUNCTION dx_freeze(p_on boolean, p_reason text DEFAULT NULL) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT dx_has_right('freeze') THEN
        RAISE EXCEPTION '%', COALESCE(dx_right_refusal('freeze'), 'You may not freeze Developer') USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_on THEN
        UPDATE dx_settings SET frozen = true, frozen_by = app_current_member_id(), frozen_at = now(), frozen_reason = p_reason WHERE id = 1;
        UPDATE access_windows SET status = 'ended', ended_at = now(), ended_by_kind = 'freeze', ended_by = app_current_member_id() WHERE status = 'open';
        UPDATE access_windows SET status = 'refused', decided_by = app_current_member_id(), decided_at = now(), decision_reason = 'frozen' WHERE status = 'requested';
    ELSE
        UPDATE dx_settings SET frozen = false, frozen_by = NULL, frozen_at = NULL, frozen_reason = NULL WHERE id = 1;
    END IF;
END$$;

-- ------------------------------------------------------------------------------------------------- favourites and recents (by address)
CREATE TABLE favourites (
    member_id          bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    obj_type           text NOT NULL,                                  -- pg_identify_object_as_address(): type
    obj_names          text[] NOT NULL,                                --   object_names
    obj_args           text[] NOT NULL DEFAULT '{}',                    --   object_args
    label              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (member_id, target_database_id, obj_type, obj_names, obj_args)
);
CREATE TABLE recents (
    member_id          bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_database_id bigint NOT NULL REFERENCES target_databases(id) ON DELETE CASCADE,
    obj_type           text NOT NULL,
    obj_names          text[] NOT NULL,
    obj_args           text[] NOT NULL DEFAULT '{}',
    visited_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (member_id, target_database_id, obj_type, obj_names, obj_args)
);
CREATE INDEX recents_member_time_idx ON recents (member_id, visited_at DESC);

-- ------------------------------------------------------------------------------------------------- the levels and the policy
-- A PERSON's level on a target (never an agent's — an agent reads no rows): structure, masked or rows — from the live target_access rows
-- naming the person or one of their roles; `rows` only while they hold data.unmask; nothing beyond structure without data.read; a
-- private-by-design target's rows only inside an open read window. One query each step; no visible set computed.
CREATE OR REPLACE FUNCTION dx_person_level(p_member bigint, p_target bigint) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE best text; t target_databases%ROWTYPE; roles text[];
BEGIN
    SELECT * INTO t FROM target_databases WHERE id = p_target AND gone_at IS NULL;
    IF NOT FOUND OR t.class NOT IN ('application', 'development') THEN RETURN 'structure'; END IF;
    IF NOT dx_member_has_right(p_member, 'data.read') THEN RETURN 'structure'; END IF;
    roles := dx_member_roles(p_member);
    SELECT CASE WHEN bool_or(a.level = 'rows') THEN 'rows' WHEN bool_or(a.level = 'masked') THEN 'masked' END INTO best
      FROM target_access a
     WHERE a.target_database_id = p_target AND a.revoked_at IS NULL
       AND ((a.principal_kind = 'member' AND a.member_id = p_member) OR (a.principal_kind = 'role' AND a.role_key = ANY (roles)));
    IF best = 'rows' AND NOT dx_member_has_right(p_member, 'data.unmask') THEN best := 'masked'; END IF;
    RETURN COALESCE(best, 'structure');
END$$;

-- The open window of a mode for a person on a target, or NULL.
CREATE OR REPLACE FUNCTION dx_open_window(p_member bigint, p_target bigint, p_mode text) RETURNS bigint
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT w.id FROM access_windows w
     WHERE w.member_id = p_member AND w.target_database_id = p_target AND w.mode = p_mode AND w.status = 'open' AND w.expires_at > now()
     ORDER BY w.expires_at DESC LIMIT 1;
$$;

-- Is the door's caller someone who belongs here (active, admitted, with a role)? The door's first question.
CREATE OR REPLACE FUNCTION dx_door_member_active(p_member bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM members m WHERE m.id = p_member AND m.status = 'active' AND m.capability IS NOT NULL)
       AND cardinality(dx_member_roles(p_member)) > 0;
$$;

-- THE ONE PLACE DESIGN §3 IS COMPILED. The door asks it before every request (caller = the member the request names; on_behalf_of =
-- K38's person when an agent acts in a chat turn; datname = the target). It answers what the door enforces — and the door's tiers'
-- privileges enforce it again. Never raises for an ordinary refusal: `ok` false with `refusal` {rule, message}. The shape is the door's
-- contract (services/door/policy.py, proven by tests/door/):
--   {ok, refusal: null|{rule, message}, frozen,
--    caller: {member_id, is_agent, active, is_super_admin, roles[]}, on_behalf_of: null|{member_id, active, level},
--    target: {id, datname, class, application_key, private_by_design, grants_state},
--    rights: [the rights the caller holds — roles × held_by; an agent in a chat turn intersected with the person's],
--    level: structure|masked|rows (an agent: structure — wall 6), window: {read: null|{id, expires_at}, write: null|{id, expires_at}},
--    workbench: null|{id, owner_member_id, role, suspended}, limits: {statement_timeout_ms, lock_timeout_ms, idle_in_tx_ms,
--    transaction_timeout_ms, show_rows, show_bytes, cell_chars, concurrent_runs, change_set_confirm_rows, change_set_max_rows,
--    workbenches_left},
--    and, for the screens: ceiling {structure, rows, dml: never|window|live, ddl: never|draft|live}, tiers[]}
CREATE OR REPLACE FUNCTION dx_door_refusal(p_rule text, p_message text, p_frozen boolean) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('ok', false, 'refusal', jsonb_build_object('rule', p_rule, 'message', p_message), 'frozen', p_frozen);
$$;

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
                                     'private_by_design', t.private_by_design, 'grants_state', t.grants_state),
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

GRANT SELECT, INSERT, UPDATE ON target_databases, target_access, access_windows TO developer_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON favourites, recents TO developer_rw;
GRANT EXECUTE ON FUNCTION dx_propose_class(text, boolean, text[], text), dx_person_level(bigint, bigint), dx_open_window(bigint, bigint, text),
    dx_door_member_active(bigint) TO developer_rw, developer_records_ro;
REVOKE ALL ON FUNCTION dx_window_request(bigint, text, integer, text, timestamptz), dx_window_decide(bigint, boolean, text), dx_window_end(bigint),
    dx_windows_expire(timestamptz), dx_freeze(boolean, text), dx_door_policy(bigint, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dx_door_refusal(text, text, boolean) TO developer_rw;
GRANT EXECUTE ON FUNCTION dx_window_request(bigint, text, integer, text, timestamptz), dx_window_decide(bigint, boolean, text), dx_window_end(bigint),
    dx_windows_expire(timestamptz), dx_freeze(boolean, text), dx_door_policy(bigint, bigint, text) TO developer_rw;

COMMIT;
