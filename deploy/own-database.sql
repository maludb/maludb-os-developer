-- Developer — the tool's own database, after the installer's apply (deploy/ROOT_STEPS.sh step 11). NOTHING HERE HAS BEEN RUN — the
-- owner runs it as postgres, idempotent, every apply:
--
--   sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d subello_developer -f deploy/own-database.sql
--
-- 1. pg_stat_statements: created ONCE, here — one database suffices, its view covers the whole cluster (design §6.7); read by
--    developer_meta through pg_monitor (the statistics screens and top_statements).
-- 2. The door's own login into this database is developer_meta (it is in the door's passfile): CONNECT, and EXECUTE on the functions
--    the schema names for the door — dx_door_policy() (the ONE place design §3 is compiled) and the audit-writing functions (intent and
--    result rows, the per-day counters). Granted by name, only for those that exist, so this file runs before and after the schema's
--    later migrations.
-- 3. The grants service reads its plan as developer_grantor: CONNECT and SELECT on mcp_grant_plan (design §6.1 says "as
--    developer_records_ro" — that password is the installer's and rotates with --rotate-db-passwords, so the grants service reads with
--    its own login instead; see the branch's report).
-- 4. dx_signal(pid, kind) — the only way the tool cancels or terminates a session (design §6.1): SECURITY DEFINER, owned by the NOLOGIN
--    role developer_signaller (pg_signal_backend + pg_read_all_stats, ROOT_STEPS step 4), search_path pinned with pg_temp last, EXECUTE
--    revoked from PUBLIC and granted to developer_ops alone. It reads the registry (target_databases: datname, class — db/006+).
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- developer_meta is the catalog tier everywhere (default_transaction_read_only = on), but on the tool's OWN database it writes the audit
-- through the dx_door_* functions (the door proof's finding 7): the read-only default is lifted for this one database.
SELECT format('ALTER ROLE developer_meta IN DATABASE %I SET default_transaction_read_only = off', current_database()) \gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO developer_meta, developer_grantor, developer_signaller', current_database()) \gexec
GRANT USAGE ON SCHEMA public TO developer_meta, developer_grantor, developer_signaller;

DO $$
DECLARE f regprocedure;
BEGIN
    FOR f IN
        SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname IN ('dx_door_policy', 'dx_door_run_open', 'dx_door_run_close', 'dx_door_job_update',
                                                      'dx_door_statement_log', 'dx_door_usage_bump', 'dx_door_member_active')
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO developer_meta', f);
        RAISE NOTICE 'door: EXECUTE on % for developer_meta', f;
    END LOOP;
    IF to_regclass('public.mcp_grant_plan') IS NOT NULL THEN
        GRANT SELECT ON public.mcp_grant_plan, public.mcp_grant_targets TO developer_grantor;
        IF to_regprocedure('public.dx_grants_pass_log(text, jsonb)') IS NOT NULL THEN
            GRANT EXECUTE ON FUNCTION public.dx_grants_pass_log(text, jsonb) TO developer_grantor;   -- the grants service records each pass
        END IF;
        RAISE NOTICE 'grants service: SELECT on mcp_grant_plan for developer_grantor';
    ELSE
        RAISE NOTICE 'mcp_grant_plan does not exist yet (the schema) — run this file again after the next apply';
    END IF;
    IF to_regclass('public.target_databases') IS NOT NULL THEN
        GRANT SELECT (datname, class) ON public.target_databases TO developer_signaller;
    END IF;
END $$;

DO $$
BEGIN
    IF to_regclass('public.target_databases') IS NULL THEN
        RAISE NOTICE 'target_databases does not exist yet (the schema) — dx_signal() is created on the next run';
        RETURN;
    END IF;
    EXECUTE $fn$
    CREATE OR REPLACE FUNCTION public.dx_signal(p_pid integer, p_kind text) RETURNS boolean
        LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $body$
    DECLARE s record; cls text;
    BEGIN
        IF p_kind NOT IN ('cancel', 'terminate') THEN
            RAISE EXCEPTION 'kind is cancel or terminate' USING ERRCODE = '22023';
        END IF;
        SELECT a.pid, a.datname, a.application_name, coalesce(r.rolsuper, false) AS rolsuper
          INTO s FROM pg_stat_activity a LEFT JOIN pg_roles r ON r.oid = a.usesysid WHERE a.pid = p_pid;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'no session with pid %', p_pid USING ERRCODE = 'P0002';
        END IF;
        IF s.rolsuper THEN
            RAISE EXCEPTION 'a superuser''s session — cancel it from psql as postgres' USING ERRCODE = '42501';
        END IF;
        -- the tool's own services' connections (application_name developer-door…, developer-grants…) are never signalled;
        -- a person's run through the door (developer:<member>:<run>) is cancelled by the door's own cancel, not here
        IF s.application_name LIKE 'developer-%' OR s.application_name LIKE 'developer:%' THEN
            RAISE EXCEPTION 'a session of Developer itself — use Cancel on its run' USING ERRCODE = '42501';
        END IF;
        SELECT t.class INTO cls FROM public.target_databases t WHERE t.datname = s.datname;
        IF cls IS NULL OR cls NOT IN ('application', 'development', 'workbench') THEN
            RAISE EXCEPTION 'sessions on % are shown, never signalled (class %)', coalesce(s.datname, '(no database)'), coalesce(cls, 'unregistered')
                USING ERRCODE = '42501';
        END IF;
        IF p_kind = 'cancel' THEN
            RETURN pg_cancel_backend(p_pid);
        END IF;
        RETURN pg_terminate_backend(p_pid);
    END
    $body$
    $fn$;
    ALTER FUNCTION public.dx_signal(integer, text) OWNER TO developer_signaller;
    REVOKE ALL ON FUNCTION public.dx_signal(integer, text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION public.dx_signal(integer, text) TO developer_ops;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO developer_ops', current_database());
    GRANT USAGE ON SCHEMA public TO developer_ops;
END $$;
